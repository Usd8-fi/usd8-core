use alloy_primitives::aliases::U80;
use alloy_primitives::{Address as AlloyAddress, Bytes, I256, U256};
use alloy_sol_types::{SolCall, SolEvent};
use async_trait::async_trait;
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use usd8_settlement::abi::{
    IAggregatorV3, IDefiInsurance, IERC20, IRegistry, ISingleAssetCoverPool,
};
use usd8_settlement::artifact::{verify_run, write_atomic_json};
use usd8_settlement::config::BootstrapConfig;
use usd8_settlement::engine::{ScoreMode, build_settlement};
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};
use usd8_settlement::typed_data::{SettlementDigestInput, settlement_digest};
use usd8_settlement::{Address, ClaimEvent, EventKind, claim_set_hash};

const DEFI: &str = "0x0000000000000000000000000000000000002000";
const REGISTRY: &str = "0x0000000000000000000000000000000000001000";
const INSURED: &str = "0x0000000000000000000000000000000000003000";
const ORACLE: &str = "0x0000000000000000000000000000000000004000";
const SCORED: &str = "0x0000000000000000000000000000000000005000";
const POOL: &str = "0x0000000000000000000000000000000000006000";
const ASSET: &str = "0x0000000000000000000000000000000000007000";
const FEED: &str = "0x0000000000000000000000000000000000008000";
const USER: &str = "0x0000000000000000000000000000000000009000";
const ZERO: &str = "0x0000000000000000000000000000000000000000";

fn aa(value: &str) -> AlloyAddress {
    AlloyAddress::from_str(value).unwrap()
}

fn ka(value: &str) -> Address {
    Address::from_str(value).unwrap()
}

fn encoded<C: SolCall>(value: &C::Return) -> Value {
    json!(format!("0x{}", hex::encode(C::abi_encode_returns(value))))
}

fn event_log<E: SolEvent>(address: &str, event: &E, block: u64, index: u64) -> Value {
    let encoded = event.encode_log_data();
    json!({
        "address": address,
        "topics": encoded.topics().iter().map(|topic| format!("{topic:#x}")).collect::<Vec<_>>(),
        "data": format!("0x{}", hex::encode(encoded.data.as_ref())),
        "blockNumber": format!("0x{block:x}"),
        "transactionHash": format!("0x{:064x}", index + 1),
        "logIndex": format!("0x{index:x}"),
        "removed": false
    })
}

fn topic_matches(filter: &Value, topic: &Value) -> bool {
    if filter.is_null() {
        true
    } else if let Some(expected) = filter.as_str() {
        topic
            .as_str()
            .is_some_and(|actual| actual.eq_ignore_ascii_case(expected))
    } else if let Some(options) = filter.as_array() {
        options.iter().any(|option| topic_matches(option, topic))
    } else {
        false
    }
}

#[derive(Clone)]
struct EngineRpc {
    responses: Arc<HashMap<(String, String), Value>>,
    balances: Arc<HashMap<(String, u64), U256>>,
    logs: Arc<Vec<Value>>,
    calls: Arc<Mutex<Vec<String>>>,
    fail_latest_incident: bool,
}

#[async_trait]
impl Rpc for EngineRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        self.calls.lock().unwrap().push(method.to_owned());
        match method {
            "eth_chainId" => Ok(json!("0x1")),
            "eth_getCode" => Ok(json!("0x01")),
            "eth_getBlockByNumber" => {
                if params[0] == "finalized" {
                    return Ok(json!({
                        "number": "0x64",
                        "timestamp": "0x3e8",
                        "hash": format!("0x{:064x}", 1_100u64),
                    }));
                }
                let number =
                    u64::from_str_radix(params[0].as_str().unwrap().trim_start_matches("0x"), 16)
                        .unwrap();
                Ok(json!({
                    "number": format!("0x{number:x}"),
                    "timestamp": format!("0x{:x}", number * 10),
                    "hash": format!("0x{:064x}", number + 1_000),
                }))
            }
            "eth_call" => {
                let to = params[0]["to"].as_str().unwrap().to_ascii_lowercase();
                let data = params[0]["data"].as_str().unwrap();
                let selector = data[..10].to_owned();
                let incident_selector =
                    format!("0x{}", hex::encode(IDefiInsurance::incidentsCall::SELECTOR));
                if self.fail_latest_incident
                    && params[1] == "latest"
                    && selector == incident_selector
                {
                    return Err(RpcError::JsonRpc {
                        code: -32000,
                        message: "late latest-state failure".to_owned(),
                    });
                }
                let balance_selector =
                    format!("0x{}", hex::encode(IERC20::balanceOfCall::SELECTOR));
                if selector == balance_selector {
                    let block = u64::from_str_radix(
                        params[1].as_str().unwrap().trim_start_matches("0x"),
                        16,
                    )
                    .unwrap();
                    let balance = self.balances.get(&(to, block)).copied().ok_or_else(|| {
                        RpcError::JsonRpc {
                            code: -32000,
                            message: "missing historical balance".to_owned(),
                        }
                    })?;
                    return Ok(json!(format!(
                        "0x{}",
                        hex::encode(IERC20::balanceOfCall::abi_encode_returns(&balance))
                    )));
                }
                self.responses
                    .get(&(to, selector))
                    .cloned()
                    .ok_or_else(|| RpcError::JsonRpc {
                        code: -32000,
                        message: "missing canned call".to_owned(),
                    })
            }
            "eth_getLogs" => {
                let filter = &params[0];
                let address = filter["address"].as_str().unwrap();
                let from = u64::from_str_radix(
                    filter["fromBlock"]
                        .as_str()
                        .unwrap()
                        .trim_start_matches("0x"),
                    16,
                )
                .unwrap();
                let to = u64::from_str_radix(
                    filter["toBlock"].as_str().unwrap().trim_start_matches("0x"),
                    16,
                )
                .unwrap();
                let topics = filter["topics"].as_array().cloned().unwrap_or_default();
                Ok(Value::Array(
                    self.logs
                        .iter()
                        .filter(|log| {
                            let block = u64::from_str_radix(
                                log["blockNumber"]
                                    .as_str()
                                    .unwrap()
                                    .trim_start_matches("0x"),
                                16,
                            )
                            .unwrap();
                            address.eq_ignore_ascii_case(log["address"].as_str().unwrap())
                                && (from..=to).contains(&block)
                                && topics.iter().enumerate().all(|(index, wanted)| {
                                    log["topics"]
                                        .get(index)
                                        .is_some_and(|actual| topic_matches(wanted, actual))
                                })
                        })
                        .cloned()
                        .collect(),
                ))
            }
            _ => panic!("unexpected RPC method {method}"),
        }
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

fn fixture_with_min_claim(min_claim_amount: u128) -> (EngineRpc, BootstrapConfig) {
    let registration = ClaimEvent {
        kind: EventKind::Register,
        claim_id: BigUint::from(1u8),
        user: ka(USER),
        amount: BigUint::from(100u8),
        score_to_spend: BigUint::from(60u8),
        booster_amount: BigUint::from(0u8),
        block_number: 92,
        log_index: 0,
    };
    let claim_set = claim_set_hash(std::slice::from_ref(&registration)).unwrap();
    let claim_set_bytes: [u8; 32] = hex::decode(claim_set.trim_start_matches("0x"))
        .unwrap()
        .try_into()
        .unwrap();
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
            insuredToken: aa(INSURED),
            claimWindowEndTime: 950,
            root: [0u8; 32].into(),
            unresolved: U256::from(1),
            rootSubmittedAt: 0,
            referenceBlock: 80,
            openBlock: 90,
            status: 1,
            disputedAt: 0,
            claimSetHash: claim_set_bytes.into(),
        }),
    );
    insert(
        DEFI,
        IDefiInsurance::getInsuredTokenCall::SELECTOR,
        encoded::<IDefiInsurance::getInsuredTokenCall>(&IDefiInsurance::InsuredToken {
            maxCoverageBps: U256::from(8_000),
            underlyingPriceOracle: aa(ORACLE),
            underlyingConversionAddress: AlloyAddress::ZERO,
            underlyingConversionCallData: Bytes::new(),
            minClaimAmount: min_claim_amount,
        }),
    );
    insert(
        DEFI,
        IDefiInsurance::settlementParamsCall::SELECTOR,
        encoded::<IDefiInsurance::settlementParamsCall>(&IDefiInsurance::settlementParamsReturn {
            twapLookbackBlocks: 10,
            holdingMarginBlocks: 5,
            sampleStepBlocks: 2,
        }),
    );
    insert(
        REGISTRY,
        IRegistry::getScoredTokensCall::SELECTOR,
        encoded::<IRegistry::getScoredTokensCall>(&vec![aa(SCORED)]),
    );
    insert(
        REGISTRY,
        IRegistry::getScoredRateHistoryCall::SELECTOR,
        encoded::<IRegistry::getScoredRateHistoryCall>(&vec![IRegistry::RatePoint {
            fromBlock: 1,
            rate: 1_000_000_000_000_000_000,
        }]),
    );
    insert(
        REGISTRY,
        IRegistry::coverPoolsCall::SELECTOR,
        encoded::<IRegistry::coverPoolsCall>(&IRegistry::coverPoolsReturn {
            assets: vec![aa(ASSET)],
            poolAddrs: vec![aa(POOL)],
        }),
    );
    insert(
        REGISTRY,
        IRegistry::boosterNFTCall::SELECTOR,
        encoded::<IRegistry::boosterNFTCall>(&aa(ZERO)),
    );
    insert(
        REGISTRY,
        IRegistry::maxCoverPoolPayoutBpsCall::SELECTOR,
        encoded::<IRegistry::maxCoverPoolPayoutBpsCall>(&U256::from(3_000)),
    );
    insert(
        REGISTRY,
        IRegistry::scoreSpentCall::SELECTOR,
        encoded::<IRegistry::scoreSpentCall>(&U256::ZERO),
    );
    for token in [INSURED, SCORED, ASSET] {
        insert(
            token,
            IERC20::decimalsCall::SELECTOR,
            encoded::<IERC20::decimalsCall>(&0),
        );
    }
    insert(
        POOL,
        ISingleAssetCoverPool::assetCall::SELECTOR,
        encoded::<ISingleAssetCoverPool::assetCall>(&aa(ASSET)),
    );
    insert(
        POOL,
        ISingleAssetCoverPool::totalAssetsCall::SELECTOR,
        encoded::<ISingleAssetCoverPool::totalAssetsCall>(&U256::from(1_000)),
    );
    for oracle in [ORACLE, FEED] {
        insert(
            oracle,
            IAggregatorV3::latestRoundDataCall::SELECTOR,
            encoded::<IAggregatorV3::latestRoundDataCall>(&IAggregatorV3::latestRoundDataReturn {
                roundId: U80::from(7),
                answer: I256::try_from(100_000_000i64).unwrap(),
                startedAt: U256::from(900),
                updatedAt: U256::from(900),
                answeredInRound: U80::from(7),
            }),
        );
        insert(
            oracle,
            IAggregatorV3::decimalsCall::SELECTOR,
            encoded::<IAggregatorV3::decimalsCall>(&8),
        );
    }

    let logs = vec![
        event_log(
            DEFI,
            &IDefiInsurance::ClaimRegistered {
                claimId: U256::from(1),
                incidentId: U256::from(7),
                user: aa(USER),
                insuredTokenAmount: 100,
                scoreToSpend: U256::from(60),
                boosterAmount: U256::ZERO,
            },
            92,
            0,
        ),
        event_log(
            SCORED,
            &IERC20::Transfer {
                from: AlloyAddress::ZERO,
                to: aa(USER),
                value: U256::from(100),
            },
            10,
            1,
        ),
    ];
    let balances = [
        ((INSURED.to_ascii_lowercase(), 75), U256::from(100)),
        ((INSURED.to_ascii_lowercase(), 80), U256::from(100)),
        ((SCORED.to_ascii_lowercase(), 1), U256::ZERO),
        ((SCORED.to_ascii_lowercase(), 80), U256::from(100)),
    ]
    .into_iter()
    .collect();
    let config = BootstrapConfig::from_json(&format!(
        r#"{{"version":"4.5.0","chainId":1,"registry":"{REGISTRY}","defiInsurance":"{DEFI}","boosterId":"1","boosterBoostBps":"100","assetUsdFeed":{{"{ASSET}":"{FEED}"}},"maxOracleStaleness":"86400","maxLogRange":"1000","logResultCap":1000}}"#
    ))
    .unwrap();
    (
        EngineRpc {
            responses: Arc::new(responses),
            balances: Arc::new(balances),
            logs: Arc::new(logs),
            calls: Arc::new(Mutex::new(Vec::new())),
            fail_latest_incident: false,
        },
        config,
    )
}

fn fixture() -> (EngineRpc, BootstrapConfig) {
    fixture_with_min_claim(1)
}

fn artifact_path() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "usd8-engine-artifact-{}-{nonce}.json",
        std::process::id()
    ))
}

#[test]
fn checkpoint_integrity_key_is_redacted_from_debug_output() {
    let mode = ScoreMode::Checkpoint {
        path: PathBuf::from("state.json"),
        integrity_key: b"definitely-secret-checkpoint-key".to_vec(),
    };
    let debug = format!("{mode:?}");
    assert!(debug.contains("[REDACTED]"));
    assert!(!debug.contains("definitely-secret"));
}

#[tokio::test]
async fn full_engine_builds_and_atomically_verifies_one_claim_artifact() {
    let (rpc, config) = fixture();
    let run = build_settlement(Arc::new(rpc), &config, BigUint::from(7u8), ScoreMode::Raw)
        .await
        .unwrap();
    assert_eq!(run.output.rows.len(), 1);
    assert_eq!(run.output.rows[0].eligible_amount, BigUint::from(100u8));
    assert_eq!(run.output.rows[0].score_spent, BigUint::from(60u8));
    assert_eq!(run.output.rows[0].amounts, vec![BigUint::from(80u8)]);
    assert_eq!(run.output.pool_payouts, vec![BigUint::from(80u8)]);
    assert!(!run.root_matches());
    verify_run(&run, &config).unwrap();

    let artifact = run.artifact(&config, true);
    let path = artifact_path();
    write_atomic_json(&path, &artifact).unwrap();
    let persisted: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(persisted, artifact);
    assert_eq!(persisted["rows"][0]["amounts"][0], "80");
    assert!(persisted["rows"][0]["proof"].is_array());
    fs::remove_file(path).unwrap();
}

#[tokio::test]
async fn artifact_verifier_recomputes_config_hash_independently() {
    let (rpc, config) = fixture();
    let mut run = build_settlement(Arc::new(rpc), &config, BigUint::from(7u8), ScoreMode::Raw)
        .await
        .unwrap();
    run.config_hash = format!("0x{}", "11".repeat(32));
    run.digest = settlement_digest(&SettlementDigestInput {
        chain_id: config.chain_id,
        verifying_contract: config.defi_insurance,
        incident_id: run.incident_id.clone(),
        root: run.output.root.clone(),
        unresolved: run.window_incident.unresolved.clone(),
        pool_payouts: run.output.pool_payouts.clone(),
        pool_addrs: run.pool_addrs.clone(),
        claim_set: run.output.claim_set_hash.clone(),
        config_hash: run.config_hash.clone(),
        settlement_input_hash: run.output.settlement_input_hash.clone(),
    })
    .unwrap();

    let error = verify_run(&run, &config).unwrap_err();
    assert!(error.to_string().contains("config hash"));
}

#[tokio::test]
async fn registered_claim_is_not_rechecked_against_join_time_minimum() {
    let (rpc, config) = fixture_with_min_claim(101);
    let run = build_settlement(Arc::new(rpc), &config, BigUint::from(7u8), ScoreMode::Raw)
        .await
        .unwrap();

    assert_eq!(run.output.rows.len(), 1);
    assert_eq!(run.output.rows[0].escrow_amount, BigUint::from(100u8));
}

#[tokio::test]
async fn anchor_recheck_is_last_rpc_operation() {
    let (rpc, config) = fixture();
    let calls = rpc.calls.clone();
    build_settlement(Arc::new(rpc), &config, BigUint::from(7u8), ScoreMode::Raw)
        .await
        .unwrap();

    assert_eq!(
        calls.lock().unwrap().last().map(String::as_str),
        Some("eth_getBlockByNumber")
    );
}

#[tokio::test]
async fn verified_checkpoint_run_commits_and_releases_lock() {
    let (rpc, config) = fixture();
    let path = artifact_path();
    let lock_path = PathBuf::from(format!("{}.lock", path.display()));
    build_settlement(
        Arc::new(rpc),
        &config,
        BigUint::from(7u8),
        ScoreMode::Checkpoint {
            path: path.clone(),
            integrity_key: vec![7u8; 32],
        },
    )
    .await
    .unwrap();

    assert!(path.exists());
    assert!(!lock_path.exists());
    fs::remove_file(path).unwrap();
}

#[tokio::test]
async fn late_rpc_failure_does_not_commit_checkpoint() {
    let (mut rpc, config) = fixture();
    rpc.fail_latest_incident = true;
    let path = artifact_path();
    let lock_path = PathBuf::from(format!("{}.lock", path.display()));
    let error = build_settlement(
        Arc::new(rpc),
        &config,
        BigUint::from(7u8),
        ScoreMode::Checkpoint {
            path: path.clone(),
            integrity_key: vec![9u8; 32],
        },
    )
    .await
    .unwrap_err();

    assert!(error.to_string().contains("late latest-state failure"));
    assert!(!path.exists());
    assert!(!lock_path.exists());
}
