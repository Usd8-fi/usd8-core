use async_trait::async_trait;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use usd8_tee_job_api::{
    App, AppConfig, CreateOutcome, InstanceLauncher, JobStore, ServiceError, SubmitOutcome,
};

const REGISTRY: &str = "0x1111111111111111111111111111111111111111";
const BODY: &[u8] = br#"{"incidentId":"7"}"#;

#[derive(Default)]
struct FakeStore {
    objects: Mutex<HashMap<String, Vec<u8>>>,
    gets: Mutex<Vec<String>>,
    download_requests: Mutex<Vec<(String, u64)>>,
}

#[async_trait]
impl JobStore for FakeStore {
    async fn create(&self, key: &str, value: &[u8]) -> Result<CreateOutcome, ServiceError> {
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
}

#[async_trait]
impl InstanceLauncher for FakeLauncher {
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
async fn submit_is_idempotent_and_reuses_ec2_client_token() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher.clone());

    let first = app.submit("request-123", BODY).await.unwrap();
    let second = app.submit("request-123", BODY).await.unwrap();
    assert_eq!(first, second);
    assert!(matches!(first, SubmitOutcome { accepted: true, .. }));
    let calls = launcher.calls.lock().unwrap();
    assert_eq!(
        calls.as_slice(),
        [first.job_id.as_str(), first.job_id.as_str()]
    );

    let request_key = format!("requests/{}.json", first.job_id);
    let stored = store
        .objects
        .lock()
        .unwrap()
        .get(&request_key)
        .unwrap()
        .clone();
    let value: serde_json::Value = serde_json::from_slice(&stored).unwrap();
    assert_eq!(value["schemaVersion"], 2);
    assert_eq!(value["request"]["kind"], "settlement");
    assert_eq!(value["request"]["incidentId"], "7");
    assert_eq!(value["jobId"], first.job_id);
    assert!(value.get("rpcUrl").is_none());
}

#[tokio::test]
async fn completed_job_is_not_relaunched_after_request_expiry() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher.clone());

    let submitted = app.submit("request-123", BODY).await.unwrap();
    let request_key = format!("requests/{}.json", submitted.job_id);
    let terminal_key = format!("terminal/{}.json", submitted.job_id);
    let terminal = serde_json::json!({
        "schemaVersion": 1,
        "jobId": submitted.job_id,
        "status": "completed",
        "payload": {"signature": "0x01"}
    });
    store
        .objects
        .lock()
        .unwrap()
        .insert(terminal_key, serde_json::to_vec(&terminal).unwrap());
    store.objects.lock().unwrap().remove(&request_key);

    let retried = app.submit("request-123", BODY).await.unwrap();

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
    let body = br#"{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":"1234567"}"#;
    let submitted = app.submit_open("open-123", body).await.unwrap();
    let stored = store
        .objects
        .lock()
        .unwrap()
        .get(&format!("requests/{}.json", submitted.job_id))
        .unwrap()
        .clone();
    let value: serde_json::Value = serde_json::from_slice(&stored).unwrap();
    assert_eq!(value["schemaVersion"], 2);
    assert_eq!(value["request"]["kind"], "open");
    assert_eq!(value["request"]["referenceBlock"], "1234567");
    assert_eq!(
        value["request"]["insuredToken"],
        "0x2222222222222222222222222222222222222222"
    );
    assert_eq!(value["request"]["registry"], REGISTRY);
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
    let submitted = app.submit("request-123", BODY).await.unwrap();

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
        [format!("terminal/{}.json", submitted.job_id)]
    );
}

#[tokio::test]
async fn poll_returns_integrity_bound_download_for_large_terminal() {
    let store = Arc::new(FakeStore::default());
    let launcher = Arc::new(FakeLauncher::default());
    let app = app(store.clone(), launcher);
    let submitted = app.submit("request-123", BODY).await.unwrap();
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
        format!("https://download.invalid/{terminal_key}")
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
        [(terminal_key, 300)]
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
