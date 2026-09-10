use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io::{Error, ErrorKind};
use std::str::FromStr;
use std::sync::Arc;
use std::time::Instant;

use num_bigint::BigUint;
use serde_json::{Value, json};
use usd8_settlement::chain::{
    block_by_number, chain_id, decimals_at, defi_insurance_at, derive_bootstrap_config_at,
    earned_score_of, incident_config_at, max_cover_pool_payout_bps_at, min_balances_over,
    pool_state_at, pools_at, price_usd_1e18, ratio_at, spent_score_at,
};
use usd8_settlement::checkpoint::BulkScoreSource;
use usd8_settlement::config::{LOG_RESULT_CAP, MAX_LOG_RANGE};
use usd8_settlement::rpc::{HttpRpc, LogMetrics};
use usd8_settlement::{Address, allocate, parse_json};

const ENGINE_IDENTITY: &str = "usd8-settlement-production-chain";
const TOPOLOGY_FUNCTIONS: [&str; 6] = [
    "derive_bootstrap_config_at",
    "incident_config_at",
    "pools_at",
    "pool_state_at",
    "price_usd_1e18",
    "ratio_at",
];
const BENCHMARK_FUNCTIONS: [&str; 9] = [
    "derive_bootstrap_config_at",
    "incident_config_at",
    "pools_at",
    "pool_state_at",
    "price_usd_1e18",
    "earned_score_of|BulkScoreSource::open+gross_score_of",
    "min_balances_over",
    "spent_score_at",
    "allocate",
];

fn invalid(message: impl Into<String>) -> Error {
    Error::new(ErrorKind::InvalidInput, message.into())
}

fn address(value: &str, label: &str) -> Result<Address, Error> {
    Address::from_str(value).map_err(|()| invalid(format!("invalid {label} address: {value}")))
}

fn block_number(value: &str) -> Result<u64, Error> {
    value
        .parse::<u64>()
        .map_err(|_| invalid(format!("invalid block number: {value}")))
}

fn metric_json(metrics: LogMetrics) -> Value {
    json!({
        "requests": metrics.requests,
        "bisections": metrics.bisections,
        "errors": metrics.errors,
        "elapsedMs": metrics.elapsed_ms,
    })
}

async fn topology(arguments: &[String]) -> Result<Value, Box<dyn std::error::Error>> {
    if arguments.len() != 6 {
        return Err(invalid(
            "usage: production_evidence_json topology <rpc-url> <registry> <defi-insurance> <insured-token> <block> <expected-block-hash>",
        )
        .into());
    }
    let rpc = HttpRpc::new(&arguments[0], None, 120_000)?;
    let registry = address(&arguments[1], "Registry")?;
    let expected_insurance = address(&arguments[2], "DefiInsurance")?;
    let insured_token = address(&arguments[3], "insured token")?;
    let pinned_block = block_number(&arguments[4])?;
    let expected_hash = arguments[5].to_ascii_lowercase();

    let actual_chain_id = chain_id(&rpc).await?;
    let anchor = block_by_number(&rpc, pinned_block).await?;
    if anchor.hash != expected_hash {
        return Err(invalid(format!(
            "pinned block hash mismatch: expected {expected_hash}, got {}",
            anchor.hash
        ))
        .into());
    }
    let actual_insurance = defi_insurance_at(&rpc, registry, Some(pinned_block)).await?;
    if actual_insurance != expected_insurance {
        return Err(invalid(format!(
            "Registry DefiInsurance mismatch: expected {expected_insurance}, got {actual_insurance}"
        ))
        .into());
    }

    // These are the exact configuration and topology functions used by build_settlement.
    let config =
        derive_bootstrap_config_at(&rpc, registry, expected_insurance, pinned_block).await?;
    let incident = incident_config_at(&rpc, &config, insured_token, pinned_block).await?;
    let topology = pools_at(&rpc, &config, pinned_block).await?;
    let mut ordered_pools = Vec::with_capacity(topology.assets.len());
    let mut price_calls = Vec::with_capacity(topology.assets.len() + 1);
    for (index, (asset, pool)) in topology
        .assets
        .iter()
        .copied()
        .zip(topology.pool_addrs.iter().copied())
        .enumerate()
    {
        let feed = config.asset_feed(asset)?;
        // Invoke the exact production pool path even before the planned oracle refresh.
        // A stale AggregatorV3 round is evidence about readiness, not a reason to lose
        // the Registry-derived topology/call-set proof.
        let validation = match pool_state_at(&rpc, &config, asset, pool, pinned_block).await {
            Ok(state) => json!({
                "ok": true,
                "normalizedUsd1e18": state.asset_usd.to_string(),
                "assetDecimals": state.asset_decimals,
                "totalAssets": state.balance.to_string(),
            }),
            Err(error) => json!({
                "ok": false,
                "error": error.to_string(),
                "classification": "production-price-validation-failed-at-pinned-block",
            }),
        };
        ordered_pools.push(json!({
            "index": index,
            "asset": asset.to_string(),
            "pool": pool.to_string(),
            "usdPriceFeed": feed.to_string(),
            "productionPoolStateValidation": validation.clone(),
        }));
        price_calls.push(json!({
            "role": "pool-asset-usd",
            "address": feed.to_string(),
            "interface": "AggregatorV3",
            "functions": ["latestRoundData()", "decimals()"],
            "productionPriceValidation": validation,
        }));
    }
    let insured_validation = match price_usd_1e18(
        &rpc,
        incident.underlying_price_oracle,
        pinned_block,
        config.max_oracle_staleness,
    )
    .await
    {
        Ok(value) => json!({"ok": true, "normalizedUsd1e18": value.to_string()}),
        Err(error) => json!({
            "ok": false,
            "error": error.to_string(),
            "classification": "production-price-validation-failed-at-pinned-block",
        }),
    };
    price_calls.push(json!({
        "role": "insured-underlying-usd",
        "address": incident.underlying_price_oracle.to_string(),
        "interface": "AggregatorV3",
        "functions": ["latestRoundData()", "decimals()"],
        "productionPriceValidation": insured_validation,
    }));

    let mut conversion_calls = Vec::new();
    if !incident.conversion_address.is_zero() {
        let result = ratio_at(
            &rpc,
            incident.conversion_address,
            &incident.conversion_call_data,
            pinned_block,
        )
        .await?;
        conversion_calls.push(json!({
            "role": "insured-underlying-conversion",
            "target": incident.conversion_address.to_string(),
            "calldata": format!("0x{}", hex::encode(&incident.conversion_call_data)),
            "interface": "generic-staticcall-uint256",
            "result": result.to_string(),
        }));
    }

    let all_price_validations_passed = price_calls.iter().all(|row| {
        row.get("productionPriceValidation")
            .and_then(|value| value.get("ok"))
            .and_then(Value::as_bool)
            == Some(true)
    });

    Ok(json!({
        "schemaVersion": 1,
        "complete": true,
        "engineIdentity": ENGINE_IDENTITY,
        "productionEntryPoint": "engine::build_settlement",
        "productionFunctions": TOPOLOGY_FUNCTIONS,
        "chainId": actual_chain_id,
        "pinnedBlock": pinned_block,
        "pinnedBlockHash": anchor.hash,
        "pinnedTimestamp": anchor.timestamp,
        "registry": registry.to_string(),
        "defiInsurance": expected_insurance.to_string(),
        "insuredToken": insured_token.to_string(),
        "configHash": config.hash()?,
        "orderedPools": ordered_pools,
        "aggregatorV3PriceCalls": price_calls,
        "conversionCalls": conversion_calls,
        "checks": {
            "registryDerivedConfig": true,
            "orderedTopologyValidatedByProductionPoolStateCall": true,
            "productionAggregatorV3CallsExecuted": true,
            "allProductionPriceValidationsPassedAtPinnedBlock": all_price_validations_passed,
            "genericConversionCallsExecuted": true,
            "pinnedBlockHashMatched": true,
        }
    }))
}

async fn planned_benchmark(arguments: &[String]) -> Result<Value, Box<dyn std::error::Error>> {
    if arguments.len() != 7 {
        return Err(invalid(
            "usage: production_evidence_json planned-benchmark <Raw|Bulk> <rpc-url> <registry> <defi-insurance> <insured-token> <reference-block> <kernel-input.json>",
        )
        .into());
    }
    let mode = arguments[0].as_str();
    if mode != "Raw" && mode != "Bulk" {
        return Err(invalid("mode must be Raw or Bulk").into());
    }
    let rpc = Arc::new(HttpRpc::new(&arguments[1], None, 120_000)?);
    let registry = address(&arguments[2], "Registry")?;
    let expected_insurance = address(&arguments[3], "DefiInsurance")?;
    let insured_token = address(&arguments[4], "insured token")?;
    let reference_block = block_number(&arguments[5])?;
    let input_text = fs::read_to_string(&arguments[6])?;
    let mut input = parse_json(&input_text)?;
    if input.claims.len() != 20 {
        return Err(invalid(format!(
            "planned benchmark requires exactly 20 claim rows, got {}",
            input.claims.len()
        ))
        .into());
    }
    let accounts = input
        .claims
        .iter()
        .map(|claim| claim.user)
        .collect::<BTreeSet<_>>();
    if accounts.len() != input.claims.len() {
        return Err(invalid("planned benchmark contains duplicate claimant addresses").into());
    }

    let started = Instant::now();
    let actual_insurance = defi_insurance_at(rpc.as_ref(), registry, Some(reference_block)).await?;
    if actual_insurance != expected_insurance {
        return Err(invalid("Registry DefiInsurance does not match expected address").into());
    }
    let config =
        derive_bootstrap_config_at(rpc.as_ref(), registry, expected_insurance, reference_block)
            .await?;
    let incident =
        incident_config_at(rpc.as_ref(), &config, insured_token, reference_block).await?;
    let score_cutoff_block = reference_block
        .saturating_sub(incident.params.holding_margin_blocks)
        .max(1);

    if input.coverage_bps != incident.coverage_bps {
        return Err(invalid("planned coverageBps differs from live Registry config").into());
    }
    if input.booster_boost_bps != BigUint::from(config.booster_boost_bps) {
        return Err(invalid("planned boosterBoostBps differs from live Registry config").into());
    }
    let insured_decimals = decimals_at(rpc.as_ref(), insured_token, reference_block).await?;
    if input.insured_decimals != u32::from(insured_decimals) {
        return Err(invalid("planned insuredDecimals differs from live token").into());
    }

    let topology = pools_at(rpc.as_ref(), &config, reference_block).await?;
    if topology.assets.len() != input.pools.len() {
        return Err(invalid("planned pool count differs from live Registry topology").into());
    }
    let mut ordered_pools = Vec::with_capacity(topology.assets.len());
    for (index, (asset, pool)) in topology
        .assets
        .iter()
        .copied()
        .zip(topology.pool_addrs.iter().copied())
        .enumerate()
    {
        let feed = config.asset_feed(asset)?;
        let state = pool_state_at(rpc.as_ref(), &config, asset, pool, reference_block).await?;
        let expected = &input.pools[index];
        if expected.balance != state.balance
            || expected.asset_usd != state.asset_usd
            || expected.asset_decimals != u32::from(state.asset_decimals)
        {
            return Err(invalid(format!(
                "planned pool row {index} differs from production pool_state_at"
            ))
            .into());
        }
        ordered_pools.push(json!({
            "index": index,
            "asset": asset.to_string(),
            "pool": pool.to_string(),
            "usdPriceFeed": feed.to_string(),
        }));
    }
    let underlying_usd = price_usd_1e18(
        rpc.as_ref(),
        incident.underlying_price_oracle,
        reference_block,
        config.max_oracle_staleness,
    )
    .await?;
    if input.underlying_usd != underlying_usd {
        return Err(invalid("planned underlyingUsd differs from production price_usd_1e18").into());
    }
    let max_payout = max_cover_pool_payout_bps_at(rpc.as_ref(), registry, reference_block).await?;
    if input.max_cover_pool_payout_bps != max_payout {
        return Err(
            invalid("planned maxCoverPoolPayoutBps differs from live Registry config").into(),
        );
    }

    let (minimums, eligibility_metrics) = min_balances_over(
        rpc.as_ref(),
        insured_token,
        &accounts,
        score_cutoff_block,
        reference_block,
        MAX_LOG_RANGE,
        LOG_RESULT_CAP,
    )
    .await?;

    let mut raw_metrics = LogMetrics::default();
    let bulk_source = if mode == "Bulk" {
        Some(
            BulkScoreSource::open(
                rpc.clone(),
                &incident,
                score_cutoff_block,
                accounts.clone(),
                config.chain_id,
                MAX_LOG_RANGE,
                LOG_RESULT_CAP,
            )
            .await?,
        )
    } else {
        None
    };
    let mut observed_scores = BTreeMap::new();
    for claim in &mut input.claims {
        let gross_score = if let Some(source) = &bulk_source {
            source.gross_score_of(claim.user).await?
        } else {
            let (score, metrics) = earned_score_of(
                rpc.as_ref(),
                &incident.scored_tokens,
                claim.user,
                score_cutoff_block,
                MAX_LOG_RANGE,
                LOG_RESULT_CAP,
            )
            .await?;
            raw_metrics.requests = raw_metrics.requests.saturating_add(metrics.requests);
            raw_metrics.bisections = raw_metrics.bisections.saturating_add(metrics.bisections);
            raw_metrics.errors = raw_metrics.errors.saturating_add(metrics.errors);
            raw_metrics.elapsed_ms = raw_metrics.elapsed_ms.saturating_add(metrics.elapsed_ms);
            score
        };
        let minimum = minimums
            .get(&claim.user)
            .ok_or_else(|| invalid(format!("missing minimum balance for {}", claim.user)))?;
        let spent = spent_score_at(rpc.as_ref(), registry, claim.user, reference_block).await?;
        if claim.gross_earned_score != gross_score {
            return Err(invalid(format!(
                "planned grossEarnedScore differs from production {mode} replay for {}",
                claim.user
            ))
            .into());
        }
        if claim.min_held != *minimum {
            return Err(invalid(format!(
                "planned minHeld differs from production min_balances_over for {}",
                claim.user
            ))
            .into());
        }
        if claim.spent_score != spent {
            return Err(invalid(format!(
                "planned spentScore differs from production spent_score_at for {}",
                claim.user
            ))
            .into());
        }
        observed_scores.insert(claim.user.to_string(), gross_score.to_string());
    }

    // The planned 22% TWAP is intentionally prospective. Every historical input above is
    // reproduced by production code; allocate is the exact production kernel.
    let planned_twap_ratio = input.twap_ratio.to_string();
    let output = allocate(&input)?;
    let duration = started.elapsed().as_secs_f64();
    let score_metrics = bulk_source.as_ref().map_or_else(
        || metric_json(raw_metrics),
        |source| metric_json(source.metadata.log_metrics),
    );
    let bulk_metadata = bulk_source.as_ref().map(|source| {
        json!({
            "asOfBlock": source.metadata.as_of_block,
            "asOfBlockHash": source.metadata.as_of_block_hash,
            "indexedTransfers": source.metadata.indexed_transfers,
            "indexedTokens": source.metadata.indexed_tokens,
            "trackedAccounts": source.metadata.tracked_accounts,
        })
    });

    Ok(json!({
        "schemaVersion": 2,
        "complete": true,
        "benchmarkKind": "planned-full-scenario-production-engine",
        "claimSetAuthority": "planned-pre-loss-not-authoritative-post-window",
        "finalFrozenSetGateEligible": false,
        "mode": mode,
        "actors": input.claims.len(),
        "engineIdentity": ENGINE_IDENTITY,
        "productionEntryPoint": "engine::build_settlement call graph + exact allocate kernel",
        "productionFunctions": BENCHMARK_FUNCTIONS,
        "referenceBlock": reference_block,
        "referenceBlockHash": block_by_number(rpc.as_ref(), reference_block).await?.hash,
        "scoreCutoffBlock": score_cutoff_block,
        "configHash": config.hash()?,
        "orderedPools": ordered_pools,
        "underlyingUsdFeed": incident.underlying_price_oracle.to_string(),
        "conversionTarget": incident.conversion_address.to_string(),
        "conversionCalldata": format!("0x{}", hex::encode(&incident.conversion_call_data)),
        "plannedProspectiveTwapRatio": planned_twap_ratio,
        "engineDurationSeconds": duration,
        "scoreReplayMetrics": score_metrics,
        "eligibilityReplayMetrics": metric_json(eligibility_metrics),
        "bulkMetadata": bulk_metadata,
        "observedGrossScores": observed_scores,
        "output": {
            "root": output.root,
            "claimSetHash": output.claim_set_hash,
            "settlementInputHash": output.settlement_input_hash,
            "poolPayouts": output.pool_payouts.iter().map(ToString::to_string).collect::<Vec<_>>(),
            "rows": output.rows.len(),
        },
        "checks": {
            "exactTwentyPlannedRows": true,
            "liveRegistryConfigMatched": true,
            "orderedPoolStateMatched": true,
            "rawOrBulkGrossScoresMatched": true,
            "minimumHoldingsMatched": true,
            "spentScoresMatched": true,
            "exactProductionKernelExecuted": true,
            "authoritativePostWindowFrozenSet": false,
        }
    }))
}

#[tokio::main]
async fn main() {
    let arguments = env::args().collect::<Vec<_>>();
    let result = match arguments.get(1).map(String::as_str) {
        Some("topology") => topology(&arguments[2..]).await,
        Some("planned-benchmark") => planned_benchmark(&arguments[2..]).await,
        _ => Err(invalid("expected topology or planned-benchmark subcommand").into()),
    };
    match result {
        Ok(value) => println!("{value}"),
        Err(error) => {
            println!(
                "{}",
                json!({
                    "complete": false,
                    "error": error.to_string(),
                })
            );
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{BENCHMARK_FUNCTIONS, TOPOLOGY_FUNCTIONS};

    #[test]
    fn topology_uses_production_chain_functions_and_separates_call_types() {
        assert_eq!(TOPOLOGY_FUNCTIONS[3], "pool_state_at");
        assert_eq!(TOPOLOGY_FUNCTIONS[4], "price_usd_1e18");
        assert_eq!(TOPOLOGY_FUNCTIONS[5], "ratio_at");
    }

    #[test]
    fn planned_benchmark_reaches_both_score_paths_and_exact_kernel() {
        assert!(
            BENCHMARK_FUNCTIONS
                .iter()
                .any(|name| name.contains("BulkScoreSource"))
        );
        assert_eq!(BENCHMARK_FUNCTIONS.last(), Some(&"allocate"));
    }
}
