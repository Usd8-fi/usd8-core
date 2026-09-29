use alloy_primitives::{Address as AlloyAddress, U256};
use alloy_sol_types::SolCall;
use async_trait::async_trait;
use serde_json::{Value, json};
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use usd8_score_api::{ScoreNetwork, compute_incremental_score_at};
use usd8_settlement::Address;
use usd8_settlement::abi::{IDefiInsurance, IERC20, IRegistry};
use usd8_settlement::chain::BlockAnchor;
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};

const REGISTRY: &str = "0x0000000000000000000000000000000000001000";
const DEFI: &str = "0x0000000000000000000000000000000000002000";
const TOKEN: &str = "0x0000000000000000000000000000000000003000";
const TOKEN_TWO: &str = "0x0000000000000000000000000000000000004000";
const EMPTY_ACCOUNT: &str = "0x0000000000000000000000000000000000000001";

fn alloy_address(value: &str) -> AlloyAddress {
    AlloyAddress::from_str(value).unwrap()
}

fn address(value: &str) -> Address {
    Address::from_str(value).unwrap()
}

fn encoded<C: SolCall>(value: &C::Return) -> Value {
    json!(format!("0x{}", hex::encode(C::abi_encode_returns(value))))
}

struct EmptyHistoryRpc {
    log_requests: Arc<AtomicUsize>,
}

#[async_trait]
impl Rpc for EmptyHistoryRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match method {
            "eth_chainId" => Ok(json!("0x1")),
            "eth_getBlockByNumber" => {
                let block =
                    u64::from_str_radix(params[0].as_str().unwrap().trim_start_matches("0x"), 16)
                        .unwrap();
                Ok(json!({
                    "number": format!("0x{block:x}"),
                    "timestamp": format!("0x{:x}", block * 12),
                    "hash": format!("0x{block:064x}")
                }))
            }
            "eth_getLogs" => {
                self.log_requests.fetch_add(1, Ordering::Relaxed);
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                Ok(json!([]))
            }
            "eth_call" => {
                let call = &params[0];
                let to = call["to"].as_str().unwrap();
                let data = call["data"].as_str().unwrap();
                let selector = &data[..10];
                match (to, selector) {
                    (REGISTRY, "0xa4119c10") => Ok(encoded::<IRegistry::defiInsuranceCall>(
                        &alloy_address(DEFI),
                    )),
                    (DEFI, "0xcbeee318") => Ok(encoded::<IDefiInsurance::settlementParamsCall>(
                        &IDefiInsurance::settlementParamsReturn {
                            twapLookbackBlocks: 10,
                            minHoldingRequired: 1,
                            sampleStepBlocks: 1,
                        },
                    )),
                    (REGISTRY, "0x3aaa0b0c") => {
                        Ok(encoded::<IRegistry::getScoredTokensCall>(&vec![
                            alloy_address(TOKEN),
                            alloy_address(TOKEN_TWO),
                        ]))
                    }
                    (REGISTRY, "0x99e54713") => {
                        Ok(encoded::<IRegistry::getScoredRateHistoryCall>(&vec![
                            IRegistry::RatePoint {
                                fromBlock: 1,
                                rate: 1_000_000_000_000_000_000,
                            },
                        ]))
                    }
                    (TOKEN | TOKEN_TWO, "0x313ce567") => Ok(encoded::<IERC20::decimalsCall>(&18)),
                    (TOKEN | TOKEN_TWO, "0x70a08231") => {
                        Ok(encoded::<IERC20::balanceOfCall>(&U256::ZERO))
                    }
                    (REGISTRY, "0xf7e2a75c") => {
                        Ok(encoded::<IRegistry::scoreSpentCall>(&U256::ZERO))
                    }
                    _ => panic!("unexpected eth_call to {to} selector {selector}"),
                }
            }
            _ => panic!("unexpected RPC method {method}"),
        }
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

#[tokio::test]
async fn cold_account_with_proven_empty_history_returns_zero_with_bounded_parallel_replay() {
    let requests = Arc::new(AtomicUsize::new(0));
    let rpc = EmptyHistoryRpc {
        log_requests: requests.clone(),
    };
    let reference = BlockAnchor {
        number: 5_001,
        timestamp: 5_001 * 12,
        hash: format!("0x{:064x}", 5_001),
    };

    let (snapshot, checkpoint) = tokio::time::timeout(
        std::time::Duration::from_millis(180),
        compute_incremental_score_at(
            &rpc,
            &ScoreNetwork {
                chain_id: 1,
                name: "test".to_owned(),
            },
            address(REGISTRY),
            address(EMPTY_ACCOUNT),
            reference,
            None,
        ),
    )
    .await
    .expect("independent token histories must replay within the bounded latency budget")
    .unwrap();

    assert_eq!(snapshot.gross_earned_score, "0");
    assert_eq!(snapshot.matured_gross_earned_score, "0");
    assert_eq!(snapshot.score_spent, "0");
    assert_eq!(snapshot.available_score, "0");
    assert_eq!(snapshot.log_requests, "8");
    assert_eq!(requests.load(Ordering::Relaxed), 8);
    assert_eq!(checkpoint.tokens.len(), 2);
    assert_eq!(checkpoint.visible_tokens.len(), 2);
    assert_eq!(snapshot.token_scores[0].token, TOKEN);
    assert_eq!(snapshot.token_scores[1].token, TOKEN_TWO);
}
