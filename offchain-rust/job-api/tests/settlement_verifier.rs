#![cfg(any(feature = "sepolia", feature = "lambda", feature = "worker"))]
#[path = "../src/settlement_verifier.rs"]
mod settlement_verifier;
use serde_json::{Value, json};
use settlement_verifier::Authorization::CurrentSigner;
use settlement_verifier::*;
use usd8_settlement::typed_data::{SettlementDigestInput, settlement_digest};
use usd8_settlement::{Address, MerkleRow, SettlementTree};
use usd8_tee_job_api::sign_digest;

fn address(byte: u8) -> Address {
    Address::from_bytes([byte; 20])
}
fn hash(byte: u8) -> String {
    format!("0x{}", hex::encode([byte; 32]))
}
fn policy() -> PromotionPolicy {
    PromotionPolicy {
        chain_id: 1,
        registry: address(1),
        defi_insurance: address(2),
    }
}
fn fixture() -> Value {
    let row = MerkleRow {
        claim_id: 1u8.into(),
        user: address(3),
        amounts: vec![90u8.into()],
        score_spent: 2u8.into(),
        boosted_score: 2u8.into(),
        eligible_amount: 4u8.into(),
        eligible_booster_amount: 0u8.into(),
    };
    let root = SettlementTree::new(&1u8.into(), &[row]).unwrap().root_hex();
    let digest = settlement_digest(&SettlementDigestInput {
        chain_id: 1,
        verifying_contract: address(2),
        incident_id: 1u8.into(),
        root: root.clone(),
        unresolved_claims: 1u8.into(),
        pool_payouts: vec![100u8.into()],
        pool_addrs: vec![address(4)],
        claim_set: hash(5),
        tee_pcr_hash: hash(6),
    })
    .unwrap();
    let sig = sign_digest(&[7; 32], &hex::decode(&digest[2..]).unwrap()).unwrap();
    json!({"schemaVersion":2,"chainId":1,"registry":address(1).to_string(),"defiInsurance":address(2).to_string(),"incidentId":"1","referenceBlock":"8","root":root,"unresolvedClaims":"1","poolAddrs":[address(4).to_string()],"poolPayouts":["100"],"claimSetHash":hash(5),"teePcrHash":hash(6),"protocolFeeShareBps":"1000","settlementDigest":digest,"signature":sig.signature,"signer":sig.signer,"rows":[{"claimId":"1","user":address(3).to_string(),"amounts":["90"],"scoreSpent":"2","boostedScore":"2","eligibleAmount":"4","eligibleBoosterAmount":"0"}]})
}
use async_trait::async_trait;
use sha3::{Digest, Keccak256};
use std::sync::Mutex;
use usd8_settlement::rpc::{Rpc, RpcError};
fn word(n: u64) -> String {
    format!("{n:064x}")
}
fn addrword(a: Address) -> String {
    format!("{}{}", "0".repeat(24), hex::encode(a.as_slice()))
}
fn selector(s: &str) -> String {
    hex::encode(&Keccak256::digest(s.as_bytes())[..4])
}
struct MockRpc {
    authorized: bool,
    calls: Mutex<Vec<(String, Value)>>,
}
impl MockRpc {
    fn new(authorized: bool) -> Self {
        Self {
            authorized,
            calls: Mutex::new(vec![]),
        }
    }
}
#[async_trait]
impl Rpc for MockRpc {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        self.calls
            .lock()
            .unwrap()
            .push((method.into(), params.clone()));
        Ok(match method {
            "eth_chainId" => json!("0x1"),
            "eth_getCode" => json!("0x6000"),
            "eth_getBlockByNumber" => {
                let n = match params[0].as_str().unwrap() {
                    "finalized" => 20,
                    "latest" => 21,
                    s => u64::from_str_radix(&s[2..], 16).unwrap(),
                };
                json!({"number":format!("0x{n:x}"),"timestamp":format!("0x{:x}",n*10),"hash":hash(n as u8)})
            }
            "eth_call" => {
                let data = params[0]["data"].as_str().unwrap();
                let sel = &data[2..10];
                let output = if sel == selector("defiInsurance()") {
                    addrword(address(2))
                } else if sel == selector("registry()") {
                    addrword(address(1))
                } else if sel == selector("incidents(uint256)") {
                    [
                        addrword(address(9)),
                        word(0),
                        word(8),
                        word(10),
                        word(150),
                        "00".repeat(32),
                        word(1),
                        "05".repeat(32),
                        "06".repeat(32),
                        word(1000),
                    ]
                    .concat()
                } else if sel == selector("incidentPools(uint256)") {
                    [word(32), word(1), addrword(address(4))].concat()
                } else if sel == selector("incidentPhaseWindow(uint256)") {
                    word(50)
                } else if sel == selector("isTeeSigner(address)") {
                    assert_eq!(
                        &data[10..],
                        addrword(fixture()["signer"].as_str().unwrap().parse().unwrap())
                    );
                    word(u64::from(self.authorized))
                } else {
                    panic!("unexpected call: {data}")
                };
                json!(format!("0x{output}"))
            }
            _ => panic!("unexpected RPC {method}: {params}"),
        })
    }
}
#[tokio::test]
async fn authorizes_recovered_signer_only_via_canonical_pinned_rpc() {
    let rpc = MockRpc::new(true);
    let verified = verify_for_promotion(&rpc, &policy(), "1", &fixture())
        .await
        .unwrap();
    assert_eq!(verified.authorization(), CurrentSigner);
    assert_eq!(verified.block().number, 20);
    for (method, params) in rpc.calls.lock().unwrap().iter() {
        if method == "eth_call" {
            assert!(params[1].as_str().unwrap().starts_with("0x"));
        }
    }
}

#[test]
fn recomputes_digest_rows_and_recovers_real_signature() {
    let artifact = fixture();
    let result = verify_candidate(&policy(), "1", &artifact).unwrap();
    assert_eq!(
        result.digest(),
        artifact["settlementDigest"].as_str().unwrap()
    );
    assert_eq!(
        result.signer().to_string(),
        artifact["signer"].as_str().unwrap()
    );
}

#[test]
fn rejects_unsigned_field_and_merkle_mutations() {
    let mutations = [
        ("/settlementDigest", json!(hash(8))),
        ("/root", json!(hash(8))),
        ("/rows/0/amounts/0", json!("91")),
        ("/rows/0/user", json!(address(8).to_string())),
        ("/poolPayouts/0", json!("101")),
        ("/poolAddrs/0", json!(address(8).to_string())),
        ("/claimSetHash", json!(hash(8))),
        ("/teePcrHash", json!(hash(8))),
        ("/unresolvedClaims", json!("2")),
        ("/protocolFeeShareBps", json!("2001")),
        ("/chainId", json!(2)),
        ("/registry", json!(address(8).to_string())),
        ("/defiInsurance", json!(address(8).to_string())),
        ("/incidentId", json!("2")),
        ("/rows/0/scoreSpent", json!("+2")),
        ("/rows/0/scoreSpent", json!("02")),
        ("/rows/0/scoreSpent", json!("9".repeat(79))),
        ("/signer", json!(address(8).to_string())),
        ("/signature", json!(format!("0x{}", "00".repeat(65)))),
    ];
    for (pointer, value) in mutations {
        let mut a = fixture();
        *a.pointer_mut(pointer).unwrap() = value;
        assert!(
            verify_candidate(&policy(), "1", &a).is_err(),
            "accepted {pointer}"
        );
    }
    let mut a = fixture();
    a["rows"][0]["proof"] = json!([hash(8)]);
    assert!(verify_candidate(&policy(), "1", &a).is_err());
    a = fixture();
    a["signature"] = json!(format!(
        "0x{}{}1b",
        word(1),
        "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140"
    ));
    assert!(
        verify_candidate(&policy(), "1", &a)
            .unwrap_err()
            .to_string()
            .contains("high-s")
    );
}
#[tokio::test]
async fn self_declared_consistent_signer_has_no_authority() {
    let a = fixture();
    assert!(verify_candidate(&policy(), "1", &a).is_ok());
    assert!(
        verify_for_promotion(&MockRpc::new(false), &policy(), "1", &a)
            .await
            .unwrap_err()
            .to_string()
            .contains("unauthorized")
    );
}
#[tokio::test]
async fn invalid_first_candidate_cannot_reserve_shared_locator() {
    let mut invalid = fixture();
    invalid["signature"] = json!(format!("0x{}", "00".repeat(65)));
    let mut shared = None;
    for candidate in [invalid, fixture()] {
        if verify_for_promotion(&MockRpc::new(true), &policy(), "1", &candidate)
            .await
            .is_ok()
            && shared.is_none()
        {
            shared = Some(candidate);
        }
    }
    assert_eq!(shared, Some(fixture()));
}
#[tokio::test]
async fn accepted_root_does_not_authenticate_unrelated_transaction() {
    let rpc = HistoricalRpc {
        inner: MockRpc::new(false),
        tamper: true,
    };
    assert!(
        verify_for_promotion(&rpc, &policy(), "1", &fixture())
            .await
            .is_err()
    );
}
struct Corrupt<R> {
    inner: R,
    case: &'static str,
    reads: Mutex<u64>,
}
#[async_trait]
impl<R: Rpc> Rpc for Corrupt<R> {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        let mut value = self.inner.request(method, params.clone()).await?;
        if self.case == "network" && method == "eth_chainId" {
            value = json!("0x2");
        }
        if self.case == "code" && method == "eth_getCode" {
            value = json!("0x");
        }
        if method == "eth_getBlockByNumber" {
            if self.case == "finality-unavailable" && params[0] == "finalized" {
                value = Value::Null;
            }
            if self.case == "finality-ahead" && params[0] == "finalized" {
                value["number"] = json!("0x99");
            }
            if self.case == "reorg" && params[0] == "0x14" {
                value["hash"] = json!(hash(99));
            }
        }
        if method == "eth_call" {
            let data = params[0]["data"].as_str().unwrap();
            if self.case == "binding" && data.starts_with(&format!("0x{}", selector("registry()")))
            {
                value = json!(format!("0x{}", addrword(address(99))));
            }
            if self.case == "pools"
                && data.starts_with(&format!("0x{}", selector("incidentPools(uint256)")))
            {
                value = json!(format!(
                    "0x{}{}{}",
                    word(32),
                    word(1),
                    addrword(address(99))
                ));
            }
            if self.case == "bool"
                && data.starts_with(&format!("0x{}", selector("isTeeSigner(address)")))
            {
                value = json!(format!("0x{}", word(2)));
            }
            if data.starts_with(&format!("0x{}", selector("incidents(uint256)"))) {
                let replacement = match self.case {
                    "pcr" => Some((8, "09".repeat(32))),
                    "fee" => Some((9, word(999))),
                    "claims" if params[1] == "0xf" => Some((6, word(2))),
                    "claimset" if params[1] == "0xf" => Some((7, "09".repeat(32))),
                    "standing-root" if params[1] == "0x14" => Some((5, "09".repeat(32))),
                    _ => None,
                };
                if let Some((index, replacement)) = replacement {
                    let raw = value.as_str().unwrap();
                    value = json!(format!(
                        "{}{}{}",
                        &raw[..2 + index * 64],
                        replacement,
                        &raw[2 + (index + 1) * 64..]
                    ));
                }
            }
        }
        if method == "eth_getTransactionReceipt" {
            match self.case {
                "reverted" => value["status"] = json!("0x0"),
                "receipt-hash" => value["blockHash"] = json!(hash(99)),
                "receipt-log" => value["logs"] = json!([]),
                _ => (),
            }
        }
        *self.reads.lock().unwrap() += 1;
        Ok(value)
    }
}
#[tokio::test]
async fn fails_closed_on_rpc_state_and_anchor_mismatches() {
    for case in [
        "network",
        "code",
        "finality-unavailable",
        "finality-ahead",
        "reorg",
        "binding",
        "pools",
        "bool",
        "pcr",
        "fee",
        "claims",
        "claimset",
    ] {
        let rpc = Corrupt {
            inner: MockRpc::new(true),
            case,
            reads: Mutex::new(0),
        };
        assert!(
            verify_for_promotion(&rpc, &policy(), "1", &fixture())
                .await
                .is_err(),
            "accepted {case}"
        );
    }
}
#[tokio::test]
async fn historical_evidence_must_be_successful_canonical_and_standing() {
    for case in ["reverted", "receipt-hash", "receipt-log", "standing-root"] {
        let rpc = Corrupt {
            inner: HistoricalRpc {
                inner: MockRpc::new(false),
                tamper: false,
            },
            case,
            reads: Mutex::new(0),
        };
        assert!(
            verify_for_promotion(&rpc, &policy(), "1", &fixture())
                .await
                .is_err(),
            "accepted {case}"
        );
    }
}

#[tokio::test]
async fn verifies_real_terminal_result_shape_without_trusting_outer_digest() {
    let mut a = fixture();
    let signature = a.as_object_mut().unwrap().remove("signature").unwrap();
    let signer = a.as_object_mut().unwrap().remove("signer").unwrap();
    let mut result =
        json!({"digest":a["settlementDigest"],"artifact":a,"signature":signature,"signer":signer});
    assert!(
        verify_result_for_promotion(&MockRpc::new(true), &policy(), "1", &result)
            .await
            .is_ok()
    );
    let mut ambiguous = result.clone();
    ambiguous["artifact"]["digest"] = json!(hash(99));
    assert!(
        verify_result_for_promotion(&MockRpc::new(true), &policy(), "1", &ambiguous)
            .await
            .is_err()
    );
    result["digest"] = json!(hash(99));
    assert!(
        verify_result_for_promotion(&MockRpc::new(true), &policy(), "1", &result)
            .await
            .is_err()
    );
}
#[tokio::test]
async fn current_signer_recovers_corrected_standing_root_without_original_event() {
    let rpc = RecoveryRpc;
    let mut a = fixture();
    let sig = sign_digest(
        &[8; 32],
        &hex::decode(&a["settlementDigest"].as_str().unwrap()[2..]).unwrap(),
    )
    .unwrap();
    a["signature"] = json!(sig.signature);
    a["signer"] = json!(sig.signer);
    let verified = verify_for_promotion(&rpc, &policy(), "1", &a)
        .await
        .unwrap();
    assert_eq!(verified.authorization(), CurrentSigner);
    for case in ["standing-root", "pools", "pcr", "fee", "claims", "claimset"] {
        let rpc = Corrupt {
            inner: RecoveryRpc,
            case,
            reads: Mutex::new(0),
        };
        assert!(
            verify_for_promotion(&rpc, &policy(), "1", &a)
                .await
                .is_err(),
            "accepted {case}"
        );
    }
}
struct RecoveryRpc;
#[async_trait]
impl Rpc for RecoveryRpc {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        if method == "eth_call"
            && params[0]["data"]
                .as_str()
                .unwrap()
                .starts_with(&format!("0x{}", selector("isTeeSigner(address)")))
        {
            let sig = sign_digest(
                &[8; 32],
                &hex::decode(&fixture()["settlementDigest"].as_str().unwrap()[2..]).unwrap(),
            )
            .unwrap();
            assert_eq!(
                &params[0]["data"].as_str().unwrap()[10..],
                addrword(sig.signer.parse().unwrap())
            );
            return Ok(json!(format!("0x{}", word(1))));
        }
        if method == "eth_getLogs" {
            return Ok(json!([]));
        }
        HistoricalRpc {
            inner: MockRpc::new(true),
            tamper: false,
        }
        .request(method, params)
        .await
    }
}
struct WrapperRpc {
    case: &'static str,
}
fn wrapper_trace() -> Value {
    json!({"type":"CALL", "from":address(7).to_string(), "to":address(8).to_string(),
    "input":"0x12345678", "value":"0x0", "calls":[
        {"type":"DELEGATECALL", "from":address(8).to_string(), "to":address(9).to_string(), "input":"0x", "calls":[
            {"type":"CALL", "from":address(8).to_string(), "to":address(2).to_string(), "value":"0x0", "input":format!("{}abcd", settlement_calldata(&fixture()))}
        ]}
    ]})
}
#[async_trait]
impl Rpc for WrapperRpc {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        if method == "debug_traceTransaction" {
            assert_eq!(params[0], hash(30));
            assert_eq!(params[1]["tracer"], "callTracer");
            assert_eq!(params[1]["tracerConfig"]["onlyTopCall"], false);
            assert!(params[1]["timeout"].is_string());
            if self.case == "unavailable" {
                return Err(RpcError::JsonRpc {
                    code: -32601,
                    message: "method not found".into(),
                });
            }
            if self.case == "null" {
                return Ok(Value::Null);
            }
            let mut v = wrapper_trace();
            if self.case == "constructor" {
                v["type"] = json!("CREATE");
            }
            match self.case {
                "inner-revert" => v["calls"][0]["calls"][0]["error"] = json!("execution reverted"),
                "ancestor-revert" => v["calls"][0]["error"] = json!("execution reverted"),
                "root-revert" => v["error"] = json!("execution reverted"),
                "wrong-to" => v["calls"][0]["calls"][0]["to"] = json!(address(99).to_string()),
                "malformed-address" => v["calls"][0]["calls"][0]["to"] = json!("bad"),
                "missing-input" => v["calls"][0]["calls"][0]["input"] = Value::Null,
                "malformed-input" => v["calls"][0]["calls"][0]["input"] = json!("0xzz"),
                "malformed-ancestor" => v["calls"][0]["type"] = Value::Null,
                "delegate-not-call" => v["calls"][0]["calls"][0]["type"] = json!("DELEGATECALL"),
                "wrong-fields" => {
                    let mut a = fixture();
                    a["root"] = json!(hash(99));
                    v["calls"][0]["calls"][0]["input"] = json!(settlement_calldata(&a));
                }
                "unrelated-trace" => v["input"] = json!("0xdeadbeef"),
                "wrong-from" => v["from"] = json!(address(99).to_string()),
                "wrong-value" => v["value"] = json!("0x1"),
                "oversized" => v["output"] = json!("aa".repeat(2 * 1024 * 1024)),
                "deep" => {
                    for _ in 0..150 {
                        v["calls"] = json!([v["calls"].take()]);
                    }
                }
                "caught-sibling" => {
                    let mut reverted = v["calls"][0].clone();
                    reverted["error"] = json!("execution reverted");
                    v["calls"].as_array_mut().unwrap().insert(0, reverted);
                }
                _ => (),
            }
            return Ok(v);
        }
        let mut v = HistoricalRpc {
            inner: MockRpc::new(false),
            tamper: false,
        }
        .request(method, params)
        .await?;
        if method == "eth_getTransactionReceipt" && self.case == "missing-receipt-hash" {
            v["transactionHash"] = Value::Null;
        }
        if method == "eth_getTransactionReceipt" && self.case == "constructor" {
            v["contractAddress"] = json!(address(8).to_string());
        }
        if method == "eth_getTransactionByHash" {
            v["to"] = if self.case == "constructor" {
                Value::Null
            } else {
                json!(address(8).to_string())
            };
            v["from"] = json!(address(7).to_string());
            v["input"] = json!("0x12345678");
            v["value"] = json!("0x0");
            if self.case == "wrong-tx" {
                v["hash"] = json!(hash(99));
            }
            if self.case == "wrong-block" {
                v["blockHash"] = json!(hash(99));
            }
        }
        Ok(v)
    }
}
#[tokio::test]
async fn historical_wrapper_accepts_successful_inner_call_and_caught_reverted_sibling() {
    for case in ["success", "caught-sibling", "constructor"] {
        let v = verify_for_promotion(&WrapperRpc { case }, &policy(), "1", &fixture())
            .await
            .unwrap();
        assert_eq!(v.authorization(), Authorization::AcceptedOnchain);
    }
}
#[tokio::test]
async fn historical_wrapper_rejects_reverted_paths_unrelated_trace_and_fields() {
    for case in [
        "inner-revert",
        "ancestor-revert",
        "root-revert",
        "wrong-to",
        "delegate-not-call",
        "wrong-fields",
        "unrelated-trace",
        "wrong-from",
        "wrong-value",
        "wrong-tx",
        "wrong-block",
    ] {
        assert!(
            verify_for_promotion(&WrapperRpc { case }, &policy(), "1", &fixture())
                .await
                .is_err(),
            "accepted {case}"
        );
    }
}
#[tokio::test]
async fn historical_wrapper_missing_or_resource_limited_trace_is_retryable_rpc_error() {
    for case in [
        "unavailable",
        "null",
        "oversized",
        "deep",
        "malformed-ancestor",
    ] {
        let e = verify_for_promotion(&WrapperRpc { case }, &policy(), "1", &fixture())
            .await
            .unwrap_err();
        assert!(matches!(e, VerificationError::Rpc(_)), "{case}: {e}");
    }
}
struct CalldataRpc {
    input: String,
}
#[async_trait]
impl Rpc for CalldataRpc {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        let mut v = HistoricalRpc {
            inner: MockRpc::new(false),
            tamper: false,
        }
        .request(method, params)
        .await?;
        if method == "eth_getTransactionByHash" {
            v["input"] = json!(self.input);
        }
        Ok(v)
    }
}
#[tokio::test]
async fn accepted_abi_arguments_allow_trailing_data_and_unaligned_reordered_tails() {
    let a = fixture();
    let canonical = settlement_calldata(&a);
    // Solidity permits reordered dynamic tails, unaligned offsets, unused gaps,
    // nonzero bytes padding and trailing bytes; equality must be semantic.
    let alternative = format!(
        "0x{}{}{}{}ff{}{}{}{}{}abcd",
        selector("settleIncident(bytes32,uint256[],bytes)"),
        &a["root"].as_str().unwrap()[2..],
        word(225),
        word(97),
        word(65),
        &a["signature"].as_str().unwrap()[2..],
        "ab".repeat(31),
        word(1),
        word(100)
    );
    for input in [format!("{canonical}deadbeef"), alternative] {
        let verified = verify_for_promotion(&CalldataRpc { input }, &policy(), "1", &a)
            .await
            .unwrap();
        assert_eq!(verified.authorization(), Authorization::AcceptedOnchain);
    }
}
#[tokio::test]
async fn accepted_abi_rejects_wrong_arguments_and_checked_bound_overflows() {
    let canonical = settlement_calldata(&fixture());
    for (start, end, replacement) in [
        (10, 74, "09".repeat(32)),   // root
        (74, 138, "ff".repeat(32)),  // offset overflow
        (138, 202, word(999999)),    // bytes out of bounds
        (202, 266, "ff".repeat(32)), // array length overflow
        (266, 330, word(101)),       // payout
        (330, 394, word(64)),        // signature size
        (394, 396, "00".into()),     // signature
    ] {
        let mut input = canonical.clone();
        input.replace_range(start..end, &replacement);
        assert!(
            verify_for_promotion(&CalldataRpc { input }, &policy(), "1", &fixture())
                .await
                .is_err()
        );
    }
    for input in ["0x".into(), canonical[..canonical.len() - 100].into()] {
        assert!(
            verify_for_promotion(&CalldataRpc { input }, &policy(), "1", &fixture())
                .await
                .is_err()
        );
    }
}
#[tokio::test]
async fn producer_artifact_and_terminal_serializers_round_trip_through_promotion() {
    use usd8_settlement::chain::{self, BlockAnchor, SettlementAnchors};
    use usd8_settlement::config::BootstrapConfig;
    use usd8_settlement::engine::{ScoreSourceMetadata, SettlementRun};
    use usd8_settlement::{KernelOutput, SettledRow};
    use usd8_tee_job_api::TerminalEnvelope;
    let config = BootstrapConfig {
        version: usd8_settlement::config::CONFIG_VERSION,
        chain_id: 1,
        registry: address(1),
        defi_insurance: address(2),
        booster_id: 1,
        booster_boost_bps: 10000,
        asset_usd_feed: Default::default(),
        max_oracle_staleness: 3600,
    };
    let rpc = MockRpc::new(true);
    let incident = chain::incident_at(&rpc, address(2), 1u8.into(), Some(15))
        .await
        .unwrap();
    let anchor = |n| BlockAnchor {
        number: n,
        timestamp: n * 10,
        hash: hash(n as u8),
    };
    // Deterministic synthetic engine output, serialized by the real producer.
    // This covers wire compatibility, not independent economic recomputation.
    let run = SettlementRun {
        incident_id: 1u8.into(),
        incident: incident.clone(),
        window_incident: incident.clone(),
        latest_incident: incident,
        anchors: SettlementAnchors {
            reference: anchor(8),
            open: anchor(10),
            window_end: anchor(15),
            finalized_head: anchor(20),
        },
        config_hash: config.hash().unwrap(),
        tee_pcr_hash: hash(6),
        pool_order: vec![address(4)],
        pool_addrs: vec![address(4)],
        twap_ratio: 1u8.into(),
        underlying_usd: 1u8.into(),
        events: vec![],
        output: KernelOutput {
            rows: vec![SettledRow {
                claim_id: 1u8.into(),
                user: address(3),
                escrow_amount: 4u8.into(),
                eligible_amount: 4u8.into(),
                loss_usd: 100u8.into(),
                gross_earned_score: 2u8.into(),
                earned_score: 2u8.into(),
                score_spent: 2u8.into(),
                boosted_score: 2u8.into(),
                booster_amount: 0u8.into(),
                eligible_booster_amount: 0u8.into(),
                payout_usd: 90u8.into(),
                amounts: vec![90u8.into()],
            }],
            pool_payouts: vec![100u8.into()],
            claim_set_hash: hash(5),
            settlement_input_hash: hash(11),
            root: fixture()["root"].as_str().unwrap().into(),
            proofs: Default::default(),
        },
        digest: fixture()["settlementDigest"].as_str().unwrap().into(),
        score_source: ScoreSourceMetadata::Raw { as_of_block: 8 },
        rpc_metrics: Default::default(),
        log_metrics: Default::default(),
    };
    for mut artifact in [
        usd8_settlement::attested_runtime::artifact_for_attestation(&run, &config),
        run.artifact(&config, true),
    ] {
        assert!(artifact["chainId"].is_u64());
        assert!(artifact["incidentId"].is_string());
        assert!(artifact.get("signature").is_none());
        // NSM/KMS are intentionally NOT run in portable tests. These diagnostic
        // fixture bytes test field coexistence; they are not genuine attestations.
        artifact["nitroAttestationDocument"] = json!("0x0102");
        artifact["measuredTeePcrHash"] = json!(hash(6));
        artifact["nitroAttestedDigest"] = json!(run.digest);
        let sig = sign_digest(&[7; 32], &hex::decode(&run.digest[2..]).unwrap()).unwrap();
        let terminal = TerminalEnvelope::completed(
            "producer-fixture",
            json!({
                "artifact":artifact, "digest":sig.digest, "signer":sig.signer, "signature":sig.signature, "kmsRecipientAttestation":"0x0304"
            }),
        );
        let wire = serde_json::to_vec(&terminal).unwrap();
        let decoded: TerminalEnvelope = serde_json::from_slice(&wire).unwrap();
        let verified = verify_result_for_promotion(&rpc, &policy(), "1", &decoded.payload)
            .await
            .unwrap();
        assert_eq!(verified.authorization(), CurrentSigner);
    }
}
fn settlement_calldata(a: &Value) -> String {
    format!(
        "0x{}{}{}{}{}{}{}{}{}",
        selector("settleIncident(bytes32,uint256[],bytes)"),
        &a["root"].as_str().unwrap()[2..],
        word(96),
        word(160),
        word(1),
        word(100),
        word(65),
        &a["signature"].as_str().unwrap()[2..],
        "00".repeat(31)
    )
}
fn acceptance_log() -> Value {
    json!({"address":address(2).to_string(),"topics":[format!("0x{}",hex::encode(Keccak256::digest(b"IncidentSettled(uint256,bytes32,bytes32)"))),format!("0x{}",word(1))],"data":format!("{}{}",fixture()["root"].as_str().unwrap(),"06".repeat(32)),"blockNumber":"0x10","blockHash":hash(16),"transactionHash":hash(30),"logIndex":"0x0","removed":false})
}
#[tokio::test]
async fn historical_search_request_budget_exhaustion_is_unavailable() {
    let rpc = OldIncidentRpc {
        head: 1_000_000,
        empty: true,
        bound: 10_000_000,
        calls: Mutex::new(vec![]),
    };
    let e = verify_for_promotion(&rpc, &policy(), "1", &fixture())
        .await
        .unwrap_err();
    assert!(
        matches!(e, VerificationError::Rpc(RpcError::LogBudgetExceeded(_))),
        "{e}"
    );
    assert_eq!(rpc.calls.lock().unwrap().len(), 256);
}
struct PaddedRpc;
#[async_trait]
impl Rpc for PaddedRpc {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        let mut v = MockRpc::new(true).request(method, params).await?;
        if v.is_object() {
            v["unneeded"] = json!("x".repeat(250_000));
        }
        Ok(v)
    }
}
#[tokio::test]
async fn aggregate_rpc_bytes_budget_exhaustion_is_unavailable() {
    let e = verify_for_promotion(&PaddedRpc, &policy(), "1", &fixture())
        .await
        .unwrap_err();
    assert!(
        matches!(e, VerificationError::Chain(_) | VerificationError::Rpc(_)),
        "{e}"
    );
    assert!(e.to_string().contains("verification bytes"));
}

#[path = "../src/completion_verifier.rs"]
mod completion_verifier;
use usd8_tee_job_api::{
    CanonicalRequest, CompletionVerifier, ServiceError, TerminalEnvelope, TerminalStatus,
};
#[tokio::test]
async fn adapter_incomplete_execution_evidence_is_unavailable() {
    for case in [
        "malformed-address",
        "missing-input",
        "malformed-input",
        "missing-receipt-hash",
        "wrong-block",
        "unrelated-trace",
    ] {
        let mut a = fixture();
        let signature = a.as_object_mut().unwrap().remove("signature").unwrap();
        let signer = a.as_object_mut().unwrap().remove("signer").unwrap();
        let terminal = TerminalEnvelope::completed(
            "unused",
            json!({"digest":a["settlementDigest"],"artifact":a,"signature":signature,"signer":signer}),
        );
        let request = usd8_tee_job_api::canonicalize_request(
            br#"{"incidentId":"1"}"#,
            &address(1).to_string(),
        )
        .unwrap();
        let verifier = completion_verifier::RpcCompletionVerifier::new(
            WrapperRpc { case },
            policy(),
            std::time::Duration::from_secs(1),
        )
        .unwrap();
        assert_eq!(
            verifier.verify(&request, &terminal).await,
            Err(ServiceError::Unavailable),
            "{case}"
        );
    }
}

#[tokio::test]
async fn attached_attestations_and_unsigned_diagnostics_are_not_authenticated() {
    let mut a = fixture();
    let signature = a.as_object_mut().unwrap().remove("signature").unwrap();
    let signer = a.as_object_mut().unwrap().remove("signer").unwrap();
    a["nitroAttestationDocument"] = json!("not an attestation");
    a["measuredTeePcrHash"] = json!(hash(99));
    a["nitroAttestedDigest"] = json!(hash(99));
    a["settlementInputHash"] = json!(hash(99));
    a["rows"][0]["payoutUsd"] = json!("999999999");
    let result = json!({"digest":a["settlementDigest"],"artifact":a,"signature":signature,"signer":signer,"kmsRecipientAttestation":"not KMS evidence"});
    verify_result_for_promotion(&MockRpc::new(true), &policy(), "1", &result)
        .await
        .unwrap();
}

struct OldIncidentRpc {
    head: u64,
    empty: bool,
    bound: u64,
    calls: Mutex<Vec<(String, Value)>>,
}
#[async_trait]
impl Rpc for OldIncidentRpc {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(
        &self,
        method: &str,
        mut params: Value,
    ) -> std::result::Result<Value, RpcError> {
        self.calls
            .lock()
            .unwrap()
            .push((method.into(), params.clone()));
        if method == "eth_getLogs" {
            let from =
                u64::from_str_radix(&params[0]["fromBlock"].as_str().unwrap()[2..], 16).unwrap();
            return Ok(if !self.empty && from <= 16 {
                json!([acceptance_log()])
            } else {
                json!([])
            });
        }
        if method == "eth_getBlockByNumber" && (params[0] == "finalized" || params[0] == "latest") {
            let n = self.head + u64::from(params[0] == "latest");
            return Ok(
                json!({"number":format!("0x{n:x}"),"timestamp":format!("0x{:x}",n*10),"hash":hash(n as u8)}),
            );
        }
        let head_call = method == "eth_call" && params[1] == format!("0x{:x}", self.head);
        if head_call {
            params[1] = json!("0x14");
        }
        let incident = head_call
            && params[0]["data"]
                .as_str()
                .unwrap()
                .starts_with(&format!("0x{}", selector("incidents(uint256)")));
        let mut v = HistoricalRpc {
            inner: MockRpc::new(false),
            tamper: false,
        }
        .request(method, params)
        .await?;
        if incident {
            let mut raw = v.as_str().unwrap().to_string();
            raw.replace_range(2 + 4 * 64..2 + 5 * 64, &word(self.bound));
            v = json!(raw);
        }
        Ok(v)
    }
}
#[tokio::test]
async fn old_incident_accepts_first_chunk_without_scanning_distant_head() {
    for (head, bound) in [
        (1_000_000, 210),
        (100_000_000, 210),
        (100_000_000, 1_000_000_000),
    ] {
        let rpc = OldIncidentRpc {
            head,
            empty: false,
            bound,
            calls: Mutex::new(vec![]),
        };
        verify_for_promotion(&rpc, &policy(), "1", &fixture())
            .await
            .unwrap();
        let calls = rpc.calls.lock().unwrap();
        let logs: Vec<_> = calls.iter().filter(|(m, _)| m == "eth_getLogs").collect();
        assert_eq!(logs.len(), 1);
        assert!(calls.len() < 100);
        assert_eq!(
            logs[0].1[0]["toBlock"],
            if bound == 210 { "0x15" } else { "0x3f6" }
        );
    }
}

struct HistoricalRpc {
    inner: MockRpc,
    tamper: bool,
}
#[async_trait]
impl Rpc for HistoricalRpc {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        match method {
            "debug_traceTransaction" => {
                return Err(RpcError::JsonRpc {
                    code: -32601,
                    message: "trace unavailable".into(),
                });
            }
            "eth_getLogs" => return Ok(json!([acceptance_log()])),
            "eth_getTransactionByHash" => {
                return Ok(
                    json!({"hash":hash(30),"to":address(2).to_string(),"blockNumber":"0x10","blockHash":hash(16),"input":if self.tamper { "0x".to_string() } else { settlement_calldata(&fixture()) }}),
                );
            }
            "eth_getTransactionReceipt" => {
                return Ok(
                    json!({"transactionHash":hash(30),"blockNumber":"0x10","blockHash":hash(16),"status":"0x1","logs":[acceptance_log()]}),
                );
            }
            _ => (),
        }
        let mut result = self.inner.request(method, params.clone()).await?;
        if method == "eth_call"
            && params[0]["data"]
                .as_str()
                .unwrap()
                .starts_with(&format!("0x{}", selector("incidents(uint256)")))
            && params[1] == "0x14"
        {
            let raw = result.as_str().unwrap().to_string();
            // Finalization consumes unresolvedClaims but preserves claimSetHash.
            result = json!(format!(
                "{}{}{}{}{}",
                &raw[..2 + 5 * 64],
                &fixture()["root"].as_str().unwrap()[2..],
                word(0),
                "05".repeat(32),
                &raw[2 + 8 * 64..]
            ));
        }
        Ok(result)
    }
}
#[tokio::test]
async fn accepted_root_survives_retired_signer_and_consumed_claim_state() {
    let rpc = HistoricalRpc {
        inner: MockRpc::new(false),
        tamper: false,
    };
    let verified = verify_for_promotion(&rpc, &policy(), "1", &fixture())
        .await
        .unwrap();
    assert_eq!(verified.authorization(), Authorization::AcceptedOnchain);
}
