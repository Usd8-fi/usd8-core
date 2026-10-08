use alloy_primitives::aliases::U80;
use alloy_primitives::{Address as AlloyAddress, Bytes, I256, U256};
use alloy_sol_types::SolCall;
use async_trait::async_trait;
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

mod support;
use usd8_settlement::Address;
use usd8_settlement::abi::{
    IAggregatorV3, IDefiInsurance, IERC20, IRegistry, ISingleAssetCoverPool,
};
use usd8_settlement::chain::{
    ChainError, derive_bootstrap_config_at, incident_at, incident_config_at, pool_state_at,
    pools_at, price_usd_1e18, ratio_at, twap_ratio_before,
};
use usd8_settlement::config::BootstrapConfig;
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};

#[path = "support/cli_http.rs"]
mod cli_http;

struct ScoreCliRpc(CallRpc);

#[async_trait]
impl Rpc for ScoreCliRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        if method == "eth_getLogs" {
            return Ok(json!([]));
        }
        self.0.request(method, params).await
    }
    fn metrics(&self) -> RpcMetrics {
        self.0.metrics()
    }
}

fn score_cli_fixture() -> ScoreCliRpc {
    let mut rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let responses = Arc::make_mut(&mut rpc.responses);
    responses.insert(
        (
            REGISTRY.into(),
            format!("0x{}", hex::encode(IRegistry::scoreSpentCall::SELECTOR)),
        ),
        encoded::<IRegistry::scoreSpentCall>(&U256::from(7_250_000_000_000_000_000u64)),
    );
    responses.insert(
        (
            SCORED.into(),
            format!("0x{}", hex::encode(IERC20::balanceOfCall::SELECTOR)),
        ),
        encoded::<IERC20::balanceOfCall>(&U256::from(2_500_000u64)),
    );
    ScoreCliRpc(rpc)
}

#[tokio::test]
async fn compute_insurance_score_cli_replays_finalized_score_over_http() {
    let expected = usd8_settlement::score::insurance_score_at(
        &score_cli_fixture(),
        config().registry,
        config().registry,
    )
    .await
    .unwrap();
    let (url, server) = cli_http::serve(score_cli_fixture()).await;
    let output = cli_http::run("compute_insurance_score", REGISTRY, REGISTRY, url, vec![]).await;
    server.abort();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value, serde_json::to_value(expected).unwrap());
    assert_eq!(value["account"], REGISTRY);
    assert_eq!(value["referenceBlock"], "100");
    assert_eq!(value["scoreCutoffBlock"], "95");
    assert_eq!(value["grossEarnedScore"], "337500000000000000000");
    assert_eq!(value["scoreSpent"], "7250000000000000000");
    assert_eq!(value["availableScore"], "330250000000000000000");
    println!(
        "local HTTP score CLI result: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    let path = std::env::temp_dir().join(format!(
        "usd8-compute_insurance_score-success-{}.json",
        std::process::id()
    ));
    let (url, server) = cli_http::serve(score_cli_fixture()).await;
    let saved = cli_http::run(
        "compute_insurance_score",
        REGISTRY,
        REGISTRY,
        url,
        vec!["--output".into(), path.display().to_string()],
    )
    .await;
    server.abort();
    assert!(
        saved.status.success(),
        "{}",
        String::from_utf8_lossy(&saved.stderr)
    );
    assert!(saved.stdout.is_empty());
    let readback: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(readback, value);
    std::fs::remove_file(path).unwrap();
}

struct ScoreFaultRpc {
    rpc: ScoreCliRpc,
    fault: &'static str,
}

#[async_trait]
impl Rpc for ScoreFaultRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        if self.fault == "chain" && method == "eth_chainId" {
            return Ok(json!("0x0"));
        }
        if self.fault == "logs" && method == "eth_getLogs" {
            return Err(RpcError::JsonRpc {
                code: -32602,
                message: "history unavailable".into(),
            });
        }
        let mut value = self.rpc.request(method, params.clone()).await?;
        if self.fault == "reorg" && method == "eth_getBlockByNumber" && params[0] == "0x64" {
            value["hash"] = json!(format!("0x{}", "22".repeat(32)));
        }
        Ok(value)
    }
    fn metrics(&self) -> RpcMetrics {
        self.rpc.metrics()
    }
}

#[tokio::test]
async fn compute_insurance_score_cli_errors_are_not_zero_score_outputs() {
    for (fault, message) in [
        ("chain", "wrong chain"),
        ("logs", "RPC"),
        ("reorg", "score reference"),
    ] {
        let (url, server) = cli_http::serve(ScoreFaultRpc {
            rpc: score_cli_fixture(),
            fault,
        })
        .await;
        let path =
            std::env::temp_dir().join(format!("usd8-score-{}-{fault}.json", std::process::id()));
        std::fs::write(&path, "untouched").unwrap();
        let output = cli_http::run(
            "compute_insurance_score",
            REGISTRY,
            REGISTRY,
            url,
            vec!["--output".into(), path.display().to_string()],
        )
        .await;
        server.abort();
        assert_eq!(
            output.status.code(),
            Some(1),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(message),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(output.stdout.is_empty());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "untouched");
        std::fs::remove_file(path).unwrap();
    }
}

const DEFI: &str = "0x0000000000000000000000000000000000002000";
const REGISTRY: &str = "0x0000000000000000000000000000000000001000";
const INSURED: &str = "0x0000000000000000000000000000000000003000";
const ORACLE: &str = "0x0000000000000000000000000000000000004000";
const SCORED: &str = "0x0000000000000000000000000000000000005000";
const POOL: &str = "0x0000000000000000000000000000000000006000";
const ASSET: &str = "0x0000000000000000000000000000000000007000";
const FEED: &str = "0x0000000000000000000000000000000000008000";

fn a(value: &str) -> AlloyAddress {
    AlloyAddress::from_str(value).unwrap()
}

fn encoded<C: SolCall>(value: &C::Return) -> Value {
    json!(format!("0x{}", hex::encode(C::abi_encode_returns(value))))
}

#[derive(Clone)]
struct CallRpc {
    responses: Arc<HashMap<(String, String), Value>>,
    calls: Arc<Mutex<Vec<Value>>>,
}

#[async_trait]
impl Rpc for CallRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match method {
            "eth_chainId" => Ok(json!(format!("0x{:x}", usd8_settlement::config::CHAIN_ID))),
            "eth_call" => {
                self.calls.lock().unwrap().push(params.clone());
                support::dispatch(&params, |params| {
                    let to = params[0]["to"].as_str().unwrap().to_ascii_lowercase();
                    let data = params[0]["data"].as_str().unwrap();
                    let selector = data[..10].to_owned();
                    self.responses
                        .get(&(to, selector))
                        .cloned()
                        .ok_or_else(|| RpcError::JsonRpc {
                            code: -32000,
                            message: "missing canned call".to_owned(),
                        })
                })
            }
            "eth_getBlockByNumber" => {
                let number = if params[0] == "finalized" {
                    "0x64"
                } else {
                    params[0].as_str().unwrap()
                };
                Ok(json!({
                    "number": number,
                    "timestamp": "0x3e8",
                    "hash": format!("0x{}", "11".repeat(32))
                }))
            }
            _ => panic!("unexpected RPC method {method}"),
        }
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

fn fixture(answer: I256) -> CallRpc {
    fixture_with_feed_decimals(answer, 8)
}

fn fixture_with_feed_decimals(answer: I256, feed_decimals: u8) -> CallRpc {
    let mut responses = HashMap::new();
    let mut insert = |to: &str, selector: [u8; 4], value: Value| {
        responses.insert(
            (
                to.to_ascii_lowercase(),
                format!("0x{}", hex::encode(selector)),
            ),
            value,
        );
    };
    insert(
        DEFI,
        IDefiInsurance::incidentsCall::SELECTOR,
        encoded::<IDefiInsurance::incidentsCall>(&IDefiInsurance::incidentsReturn {
            insuredToken: a(INSURED),
            resolvedAt: 0,
            referenceBlock: 80,
            openBlock: 90,
            phaseDeadline: 900,
            root: [0x22; 32].into(),
            unresolvedClaims: U256::from(2),
            claimSetHash: [0x33; 32].into(),
            teePcrHash: [0x44; 32].into(),
            protocolFeeShareBps: 2_000,
        }),
    );
    insert(
        REGISTRY,
        IRegistry::defiInsuranceCall::SELECTOR,
        encoded::<IRegistry::defiInsuranceCall>(&a(DEFI)),
    );
    insert(
        DEFI,
        IDefiInsurance::registryCall::SELECTOR,
        encoded::<IDefiInsurance::registryCall>(&a(REGISTRY)),
    );
    insert(
        REGISTRY,
        IRegistry::boosterConfigCall::SELECTOR,
        encoded::<IRegistry::boosterConfigCall>(&IRegistry::boosterConfigReturn {
            collection: AlloyAddress::ZERO,
            tokenId: 1,
            boostBps: 100,
        }),
    );
    insert(
        REGISTRY,
        IRegistry::assetUsdFeedCall::SELECTOR,
        encoded::<IRegistry::assetUsdFeedCall>(&a(FEED)),
    );
    insert(
        REGISTRY,
        IRegistry::maxOracleStalenessCall::SELECTOR,
        encoded::<IRegistry::maxOracleStalenessCall>(&129_600),
    );
    insert(
        DEFI,
        IDefiInsurance::getInsuredTokenCall::SELECTOR,
        encoded::<IDefiInsurance::getInsuredTokenCall>(&IDefiInsurance::InsuredToken {
            maxCoverageBps: 8_000,
            underlyingPriceOracle: a(ORACLE),
            underlyingConversionAddress: AlloyAddress::ZERO,
            underlyingConversionCallData: Bytes::new(),
        }),
    );
    insert(
        DEFI,
        IDefiInsurance::settlementParamsCall::SELECTOR,
        encoded::<IDefiInsurance::settlementParamsCall>(&IDefiInsurance::settlementParamsReturn {
            twapLookbackBlocks: 10,
            minHoldingRequired: 5,
            sampleStepBlocks: 2,
        }),
    );
    insert(
        REGISTRY,
        IRegistry::getScoredTokensCall::SELECTOR,
        encoded::<IRegistry::getScoredTokensCall>(&vec![a(SCORED)]),
    );
    insert(
        REGISTRY,
        IRegistry::getScoredRateHistoryCall::SELECTOR,
        encoded::<IRegistry::getScoredRateHistoryCall>(&vec![
            IRegistry::RatePoint {
                fromBlock: 5,
                rate: 1_000_000_000_000_000_000,
            },
            IRegistry::RatePoint {
                fromBlock: 50,
                rate: 2_000_000_000_000_000_000,
            },
        ]),
    );
    insert(
        REGISTRY,
        IRegistry::coverPoolsCall::SELECTOR,
        encoded::<IRegistry::coverPoolsCall>(&IRegistry::coverPoolsReturn {
            assets: vec![a(ASSET)],
            poolAddrs: vec![a(POOL)],
        }),
    );
    insert(
        SCORED,
        IERC20::decimalsCall::SELECTOR,
        encoded::<IERC20::decimalsCall>(&6),
    );
    insert(
        ASSET,
        IERC20::decimalsCall::SELECTOR,
        encoded::<IERC20::decimalsCall>(&6),
    );
    insert(
        POOL,
        ISingleAssetCoverPool::assetCall::SELECTOR,
        encoded::<ISingleAssetCoverPool::assetCall>(&a(ASSET)),
    );
    insert(
        POOL,
        ISingleAssetCoverPool::totalAssetsCall::SELECTOR,
        encoded::<ISingleAssetCoverPool::totalAssetsCall>(&U256::from(1_000_000_000u64)),
    );
    insert(
        FEED,
        IAggregatorV3::latestRoundDataCall::SELECTOR,
        encoded::<IAggregatorV3::latestRoundDataCall>(&IAggregatorV3::latestRoundDataReturn {
            roundId: U80::from(7),
            answer,
            startedAt: U256::from(900),
            updatedAt: U256::from(950),
            answeredInRound: U80::from(7),
        }),
    );
    insert(
        FEED,
        IAggregatorV3::decimalsCall::SELECTOR,
        encoded::<IAggregatorV3::decimalsCall>(&feed_decimals),
    );
    CallRpc {
        responses: Arc::new(responses),
        calls: Arc::default(),
    }
}

fn config() -> BootstrapConfig {
    BootstrapConfig::derived(
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(DEFI).unwrap(),
        1,
        100,
        [(
            Address::from_str(ASSET).unwrap(),
            Address::from_str(FEED).unwrap(),
        )]
        .into_iter()
        .collect(),
        129_600,
    )
    .unwrap()
}

#[tokio::test]
async fn required_read_plans_reject_unsafe_or_oversized_inputs_before_rpc() {
    use usd8_settlement::chain::{aggregate_reads, read_call};
    let rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let valid = read_call(config().registry, IRegistry::defiInsuranceCall {});
    let mut permissive = valid.clone();
    permissive.allowFailure = true;
    let mut short = valid.clone();
    short.callData = vec![0; 3].into();
    let mut oversized = valid.clone();
    oversized.callData = vec![0; 32768].into();
    for invalid in [permissive, short, oversized] {
        assert!(
            aggregate_reads(&rpc, vec![valid.clone(), invalid], 90)
                .await
                .is_err()
        );
        assert!(rpc.calls.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn standalone_score_config_batches_rate_histories_in_token_order() {
    let mut rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let responses = Arc::make_mut(&mut rpc.responses);
    responses.insert(
        (
            REGISTRY.into(),
            format!(
                "0x{}",
                hex::encode(IRegistry::getScoredTokensCall::SELECTOR)
            ),
        ),
        encoded::<IRegistry::getScoredTokensCall>(&vec![a(SCORED), a(ASSET)]),
    );
    let cfg = usd8_settlement::chain::score_config_at(
        &rpc,
        config().registry,
        config().defi_insurance,
        90,
    )
    .await
    .unwrap();
    assert_eq!(
        cfg.scored_tokens
            .iter()
            .map(|token| token.token)
            .collect::<Vec<_>>(),
        vec![
            Address::from_str(SCORED).unwrap(),
            Address::from_str(ASSET).unwrap()
        ]
    );
    assert_eq!(rpc.calls.lock().unwrap().len(), 4);
    let calls = rpc.calls.lock().unwrap();
    assert_eq!(calls[2][0]["to"], SCORED);
    assert_eq!(calls[3][0]["to"], ASSET);
    assert!(calls.iter().all(|call| call[1] == "0x5a"));
}

#[tokio::test]
async fn bootstrap_aggregate_faults_abort_without_fallback() {
    for fault in [
        "revert",
        "envelope",
        "trailing-envelope",
        "count",
        "failed",
        "empty",
        "malformed",
        "trailing-subcall",
    ] {
        let rpc =
            support::FaultRpc::new(fixture(I256::try_from(100_000_000i64).unwrap()), fault, 0);
        assert!(
            derive_bootstrap_config_at(&rpc, config().registry, config().defi_insurance, 90)
                .await
                .is_err(),
            "{fault}"
        );
        assert!(rpc.poisoned.load(std::sync::atomic::Ordering::SeqCst));
    }
}

#[tokio::test]
async fn registry_root_derives_historical_runtime_configuration() {
    let rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let registry = Address::from_str(REGISTRY).unwrap();
    let defi = Address::from_str(DEFI).unwrap();
    let config = derive_bootstrap_config_at(&rpc, registry, defi, 90)
        .await
        .unwrap();

    assert_eq!(config.registry, registry);
    assert_eq!(config.defi_insurance, defi);
    assert_eq!(config.booster_id, 1);
    assert_eq!(config.booster_boost_bps, 100);
    assert_eq!(config.max_oracle_staleness, 129_600);
    let calls = rpc.calls.lock().unwrap();
    println!("bootstrap eth_call count: {}", calls.len());
    assert_eq!(
        calls.len(),
        3,
        "bootstrap dependency rounds: pointer, config, feeds"
    );
    assert!(calls.iter().all(|call| call[1] == "0x5a"));
    assert_eq!(
        config
            .asset_feed(Address::from_str(ASSET).unwrap())
            .unwrap(),
        Address::from_str(FEED).unwrap()
    );
}

#[tokio::test]
async fn public_score_snapshot_batches_config_and_spent() {
    let mut rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let responses = Arc::make_mut(&mut rpc.responses);
    responses.insert(
        (
            REGISTRY.into(),
            format!(
                "0x{}",
                hex::encode(IRegistry::getScoredTokensCall::SELECTOR)
            ),
        ),
        encoded::<IRegistry::getScoredTokensCall>(&vec![]),
    );
    responses.insert(
        (
            REGISTRY.into(),
            format!("0x{}", hex::encode(IRegistry::scoreSpentCall::SELECTOR)),
        ),
        encoded::<IRegistry::scoreSpentCall>(&U256::ZERO),
    );
    let snapshot =
        usd8_settlement::score::insurance_score_at(&rpc, config().registry, config().registry)
            .await
            .unwrap();
    assert_eq!(snapshot.gross_earned_score, "0");
    assert_eq!(snapshot.available_score, "0");
    assert_eq!(snapshot.reference_block, "100");
    assert_eq!(snapshot.score_cutoff_block, "95");
    println!(
        "public score eth_call count: {}",
        rpc.calls.lock().unwrap().len()
    );
    assert_eq!(rpc.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn bootstrap_chunks_large_topology_deterministically() {
    let mut rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let assets = (1..=130)
        .map(AlloyAddress::with_last_byte)
        .collect::<Vec<_>>();
    Arc::make_mut(&mut rpc.responses).insert(
        (
            REGISTRY.into(),
            format!("0x{}", hex::encode(IRegistry::coverPoolsCall::SELECTOR)),
        ),
        encoded::<IRegistry::coverPoolsCall>(&IRegistry::coverPoolsReturn {
            assets: assets.clone(),
            poolAddrs: assets.clone(),
        }),
    );
    let cfg = derive_bootstrap_config_at(&rpc, config().registry, config().defi_insurance, 90)
        .await
        .unwrap();
    for asset in assets {
        assert_eq!(
            cfg.asset_feed(Address::from_bytes(asset.into_array()))
                .unwrap(),
            config()
                .asset_feed(Address::from_str(ASSET).unwrap())
                .unwrap()
        );
    }
    let calls = rpc.calls.lock().unwrap();
    println!("large bootstrap eth_call count: {}", calls.len());
    assert_eq!(calls.len(), 5);
    let widths = calls
        .iter()
        .skip(2)
        .map(|params| {
            let bytes = hex::decode(&params[0]["data"].as_str().unwrap()[2..]).unwrap();
            usd8_settlement::abi::IMulticall3::aggregate3Call::abi_decode(&bytes)
                .unwrap()
                .calls
                .len()
        })
        .collect::<Vec<_>>();
    assert_eq!(widths, vec![64, 64, 2]);
    assert!(calls.iter().all(|params| params[1] == "0x5a"));
}

#[tokio::test]
async fn bootstrap_single_feed_stays_direct_and_empty_feeds_need_no_call() {
    let rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    derive_bootstrap_config_at(&rpc, config().registry, config().defi_insurance, 90)
        .await
        .unwrap();
    assert_eq!(rpc.calls.lock().unwrap()[2][0]["to"], REGISTRY);
    let mut empty = fixture(I256::try_from(100_000_000i64).unwrap());
    Arc::make_mut(&mut empty.responses).insert(
        (
            REGISTRY.into(),
            format!("0x{}", hex::encode(IRegistry::coverPoolsCall::SELECTOR)),
        ),
        encoded::<IRegistry::coverPoolsCall>(&IRegistry::coverPoolsReturn {
            assets: vec![],
            poolAddrs: vec![],
        }),
    );
    derive_bootstrap_config_at(&empty, config().registry, config().defi_insurance, 90)
        .await
        .unwrap();
    assert_eq!(empty.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn historical_abi_reads_reconstruct_incident_config_and_pool_state() {
    let rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let cfg = config();
    let incident = incident_at(&rpc, cfg.defi_insurance, 7u8.into(), Some(100))
        .await
        .unwrap();
    assert_eq!(incident.reference_block, 80);
    assert_eq!(incident.open_block, 90);
    assert_eq!(incident.unresolved_claims.to_string(), "2");

    rpc.calls.lock().unwrap().clear();
    let incident_cfg = incident_config_at(&rpc, &cfg, incident.insured_token, 90)
        .await
        .unwrap();
    println!(
        "incident config eth_call count: {}",
        rpc.calls.lock().unwrap().len()
    );
    assert_eq!(rpc.calls.lock().unwrap().len(), 3);
    assert_eq!(incident_cfg.coverage_bps.to_string(), "8000");
    assert_eq!(incident_cfg.params.sample_step_blocks, 2);
    assert_eq!(incident_cfg.scored_tokens.len(), 1);
    assert_eq!(incident_cfg.scored_tokens[0].decimals, 6);
    assert_eq!(incident_cfg.scored_tokens[0].rates.len(), 2);
    assert_eq!(incident_cfg.scored_tokens[0].rates[0].from_block, 5);
    assert_eq!(
        incident_cfg.scored_tokens[0].rates[0].rate,
        BigUint::from(1_000_000_000_000_000_000u64)
    );
    assert_eq!(incident_cfg.scored_tokens[0].rates[1].from_block, 50);
    assert_eq!(
        incident_cfg.scored_tokens[0].rates[1].rate,
        BigUint::from(2_000_000_000_000_000_000u64)
    );
    assert_eq!(
        twap_ratio_before(&rpc, &incident_cfg, 80)
            .await
            .unwrap()
            .to_string(),
        "1000000000000000000"
    );

    let topology = pools_at(&rpc, &cfg, 90).await.unwrap();
    assert_eq!(topology.assets.len(), 1);
    rpc.calls.lock().unwrap().clear();
    let pool = pool_state_at(&rpc, &cfg, topology.assets[0], topology.pool_addrs[0], 100)
        .await
        .unwrap();
    println!("pool eth_call count: {}", rpc.calls.lock().unwrap().len());
    assert_eq!(rpc.calls.lock().unwrap().len(), 4);
    assert_eq!(pool.balance.to_string(), "1000000000");
    assert_eq!(pool.asset_decimals, 6);
    assert_eq!(pool.asset_usd.to_string(), "1000000000000000000");
}

#[tokio::test]
async fn oracle_price_that_normalizes_to_zero_is_rejected() {
    let cfg = config();
    let rpc = fixture_with_feed_decimals(I256::try_from(100_000_000i64).unwrap(), 30);

    let error = price_usd_1e18(
        &rpc,
        cfg.asset_feed(Address::from_str(ASSET).unwrap()).unwrap(),
        100,
        cfg.max_oracle_staleness,
    )
    .await
    .unwrap_err();
    assert!(matches!(
        error,
        ChainError::InvalidOracle { message, .. } if message == "normalized price rounds to zero"
    ));
}

#[tokio::test]
async fn oracle_and_conversion_reads_fail_closed_on_invalid_values() {
    let cfg = config();
    let negative = fixture(I256::try_from(-1i64).unwrap());
    assert!(
        price_usd_1e18(
            &negative,
            cfg.asset_feed(Address::from_str(ASSET).unwrap()).unwrap(),
            100,
            cfg.max_oracle_staleness
        )
        .await
        .is_err()
    );

    let rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    assert_eq!(
        ratio_at(
            &rpc,
            Address::from_str("0x0000000000000000000000000000000000000000").unwrap(),
            &[],
            100,
        )
        .await
        .unwrap()
        .to_string(),
        "1000000000000000000"
    );
}
