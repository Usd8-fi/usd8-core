use alloy_primitives::{Address as AlloyAddress, U256};
use alloy_sol_types::{SolCall, SolEvent};
use async_trait::async_trait;
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;
use usd8_settlement::Address;
use usd8_settlement::abi::{IDefiInsurance, IERC20, IERC1155};
use usd8_settlement::chain::{min_balance_over, min_erc1155_balance_over, read_input_events};
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};

const DEFI: &str = "0x0000000000000000000000000000000000002000";
const TOKEN: &str = "0x0000000000000000000000000000000000003000";
const BOOSTER: &str = "0x0000000000000000000000000000000000004000";
const USER: &str = "0x0000000000000000000000000000000000005000";
const OTHER: &str = "0x0000000000000000000000000000000000006000";

fn aa(value: &str) -> AlloyAddress {
    AlloyAddress::from_str(value).unwrap()
}

fn ka(value: &str) -> Address {
    Address::from_str(value).unwrap()
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

#[derive(Clone)]
struct HistoryRpc {
    logs: Arc<Vec<Value>>,
    balances: Arc<HashMap<(String, u64), U256>>,
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

#[async_trait]
impl Rpc for HistoryRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match method {
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
                let requested_topics = filter["topics"].as_array().cloned().unwrap_or_default();
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
                                && block >= from
                                && block <= to
                                && requested_topics.iter().enumerate().all(|(index, wanted)| {
                                    log["topics"]
                                        .get(index)
                                        .is_some_and(|actual| topic_matches(wanted, actual))
                                })
                        })
                        .cloned()
                        .collect(),
                ))
            }
            "eth_call" => {
                let address = params[0]["to"].as_str().unwrap().to_ascii_lowercase();
                let block =
                    u64::from_str_radix(params[1].as_str().unwrap().trim_start_matches("0x"), 16)
                        .unwrap();
                let value = self
                    .balances
                    .get(&(address, block))
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
            _ => panic!("unexpected method {method}"),
        }
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

fn rpc(logs: Vec<Value>, balances: &[((&str, u64), u64)]) -> HistoryRpc {
    HistoryRpc {
        logs: Arc::new(logs),
        balances: Arc::new(
            balances
                .iter()
                .map(|((address, block), value)| {
                    ((address.to_ascii_lowercase(), *block), U256::from(*value))
                })
                .collect(),
        ),
    }
}

#[tokio::test]
async fn incident_events_include_only_member_cancellations_in_chain_order() {
    let logs = vec![
        event_log(
            DEFI,
            &IDefiInsurance::ClaimRegistered {
                claimId: U256::from(1),
                incidentId: U256::from(9),
                user: aa(USER),
                insuredTokenAmount: 100,
                scoreToSpend: U256::from(40),
                boosterAmount: U256::from(2),
            },
            11,
            0,
        ),
        event_log(
            DEFI,
            &IDefiInsurance::ClaimRegistered {
                claimId: U256::from(2),
                incidentId: U256::from(9),
                user: aa(OTHER),
                insuredTokenAmount: 50,
                scoreToSpend: U256::from(20),
                boosterAmount: U256::ZERO,
            },
            12,
            1,
        ),
        event_log(
            DEFI,
            &IDefiInsurance::ClaimCancelled {
                claimId: U256::from(777),
                user: aa(OTHER),
            },
            12,
            2,
        ),
        event_log(
            DEFI,
            &IDefiInsurance::ClaimCancelled {
                claimId: U256::from(2),
                user: aa(OTHER),
            },
            13,
            3,
        ),
    ];
    let (events, metrics) = read_input_events(
        &rpc(logs, &[]),
        ka(DEFI),
        &BigUint::from(9u8),
        10,
        14,
        1000,
        1000,
    )
    .await
    .unwrap();
    assert_eq!(events.len(), 3);
    assert_eq!(events[0].claim_id, BigUint::from(1u8));
    assert_eq!(events[1].claim_id, BigUint::from(2u8));
    assert_eq!(events[2].claim_id, BigUint::from(2u8));
    assert_eq!(events[2].block_number, 13);
    assert_eq!(metrics.requests, 2);
}

#[tokio::test]
async fn erc20_minimum_nets_self_transfer_and_reconciles_endpoint() {
    let logs = vec![
        event_log(
            TOKEN,
            &IERC20::Transfer {
                from: aa(USER),
                to: aa(OTHER),
                value: U256::from(20),
            },
            11,
            0,
        ),
        event_log(
            TOKEN,
            &IERC20::Transfer {
                from: aa(OTHER),
                to: aa(USER),
                value: U256::from(10),
            },
            12,
            1,
        ),
        event_log(
            TOKEN,
            &IERC20::Transfer {
                from: aa(USER),
                to: aa(USER),
                value: U256::from(50),
            },
            13,
            2,
        ),
    ];
    let (minimum, metrics) = min_balance_over(
        &rpc(logs, &[((TOKEN, 10), 100), ((TOKEN, 13), 90)]),
        ka(TOKEN),
        ka(USER),
        10,
        13,
        1000,
        1000,
    )
    .await
    .unwrap();
    assert_eq!(minimum, BigUint::from(80u8));
    assert_eq!(metrics.requests, 2);
}

#[tokio::test]
async fn erc20_endpoint_mismatch_fails_closed() {
    let logs = vec![event_log(
        TOKEN,
        &IERC20::Transfer {
            from: aa(USER),
            to: aa(OTHER),
            value: U256::from(20),
        },
        11,
        0,
    )];
    let error = min_balance_over(
        &rpc(logs, &[((TOKEN, 10), 100), ((TOKEN, 11), 81)]),
        ka(TOKEN),
        ka(USER),
        10,
        11,
        1000,
        1000,
    )
    .await
    .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("unsupported token balance semantics")
    );
}

#[tokio::test]
async fn erc1155_minimum_handles_batch_and_self_transfer() {
    let logs = vec![
        event_log(
            BOOSTER,
            &IERC1155::TransferBatch {
                operator: aa(OTHER),
                from: aa(USER),
                to: aa(OTHER),
                ids: vec![U256::from(1), U256::from(2)],
                values: vec![U256::from(2), U256::from(99)],
            },
            11,
            0,
        ),
        event_log(
            BOOSTER,
            &IERC1155::TransferSingle {
                operator: aa(OTHER),
                from: aa(USER),
                to: aa(USER),
                id: U256::from(1),
                value: U256::from(5),
            },
            12,
            1,
        ),
        event_log(
            BOOSTER,
            &IERC1155::TransferSingle {
                operator: aa(OTHER),
                from: aa(OTHER),
                to: aa(USER),
                id: U256::from(1),
                value: U256::from(1),
            },
            13,
            2,
        ),
    ];
    let (minimum, metrics) = min_erc1155_balance_over(
        &rpc(logs, &[((BOOSTER, 10), 3), ((BOOSTER, 13), 2)]),
        ka(BOOSTER),
        ka(USER),
        &BigUint::from(1u8),
        10,
        13,
        1000,
        1000,
    )
    .await
    .unwrap();
    assert_eq!(minimum, BigUint::from(1u8));
    assert_eq!(metrics.requests, 4);
}
