use alloy_primitives::{Address as AlloyAddress, Bytes, U256};
use alloy_sol_types::SolCall;
use async_trait::async_trait;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::str::FromStr;
use usd8_settlement::Address;
use usd8_settlement::abi::{IDefiInsurance, IRegistry};
use usd8_settlement::config::CHAIN_ID;
use usd8_settlement::incident_open::build_incident_open;
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};

const REGISTRY: &str = "0x3Fa82eC1842f72c36580D84E03377b10B5E2F590";
const DEFI: &str = "0x250cebdd9d6997ffd45c60d6e713f42e44e383ec";
const TOKEN: &str = "0x5300000000000000000000000000000000000004";
const SIGNER: &str = "0xEa29C49787Df66003Af40e3409A1E1766Bfda193";

fn a(value: &str) -> AlloyAddress {
    AlloyAddress::from_str(value).unwrap()
}

fn encoded<C: SolCall>(value: &C::Return) -> Value {
    json!(format!("0x{}", hex::encode(C::abi_encode_returns(value))))
}

struct OpenRpc {
    responses: HashMap<(String, String), Value>,
    active: bool,
    finalized_number: u64,
    change_finalized_hash: bool,
    change_latest_hash: bool,
    finalized_unavailable: bool,
}

#[async_trait]
impl Rpc for OpenRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match method {
            "eth_chainId" => Ok(json!(format!("0x{CHAIN_ID:x}"))),
            "eth_getBlockByNumber" => {
                let tag = params[0].as_str().unwrap();
                if tag == "finalized" && self.finalized_unavailable {
                    return Ok(Value::Null);
                }
                let finalized =
                    tag == "finalized" || tag == format!("0x{:x}", self.finalized_number);
                Ok(json!({
                    "number": if finalized {
                        format!("0x{:x}", self.finalized_number)
                    } else {
                        "0x12d6a8".to_owned()
                    },
                    "timestamp": if finalized { "0x384" } else { "0x3e8" },
                    "hash": format!("0x{}", if finalized && self.change_finalized_hash && tag != "finalized" {
                        "33"
                    } else if finalized {
                        "22"
                    } else if self.change_latest_hash && tag != "latest" {
                        "44"
                    } else {
                        "11"
                    }.repeat(32))
                }))
            }
            "eth_call" => {
                assert_eq!(params[1], json!("0x12d6a8"));
                let to = params[0]["to"].as_str().unwrap().to_ascii_lowercase();
                let data = params[0]["data"].as_str().unwrap();
                let selector = data[..10].to_owned();
                if self.active
                    && selector
                        == format!("0x{}", hex::encode(IDefiInsurance::incidentsCall::SELECTOR))
                {
                    return Ok(encoded::<IDefiInsurance::incidentsCall>(
                        &IDefiInsurance::incidentsReturn {
                            insuredToken: a(TOKEN),
                            claimWindowEndTime: 2_000,
                            root: [0u8; 32].into(),
                            unresolved: U256::from(1),
                            rootSubmittedAt: 0,
                            referenceBlock: 1_200_000,
                            openBlock: 1_200_001,
                            status: 0,
                            disputedAt: 0,
                            claimSetHash: [0u8; 32].into(),
                        },
                    ));
                }
                self.responses
                    .get(&(to, selector))
                    .cloned()
                    .ok_or_else(|| RpcError::JsonRpc {
                        code: -32000,
                        message: "missing canned call".to_owned(),
                    })
            }
            _ => panic!("unexpected RPC method {method}"),
        }
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

fn fixture_with_finalized(active: bool, finalized_number: u64) -> OpenRpc {
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
        REGISTRY,
        IRegistry::defiInsuranceCall::SELECTOR,
        encoded::<IRegistry::defiInsuranceCall>(&a(DEFI)),
    );
    insert(
        REGISTRY,
        IRegistry::teePcrHashCall::SELECTOR,
        encoded::<IRegistry::teePcrHashCall>(&[0x44; 32].into()),
    );
    insert(
        DEFI,
        IDefiInsurance::registryCall::SELECTOR,
        encoded::<IDefiInsurance::registryCall>(&a(REGISTRY)),
    );
    insert(
        DEFI,
        IDefiInsurance::nextIncidentIdCall::SELECTOR,
        encoded::<IDefiInsurance::nextIncidentIdCall>(&U256::from(if active { 2 } else { 1 })),
    );
    insert(
        DEFI,
        IDefiInsurance::getInsuredTokenCall::SELECTOR,
        encoded::<IDefiInsurance::getInsuredTokenCall>(&IDefiInsurance::InsuredToken {
            maxCoverageBps: U256::from(8_000),
            underlyingPriceOracle: a("0x1111111111111111111111111111111111111111"),
            underlyingConversionAddress: AlloyAddress::ZERO,
            underlyingConversionCallData: Bytes::new(),
            minClaimAmount: 1,
        }),
    );
    insert(
        DEFI,
        IDefiInsurance::isTeeSignerCall::SELECTOR,
        encoded::<IDefiInsurance::isTeeSignerCall>(&true),
    );
    for (selector, value) in [
        (
            IDefiInsurance::MAX_REFERENCE_BLOCK_AGECall::SELECTOR,
            43_200,
        ),
        (IDefiInsurance::SUBMIT_DEADLINECall::SELECTOR, 259_200),
        (IDefiInsurance::DISPUTE_PERIODCall::SELECTOR, 172_800),
        (IDefiInsurance::FINALIZE_WINDOWCall::SELECTOR, 345_600),
    ] {
        insert(DEFI, selector, json!(format!("0x{:064x}", value)));
    }
    OpenRpc {
        responses,
        active,
        finalized_number,
        change_finalized_hash: false,
        change_latest_hash: false,
        finalized_unavailable: false,
    }
}

fn fixture(active: bool) -> OpenRpc {
    fixture_with_finalized(active, 1_234_580)
}

#[tokio::test]
async fn open_authorization_is_derived_from_live_contract_state() {
    let authorization = build_incident_open(
        &fixture(false),
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        1_234_567,
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(authorization.incident_id, U256::from(1).to_string());
    assert_eq!(authorization.chain_id, CHAIN_ID);
    assert_eq!(
        authorization.open_digest,
        if cfg!(feature = "sepolia") {
            "0xe7ea0c7c3b31de0748b741449670f22578bd38e98e367132bae03661707acee4"
        } else {
            "0x4742d8cf5e7ea6004cc0dd0bb8c2f20d67c3b106751356c603ada6cd3b6c0485"
        }
    );
    assert_eq!(authorization.tee_pcr_hash, format!("0x{}", "44".repeat(32)));
}

#[tokio::test]
async fn open_authorization_rejects_an_active_incident() {
    assert!(
        build_incident_open(
            &fixture(true),
            Address::from_str(REGISTRY).unwrap(),
            Address::from_str(TOKEN).unwrap(),
            1_234_567,
            Address::from_str(SIGNER).unwrap(),
        )
        .await
        .unwrap_err()
        .to_string()
        .contains("active incident")
    );
}

#[tokio::test]
async fn open_authorization_rejects_an_unfinalized_reference_block() {
    let error = build_incident_open(
        &fixture_with_finalized(false, 1_234_500),
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        1_234_567,
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("not finalized"));
}

#[tokio::test]
async fn open_authorization_accepts_the_finalized_head_as_reference() {
    let finalized = 1_234_580;
    let authorization = build_incident_open(
        &fixture_with_finalized(false, finalized),
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        finalized,
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(authorization.reference_block, finalized);
}

#[tokio::test]
async fn open_authorization_fails_closed_without_a_finalized_head() {
    let mut rpc = fixture(false);
    rpc.finalized_unavailable = true;
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        1_234_567,
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("block finalized not found"));
}

#[tokio::test]
async fn open_authorization_rechecks_the_finalized_anchor_hash() {
    let mut rpc = fixture(false);
    rpc.change_finalized_hash = true;
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        1_234_567,
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("finalized block changed"));
}

#[tokio::test]
async fn open_authorization_rechecks_the_latest_anchor_hash() {
    let mut rpc = fixture(false);
    rpc.change_latest_hash = true;
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        1_234_567,
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("latest block changed"));
}

#[tokio::test]
async fn open_authorization_rejects_a_finalized_head_ahead_of_latest() {
    let error = build_incident_open(
        &fixture_with_finalized(false, 1_234_700),
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        1_234_567,
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("ahead of latest"));
}
