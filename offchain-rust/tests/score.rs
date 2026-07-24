use alloy_primitives::{Address as AlloyAddress, U256};
use alloy_sol_types::{SolCall, SolEvent};
use async_trait::async_trait;
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use usd8_settlement::Address;
use usd8_settlement::abi::IERC20;
use usd8_settlement::chain::{
    IncidentConfig, RatePoint, ScoredToken, SettlementParams, earned_score_of,
};
use usd8_settlement::checkpoint::{BulkScoreSource, CheckpointError, CheckpointScoreSource};
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};

const TOKEN: &str = "0x0000000000000000000000000000000000001000";
const ALICE: &str = "0x000000000000000000000000000000000000a11c";
const BOB: &str = "0x000000000000000000000000000000000000b0b0";
const ZERO: &str = "0x0000000000000000000000000000000000000000";
static NEXT_PATH: AtomicUsize = AtomicUsize::new(0);

fn aa(value: &str) -> AlloyAddress {
    AlloyAddress::from_str(value).unwrap()
}
fn ka(value: &str) -> Address {
    Address::from_str(value).unwrap()
}

fn transfer(from: &str, to: &str, value: u64, block: u64, index: u64) -> Value {
    let encoded = IERC20::Transfer {
        from: aa(from),
        to: aa(to),
        value: U256::from(value),
    }
    .encode_log_data();
    json!({
        "address": TOKEN,
        "topics": encoded.topics().iter().map(|topic| format!("{topic:#x}")).collect::<Vec<_>>(),
        "data": format!("0x{}", hex::encode(encoded.data.as_ref())),
        "blockNumber": format!("0x{block:x}"),
        "transactionHash": format!("0x{:064x}", index + 1),
        "logIndex": format!("0x{index:x}"),
        "removed": false
    })
}

#[derive(Clone)]
struct ScoreRpc {
    logs: Arc<Vec<Value>>,
    balances: Arc<HashMap<(String, u64), U256>>,
    global_log_queries: Arc<AtomicUsize>,
    chain_id: Arc<AtomicUsize>,
    corrupt_block_hash: Arc<AtomicUsize>,
}

fn topic_matches(filter: &Value, topic: &Value) -> bool {
    filter.is_null()
        || filter
            .as_str()
            .zip(topic.as_str())
            .is_some_and(|(wanted, actual)| wanted.eq_ignore_ascii_case(actual))
}

#[async_trait]
impl Rpc for ScoreRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match method {
            "eth_getLogs" => {
                let filter = &params[0];
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
                let wanted = filter["topics"].as_array().unwrap();
                if wanted.len() == 1 {
                    self.global_log_queries.fetch_add(1, Ordering::Relaxed);
                }
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
                            block >= from
                                && block <= to
                                && wanted.iter().enumerate().all(|(i, topic)| {
                                    log["topics"]
                                        .get(i)
                                        .is_some_and(|actual| topic_matches(topic, actual))
                                })
                        })
                        .cloned()
                        .collect(),
                ))
            }
            "eth_call" => {
                let data = params[0]["data"].as_str().unwrap();
                let account_word = &data[data.len() - 40..];
                let account = format!("0x{}", account_word.to_ascii_lowercase());
                let block =
                    u64::from_str_radix(params[1].as_str().unwrap().trim_start_matches("0x"), 16)
                        .unwrap();
                let value = self
                    .balances
                    .get(&(account, block))
                    .copied()
                    .ok_or_else(|| RpcError::JsonRpc {
                        code: -32000,
                        message: "missing balance".to_owned(),
                    })?;
                Ok(json!(format!(
                    "0x{}",
                    hex::encode(IERC20::balanceOfCall::abi_encode_returns(&value))
                )))
            }
            "eth_chainId" => Ok(json!(format!(
                "0x{:x}",
                self.chain_id.load(Ordering::Relaxed)
            ))),
            "eth_getBlockByNumber" => {
                let block =
                    u64::from_str_radix(params[0].as_str().unwrap().trim_start_matches("0x"), 16)
                        .unwrap();
                let corrupt = self.corrupt_block_hash.load(Ordering::Relaxed) == block as usize;
                Ok(json!({
                    "number": format!("0x{block:x}"),
                    "timestamp": format!("0x{:x}", block * 12),
                    "hash": if corrupt { format!("0x{:064x}", block + 1) } else { format!("0x{block:064x}") }
                }))
            }
            _ => panic!("unexpected {method}"),
        }
    }
    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

fn cfg() -> IncidentConfig {
    IncidentConfig {
        coverage_bps: BigUint::from(8_000u16),
        underlying_price_oracle: ka(ZERO),
        conversion_address: ka(ZERO),
        conversion_call_data: vec![],
        params: SettlementParams {
            twap_lookback_blocks: 1,
            holding_margin_blocks: 1,
            sample_step_blocks: 1,
        },
        scored_tokens: vec![ScoredToken {
            token: ka(TOKEN),
            decimals: 18,
            rates: vec![
                RatePoint {
                    from_block: 2,
                    rate: BigUint::from(2_000_000_000_000_000_000u64),
                },
                RatePoint {
                    from_block: 6,
                    rate: BigUint::from(1_000_000_000_000_000_000u64),
                },
            ],
        }],
    }
}

fn score_rpc(logs: Vec<Value>, balances: HashMap<(String, u64), U256>) -> ScoreRpc {
    ScoreRpc {
        logs: Arc::new(logs),
        balances: Arc::new(balances),
        global_log_queries: Arc::new(AtomicUsize::new(0)),
        chain_id: Arc::new(AtomicUsize::new(1)),
        corrupt_block_hash: Arc::new(AtomicUsize::new(usize::MAX)),
    }
}

fn rpc() -> ScoreRpc {
    let logs = vec![
        transfer(ZERO, ALICE, 100, 1, 0),
        transfer(ALICE, BOB, 40, 4, 1),
        transfer(BOB, ALICE, 10, 8, 2),
    ];
    let balances = [
        ((ALICE.to_ascii_lowercase(), 2), 100),
        ((ALICE.to_ascii_lowercase(), 6), 60),
        ((ALICE.to_ascii_lowercase(), 10), 70),
        ((BOB.to_ascii_lowercase(), 2), 0),
        ((BOB.to_ascii_lowercase(), 6), 40),
        ((BOB.to_ascii_lowercase(), 10), 30),
    ]
    .into_iter()
    .map(|(key, value)| (key, U256::from(value)))
    .collect();
    score_rpc(logs, balances)
}

fn checkpoint_path() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let sequence = NEXT_PATH.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "usd8-rust-score-{}-{nonce}-{sequence}.json",
        std::process::id()
    ))
}

#[tokio::test]
async fn raw_score_matches_rate_segment_golden_vector() {
    let (alice, alice_metrics) = earned_score_of(&rpc(), &cfg(), ka(ALICE), 10, 1000, 1000)
        .await
        .unwrap();
    let (bob, _) = earned_score_of(&rpc(), &cfg(), ka(BOB), 10, 1000, 1000)
        .await
        .unwrap();
    assert_eq!(alice, BigUint::from(900u16));
    assert_eq!(bob, BigUint::from(300u16));
    assert_eq!(alice_metrics.requests, 4);
}

#[tokio::test]
async fn ephemeral_bulk_matches_raw_for_multiple_users_and_tracks_only_claimants() {
    let rpc = Arc::new(rpc());
    let bulk = BulkScoreSource::open(
        rpc.clone(),
        &cfg(),
        10,
        BTreeSet::from([ka(ALICE), ka(BOB), ka(ALICE)]),
        1,
        3,
        1_000,
    )
    .await
    .unwrap();
    for user in [ka(ALICE), ka(BOB)] {
        let (raw, _) = earned_score_of(rpc.as_ref(), &cfg(), user, 10, 1_000, 1_000)
            .await
            .unwrap();
        assert_eq!(bulk.gross_score_of(user).await.unwrap(), raw);
    }
    assert_eq!(bulk.metadata.tracked_accounts, 2);
    assert_eq!(bulk.metadata.indexed_tokens, 1);
    assert_eq!(bulk.metadata.indexed_transfers, 3);
    // Four bounded 3-block slices, independent of claimant and rate-segment counts.
    assert_eq!(rpc.global_log_queries.load(Ordering::Relaxed), 4);
}

#[tokio::test]
async fn ephemeral_bulk_reconciles_every_tracked_balance_and_ignores_untracked_accounts() {
    let stranger = "0x000000000000000000000000000000000000cafe";
    let logs = vec![
        transfer(ZERO, stranger, 1_000, 1, 0),
        transfer(ZERO, ALICE, 100, 1, 1),
        transfer(stranger, ZERO, 1_000, 9, 2),
    ];
    let balances = [((ALICE.to_ascii_lowercase(), 10), U256::from(101))]
        .into_iter()
        .collect();
    let error = BulkScoreSource::open(
        Arc::new(score_rpc(logs, balances)),
        &cfg(),
        10,
        BTreeSet::from([ka(ALICE)]),
        1,
        1_000,
        1_000,
    )
    .await
    .err()
    .unwrap();
    assert!(
        error
            .to_string()
            .contains("unsupported token balance semantics")
    );
}

#[tokio::test]
async fn authenticated_checkpoint_matches_raw_and_advances_once_per_token() {
    let rpc = Arc::new(rpc());
    let path = checkpoint_path();
    let key = [7u8; 32];
    let first = CheckpointScoreSource::open(rpc.clone(), &cfg(), 6, &path, 1, &key, 1_000, 1_000)
        .await
        .unwrap();
    assert_eq!(
        first.gross_score_of(ka(ALICE)).await.unwrap(),
        BigUint::from(640u16)
    );
    assert!(
        !path.exists(),
        "unverified checkpoint must not be persisted"
    );
    first.commit(&key).unwrap();
    assert!(path.exists());

    let second = CheckpointScoreSource::open(rpc.clone(), &cfg(), 10, &path, 1, &key, 1_000, 1_000)
        .await
        .unwrap();
    assert_eq!(
        second.gross_score_of(ka(ALICE)).await.unwrap(),
        BigUint::from(900u16)
    );
    assert_eq!(
        second.gross_score_of(ka(BOB)).await.unwrap(),
        BigUint::from(300u16)
    );
    assert_eq!(rpc.global_log_queries.load(Ordering::Relaxed), 2);
    assert_eq!(second.metadata.indexed_transfers, 1);
    second.commit(&key).unwrap();

    let _same = CheckpointScoreSource::open(rpc.clone(), &cfg(), 10, &path, 1, &key, 1_000, 1_000)
        .await
        .unwrap();
    assert_eq!(rpc.global_log_queries.load(Ordering::Relaxed), 2);
    let _ = fs::remove_file(path);
}

#[tokio::test]
async fn checkpoint_tampering_fails_authentication_before_use() {
    let rpc = Arc::new(rpc());
    let path = checkpoint_path();
    let key = [9u8; 32];
    let source = CheckpointScoreSource::open(rpc.clone(), &cfg(), 6, &path, 1, &key, 1_000, 1_000)
        .await
        .unwrap();
    source.commit(&key).unwrap();
    let mut persisted: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    persisted["tokens"][TOKEN]["accounts"][ALICE]["completedNumerator"] =
        json!("999999999999999999999999");
    fs::write(&path, serde_json::to_vec(&persisted).unwrap()).unwrap();
    let error = CheckpointScoreSource::open(rpc, &cfg(), 6, &path, 1, &key, 1_000, 1_000)
        .await
        .err()
        .unwrap();
    assert!(error.to_string().contains("authentication failed"));
    let _ = fs::remove_file(path);
}

fn score_config(decimals: u8, rate: u64, copies: usize) -> IncidentConfig {
    let token = ScoredToken {
        token: ka(TOKEN),
        decimals,
        rates: vec![RatePoint {
            from_block: 1,
            rate: BigUint::from(rate),
        }],
    };
    IncidentConfig {
        coverage_bps: BigUint::from(8_000u16),
        underlying_price_oracle: ka(ZERO),
        conversion_address: ka(ZERO),
        conversion_call_data: vec![],
        params: SettlementParams {
            twap_lookback_blocks: 1,
            holding_margin_blocks: 1,
            sample_step_blocks: 1,
        },
        scored_tokens: vec![token; copies],
    }
}

#[tokio::test]
async fn checkpoint_rejects_reorg_rollback_rate_edit_lock_and_wrong_chain() {
    let key = [3u8; 32];

    let reorg_rpc = Arc::new(rpc());
    let reorg_path = checkpoint_path();
    let reorg_source = CheckpointScoreSource::open(
        reorg_rpc.clone(),
        &cfg(),
        6,
        &reorg_path,
        1,
        &key,
        1_000,
        1_000,
    )
    .await
    .unwrap();
    reorg_source.commit(&key).unwrap();
    reorg_rpc.corrupt_block_hash.store(6, Ordering::Relaxed);
    let error =
        CheckpointScoreSource::open(reorg_rpc, &cfg(), 10, &reorg_path, 1, &key, 1_000, 1_000)
            .await
            .err()
            .unwrap();
    assert!(
        matches!(error, CheckpointError::Invalid(message) if message.contains("block hash mismatch") && message.contains("at 6"))
    );
    fs::remove_file(reorg_path).unwrap();

    let lifecycle_rpc = Arc::new(rpc());
    let lifecycle_path = checkpoint_path();
    let lifecycle_source = CheckpointScoreSource::open(
        lifecycle_rpc.clone(),
        &cfg(),
        10,
        &lifecycle_path,
        1,
        &key,
        1_000,
        1_000,
    )
    .await
    .unwrap();
    lifecycle_source.commit(&key).unwrap();
    let rollback = CheckpointScoreSource::open(
        lifecycle_rpc.clone(),
        &cfg(),
        6,
        &lifecycle_path,
        1,
        &key,
        1_000,
        1_000,
    )
    .await
    .err()
    .unwrap();
    assert!(
        matches!(rollback, CheckpointError::Invalid(message) if message.contains("ahead of requested block 6"))
    );
    let mut edited = cfg();
    edited.scored_tokens[0].rates[0].rate += BigUint::from(1u8);
    let rate_edit = CheckpointScoreSource::open(
        lifecycle_rpc,
        &edited,
        10,
        &lifecycle_path,
        1,
        &key,
        1_000,
        1_000,
    )
    .await
    .err()
    .unwrap();
    assert!(
        matches!(rate_edit, CheckpointError::Invalid(message) if message.contains("rate history mismatch"))
    );
    fs::remove_file(lifecycle_path).unwrap();

    let lock_path = checkpoint_path();
    let lock_file = PathBuf::from(format!("{}.lock", lock_path.display()));
    fs::write(&lock_file, b"occupied").unwrap();
    let locked = CheckpointScoreSource::open(
        Arc::new(rpc()),
        &cfg(),
        6,
        &lock_path,
        1,
        &key,
        1_000,
        1_000,
    )
    .await
    .err()
    .unwrap();
    assert!(matches!(locked, CheckpointError::Locked(_)));
    fs::remove_file(lock_file).unwrap();

    let wrong_chain_rpc = Arc::new(rpc());
    wrong_chain_rpc.chain_id.store(2, Ordering::Relaxed);
    let wrong_chain_path = checkpoint_path();
    let wrong_chain = CheckpointScoreSource::open(
        wrong_chain_rpc,
        &cfg(),
        6,
        &wrong_chain_path,
        1,
        &key,
        1_000,
        1_000,
    )
    .await
    .err()
    .unwrap();
    assert!(
        matches!(wrong_chain, CheckpointError::Invalid(message) if message.contains("RPC chain 2 does not match expected chain 1"))
    );
}

#[tokio::test]
async fn checkpoint_matches_raw_for_more_than_18_decimals() {
    let balances = [
        ((ALICE.to_ascii_lowercase(), 1), U256::from(15)),
        ((ALICE.to_ascii_lowercase(), 10), U256::from(15)),
    ]
    .into_iter()
    .collect();
    let rpc = Arc::new(score_rpc(vec![transfer(ZERO, ALICE, 15, 1, 0)], balances));
    let config = score_config(19, 1_000_000_000_000_000_000, 1);
    let (raw, _) = earned_score_of(rpc.as_ref(), &config, ka(ALICE), 10, 1_000, 1_000)
        .await
        .unwrap();
    assert_eq!(raw, BigUint::from(13u8));
    let path = checkpoint_path();
    let checkpoint =
        CheckpointScoreSource::open(rpc.clone(), &config, 10, &path, 1, &[4u8; 32], 1_000, 1_000)
            .await
            .unwrap();
    assert_eq!(checkpoint.gross_score_of(ka(ALICE)).await.unwrap(), raw);
    let bulk = BulkScoreSource::open(
        rpc,
        &config,
        10,
        BTreeSet::from([ka(ALICE)]),
        1,
        1_000,
        1_000,
    )
    .await
    .unwrap();
    assert_eq!(bulk.gross_score_of(ka(ALICE)).await.unwrap(), raw);
    let _ = fs::remove_file(path);
}

#[tokio::test]
async fn score_divides_once_after_summing_all_token_numerators() {
    let balances = [
        ((ALICE.to_ascii_lowercase(), 1), U256::from(1)),
        ((ALICE.to_ascii_lowercase(), 2), U256::from(1)),
    ]
    .into_iter()
    .collect();
    let rpc = Arc::new(score_rpc(vec![transfer(ZERO, ALICE, 1, 1, 0)], balances));
    let config = score_config(18, 600_000_000_000_000_000, 2);
    let (raw, _) = earned_score_of(rpc.as_ref(), &config, ka(ALICE), 2, 1_000, 1_000)
        .await
        .unwrap();
    assert_eq!(raw, BigUint::from(1u8));
    let path = checkpoint_path();
    let checkpoint =
        CheckpointScoreSource::open(rpc.clone(), &config, 2, &path, 1, &[5u8; 32], 1_000, 1_000)
            .await
            .unwrap();
    assert_eq!(checkpoint.gross_score_of(ka(ALICE)).await.unwrap(), raw);
    let bulk = BulkScoreSource::open(
        rpc,
        &config,
        2,
        BTreeSet::from([ka(ALICE)]),
        1,
        1_000,
        1_000,
    )
    .await
    .unwrap();
    assert_eq!(bulk.gross_score_of(ka(ALICE)).await.unwrap(), raw);
    let _ = fs::remove_file(path);
}
