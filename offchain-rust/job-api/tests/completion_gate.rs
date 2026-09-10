#![cfg(any(feature = "sepolia", feature = "lambda", feature = "worker"))]
#[allow(dead_code)]
#[path = "../src/settlement_verifier.rs"]
mod settlement_verifier;
use serde_json::{Value, json};
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
        chain_id: usd8_tee_job_api::configured_chain_id(),
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
        chain_id: usd8_tee_job_api::configured_chain_id(),
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
    json!({"schemaVersion":2,"chainId":usd8_tee_job_api::configured_chain_id(),"registry":address(1).to_string(),"defiInsurance":address(2).to_string(),"incidentId":"1","referenceBlock":"8","root":root,"unresolvedClaims":"1","poolAddrs":[address(4).to_string()],"poolPayouts":["100"],"claimSetHash":hash(5),"teePcrHash":hash(6),"protocolFeeShareBps":"1000","settlementDigest":digest,"signature":sig.signature,"signer":sig.signer,"rows":[{"claimId":"1","user":address(3).to_string(),"amounts":["90"],"scoreSpent":"2","boostedScore":"2","eligibleAmount":"4","eligibleBoosterAmount":"0"}]})
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
            "eth_chainId" => json!(format!("0x{:x}", usd8_tee_job_api::configured_chain_id())),
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
#[path = "../src/completion_verifier.rs"]
mod completion_verifier;
use completion_verifier::RpcCompletionVerifier;
use std::{sync::Arc, time::Duration};
use usd8_tee_job_api::{
    CanonicalRequest, CompletionVerifier, ServiceError, TerminalEnvelope, TerminalStatus,
};
fn request() -> CanonicalRequest {
    usd8_tee_job_api::canonicalize_request(br#"{"incidentId":"1"}"#, &address(1).to_string())
        .unwrap()
}
fn payload() -> Value {
    let mut artifact = fixture();
    // Structural NSM envelope only; authorization proof is the real ECDSA
    // signature plus pinned canonical RPC, not these untrusted metadata bytes.
    artifact["nitroAttestedDigest"] = artifact["settlementDigest"].clone();
    artifact["measuredTeePcrHash"] = artifact["teePcrHash"].clone();
    artifact["nitroAttestationDocument"] = json!("0x00");
    let signature = artifact
        .as_object_mut()
        .unwrap()
        .remove("signature")
        .unwrap();
    let signer = artifact.as_object_mut().unwrap().remove("signer").unwrap();
    json!({"digest":artifact["settlementDigest"],"signature":signature,"signer":signer,"artifact":artifact})
}
#[tokio::test]
async fn valid_actual_enclave_payload_is_authenticated() {
    let verifier =
        RpcCompletionVerifier::new(MockRpc::new(true), policy(), Duration::from_secs(1)).unwrap();
    verifier
        .verify(
            &request(),
            &TerminalEnvelope::completed("unused", payload()),
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn trusted_request_registry_mismatch_is_invalid() {
    let verifier =
        RpcCompletionVerifier::new(MockRpc::new(true), policy(), Duration::from_secs(1)).unwrap();
    let mut request = request();
    if let CanonicalRequest::Settlement(ref mut r) = request {
        r.registry = address(99).to_string();
    }
    assert_eq!(
        verifier
            .verify(&request, &TerminalEnvelope::completed("unused", payload()))
            .await,
        Err(ServiceError::InvalidStoredResult)
    );
}

#[test]
fn timeout_and_trusted_policy_configuration_are_bounded() {
    for timeout in [Duration::ZERO, Duration::from_secs(31)] {
        assert!(RpcCompletionVerifier::new(MockRpc::new(true), policy(), timeout).is_err());
    }
    let mut bad = policy();
    bad.chain_id = 0;
    assert!(RpcCompletionVerifier::new(MockRpc::new(true), bad, Duration::from_secs(1)).is_err());
}
#[tokio::test]
async fn noncompletion_envelope_cannot_be_authenticated() {
    let verifier =
        RpcCompletionVerifier::new(MockRpc::new(true), policy(), Duration::from_secs(1)).unwrap();
    let mut terminal = TerminalEnvelope::completed("unused", payload());
    terminal.status = TerminalStatus::Failed;
    assert_eq!(
        verifier.verify(&request(), &terminal).await,
        Err(ServiceError::InvalidStoredResult)
    );
}

use sha2::Sha256;
use std::collections::HashMap;
use usd8_tee_job_api::{
    App, AppConfig, CreateOutcome, InstanceLauncher, JobPaths, JobStore, SettlementLocator,
    VersionedObject,
};
#[derive(Default)]
struct Store {
    objects: Mutex<HashMap<String, Vec<u8>>>,
    creates: Mutex<Vec<String>>,
}
#[async_trait]
impl JobStore for Store {
    async fn get(&self, key: &str, max: usize) -> Result<Option<Vec<u8>>, ServiceError> {
        let value = self.objects.lock().unwrap().get(key).cloned();
        if value.as_ref().is_some_and(|v| v.len() > max) {
            return Err(ServiceError::InvalidStoredResult);
        }
        Ok(value)
    }
    async fn get_versioned(
        &self,
        key: &str,
        max: usize,
    ) -> Result<Option<VersionedObject>, ServiceError> {
        Ok(self.get(key, max).await?.map(|bytes| VersionedObject {
            revision: hex::encode(Sha256::digest(&bytes)),
            bytes,
        }))
    }
    async fn compare_exchange(
        &self,
        key: &str,
        revision: Option<&str>,
        bytes: &[u8],
    ) -> Result<bool, ServiceError> {
        let mut objects = self.objects.lock().unwrap();
        let actual = objects.get(key).map(|v| hex::encode(Sha256::digest(v)));
        if actual.as_deref() != revision {
            return Ok(false);
        }
        objects.insert(key.into(), bytes.to_vec());
        Ok(true)
    }
    async fn create(&self, key: &str, bytes: &[u8]) -> Result<CreateOutcome, ServiceError> {
        self.creates.lock().unwrap().push(key.into());
        let mut objects = self.objects.lock().unwrap();
        if let Some(v) = objects.get(key) {
            return Ok(CreateOutcome::Exists(v.clone()));
        }
        objects.insert(key.into(), bytes.to_vec());
        Ok(CreateOutcome::Created)
    }
    async fn download_url(&self, _: &str, _: u64) -> Result<String, ServiceError> {
        panic!("unexpected download")
    }
}
#[derive(Default)]
struct Launcher {
    calls: Mutex<Vec<String>>,
}
#[async_trait]
impl InstanceLauncher for Launcher {
    async fn precheck(&self, _: &CanonicalRequest) -> Result<(), ServiceError> {
        Ok(())
    }
    async fn launch(&self, id: &str) -> Result<(), ServiceError> {
        self.calls.lock().unwrap().push(id.into());
        Ok(())
    }
}
fn app<R: Rpc + 'static>(
    store: Arc<Store>,
    launcher: Arc<Launcher>,
    rpc: R,
    timeout: Duration,
) -> App<Store, Launcher> {
    App::new(
        AppConfig {
            registry: address(1).to_string(),
            defi_insurance: address(2).to_string(),
            job_secret: vec![42; 32],
            max_result_bytes: 65536,
            max_inline_result_bytes: 65536,
            result_url_ttl_seconds: 300,
            job_ttl_seconds: 1800,
        },
        store,
        launcher,
    )
    .unwrap()
    .with_clock(Arc::new(|| 10000))
    .with_completion_verifier(Arc::new(
        RpcCompletionVerifier::new(rpc, policy(), timeout).unwrap(),
    ))
}
fn shared_key() -> String {
    SettlementLocator::new(
        usd8_tee_job_api::configured_chain_id(),
        &address(1).to_string(),
        &address(2).to_string(),
        "1",
        fixture()["root"].as_str().unwrap(),
    )
    .unwrap()
    .key()
}
fn put_terminal(store: &Store, id: &str, value: Value) -> Vec<u8> {
    let bytes = serde_json::to_vec(&TerminalEnvelope::completed(id, value)).unwrap();
    store
        .objects
        .lock()
        .unwrap()
        .insert(JobPaths::new(id).unwrap().terminal, bytes.clone());
    bytes
}
fn work(store: &Store) -> Vec<u8> {
    store
        .objects
        .lock()
        .unwrap()
        .iter()
        .find(|(k, _)| k.starts_with("control/work/"))
        .unwrap()
        .1
        .clone()
}
#[tokio::test]
async fn invalid_first_candidate_cannot_reserve_index_then_real_signed_result_publishes() {
    let store = Arc::new(Store::default());
    let launcher = Arc::new(Launcher::default());
    let app = app(
        store.clone(),
        launcher,
        MockRpc::new(true),
        Duration::from_secs(1),
    );
    let job = app.submit("first", br#"{"incidentId":"1"}"#).await.unwrap();
    let before = work(&store);
    let mut invalid = payload();
    invalid["signature"] = json!(format!("0x{}", "00".repeat(65)));
    put_terminal(&store, &job.job_id, invalid);
    assert_eq!(
        app.poll(&job.job_id).await,
        Err(ServiceError::InvalidStoredResult)
    );
    assert_eq!(work(&store), before);
    assert!(!store.objects.lock().unwrap().contains_key(&shared_key()));
    assert!(!store.creates.lock().unwrap().contains(&shared_key()));
    let bytes = put_terminal(&store, &job.job_id, payload());
    let outcome = app.poll(&job.job_id).await.unwrap();
    assert_eq!(outcome.payload, Some(payload()));
    assert_eq!(
        store.objects.lock().unwrap().get(&shared_key()),
        Some(&bytes)
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&work(&store)).unwrap()["completed"],
        true
    );
}
#[tokio::test]
async fn existing_shared_object_does_not_bypass_actual_payload_authentication() {
    let store = Arc::new(Store::default());
    let app = app(
        store.clone(),
        Arc::new(Launcher::default()),
        MockRpc::new(true),
        Duration::from_secs(1),
    );
    let job = app.submit("first", br#"{"incidentId":"1"}"#).await.unwrap();
    let mut bad = payload();
    bad["artifact"]["rows"][0]["amounts"][0] = json!("91");
    let bytes = put_terminal(&store, &job.job_id, bad);
    store
        .objects
        .lock()
        .unwrap()
        .insert(shared_key(), bytes.clone());
    assert_eq!(
        app.poll(&job.job_id).await,
        Err(ServiceError::InvalidStoredResult)
    );
    assert_eq!(
        app.settlement(
            usd8_tee_job_api::configured_chain_id(),
            &address(1).to_string(),
            &address(2).to_string(),
            "1",
            fixture()["root"].as_str().unwrap()
        )
        .await,
        Err(ServiceError::InvalidStoredResult)
    );
    assert_eq!(
        store.objects.lock().unwrap().get(&shared_key()),
        Some(&bytes)
    );
}
#[derive(Clone, Copy)]
enum Failure {
    Timeout,
    Transport,
    MalformedChain,
    Finality,
    AnchorChanged,
}
struct FailingRpc(Failure);
#[async_trait]
impl Rpc for FailingRpc {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        Default::default()
    }
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match self.0 {
            Failure::Timeout => std::future::pending().await,
            Failure::Transport => Err(RpcError::Transport {
                method: method.into(),
                message: "offline".into(),
            }),
            Failure::MalformedChain => Ok(json!("not-hex")),
            Failure::Finality if method == "eth_getBlockByNumber" && params[0] == "finalized" => {
                Ok(Value::Null)
            }
            Failure::AnchorChanged if method == "eth_getBlockByNumber" && params[0] == "0x14" => {
                let mut v = MockRpc::new(true).request(method, params).await?;
                v["hash"] = json!(hash(99));
                Ok(v)
            }
            Failure::Finality | Failure::AnchorChanged => {
                MockRpc::new(true).request(method, params).await
            }
        }
    }
}
#[tokio::test]
async fn rpc_chain_and_timeout_unavailable_do_not_advance_canonical_generation() {
    for failure in [
        Failure::Timeout,
        Failure::Transport,
        Failure::MalformedChain,
        Failure::Finality,
        Failure::AnchorChanged,
    ] {
        let store = Arc::new(Store::default());
        let launcher = Arc::new(Launcher::default());
        let app = app(
            store.clone(),
            launcher.clone(),
            FailingRpc(failure),
            Duration::from_millis(20),
        );
        let job = app.submit("first", br#"{"incidentId":"1"}"#).await.unwrap();
        put_terminal(&store, &job.job_id, payload());
        let before = work(&store);
        // A transient verifier failure must not trigger takeover even after expiry.
        let app = app.with_clock(Arc::new(|| 20000));
        let start = std::time::Instant::now();
        assert_eq!(
            app.submit("retry", br#"{"incidentId":"1"}"#).await,
            Err(ServiceError::Unavailable)
        );
        assert_eq!(app.poll(&job.job_id).await, Err(ServiceError::Unavailable));
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(work(&store), before);
        assert_eq!(launcher.calls.lock().unwrap().len(), 1);
        assert!(!store.creates.lock().unwrap().contains(&shared_key()));
    }
}
#[tokio::test]
async fn exact_payload_mutations_and_unauthorized_signer_are_invalid() {
    let verifier =
        RpcCompletionVerifier::new(MockRpc::new(true), policy(), Duration::from_secs(1)).unwrap();
    for (pointer, value) in [
        ("/digest", json!(hash(99))),
        ("/artifact/rows/0/amounts/0", json!("91")),
        ("/artifact/chainId", json!(2)),
        ("/artifact/incidentId", json!("2")),
        ("/artifact/defiInsurance", json!(address(99).to_string())),
    ] {
        let mut bad = payload();
        *bad.pointer_mut(pointer).unwrap() = value;
        assert_eq!(
            verifier
                .verify(&request(), &TerminalEnvelope::completed("unused", bad))
                .await,
            Err(ServiceError::InvalidStoredResult),
            "{pointer}"
        );
    }
    let verifier =
        RpcCompletionVerifier::new(MockRpc::new(false), policy(), Duration::from_secs(1)).unwrap();
    assert_eq!(
        verifier
            .verify(
                &request(),
                &TerminalEnvelope::completed("unused", payload())
            )
            .await,
        Err(ServiceError::InvalidStoredResult)
    );
}

#[tokio::test]
async fn sealed_completion_and_existing_valid_index_do_not_bypass_new_terminal_auth() {
    let store = Arc::new(Store::default());
    let app = app(
        store.clone(),
        Arc::new(Launcher::default()),
        MockRpc::new(true),
        Duration::from_secs(1),
    );
    let job = app.submit("first", br#"{"incidentId":"1"}"#).await.unwrap();
    let valid = put_terminal(&store, &job.job_id, payload());
    app.poll(&job.job_id).await.unwrap();
    let before = work(&store);
    let mut bad = payload();
    bad["signature"] = json!(format!("0x{}", "00".repeat(65)));
    put_terminal(&store, &job.job_id, bad);
    assert_eq!(
        app.poll(&job.job_id).await,
        Err(ServiceError::InvalidStoredResult)
    );
    assert_eq!(
        store.objects.lock().unwrap().get(&shared_key()),
        Some(&valid)
    );
    assert_eq!(work(&store), before);
}
