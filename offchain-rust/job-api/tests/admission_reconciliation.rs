use async_trait::async_trait;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use usd8_tee_job_api::{App, AppConfig, CreateOutcome, InstanceLauncher, JobStore, ServiceError};

const REGISTRY: &str = "0x1111111111111111111111111111111111111111";
const DEFI_INSURANCE: &str = "0x2222222222222222222222222222222222222222";
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
    proof_calls: AtomicU64,
    proof_by_job: Mutex<HashMap<String, Result<bool, ServiceError>>>,
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
    async fn is_terminated(&self, job_id: &str) -> Result<bool, ServiceError> {
        self.proof_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(proof) = self.proof_by_job.lock().unwrap().get(job_id) {
            return proof.clone();
        }
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
}

#[tokio::test]
async fn cost_only_is_default_and_accepts_explicit_zero() {
    assert_eq!(
        usd8_tee_job_api::AdmissionPolicy::default().max_active_workers,
        0
    );
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    timed_app(store, launcher.clone(), time, 0, 1)
        .submit("a", BODY)
        .await
        .unwrap();
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn cost_only_never_launched_slot_expires_without_ec2_proof_or_refund() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    let moved_time = time.clone();
    *store.on_budget_write.lock().unwrap() = Some(Arc::new(move || {
        moved_time.store(10_121, Ordering::SeqCst);
    }));
    let first = timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
        .submit("a", BODY)
        .await
        .unwrap();
    assert!(launcher.calls.lock().unwrap().is_empty());
    *store.on_budget_write.lock().unwrap() = None;
    time.store(11_100, Ordering::SeqCst);
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
            .submit("b", br#"{"incidentId":"8"}"#)
            .await
            .unwrap_err(),
        ServiceError::AdmissionLimited
    );
    assert_eq!(ledger(&store)["starts"].as_array().unwrap().len(), 1);
    assert_eq!(ledger(&store)["reservations"].as_array().unwrap().len(), 1);
    time.store(13_601, Ordering::SeqCst);
    timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
        .submit("c", br#"{"incidentId":"9"}"#)
        .await
        .unwrap();
    let remaining = ledger(&store);
    assert_eq!(remaining["reservations"].as_array().unwrap().len(), 1);
    assert_ne!(remaining["reservations"][0]["jobId"], first.job_id);
    assert_eq!(remaining["starts"].as_array().unwrap().len(), 1);
    assert_eq!(launcher.proof_calls.load(Ordering::SeqCst), 0);
    // Expired canonical work can only obtain a new generation, never relaunch the old token.
    time.store(17_202, Ordering::SeqCst);
    let next = timed_app(store, launcher.clone(), time, 0, 1)
        .submit("a", BODY)
        .await
        .unwrap();
    assert_ne!(next.job_id, first.job_id);
    assert!(!launcher.calls.lock().unwrap().contains(&first.job_id));
}

#[tokio::test]
async fn cost_only_full_hourly_capacity_fits_bounded_durable_ledger() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    for incident in 0..1024 {
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1024)
            .submit("a", format!("{{\"incidentId\":\"{incident}\"}}").as_bytes())
            .await
            .unwrap();
    }
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1024)
            .submit("a", br#"{"incidentId":"1024"}"#)
            .await
            .unwrap_err(),
        ServiceError::AdmissionLimited
    );
    assert_eq!(
        ledger(&store)["reservations"].as_array().unwrap().len(),
        1024
    );
    time.store(13_600, Ordering::SeqCst);
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1024)
            .submit("boundary", br#"{"incidentId":"1026"}"#)
            .await
            .unwrap_err(),
        ServiceError::AdmissionLimited
    );
    time.store(13_601, Ordering::SeqCst);
    timed_app(store.clone(), launcher, time, 0, 1024)
        .submit("a", br#"{"incidentId":"1025"}"#)
        .await
        .unwrap();
    assert_eq!(ledger(&store)["reservations"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn cost_only_clock_rollback_cannot_relaunch_pruned_attempt() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    *launcher.fail.lock().unwrap() = true;
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 2)
            .submit("a", BODY)
            .await
            .unwrap_err(),
        ServiceError::Unavailable
    );
    let old = launcher.calls.lock().unwrap()[0].clone();
    *launcher.fail.lock().unwrap() = false;
    time.store(13_601, Ordering::SeqCst);
    timed_app(store.clone(), launcher.clone(), time.clone(), 0, 2)
        .submit("b", br#"{"incidentId":"8"}"#)
        .await
        .unwrap();
    assert_ne!(ledger(&store)["reservations"][0]["jobId"], old);
    time.store(10_061, Ordering::SeqCst);
    assert_eq!(
        timed_app(store, launcher.clone(), time, 0, 2)
            .submit("a", BODY)
            .await
            .unwrap_err(),
        ServiceError::Unavailable
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn cost_only_retry_cannot_change_reserved_launch_horizon() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    *launcher.fail.lock().unwrap() = true;
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
            .submit("a", BODY)
            .await
            .unwrap_err(),
        ServiceError::Unavailable
    );
    let mut value = ledger(&store);
    value["reservations"][0]["launchUntil"] = serde_json::json!(10_121);
    store
        .objects
        .lock()
        .unwrap()
        .insert(BUDGET.into(), serde_json::to_vec(&value).unwrap());
    time.store(10_061, Ordering::SeqCst);
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time, 0, 1)
            .submit("a", BODY)
            .await
            .unwrap_err(),
        ServiceError::InvalidStoredResult
    );
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
    assert_eq!(ledger(&store)["starts"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn cost_only_same_attempt_retry_is_charged_once_across_apps() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    *launcher.fail.lock().unwrap() = true;
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
            .submit("a", BODY)
            .await
            .unwrap_err(),
        ServiceError::Unavailable
    );
    let original = ledger(&store);
    *launcher.fail.lock().unwrap() = false;
    time.store(10_061, Ordering::SeqCst);
    let retry = timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
        .submit("different-caller", BODY)
        .await
        .unwrap();
    assert_eq!(original["reservations"][0]["jobId"], retry.job_id);
    assert_eq!(
        ledger(&store),
        original,
        "retry must not extend retention or recharge"
    );
    let calls = launcher.calls.lock().unwrap().clone();
    assert_eq!(calls, vec![retry.job_id.clone(), retry.job_id]);
    assert_eq!(
        timed_app(store.clone(), launcher, time, 0, 1)
            .submit("other", br#"{"incidentId":"8"}"#)
            .await
            .unwrap_err(),
        ServiceError::AdmissionLimited
    );
    assert_eq!(ledger(&store)["starts"].as_array().unwrap().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cost_only_parallel_distinct_jobs_obey_shared_hourly_cap() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    let mut tasks = Vec::new();
    for incident in 0..12 {
        let app = timed_app(store.clone(), launcher.clone(), time.clone(), 0, 3);
        tasks.push(tokio::spawn(async move {
            app.submit("a", format!("{{\"incidentId\":\"{incident}\"}}").as_bytes())
                .await
        }));
    }
    let mut admitted = 0;
    for task in tasks {
        match task.await.unwrap() {
            Ok(_) => admitted += 1,
            Err(ServiceError::AdmissionLimited | ServiceError::Unavailable) => (),
            Err(error) => panic!("unexpected error: {error:?}"),
        }
    }
    assert_eq!(admitted, 3);
    assert_eq!(launcher.calls.lock().unwrap().len(), 3);
    assert_eq!(ledger(&store)["starts"].as_array().unwrap().len(), 3);
    assert_eq!(launcher.proof_calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn cost_only_legacy_reservation_retention_is_conservative_and_bounded() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    let first = timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
        .submit("a", BODY)
        .await
        .unwrap();
    let mut legacy = ledger(&store);
    legacy["reservations"][0]
        .as_object_mut()
        .unwrap()
        .remove("startedAt");
    legacy.as_object_mut().unwrap().remove("observedAt");
    store
        .objects
        .lock()
        .unwrap()
        .insert(BUDGET.into(), serde_json::to_vec(&legacy).unwrap());
    time.store(13_601, Ordering::SeqCst);
    timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
        .submit("b", br#"{"incidentId":"8"}"#)
        .await
        .unwrap();
    assert_eq!(ledger(&store)["reservations"].as_array().unwrap().len(), 2);
    time.store(13_720, Ordering::SeqCst);
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
            .submit("boundary", br#"{"incidentId":"10"}"#)
            .await
            .unwrap_err(),
        ServiceError::AdmissionLimited
    );
    assert_eq!(ledger(&store)["reservations"].as_array().unwrap().len(), 2);
    time.store(13_721, Ordering::SeqCst);
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time, 0, 1)
            .submit("c", br#"{"incidentId":"9"}"#)
            .await
            .unwrap_err(),
        ServiceError::AdmissionLimited
    );
    let value = ledger(&store);
    assert_eq!(value["reservations"].as_array().unwrap().len(), 1);
    assert_ne!(value["reservations"][0]["jobId"], first.job_id);
    assert_eq!(value["starts"].as_array().unwrap().len(), 1);
    assert_eq!(launcher.proof_calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn cost_only_epoch_clock_cannot_refund_in_window_start() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(0));
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
            .submit("a", BODY)
            .await
            .unwrap_err(),
        ServiceError::Unavailable
    );
    assert!(!store.objects.lock().unwrap().contains_key(BUDGET));
    assert!(launcher.calls.lock().unwrap().is_empty());
    // A pre-existing epoch-zero charge must not be erased by saturating
    // subtraction, even though new submissions at epoch zero fail closed.
    time.store(1, Ordering::SeqCst);
    timed_app(store.clone(), launcher.clone(), time.clone(), 0, 1)
        .submit("a", BODY)
        .await
        .unwrap();
    let mut value = ledger(&store);
    value["starts"] = serde_json::json!([0]);
    value["reservations"][0]["startedAt"] = serde_json::json!(0);
    store
        .objects
        .lock()
        .unwrap()
        .insert(BUDGET.into(), serde_json::to_vec(&value).unwrap());
    assert_eq!(
        timed_app(store.clone(), launcher.clone(), time, 0, 1)
            .submit("b", br#"{"incidentId":"8"}"#)
            .await
            .unwrap_err(),
        ServiceError::AdmissionLimited
    );
    assert_eq!(ledger(&store)["starts"], serde_json::json!([0]));
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn cost_only_clock_falling_to_epoch_during_io_cannot_create_charge() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let reads = Arc::new(AtomicU64::new(0));
    let app = app(store.clone(), launcher.clone()).with_clock(Arc::new(move || {
        if reads.fetch_add(1, Ordering::SeqCst) == 0 {
            1
        } else {
            0
        }
    }));
    assert_eq!(
        app.submit("a", BODY).await.unwrap_err(),
        ServiceError::Unavailable
    );
    assert!(!store.objects.lock().unwrap().contains_key(BUDGET));
    assert!(launcher.calls.lock().unwrap().is_empty());
}

const BUDGET: &str = "control/admission/v1.json";
fn ledger(store: &FakeStore) -> serde_json::Value {
    serde_json::from_slice(store.objects.lock().unwrap().get(BUDGET).unwrap()).unwrap()
}
fn timed_app(
    store: Arc<FakeStore>,
    launcher: Arc<FakeLauncher>,
    time: Arc<AtomicU64>,
    active: usize,
    hourly: usize,
) -> App<FakeStore, FakeLauncher> {
    app(store, launcher)
        .with_clock(Arc::new(move || time.load(Ordering::SeqCst)))
        .with_admission_policy(usd8_tee_job_api::AdmissionPolicy {
            max_active_workers: active,
            max_starts_per_hour: hourly,
        })
        .unwrap()
}

#[tokio::test]
async fn proven_cleanup_is_durable_while_hourly_denied_then_proof_disappears() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    let app = timed_app(store.clone(), launcher.clone(), time.clone(), 1, 1);
    app.submit("a", BODY).await.unwrap();
    *launcher.terminated.lock().unwrap() = true;
    time.store(11_100, Ordering::SeqCst);
    assert!(matches!(
        app.submit("b", br#"{"incidentId":"8"}"#).await,
        Err(ServiceError::AdmissionLimited)
    ));
    assert_eq!(
        ledger(&store)["reservations"].as_array().unwrap().len(),
        0,
        "denied admission must still persist cleanup"
    );
    assert_eq!(
        ledger(&store)["starts"].as_array().unwrap().len(),
        1,
        "cleanup must not refund hourly charge"
    );
    *launcher.terminated.lock().unwrap() = false;
    time.store(13_601, Ordering::SeqCst);
    timed_app(store.clone(), launcher.clone(), time, 1, 1)
        .submit("c", br#"{"incidentId":"9"}"#)
        .await
        .unwrap();
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn concurrent_denied_cleanup_cannot_overwrite_another_reservation() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    timed_app(store.clone(), launcher.clone(), time.clone(), 1, 10)
        .submit("a", BODY)
        .await
        .unwrap();
    *launcher.terminated.lock().unwrap() = true;
    time.store(11_100, Ordering::SeqCst);
    let a = timed_app(store.clone(), launcher.clone(), time.clone(), 1, 10);
    let b = timed_app(store.clone(), launcher.clone(), time, 1, 10);
    let (a, b) = tokio::join!(
        a.submit("b", br#"{"incidentId":"8"}"#),
        b.submit("c", br#"{"incidentId":"9"}"#)
    );
    assert_eq!(usize::from(a.is_ok()) + usize::from(b.is_ok()), 1);
    assert_eq!(ledger(&store)["reservations"].as_array().unwrap().len(), 1);
    assert_eq!(ledger(&store)["starts"].as_array().unwrap().len(), 2);
    assert_eq!(launcher.calls.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn partial_cleanup_persists_while_active_denied_even_if_other_inventory_errors() {
    for other_proof in [Ok(false), Err(ServiceError::Unavailable)] {
        let store = Arc::new(FakeStore::default());
        let launcher = Arc::new(FakeLauncher::default());
        let time = Arc::new(AtomicU64::new(10_000));
        let app = timed_app(store.clone(), launcher.clone(), time.clone(), 2, 10);
        let a = app.submit("a", BODY).await.unwrap();
        let b = app.submit("b", br#"{"incidentId":"8"}"#).await.unwrap();
        launcher
            .proof_by_job
            .lock()
            .unwrap()
            .insert(a.job_id, Ok(true));
        launcher
            .proof_by_job
            .lock()
            .unwrap()
            .insert(b.job_id.clone(), other_proof);
        time.store(11_100, Ordering::SeqCst);
        let app = timed_app(store.clone(), launcher, time, 1, 10);
        assert!(matches!(
            app.submit("c", br#"{"incidentId":"9"}"#).await,
            Err(ServiceError::AdmissionLimited)
        ));
        let remaining = ledger(&store);
        assert_eq!(remaining["reservations"].as_array().unwrap().len(), 1);
        assert_eq!(remaining["reservations"][0]["jobId"], b.job_id);
        assert_eq!(remaining["starts"].as_array().unwrap().len(), 2);
    }
}

#[tokio::test]
async fn reservation_committed_but_launch_skipped_recovers_after_trusted_proof() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let time = Arc::new(AtomicU64::new(10_000));
    let moved_time = time.clone();
    *store.on_budget_write.lock().unwrap() = Some(Arc::new(move || {
        moved_time.store(10_121, Ordering::SeqCst);
    }));
    let app = timed_app(store.clone(), launcher.clone(), time.clone(), 1, 10);
    let _ = app.submit("a", BODY).await;
    assert!(launcher.calls.lock().unwrap().is_empty());
    assert_eq!(ledger(&store)["reservations"].as_array().unwrap().len(), 1);
    *store.on_budget_write.lock().unwrap() = None;
    // The actual EC2 absence proof is exercised in the Lambda module tests;
    // this layer tests that a never-launched reservation consumes and recovers a slot.
    *launcher.terminated.lock().unwrap() = true;
    time.store(11_421, Ordering::SeqCst);
    app.submit("b", br#"{"incidentId":"8"}"#).await.unwrap();
    assert_eq!(launcher.calls.lock().unwrap().len(), 1);
    assert_eq!(ledger(&store)["starts"].as_array().unwrap().len(), 2);
}
