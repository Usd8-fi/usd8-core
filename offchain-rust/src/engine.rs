use crate::chain::{
    BlockAnchor, ChainError, Incident, SettlementAnchors, assert_anchors_unchanged,
    assert_contract_code_at, booster_nft_at, chain_id, decimals_at, earned_score_of,
    finalized_settlement_anchors, incident_at, incident_config_at, max_cover_pool_payout_bps_at,
    min_balance_over, min_erc1155_balance_over, pool_state_at, pools_at, price_usd_1e18,
    read_input_events, spent_score_at, twap_ratio_before,
};
use crate::checkpoint::{CheckpointError, CheckpointScoreSource};
use crate::config::{BootstrapConfig, ConfigError};
use crate::rpc::{LogMetrics, Rpc, RpcMetrics};
use crate::typed_data::{SettlementDigestInput, TypedDataError, settlement_digest};
use crate::{
    Address, ClaimEvent, ClaimInput, EventKind, KernelError, KernelInput, KernelOutput, PoolInput,
    allocate_with_events, replay_claim_set,
};
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use thiserror::Error;

#[derive(Clone)]
pub enum ScoreMode {
    Raw,
    Checkpoint {
        path: PathBuf,
        integrity_key: Vec<u8>,
    },
}

impl std::fmt::Debug for ScoreMode {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Raw => formatter.write_str("Raw"),
            Self::Checkpoint { path, .. } => formatter
                .debug_struct("Checkpoint")
                .field("path", path)
                .field("integrity_key", &"[REDACTED]")
                .finish(),
        }
    }
}

#[derive(Debug, Error)]
pub enum EngineError {
    #[error(transparent)]
    Chain(#[from] ChainError),
    #[error(transparent)]
    Checkpoint(#[from] CheckpointError),
    #[error(transparent)]
    Config(#[from] ConfigError),
    #[error(transparent)]
    Kernel(#[from] KernelError),
    #[error(transparent)]
    TypedData(#[from] TypedDataError),
    #[error("settlement invariant failed: {0}")]
    Invariant(String),
}

#[derive(Clone, Debug)]
pub enum ScoreSourceMetadata {
    Raw {
        as_of_block: u64,
    },
    Checkpoint {
        path: PathBuf,
        as_of_block: u64,
        as_of_block_hash: String,
        indexed_transfers: usize,
        indexed_tokens: usize,
    },
}

#[derive(Clone, Debug)]
pub struct SettlementRun {
    pub incident_id: BigUint,
    pub incident: Incident,
    pub window_incident: Incident,
    pub latest_incident: Incident,
    pub anchors: SettlementAnchors,
    pub config_hash: String,
    pub pool_order: Vec<Address>,
    pub pool_addrs: Vec<Address>,
    pub twap_ratio: BigUint,
    pub underlying_usd: BigUint,
    pub events: Vec<ClaimEvent>,
    pub output: KernelOutput,
    pub digest: String,
    pub score_source: ScoreSourceMetadata,
    pub rpc_metrics: RpcMetrics,
    pub log_metrics: LogMetrics,
}

fn anchor_json(anchor: &BlockAnchor) -> Value {
    json!({
        "number": anchor.number.to_string(),
        "timestamp": anchor.timestamp.to_string(),
        "hash": anchor.hash,
    })
}

fn metrics_json(metrics: RpcMetrics) -> Value {
    json!({
        "logicalRequests": metrics.logical_requests,
        "transportAttempts": metrics.transport_attempts,
        "transportResponses": metrics.transport_responses,
        "transportRetries": metrics.transport_retries,
    })
}

fn log_metrics_json(metrics: LogMetrics) -> Value {
    json!({
        "requests": metrics.requests,
        "bisections": metrics.bisections,
        "errors": metrics.errors,
        "elapsedMs": metrics.elapsed_ms,
    })
}

impl SettlementRun {
    pub fn root_matches(&self) -> bool {
        self.output
            .root
            .eq_ignore_ascii_case(&self.latest_incident.root)
    }

    pub fn artifact(&self, config: &BootstrapConfig, include_proofs: bool) -> Value {
        let rows = self
            .output
            .rows
            .iter()
            .map(|row| {
                let mut value = json!({
                    "claimId": row.claim_id.to_string(),
                    "user": row.user.to_string(),
                    "escrowAmount": row.escrow_amount.to_string(),
                    "eligibleAmount": row.eligible_amount.to_string(),
                    "lossUsd": row.loss_usd.to_string(),
                    "grossEarnedScore": row.gross_earned_score.to_string(),
                    "earnedScore": row.earned_score.to_string(),
                    "scoreSpent": row.score_spent.to_string(),
                    "payoutUsd": row.payout_usd.to_string(),
                    "amounts": row.amounts.iter().map(ToString::to_string).collect::<Vec<_>>(),
                });
                if include_proofs {
                    value["proof"] = json!(
                        self.output
                            .proofs
                            .get(&row.claim_id)
                            .cloned()
                            .unwrap_or_default()
                    );
                }
                value
            })
            .collect::<Vec<_>>();
        let input_rows = self
            .output
            .rows
            .iter()
            .map(|row| {
                json!({
                    "user": row.user.to_string(),
                    "grossEarnedScore": row.gross_earned_score.to_string(),
                })
            })
            .collect::<Vec<_>>();
        let score_source = match &self.score_source {
            ScoreSourceMetadata::Raw { as_of_block } => {
                json!({ "kind": "raw-rpc", "asOfBlock": as_of_block.to_string() })
            }
            ScoreSourceMetadata::Checkpoint {
                path,
                as_of_block,
                as_of_block_hash,
                indexed_transfers,
                indexed_tokens,
            } => json!({
                "kind": "checkpoint",
                "path": path,
                "asOfBlock": as_of_block.to_string(),
                "asOfBlockHash": as_of_block_hash,
                "indexedTransfers": indexed_transfers,
                "indexedTokens": indexed_tokens,
            }),
        };
        json!({
            "schemaVersion": 1,
            "configVersion": config.version,
            "configHash": self.config_hash,
            "claimSetHash": self.output.claim_set_hash,
            "settlementInputHash": self.output.settlement_input_hash,
            "settlementInputRows": input_rows,
            "chainId": config.chain_id,
            "blockAnchors": {
                "finalizedHead": anchor_json(&self.anchors.finalized_head),
                "open": anchor_json(&self.anchors.open),
                "reference": anchor_json(&self.anchors.reference),
                "windowEnd": anchor_json(&self.anchors.window_end),
            },
            "rpcMetrics": metrics_json(self.rpc_metrics),
            "historicalLogMetrics": log_metrics_json(self.log_metrics),
            "scoreSource": score_source,
            "registry": config.registry.to_string(),
            "defiInsurance": config.defi_insurance.to_string(),
            "incidentId": self.incident_id.to_string(),
            "referenceBlock": self.incident.reference_block.to_string(),
            "windowEndBlock": self.anchors.window_end.number.to_string(),
            "twapRatio": self.twap_ratio.to_string(),
            "underlyingUsd": self.underlying_usd.to_string(),
            "root": self.output.root,
            "onchainRoot": self.latest_incident.root,
            "rootMatches": self.root_matches(),
            "settlementDigest": self.digest,
            "unresolved": self.window_incident.unresolved.to_string(),
            "poolOrder": self.pool_order.iter().map(ToString::to_string).collect::<Vec<_>>(),
            "poolAddrs": self.pool_addrs.iter().map(ToString::to_string).collect::<Vec<_>>(),
            "poolPayouts": self.output.pool_payouts.iter().map(ToString::to_string).collect::<Vec<_>>(),
            "rows": rows,
        })
    }
}

fn merge_metrics(left: LogMetrics, right: LogMetrics) -> LogMetrics {
    LogMetrics {
        requests: left.requests.saturating_add(right.requests),
        bisections: left.bisections.saturating_add(right.bisections),
        errors: left.errors.saturating_add(right.errors),
        elapsed_ms: left.elapsed_ms.saturating_add(right.elapsed_ms),
    }
}

async fn assert_code<R: Rpc + ?Sized>(
    rpc: &R,
    address: Address,
    label: &str,
    block: u64,
) -> Result<(), EngineError> {
    assert_contract_code_at(rpc, &address.to_string(), label, block).await?;
    Ok(())
}

fn assert_incident_anchors(
    provisional: &Incident,
    finalized: &Incident,
) -> Result<(), EngineError> {
    if provisional.insured_token != finalized.insured_token
        || provisional.claim_window_end_time != finalized.claim_window_end_time
        || provisional.reference_block != finalized.reference_block
        || provisional.open_block != finalized.open_block
    {
        return Err(EngineError::Invariant(format!(
            "provisional incident anchors differ from finalized state: provisional={provisional:?}, finalized={finalized:?}"
        )));
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
pub async fn build_settlement<R: Rpc + ?Sized>(
    rpc: Arc<R>,
    config: &BootstrapConfig,
    incident_id: BigUint,
    score_mode: ScoreMode,
) -> Result<SettlementRun, EngineError> {
    let actual_chain = chain_id(rpc.as_ref()).await?;
    if actual_chain != config.chain_id {
        return Err(EngineError::Invariant(format!(
            "wrong chain: RPC reports {actual_chain}, expected {}",
            config.chain_id
        )));
    }

    let provisional = incident_at(
        rpc.as_ref(),
        config.defi_insurance,
        incident_id.clone(),
        None,
    )
    .await?;
    if provisional.insured_token.is_zero() {
        return Err(EngineError::Invariant(format!(
            "incident {incident_id} does not exist"
        )));
    }
    let anchors = finalized_settlement_anchors(
        rpc.as_ref(),
        provisional.reference_block,
        provisional.open_block,
        provisional.claim_window_end_time,
    )
    .await?;
    let finalized_incident = incident_at(
        rpc.as_ref(),
        config.defi_insurance,
        incident_id.clone(),
        Some(anchors.finalized_head.number),
    )
    .await?;
    assert_incident_anchors(&provisional, &finalized_incident)?;
    assert_code(
        rpc.as_ref(),
        config.registry,
        "Registry",
        provisional.open_block,
    )
    .await?;
    assert_code(
        rpc.as_ref(),
        config.defi_insurance,
        "DefiInsurance",
        provisional.open_block,
    )
    .await?;
    assert_code(
        rpc.as_ref(),
        provisional.insured_token,
        "insured token",
        provisional.open_block,
    )
    .await?;

    let (events, event_metrics) = read_input_events(
        rpc.as_ref(),
        config.defi_insurance,
        &incident_id,
        provisional.open_block,
        anchors.window_end.number,
        config.max_log_range,
        config.log_result_cap as usize,
    )
    .await?;
    let window_incident = incident_at(
        rpc.as_ref(),
        config.defi_insurance,
        incident_id.clone(),
        Some(anchors.window_end.number),
    )
    .await?;
    let replay = replay_claim_set(&events)?;
    if BigUint::from(replay.unresolved) != window_incident.unresolved {
        return Err(EngineError::Invariant(format!(
            "unresolved claim count mismatch: replayed {}, on-chain {}",
            replay.unresolved, window_incident.unresolved
        )));
    }
    if !replay
        .hash
        .eq_ignore_ascii_case(&window_incident.claim_set_hash)
    {
        return Err(EngineError::Invariant(format!(
            "claim-set hash mismatch: replayed {}, on-chain {}",
            replay.hash, window_incident.claim_set_hash
        )));
    }

    let incident_config = incident_config_at(
        rpc.as_ref(),
        config,
        provisional.insured_token,
        provisional.open_block,
    )
    .await?;
    assert_code(
        rpc.as_ref(),
        incident_config.underlying_price_oracle,
        "underlying USD oracle",
        anchors.window_end.number,
    )
    .await?;
    if !incident_config.conversion_address.is_zero() {
        assert_code(
            rpc.as_ref(),
            incident_config.conversion_address,
            "underlying conversion",
            provisional.reference_block,
        )
        .await?;
    }
    for scored in &incident_config.scored_tokens {
        assert_code(
            rpc.as_ref(),
            scored.token,
            "scored token",
            provisional.reference_block,
        )
        .await?;
    }

    let insured_decimals = decimals_at(
        rpc.as_ref(),
        provisional.insured_token,
        provisional.open_block,
    )
    .await?;
    let topology = pools_at(rpc.as_ref(), config, provisional.open_block).await?;
    let mut pools = Vec::with_capacity(topology.pool_addrs.len());
    for (index, (asset, pool)) in topology
        .assets
        .iter()
        .copied()
        .zip(topology.pool_addrs.iter().copied())
        .enumerate()
    {
        let feed = config.asset_feed(&asset.to_string())?;
        assert_code(
            rpc.as_ref(),
            pool,
            &format!("cover pool {index}"),
            provisional.open_block,
        )
        .await?;
        assert_code(
            rpc.as_ref(),
            asset,
            &format!("pool asset {index}"),
            anchors.window_end.number,
        )
        .await?;
        assert_code(
            rpc.as_ref(),
            feed,
            &format!("USD feed for pool asset {index}"),
            anchors.window_end.number,
        )
        .await?;
        let state =
            pool_state_at(rpc.as_ref(), config, asset, pool, anchors.window_end.number).await?;
        pools.push(PoolInput {
            balance: state.balance,
            asset_usd: state.asset_usd,
            asset_decimals: u32::from(state.asset_decimals),
        });
    }
    let booster_collection =
        booster_nft_at(rpc.as_ref(), config.registry, provisional.open_block).await?;
    if !booster_collection.is_zero() {
        assert_code(
            rpc.as_ref(),
            booster_collection,
            "booster ERC1155",
            provisional.open_block,
        )
        .await?;
    }
    let max_payout_bps =
        max_cover_pool_payout_bps_at(rpc.as_ref(), config.registry, provisional.open_block).await?;
    if max_payout_bps > BigUint::from(10_000u16) {
        return Err(EngineError::Invariant(format!(
            "maxCoverPoolPayoutBps exceeds 10000: {max_payout_bps}"
        )));
    }
    let twap_ratio =
        twap_ratio_before(rpc.as_ref(), &incident_config, provisional.reference_block).await?;
    let underlying_usd = price_usd_1e18(
        rpc.as_ref(),
        incident_config.underlying_price_oracle,
        anchors.window_end.number,
        config.max_oracle_staleness,
    )
    .await?;

    let (mut checkpoint_source, checkpoint_integrity_key) = match score_mode {
        ScoreMode::Raw => (None, None),
        ScoreMode::Checkpoint {
            path,
            integrity_key,
        } => {
            let source = CheckpointScoreSource::open(
                rpc.clone(),
                &incident_config,
                provisional.reference_block,
                path,
                config.chain_id,
                &integrity_key,
                config.max_log_range,
                config.log_result_cap as usize,
            )
            .await?;
            (Some(source), Some(integrity_key))
        }
    };
    let score_source = checkpoint_source.as_ref().map_or(
        ScoreSourceMetadata::Raw {
            as_of_block: provisional.reference_block,
        },
        |source| ScoreSourceMetadata::Checkpoint {
            path: source.metadata.path.clone(),
            as_of_block: source.metadata.as_of_block,
            as_of_block_hash: source.metadata.as_of_block_hash.clone(),
            indexed_transfers: source.metadata.indexed_transfers,
            indexed_tokens: source.metadata.indexed_tokens,
        },
    );
    let mut log_metrics = checkpoint_source.as_ref().map_or(event_metrics, |source| {
        merge_metrics(event_metrics, source.metadata.log_metrics)
    });

    let registrations = events
        .iter()
        .filter(|event| matches!(event.kind, EventKind::Register))
        .map(|event| (event.claim_id.clone(), event))
        .collect::<HashMap<_, _>>();
    let hold_from = if provisional.reference_block > incident_config.params.holding_margin_blocks {
        provisional.reference_block - incident_config.params.holding_margin_blocks
    } else {
        1
    };
    let mut claims = Vec::with_capacity(replay.live_claim_ids.len());
    for claim_id in &replay.live_claim_ids {
        let event = registrations.get(claim_id).ok_or_else(|| {
            EngineError::Invariant(format!("missing registration for live claim {claim_id}"))
        })?;
        let (min_held, eligibility_metrics) = min_balance_over(
            rpc.as_ref(),
            provisional.insured_token,
            event.user,
            hold_from,
            provisional.reference_block,
            config.max_log_range,
            config.log_result_cap as usize,
        )
        .await?;
        log_metrics = merge_metrics(log_metrics, eligibility_metrics);
        let gross_earned_score = if let Some(source) = &checkpoint_source {
            source.gross_score_of(event.user).await?
        } else {
            let (score, score_metrics) = earned_score_of(
                rpc.as_ref(),
                &incident_config,
                event.user,
                provisional.reference_block,
                config.max_log_range,
                config.log_result_cap as usize,
            )
            .await?;
            log_metrics = merge_metrics(log_metrics, score_metrics);
            score
        };
        let spent_score = spent_score_at(
            rpc.as_ref(),
            config.registry,
            event.user,
            provisional.open_block,
        )
        .await?;
        let booster_held =
            if event.booster_amount == BigUint::from(0u8) || booster_collection.is_zero() {
                BigUint::from(0u8)
            } else {
                let (held, booster_metrics) = min_erc1155_balance_over(
                    rpc.as_ref(),
                    booster_collection,
                    event.user,
                    &BigUint::from(config.booster_id),
                    event.block_number,
                    anchors.window_end.number,
                    config.max_log_range,
                    config.log_result_cap as usize,
                )
                .await?;
                log_metrics = merge_metrics(log_metrics, booster_metrics);
                held
            };
        claims.push(ClaimInput {
            claim_id: event.claim_id.clone(),
            user: event.user,
            escrow_amount: event.amount.clone(),
            min_held,
            gross_earned_score,
            spent_score,
            score_to_spend: event.score_to_spend.clone(),
            booster_amount: event.booster_amount.clone(),
            booster_held,
        });
    }

    let kernel_input = KernelInput {
        incident_id: incident_id.clone(),
        coverage_bps: incident_config.coverage_bps,
        insured_decimals: u32::from(insured_decimals),
        twap_ratio: twap_ratio.clone(),
        underlying_usd: underlying_usd.clone(),
        max_cover_pool_payout_bps: max_payout_bps,
        pools,
        claims,
    };
    let output = allocate_with_events(&kernel_input, &events)?;
    if !output
        .claim_set_hash
        .eq_ignore_ascii_case(&window_incident.claim_set_hash)
    {
        return Err(EngineError::Invariant(
            "kernel claim-set commitment differs after allocation".to_owned(),
        ));
    }
    let config_hash = config.hash()?;
    let digest = settlement_digest(&SettlementDigestInput {
        chain_id: config.chain_id,
        verifying_contract: config.defi_insurance,
        incident_id: incident_id.clone(),
        root: output.root.clone(),
        unresolved: window_incident.unresolved.clone(),
        pool_payouts: output.pool_payouts.clone(),
        pool_addrs: topology.pool_addrs.clone(),
        claim_set: output.claim_set_hash.clone(),
        config_hash: config_hash.clone(),
        settlement_input_hash: output.settlement_input_hash.clone(),
    })?;
    let latest_incident = incident_at(
        rpc.as_ref(),
        config.defi_insurance,
        incident_id.clone(),
        None,
    )
    .await?;
    assert_anchors_unchanged(rpc.as_ref(), &anchors).await?;

    let run = SettlementRun {
        incident_id,
        incident: provisional,
        window_incident,
        latest_incident,
        anchors,
        config_hash,
        pool_order: topology.assets,
        pool_addrs: topology.pool_addrs,
        twap_ratio,
        underlying_usd,
        events,
        output,
        digest,
        score_source,
        rpc_metrics: rpc.metrics(),
        log_metrics,
    };
    crate::artifact::verify_run(&run, config).map_err(|error| {
        EngineError::Invariant(format!("internal artifact verification failed: {error}"))
    })?;
    if let Some(source) = checkpoint_source.take() {
        let integrity_key = checkpoint_integrity_key.as_deref().ok_or_else(|| {
            EngineError::Invariant("checkpoint integrity key disappeared before commit".to_owned())
        })?;
        source.commit(integrity_key)?;
    }
    Ok(run)
}
