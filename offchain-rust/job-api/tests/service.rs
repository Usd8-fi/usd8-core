use async_trait::async_trait;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use usd8_tee_job_api::{
    App, AppConfig, CreateOutcome, InstanceLauncher, JobStore, ServiceError, SubmitOutcome,
};

const REGISTRY: &str = "0x1111111111111111111111111111111111111111";
const DEFI_INSURANCE: &str = "0x2222222222222222222222222222222222222222";
const ROOT: &str = "0x3333333333333333333333333333333333333333333333333333333333333333";
const BODY: &[u8] = br#"{"incidentId":"7"}"#;

#[derive(Default)]
struct FakeStore {
    objects: Mutex<HashMap<String, Vec<u8>>>,
    gets: Mutex<Vec<String>>,
    download_requests: Mutex<Vec<(String, u64)>>,
    on_budget_write: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    fail_create_prefix: Mutex<Option<String>>,
}

#[async_trait]
impl JobStore for FakeStore {
    async fn get_versioned(
        &self,
        key: &str,
        max_bytes: usize,
    ) -> Result<Option<usd8_tee_job_api::VersionedObject>, ServiceError> {
        let objects = self.objects.lock().unwrap();
        objects
            .get(key)
            .map(|bytes| {
                if bytes.len() > max_bytes {
                    return Err(ServiceError::InvalidStoredResult);
                }
                Ok(usd8_tee_job_api::VersionedObject {
                    bytes: bytes.clone(),
                    revision: hex::encode(Sha256::digest(bytes)),
                })
            })
            .transpose()
    }
    async fn compare_exchange(
        &self,
        key: &str,
        revision: Option<&str>,
        value: &[u8],
    ) -> Result<bool, ServiceError> {
        tokio::task::yield_now().await; // force races between snapshot read and CAS
        let mut objects = self.objects.lock().unwrap();
        let actual = objects
            .get(key)
            .map(|bytes| hex::encode(Sha256::digest(bytes)));
        if actual.as_deref() != revision {
            return Ok(false);
        }
        if key == "control/admission/v1.json"
            && let Some(callback) = &*self.on_budget_write.lock().unwrap()
        {
            callback();
        }
        objects.insert(key.into(), value.to_vec());
        Ok(true)
    }
    async fn create(&self, key: &str, value: &[u8]) -> Result<CreateOutcome, ServiceError> {
        if self
            .fail_create_prefix
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|prefix| key.starts_with(prefix))
        {
            return Err(ServiceError::Unavailable);
        }
        let mut objects = self.objects.lock().unwrap();
        match objects.get(key) {
            Some(existing) => Ok(CreateOutcome::Exists(existing.clone())),
            None => {
                objects.insert(key.into(), value.to_vec());
                Ok(CreateOutcome::Created)
            }
        }
    }

    async fn get(&self, key: &str, max_bytes: usize) -> Result<Option<Vec<u8>>, ServiceError> {
        self.gets.lock().unwrap().push(key.to_owned());
        Ok(self.objects.lock().unwrap().get(key).map(|value| {
            if value.len() > max_bytes {
                vec![0; max_bytes + 1]
            } else {
                value.clone()
            }
        }))
    }

    async fn download_url(&self, key: &str, ttl_seconds: u64) -> Result<String, ServiceError> {
        self.download_requests
            .lock()
            .unwrap()
            .push((key.into(), ttl_seconds));
        Ok(format!("https://download.invalid/{key}"))
    }
}

#[derive(Default)]
struct FakeLauncher {
    calls: Mutex<Vec<String>>,
    fail: Mutex<bool>,
    terminated: Mutex<bool>,
    precheck_error: Mutex<Option<ServiceError>>,
}

#[async_trait]
impl InstanceLauncher for FakeLauncher {
    async fn precheck(&self, _: &usd8_tee_job_api::CanonicalRequest) -> Result<(), ServiceError> {
        self.precheck_error
            .lock()
            .unwrap()
            .clone()
            .map_or(Ok(()), Err)
    }
    async fn is_terminated(&self, _job_id: &str) -> Result<bool, ServiceError> {
        Ok(*self.terminated.lock().unwrap())
    }
    async fn launch(&self, job_id: &str) -> Result<(), ServiceError> {
        self.calls.lock().unwrap().push(job_id.into());
        if *self.fail.lock().unwrap() {
            Err(ServiceError::Unavailable)
        } else {
            Ok(())
        }
    }
}

fn app(store: Arc<FakeStore>, launcher: Arc<FakeLauncher>) -> App<FakeStore, FakeLauncher> {
    App::new(
        AppConfig {
            registry: REGISTRY.into(),
            defi_insurance: DEFI_INSURANCE.into(),
            job_secret: b"0123456789abcdef0123456789abcdef".to_vec(),
            max_result_bytes: 1024,
            max_inline_result_bytes: 256,
            result_url_ttl_seconds: 300,
            job_ttl_seconds: 1_800,
        },
        store,
        launcher,
    )
    .unwrap()
    .with_completion_verifier(Arc::new(TestCompletionVerifier(true)))
}

#[tokio::test]
async fn submit_is_idempotent_and_reuses_ec2_client_token() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher.clone());

    let first = app.submit("request-123", BODY).await.unwrap();
    let second = app.submit("different-caller-key", BODY).await.unwrap();
    assert_eq!(first, second);
    assert!(matches!(first, SubmitOutcome { accepted: true, .. }));
    let calls = launcher.calls.lock().unwrap();
    assert_eq!(calls.as_slice(), [first.job_id.as_str()]);

    let request_key = format!("requests/{}.json", first.job_id);
    let stored = store
        .objects
        .lock()
        .unwrap()
        .get(&request_key)
        .unwrap()
        .clone();
    let value: serde_json::Value = serde_json::from_slice(&stored).unwrap();
    assert_eq!(value["schemaVersion"], 3);
    assert_eq!(value["request"]["kind"], "settlement");
    assert_eq!(value["request"]["incidentId"], "7");
    assert_eq!(value["jobId"], first.job_id);
    assert!(value.get("rpcUrl").is_none());
}

#[tokio::test]
async fn completed_job_is_not_relaunched_after_request_expiry() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = artifact_app(store.clone(), launcher.clone());

    let submitted = app.submit("request-123", BODY).await.unwrap();
    let request_key = format!("requests/{}.json", submitted.job_id);
    let terminal_key = format!("terminal/{}.json", submitted.job_id);
    let terminal = synthetic_settlement_terminal(&submitted.job_id);
    store
        .objects
        .lock()
        .unwrap()
        .insert(terminal_key, serde_json::to_vec(&terminal).unwrap());
    store.objects.lock().unwrap().remove(&request_key);

    let retried = app.submit("a-new-caller-key", BODY).await.unwrap();

    assert_eq!(retried, submitted);
    assert_eq!(
        launcher.calls.lock().unwrap().as_slice(),
        [submitted.job_id]
    );
    assert_eq!(app.poll(&retried.job_id).await.unwrap().status, "completed");
}

#[tokio::test]
async fn open_submit_stores_a_distinct_canonical_job() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher);
    let body = br#"{"insuredToken":"0x2222222222222222222222222222222222222222"}"#;
    let submitted = app.submit_open("open-123", body).await.unwrap();
    let stored = store
        .objects
        .lock()
        .unwrap()
        .get(&format!("requests/{}.json", submitted.job_id))
        .unwrap()
        .clone();
    let value: serde_json::Value = serde_json::from_slice(&stored).unwrap();
    assert_eq!(value["schemaVersion"], 3);
    assert_eq!(value["request"]["kind"], "open");
    assert!(value["request"].get("referenceBlock").is_none());
    assert_eq!(
        value["request"]["insuredToken"],
        "0x2222222222222222222222222222222222222222"
    );
    assert_eq!(value["request"]["registry"], REGISTRY);
}

#[tokio::test]
async fn hourly_cost_budget_survives_worker_termination_and_refills_after_window() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let clock = Arc::new(AtomicU64::new(10_000));
    let time = clock.clone();
    let app = app(store, launcher.clone())
        .with_clock(Arc::new(move || time.load(Ordering::SeqCst)))
        .with_admission_policy(usd8_tee_job_api::AdmissionPolicy {
            max_active_workers: 4,
            max_starts_per_hour: 1,
        })
        .unwrap();
    app.submit("a", BODY).await.unwrap();
    *launcher.terminated.lock().unwrap() = true;
    clock.store(11_100, Ordering::SeqCst);
    assert!(app.submit("b", br#"{"incidentId":"8"}"#).await.is_err());
    clock.store(13_601, Ordering::SeqCst);
    app.submit("c", br#"{"incidentId":"9"}"#).await.unwrap();
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn active_budget_reclaims_only_confirmed_terminated_after_launch_horizon() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let clock = Arc::new(AtomicU64::new(10_000));
    let time = clock.clone();
    let app = app(store, launcher.clone())
        .with_clock(Arc::new(move || time.load(Ordering::SeqCst)))
        .with_admission_policy(usd8_tee_job_api::AdmissionPolicy {
            max_active_workers: 1,
            max_starts_per_hour: 16,
        })
        .unwrap();
    app.submit("a", BODY).await.unwrap();
    *launcher.terminated.lock().unwrap() = true;
    assert!(app.submit("b", br#"{"incidentId":"8"}"#).await.is_err());
    clock.store(11_100, Ordering::SeqCst);
    app.submit("c", br#"{"incidentId":"9"}"#).await.unwrap();
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn global_admission_bounds_distinct_work_across_app_instances() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    for incident in 0..16 {
        app(store.clone(), launcher.clone())
            .submit(
                "caller",
                format!("{{\"incidentId\":\"{incident}\"}}").as_bytes(),
            )
            .await
            .unwrap();
    }
    let outcome = app(store, launcher.clone())
        .submit("different-key", br#"{"incidentId":"99"}"#)
        .await;
    assert!(
        outcome.is_err(),
        "default global hourly budget must block a seventeenth distinct worker"
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 16);
}

fn custom_app(
    store: Arc<FakeStore>,
    launcher: Arc<FakeLauncher>,
    module: &str,
    secret: u8,
) -> App<FakeStore, FakeLauncher> {
    App::new(
        AppConfig {
            registry: REGISTRY.into(),
            defi_insurance: module.into(),
            job_secret: vec![secret; 32],
            max_result_bytes: 1024,
            max_inline_result_bytes: 256,
            result_url_ttl_seconds: 300,
            job_ttl_seconds: 1800,
        },
        store,
        launcher,
    )
    .unwrap()
}

#[tokio::test]
async fn trusted_module_namespaces_work_but_secret_rotation_does_not() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let first = custom_app(store.clone(), launcher.clone(), DEFI_INSURANCE, 1)
        .submit("a", BODY)
        .await
        .unwrap();
    let rotated = custom_app(store.clone(), launcher.clone(), DEFI_INSURANCE, 2)
        .submit("b", BODY)
        .await
        .unwrap();
    assert_eq!(
        first, rotated,
        "secret rotation must reconnect to persisted canonical work"
    );
    let module = "0x4444444444444444444444444444444444444444";
    let different = custom_app(store, launcher.clone(), module, 1)
        .submit("c", BODY)
        .await
        .unwrap();
    assert_ne!(
        first, different,
        "incident IDs may overlap after a Registry module migration"
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn slow_admission_cannot_launch_after_immutable_launch_deadline() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let clock = Arc::new(AtomicU64::new(10_000));
    let time = clock.clone();
    let app = app(store.clone(), launcher.clone())
        .with_clock(Arc::new(move || time.load(Ordering::SeqCst)));
    *store.on_budget_write.lock().unwrap() =
        Some(Arc::new(move || clock.store(11_000, Ordering::SeqCst)));
    app.submit("a", BODY).await.unwrap();
    assert!(launcher.calls.lock().unwrap().is_empty());
}

struct TestCompletionVerifier(bool);
#[async_trait]
impl usd8_tee_job_api::CompletionVerifier for TestCompletionVerifier {
    async fn verify(
        &self,
        _: &usd8_tee_job_api::CanonicalRequest,
        _: &usd8_tee_job_api::TerminalEnvelope,
    ) -> Result<(), ServiceError> {
        // Service state tests only; cryptographic verification lives in its own lane.
        if self.0 {
            Ok(())
        } else {
            Err(ServiceError::InvalidStoredResult)
        }
    }
}

#[tokio::test]
async fn invalid_completed_candidate_cannot_permanently_pin_canonical_work() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let clock = Arc::new(AtomicU64::new(10_000));
    let time = clock.clone();
    let app = app(store.clone(), launcher.clone())
        .with_clock(Arc::new(move || time.load(Ordering::SeqCst)))
        .with_completion_verifier(Arc::new(TestCompletionVerifier(false)));
    let first = app.submit("a", BODY).await.unwrap();
    store.objects.lock().unwrap().insert(format!("terminal/{}.json", first.job_id),
        serde_json::to_vec(&usd8_tee_job_api::TerminalEnvelope::completed(&first.job_id, serde_json::json!({"artifact":{}, "signature":"0x00", "digest":"0x00", "signer": DEFI_INSURANCE}))).unwrap());
    assert_eq!(app.submit("b", BODY).await.unwrap().job_id, first.job_id);
    clock.store(11_801, Ordering::SeqCst);
    assert_ne!(app.submit("c", BODY).await.unwrap().job_id, first.job_id);
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn malformed_terminal_is_recoverable_after_expiry() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let clock = Arc::new(AtomicU64::new(10_000));
    let time = clock.clone();
    let app =
        app(store.clone(), launcher).with_clock(Arc::new(move || time.load(Ordering::SeqCst)));
    let first = app.submit("a", BODY).await.unwrap();
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", first.job_id),
        b"not-json".to_vec(),
    );
    clock.store(11_801, Ordering::SeqCst);
    assert_ne!(app.submit("b", BODY).await.unwrap().job_id, first.job_id);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_callers_share_one_generation_and_global_budget_is_atomic() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let service = Arc::new(
        app(store.clone(), launcher.clone())
            .with_admission_policy(usd8_tee_job_api::AdmissionPolicy {
                max_active_workers: 4,
                max_starts_per_hour: 16,
            })
            .unwrap(),
    );
    for generation in 0..2 {
        let mut handles = Vec::new();
        for caller in 0..32 {
            let service = service.clone();
            handles.push(tokio::spawn(async move {
                service
                    .submit(&format!("caller-{caller}"), BODY)
                    .await
                    .unwrap()
                    .job_id
            }));
        }
        let mut ids = std::collections::HashSet::new();
        for handle in handles {
            ids.insert(handle.await.unwrap());
        }
        assert_eq!(ids.len(), 1);
        assert_eq!(launcher.calls.lock().unwrap().len(), generation + 1);
        let job_id = ids.into_iter().next().unwrap();
        store.objects.lock().unwrap().insert(
            format!("terminal/{job_id}.json"),
            serde_json::to_vec(&usd8_tee_job_api::TerminalEnvelope::failed(
                &job_id, "FAILED",
            ))
            .unwrap(),
        );
    }
    let mut handles = Vec::new();
    for incident in 100..132 {
        let service = service.clone();
        handles.push(tokio::spawn(async move {
            service
                .submit(
                    "caller",
                    format!("{{\"incidentId\":\"{incident}\"}}").as_bytes(),
                )
                .await
        }));
    }
    let mut accepted = 0;
    for handle in handles {
        if handle.await.unwrap().is_ok() {
            accepted += 1;
        }
    }
    assert_eq!(accepted, 2); // two previous generations still reserve active slots
    assert_eq!(launcher.calls.lock().unwrap().len(), 4);
}

#[tokio::test]
async fn missing_completion_verifier_fails_closed_without_generation_takeover() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = custom_app(store.clone(), launcher.clone(), DEFI_INSURANCE, 1);
    let first = app.submit("a", BODY).await.unwrap();
    store.objects.lock().unwrap().insert(format!("terminal/{}.json", first.job_id),
        serde_json::to_vec(&usd8_tee_job_api::TerminalEnvelope::completed(&first.job_id, serde_json::json!({"artifact":{}, "signature":"0x00", "digest":"0x00", "signer": DEFI_INSURANCE}))).unwrap());
    let app = app.with_clock(Arc::new(|| u64::MAX - 1));
    assert_eq!(
        app.submit("b", BODY).await.unwrap_err(),
        ServiceError::Unavailable
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn preflight_rejection_spends_no_generation_or_worker_budget() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher.clone());
    *launcher.precheck_error.lock().unwrap() = Some(ServiceError::Unavailable);
    assert_eq!(
        app.submit("a", BODY).await.unwrap_err(),
        ServiceError::Unavailable
    );
    assert!(store.objects.lock().unwrap().is_empty());
    assert!(launcher.calls.lock().unwrap().is_empty());
    *launcher.precheck_error.lock().unwrap() = None;
    let first = app.submit("a", BODY).await.unwrap();
    *launcher.precheck_error.lock().unwrap() = Some(ServiceError::Unavailable);
    assert_eq!(app.submit("b", BODY).await.unwrap(), first); // reconnect is cheap
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", first.job_id),
        serde_json::to_vec(&usd8_tee_job_api::TerminalEnvelope::failed(
            &first.job_id,
            "FAILED",
        ))
        .unwrap(),
    );
    let before = store.objects.lock().unwrap().clone();
    assert_eq!(
        app.submit("retry-failed", BODY).await.unwrap_err(),
        ServiceError::Unavailable
    );
    assert_eq!(*store.objects.lock().unwrap(), before); // no new generation or charge
}

#[tokio::test]
async fn expired_attempt_recovers() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let clock = Arc::new(AtomicU64::new(10_000));
    let time = clock.clone();
    let app = app(store.clone(), launcher.clone())
        .with_clock(Arc::new(move || time.load(Ordering::SeqCst)));
    let first = app.submit("first", BODY).await.unwrap();
    clock.store(11_800, Ordering::SeqCst);
    assert_eq!(
        app.submit("boundary", BODY).await.unwrap().job_id,
        first.job_id
    );
    clock.store(11_801, Ordering::SeqCst);
    let next = app.submit("second", BODY).await.unwrap();
    assert_ne!(first.job_id, next.job_id);
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn ambiguous_launch_recovers_the_same_token_after_lease_timeout() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let clock = Arc::new(AtomicU64::new(10_000));
    let time = clock.clone();
    let app =
        app(store, launcher.clone()).with_clock(Arc::new(move || time.load(Ordering::SeqCst)));
    *launcher.fail.lock().unwrap() = true;
    assert!(app.submit("first", BODY).await.is_err());
    *launcher.fail.lock().unwrap() = false;
    let first_token = launcher.calls.lock().unwrap()[0].clone();
    assert_eq!(
        app.submit("second", BODY).await.unwrap().job_id,
        first_token
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
    clock.store(10_061, Ordering::SeqCst);
    assert_eq!(app.submit("third", BODY).await.unwrap().job_id, first_token);
    assert_eq!(
        launcher.calls.lock().unwrap().as_slice(),
        [first_token.clone(), first_token]
    );
}

#[tokio::test]
async fn failed_attempt_advances_once_for_different_callers() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher.clone());
    let first = app.submit("first", BODY).await.unwrap();
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", first.job_id),
        serde_json::to_vec(&usd8_tee_job_api::TerminalEnvelope::failed(
            &first.job_id,
            "FAILED",
        ))
        .unwrap(),
    );
    let (a, b) = tokio::join!(app.submit("other-a", BODY), app.submit("other-b", BODY));
    let a = a.unwrap();
    assert_ne!(first.job_id, a.job_id);
    assert_eq!(a, b.unwrap());
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn launch_failure_becomes_a_retriable_service_error() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    *launcher.fail.lock().unwrap() = true;
    let app = app(store, launcher);
    assert_eq!(
        app.submit("request-123", BODY).await.unwrap_err(),
        ServiceError::Unavailable
    );
}

#[tokio::test]
async fn poll_returns_expired_after_the_stored_deadline() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher);
    let submitted = app.submit("request-123", BODY).await.unwrap();
    let request_key = format!("requests/{}.json", submitted.job_id);
    let mut request: serde_json::Value =
        serde_json::from_slice(store.objects.lock().unwrap().get(&request_key).unwrap()).unwrap();
    let created_at = request["createdAt"].as_u64().unwrap();
    assert_eq!(request["expiresAt"].as_u64().unwrap() - created_at, 1_800);
    request["createdAt"] = serde_json::json!(1);
    request["expiresAt"] = serde_json::json!(1_801);
    store
        .objects
        .lock()
        .unwrap()
        .insert(request_key, serde_json::to_vec(&request).unwrap());

    let outcome = app.poll(&submitted.job_id).await.unwrap();

    assert_eq!(outcome.status, "expired");
    assert!(outcome.payload.is_none());
    assert!(outcome.download.is_none());
}

#[tokio::test]
async fn poll_returns_pending_then_exact_terminal_object() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher);
    let submitted = app
        .submit_open(
            "request-123",
            br#"{"insuredToken":"0x2222222222222222222222222222222222222222"}"#,
        )
        .await
        .unwrap();

    assert_eq!(app.poll(&submitted.job_id).await.unwrap().status, "pending");
    let terminal = serde_json::json!({
        "schemaVersion": 1,
        "jobId": submitted.job_id,
        "status": "completed",
        "payload": {"signature": "0x01"}
    });
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", submitted.job_id),
        serde_json::to_vec(&terminal).unwrap(),
    );
    store.gets.lock().unwrap().clear();
    let completed = app.poll(&submitted.job_id).await.unwrap();
    assert_eq!(completed.status, "completed");
    assert!(!completed.api_verified);
    assert_eq!(completed.payload.unwrap()["signature"], "0x01");
    assert!(store.download_requests.lock().unwrap().is_empty());
    assert_eq!(
        store.gets.lock().unwrap().as_slice(),
        [
            format!("terminal/{}.json", submitted.job_id),
            format!("control/completion-requests/{}.json", submitted.job_id),
            format!("requests/{}.json", submitted.job_id)
        ]
    );
}

fn artifact_app(
    store: Arc<FakeStore>,
    launcher: Arc<FakeLauncher>,
) -> App<FakeStore, FakeLauncher> {
    App::new(
        AppConfig {
            registry: REGISTRY.into(),
            defi_insurance: DEFI_INSURANCE.into(),
            job_secret: b"0123456789abcdef0123456789abcdef".to_vec(),
            max_result_bytes: 4_096,
            max_inline_result_bytes: 4_096,
            result_url_ttl_seconds: 300,
            job_ttl_seconds: 1_800,
        },
        store.clone(),
        launcher,
    )
    .unwrap()
    .with_completion_verifier(Arc::new(TestCompletionVerifier(true)))
}

fn synthetic_settlement_terminal(job_id: &str) -> serde_json::Value {
    let digest = format!("0x{}", "44".repeat(32));
    let pcr_hash = format!("0x{}", "55".repeat(32));
    serde_json::json!({
        "schemaVersion": 1,
        "jobId": job_id,
        "status": "completed",
        "payload": {
            "artifact": {
                "schemaVersion": 2,
                "chainId": 11_155_111,
                "registry": REGISTRY,
                "defiInsurance": DEFI_INSURANCE,
                "incidentId": "7",
                "root": ROOT,
                "settlementDigest": digest,
                "nitroAttestedDigest": digest,
                "teePcrHash": pcr_hash,
                "measuredTeePcrHash": pcr_hash,
                "nitroAttestationDocument": "0x01",
                "poolOrder": [],
                "poolPayouts": [],
                "rows": []
            },
            "digest": digest,
            "signature": format!("0x{}", "66".repeat(65)),
            "signer": DEFI_INSURANCE
        }
    })
}

#[tokio::test]
async fn stale_completed_worker_cannot_seal_or_promote_over_replacement() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let clock = Arc::new(AtomicU64::new(10_000));
    let time = clock.clone();
    let app = artifact_app(store.clone(), launcher.clone())
        .with_clock(Arc::new(move || time.load(Ordering::SeqCst)));
    let first = app.submit("a", BODY).await.unwrap();
    clock.store(11_801, Ordering::SeqCst);
    let second = app.submit("b", BODY).await.unwrap();
    let key = format!("settlements/v2/11155111/{REGISTRY}/{DEFI_INSURANCE}/7/{ROOT}.json");
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", first.job_id),
        serde_json::to_vec(&synthetic_settlement_terminal(&first.job_id)).unwrap(),
    );
    app.poll(&first.job_id).await.unwrap();
    assert!(!store.objects.lock().unwrap().contains_key(&key));
    assert_eq!(app.submit("c", BODY).await.unwrap(), second);
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", second.job_id),
        serde_json::to_vec(&synthetic_settlement_terminal(&second.job_id)).unwrap(),
    );
    app.poll(&second.job_id).await.unwrap();
    let bytes = store.objects.lock().unwrap().get(&key).unwrap().clone();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["jobId"],
        second.job_id
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[derive(Default)]
struct RecordingVerifier {
    calls: Mutex<Vec<serde_json::Value>>,
    error: Option<ServiceError>,
}
#[async_trait]
impl usd8_tee_job_api::CompletionVerifier for RecordingVerifier {
    async fn verify(
        &self,
        _: &usd8_tee_job_api::CanonicalRequest,
        terminal: &usd8_tee_job_api::TerminalEnvelope,
    ) -> Result<(), ServiceError> {
        self.calls.lock().unwrap().push(terminal.payload.clone());
        if terminal.payload.get("poison").is_some() {
            return Err(ServiceError::InvalidStoredResult);
        }
        self.error.clone().map_or(Ok(()), Err)
    }
}

#[tokio::test]
async fn every_completed_poll_shape_invokes_verifier_and_propagates_failure() {
    for error in [ServiceError::InvalidStoredResult, ServiceError::Unavailable] {
        for payload in [
            serde_json::json!({"signature":"0x01"}),
            serde_json::json!({"artifact":"bad"}),
            serde_json::json!({"artifact":{}}),
            synthetic_settlement_terminal("unused")["payload"].clone(),
        ] {
            let store = Arc::new(FakeStore::default());
            let verifier = Arc::new(RecordingVerifier {
                error: Some(error.clone()),
                ..Default::default()
            });
            let service = artifact_app(store.clone(), Arc::new(FakeLauncher::default()))
                .with_completion_verifier(verifier.clone());
            let first = service.submit("first", BODY).await.unwrap();
            store.objects.lock().unwrap().insert(
                format!("terminal/{}.json", first.job_id),
                serde_json::to_vec(&usd8_tee_job_api::TerminalEnvelope::completed(
                    &first.job_id,
                    payload,
                ))
                .unwrap(),
            );
            assert_eq!(service.poll(&first.job_id).await.unwrap_err(), error);
            assert_eq!(verifier.calls.lock().unwrap().len(), 1);
            assert!(
                !store
                    .objects
                    .lock()
                    .unwrap()
                    .keys()
                    .any(|k| k.starts_with("control/completion"))
            );
        }
    }
}

#[tokio::test]
async fn legacy_fallback_and_verified_namespace_conflicts_are_authenticated() {
    let store = Arc::new(FakeStore::default());
    let verifier = Arc::new(RecordingVerifier::default());
    let service = artifact_app(store.clone(), Arc::new(FakeLauncher::default()))
        .with_completion_verifier(verifier.clone());
    let first = service.submit("first", BODY).await.unwrap();
    let valid = synthetic_settlement_terminal(&first.job_id);
    let mut poison = valid.clone();
    poison["payload"]["poison"] = serde_json::json!(true);
    let legacy = format!("settlements/v1/11155111/{REGISTRY}/{DEFI_INSURANCE}/7/{ROOT}.json");
    store
        .objects
        .lock()
        .unwrap()
        .insert(legacy.clone(), serde_json::to_vec(&valid).unwrap());
    assert_eq!(
        service
            .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
            .await
            .unwrap()
            .job_id,
        first.job_id
    );
    store
        .objects
        .lock()
        .unwrap()
        .insert(legacy.clone(), serde_json::to_vec(&poison).unwrap());
    assert_eq!(
        service
            .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
            .await
            .unwrap_err(),
        ServiceError::InvalidStoredResult
    );
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", first.job_id),
        serde_json::to_vec(&valid).unwrap(),
    );
    // Historical poison cannot strand the new verified-only publication.
    service.poll(&first.job_id).await.unwrap();
    assert_eq!(
        service
            .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
            .await
            .unwrap()
            .job_id,
        first.job_id
    );
    // Even the verified namespace is not blindly trusted on a create conflict.
    store.objects.lock().unwrap().insert(
        legacy.replacen("/v1/", "/v2/", 1),
        serde_json::to_vec(&poison).unwrap(),
    );
    assert_eq!(
        service.poll(&first.job_id).await.unwrap_err(),
        ServiceError::InvalidStoredResult
    );
    assert!(
        verifier
            .calls
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .get("poison")
            .is_some()
    );
    assert!(
        store
            .objects
            .lock()
            .unwrap()
            .contains_key(&format!("control/completions/{}.json", first.job_id))
    );
}

#[tokio::test]
async fn completion_write_faults_recover_from_fresh_app_without_duplicate() {
    for prefix in [
        "control/completions/",
        "control/completion-requests/",
        "settlements/v2/",
    ] {
        let store = Arc::new(FakeStore::default());
        let launcher = Arc::new(FakeLauncher::default());
        let service = artifact_app(store.clone(), launcher.clone());
        let first = service.submit("first", BODY).await.unwrap();
        store.objects.lock().unwrap().insert(
            format!("terminal/{}.json", first.job_id),
            serde_json::to_vec(&synthetic_settlement_terminal(&first.job_id)).unwrap(),
        );
        *store.fail_create_prefix.lock().unwrap() = Some(prefix.into());
        assert_eq!(
            service.submit("complete", BODY).await.unwrap_err(),
            ServiceError::Unavailable
        );
        {
            let objects = store.objects.lock().unwrap();
            let state: serde_json::Value = serde_json::from_slice(
                objects
                    .iter()
                    .find(|(k, _)| k.starts_with("control/work/"))
                    .unwrap()
                    .1,
            )
            .unwrap();
            assert_eq!(state["completed"], prefix == "settlements/v2/");
        }
        *store.fail_create_prefix.lock().unwrap() = None;
        // Once sealed, discard ALL temporary material before trying recovery.
        if prefix == "settlements/v2/" {
            store
                .objects
                .lock()
                .unwrap()
                .retain(|k, _| !k.starts_with("requests/") && !k.starts_with("terminal/"));
        }
        let fresh = artifact_app(store.clone(), launcher.clone());
        assert_eq!(fresh.submit("repair", BODY).await.unwrap(), first);
        store
            .objects
            .lock()
            .unwrap()
            .retain(|k, _| !k.starts_with("requests/") && !k.starts_with("terminal/"));
        assert_eq!(fresh.poll(&first.job_id).await.unwrap().status, "completed");
        assert_eq!(
            fresh
                .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
                .await
                .unwrap()
                .job_id,
            first.job_id
        );
        assert_eq!(launcher.calls.lock().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn legacy_poison_does_not_block_verified_namespace() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let service = artifact_app(store.clone(), launcher);
    let first = service.submit("first", BODY).await.unwrap();
    let valid = serde_json::to_vec(&synthetic_settlement_terminal(&first.job_id)).unwrap();
    let legacy = format!("settlements/v1/11155111/{REGISTRY}/{DEFI_INSURANCE}/7/{ROOT}.json");
    store
        .objects
        .lock()
        .unwrap()
        .insert(legacy.clone(), b"legacy poison".to_vec());
    store
        .objects
        .lock()
        .unwrap()
        .insert(format!("terminal/{}.json", first.job_id), valid.clone());
    service.poll(&first.job_id).await.unwrap();
    assert_eq!(
        service
            .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
            .await
            .unwrap()
            .job_id,
        first.job_id
    );
    assert_eq!(
        store
            .objects
            .lock()
            .unwrap()
            .get(&legacy.replacen("/v1/", "/v2/", 1)),
        Some(&valid)
    );
    assert_eq!(
        store.objects.lock().unwrap().get(&legacy).unwrap(),
        b"legacy poison"
    );
}

#[tokio::test]
async fn malformed_settlement_completion_never_reports_completed() {
    for payload in [
        serde_json::json!({"signature":"0x01"}),
        serde_json::json!({"artifact":"bad"}),
        serde_json::json!({"artifact":{}}),
    ] {
        let store = Arc::new(FakeStore::default());
        let service = artifact_app(store.clone(), Arc::new(FakeLauncher::default()));
        let first = service.submit("first", BODY).await.unwrap();
        let terminal = usd8_tee_job_api::TerminalEnvelope::completed(&first.job_id, payload);
        store.objects.lock().unwrap().insert(
            format!("terminal/{}.json", first.job_id),
            serde_json::to_vec(&terminal).unwrap(),
        );
        assert_eq!(
            service.poll(&first.job_id).await.unwrap_err(),
            ServiceError::InvalidStoredResult
        );
    }
}

#[tokio::test]
async fn post_completion_survives_temporary_object_deletion() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let service = artifact_app(store.clone(), launcher.clone());
    let first = service.submit("first", BODY).await.unwrap();
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", first.job_id),
        serde_json::to_vec(&synthetic_settlement_terminal(&first.job_id)).unwrap(),
    );
    assert_eq!(service.submit("post-only", BODY).await.unwrap(), first);
    store
        .objects
        .lock()
        .unwrap()
        .retain(|k, _| !k.starts_with("terminal/") && !k.starts_with("requests/"));
    let fresh = artifact_app(store.clone(), launcher.clone());
    assert_eq!(fresh.submit("reconnect", BODY).await.unwrap(), first);
    assert_eq!(fresh.poll(&first.job_id).await.unwrap().status, "completed");
    assert_eq!(
        fresh
            .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
            .await
            .unwrap()
            .job_id,
        first.job_id
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn poll_completion_survives_temporary_object_deletion() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let service = artifact_app(store.clone(), launcher.clone());
    let first = service.submit("first", BODY).await.unwrap();
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", first.job_id),
        serde_json::to_vec(&synthetic_settlement_terminal(&first.job_id)).unwrap(),
    );
    assert_eq!(
        service.poll(&first.job_id).await.unwrap().status,
        "completed"
    );
    assert_eq!(service.submit("after-poll", BODY).await.unwrap(), first);
    store
        .objects
        .lock()
        .unwrap()
        .retain(|k, _| !k.starts_with("terminal/") && !k.starts_with("requests/"));
    let fresh = artifact_app(store.clone(), launcher.clone());
    assert_eq!(fresh.submit("reconnect", BODY).await.unwrap(), first);
    assert_eq!(fresh.poll(&first.job_id).await.unwrap().status, "completed");
    assert_eq!(
        fresh
            .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
            .await
            .unwrap()
            .job_id,
        first.job_id
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn completed_settlement_is_saved_and_retrievable_without_its_job_id() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = artifact_app(store.clone(), launcher);
    let submitted = app.submit("private-relayer-key", BODY).await.unwrap();
    let terminal = synthetic_settlement_terminal(&submitted.job_id);
    let terminal_bytes = serde_json::to_vec(&terminal).unwrap();
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", submitted.job_id),
        terminal_bytes.clone(),
    );

    app.poll(&submitted.job_id).await.unwrap();

    let settlement_key =
        format!("settlements/v2/11155111/{REGISTRY}/{DEFI_INSURANCE}/7/{ROOT}.json");
    assert_eq!(
        store.objects.lock().unwrap().get(&settlement_key),
        Some(&terminal_bytes)
    );
    let discovered = app
        .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
        .await
        .unwrap();
    assert_eq!(discovered.status, "completed");
    assert_eq!(discovered.job_id, submitted.job_id);
    assert_eq!(discovered.payload.unwrap()["artifact"]["root"], ROOT);
    let rejected = app
        .with_completion_verifier(Arc::new(TestCompletionVerifier(false)))
        .settlement(11_155_111, REGISTRY, DEFI_INSURANCE, "7", ROOT)
        .await;
    assert_eq!(rejected.unwrap_err(), ServiceError::InvalidStoredResult);
}

#[tokio::test]
async fn poll_returns_integrity_bound_download_for_large_terminal() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher);
    let submitted = app
        .submit_open(
            "request-123",
            br#"{"insuredToken":"0x2222222222222222222222222222222222222222"}"#,
        )
        .await
        .unwrap();
    let terminal = serde_json::json!({
        "schemaVersion": 1,
        "jobId": submitted.job_id,
        "status": "completed",
        "payload": {"artifact": "x".repeat(256)}
    });
    let terminal_bytes = serde_json::to_vec(&terminal).unwrap();
    let terminal_key = format!("terminal/{}.json", submitted.job_id);
    store
        .objects
        .lock()
        .unwrap()
        .insert(terminal_key.clone(), terminal_bytes.clone());

    let completed = app.poll(&submitted.job_id).await.unwrap();
    assert_eq!(completed.status, "completed");
    assert!(completed.payload.is_none());
    let download = completed.download.clone().unwrap();
    assert_eq!(
        download.url,
        format!(
            "https://download.invalid/control/completions/{}.json",
            submitted.job_id
        )
    );
    assert_eq!(download.bytes, terminal_bytes.len());
    assert_eq!(
        download.sha256,
        hex::encode(Sha256::digest(&terminal_bytes))
    );
    assert_eq!(download.expires_in_seconds, 300);
    assert!(serde_json::to_vec(&completed).unwrap().len() < 4096);
    assert_eq!(
        store.download_requests.lock().unwrap().as_slice(),
        [(
            format!("control/completions/{}.json", submitted.job_id),
            300
        )]
    );
}

#[tokio::test]
async fn poll_validates_terminal_binding_size_and_known_jobs() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher);
    let submitted = app.submit("request-123", BODY).await.unwrap();
    let failed = serde_json::json!({
        "schemaVersion": 1,
        "jobId": submitted.job_id,
        "status": "failed",
        "payload": {"code": "ENCLAVE_FAILED"}
    });
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", submitted.job_id),
        serde_json::to_vec(&failed).unwrap(),
    );
    assert_eq!(app.poll(&submitted.job_id).await.unwrap().status, "failed");

    let wrong_job = serde_json::json!({
        "schemaVersion": 1,
        "jobId": "b".repeat(64),
        "status": "completed",
        "payload": {}
    });
    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", submitted.job_id),
        serde_json::to_vec(&wrong_job).unwrap(),
    );
    assert_eq!(
        app.poll(&submitted.job_id).await.unwrap_err(),
        ServiceError::InvalidStoredResult
    );

    store.objects.lock().unwrap().insert(
        format!("terminal/{}.json", submitted.job_id),
        vec![b'x'; 1025],
    );
    assert_eq!(
        app.poll(&submitted.job_id).await.unwrap_err(),
        ServiceError::InvalidStoredResult
    );
    assert_eq!(
        app.poll(&"a".repeat(64)).await.unwrap_err(),
        ServiceError::NotFound
    );
    assert_eq!(
        app.poll("../escape").await.unwrap_err(),
        ServiceError::InvalidRequest
    );
}
