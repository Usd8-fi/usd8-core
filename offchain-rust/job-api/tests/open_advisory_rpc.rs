#![cfg(feature = "lambda")]
// This fixture exercises the RPC adapter; the cache engine has its own suite.
#[allow(dead_code)]
#[path = "../src/open_advisory_cache.rs"]
mod open_advisory_cache;
#[path = "../src/open_advisory_rpc.rs"]
mod open_advisory_rpc;
use alloy_primitives::{Address, B256, Bytes, U256};
use alloy_sol_types::SolCall;
use async_trait::async_trait;
use open_advisory_cache::AdvisorySource;
use serde_json::{Value, json};
use usd8_settlement::abi::{IDefiInsurance as D, IMulticall3 as M, IRegistry as R};
const REG: &str = "0x1111111111111111111111111111111111111111";
const MODULE: &str = "0x2222222222222222222222222222222222222222";
const TOKEN: &str = "0x3333333333333333333333333333333333333333";
struct Rpc {
    step: u64,
    active: bool,
}
#[async_trait]
impl usd8_settlement::rpc::Rpc for Rpc {
    async fn request(
        &self,
        method: &str,
        params: Value,
    ) -> Result<Value, usd8_settlement::rpc::RpcError> {
        Ok(match method {
            "eth_chainId" => json!(format!("0x{:x}", usd8_tee_job_api::configured_chain_id())),
            "eth_getBlockByNumber" => {
                json!({"number":"0x3e8","timestamp":"0x1000","hash":format!("0x{}", "11".repeat(32))})
            }
            "eth_call" => {
                let data =
                    hex::decode(params[0]["data"].as_str().unwrap().trim_start_matches("0x"))
                        .unwrap();
                let bytes = if data.starts_with(&R::defiInsuranceCall::SELECTOR) {
                    R::defiInsuranceCall::abi_encode_returns(&MODULE.parse::<Address>().unwrap())
                } else {
                    let calls = M::aggregate3Call::abi_decode(&data).unwrap().calls;
                    let results: Vec<_> = calls
                        .iter()
                        .map(|c| {
                            let d = &c.callData;
                            let value = if d.starts_with(&D::registryCall::SELECTOR) {
                                D::registryCall::abi_encode_returns(
                                    &REG.parse::<Address>().unwrap(),
                                )
                            } else if d.starts_with(&D::nextIncidentIdCall::SELECTOR) {
                                D::nextIncidentIdCall::abi_encode_returns(&1)
                            } else if d.starts_with(&R::incidentTimingConfigCall::SELECTOR) {
                                R::incidentTimingConfigCall::abi_encode_returns(
                                    &R::IncidentTimingConfig {
                                        phaseWindow: 100,
                                        maxReferenceBlockAge: 100,
                                    },
                                )
                            } else if d.starts_with(&R::incidentOpenPriceConfigCall::SELECTOR) {
                                R::incidentOpenPriceConfigCall::abi_encode_returns(
                                    &R::IncidentOpenPriceConfig {
                                        twapBlocks: 20,
                                        sampleStepBlocks: self.step,
                                        minimumDropBps: 2000,
                                    },
                                )
                            } else if d.starts_with(&D::getInsuredTokenCall::SELECTOR) {
                                D::getInsuredTokenCall::abi_encode_returns(&D::InsuredToken {
                                    maxCoverageBps: 8000,
                                    underlyingPriceOracle: Address::ZERO,
                                    underlyingConversionAddress: Address::ZERO,
                                    underlyingConversionCallData: Bytes::new(),
                                })
                            } else if d.starts_with(&D::incidentOpenEligibilityHashCall::SELECTOR) {
                                D::incidentOpenEligibilityHashCall::abi_encode_returns(
                                    &B256::repeat_byte(7),
                                )
                            } else if d.starts_with(&R::teePcrHashCall::SELECTOR) {
                                R::teePcrHashCall::abi_encode_returns(&B256::repeat_byte(8))
                            } else {
                                U256::from(u64::from(self.active))
                                    .to_be_bytes::<32>()
                                    .to_vec()
                            };
                            M::Result {
                                success: true,
                                returnData: value.into(),
                            }
                        })
                        .collect();
                    M::aggregate3Call::abi_encode_returns(&results)
                };
                json!(format!("0x{}", hex::encode(bytes)))
            }
            _ => panic!("unexpected method {method}"),
        })
    }
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
}
#[tokio::test]
async fn live_configuration_commitment_changes_and_active_incident_fails_closed() {
    let rpc = Rpc {
        step: 5,
        active: false,
    };
    let source = open_advisory_rpc::Source {
        rpc: &rpc,
        registry: REG.parse().unwrap(),
        module: MODULE.parse().unwrap(),
        token: TOKEN.parse().unwrap(),
    };
    let first = source.binding().await.unwrap();
    assert_eq!(
        source.refresh().await.unwrap(),
        open_advisory_cache::Semantic::NoDrop
    );
    let rpc2 = Rpc {
        step: 10,
        active: false,
    };
    let source2 = open_advisory_rpc::Source {
        rpc: &rpc2,
        ..source
    };
    assert_ne!(
        first.commitment,
        source2.binding().await.unwrap().commitment
    );
    let active = Rpc {
        step: 5,
        active: true,
    };
    let source3 = open_advisory_rpc::Source {
        rpc: &active,
        ..source
    };
    assert!(matches!(
        source3.binding().await,
        Err(open_advisory_cache::CheckError::Active)
    ));
}
