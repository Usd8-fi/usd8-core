#[path = "../src/open_advisory_cache.rs"]
mod open_advisory_cache;

use async_trait::async_trait;
use open_advisory_cache::*;
use std::collections::HashMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use usd8_tee_job_api::{CreateOutcome, JobStore, ServiceError, VersionedObject};

async fn check<S: JobStore, P: AdvisorySource>(
    store: &S,
    source: &P,
    namespace: &str,
    now: u64,
) -> Result<Decision, CheckError> {
    open_advisory_cache::check(
        store,
        source,
        namespace,
        now,
        tokio::time::Instant::now() + CACHE_BUDGET,
    )
    .await
}

#[derive(Default)]
struct Store(Mutex<HashMap<String, (usize, Vec<u8>)>>, Controls);
#[derive(Default)]
struct Controls {
    reads: AtomicUsize,
    exchanges: AtomicUsize,
    wins: AtomicUsize,
    initial_reads: Option<Arc<tokio::sync::Barrier>>,
    publish_gate: Option<Arc<(tokio::sync::Notify, tokio::sync::Notify)>>,
    read_delay: Option<(usize, std::time::Duration)>,
    exchange_delay: Option<(usize, std::time::Duration)>,
}
#[async_trait]
impl JobStore for Store {
    async fn get_versioned(
        &self,
        key: &str,
        _: usize,
    ) -> Result<Option<VersionedObject>, ServiceError> {
        let call = self.1.reads.fetch_add(1, Ordering::SeqCst) + 1;
        if let Some((at, delay)) = self.1.read_delay
            && call == at
        {
            tokio::time::sleep(delay).await;
        }
        let object = self
            .0
            .lock()
            .unwrap()
            .get(key)
            .map(|(v, bytes)| VersionedObject {
                revision: v.to_string(),
                bytes: bytes.clone(),
            });
        if call <= 2
            && let Some(barrier) = &self.1.initial_reads
        {
            barrier.wait().await;
        }
        Ok(object)
    }
    async fn compare_exchange(
        &self,
        key: &str,
        revision: Option<&str>,
        value: &[u8],
    ) -> Result<bool, ServiceError> {
        let call = self.1.exchanges.fetch_add(1, Ordering::SeqCst) + 1;
        if let Some((at, delay)) = self.1.exchange_delay
            && call == at
        {
            tokio::time::sleep(delay).await;
        }
        if call == 2
            && let Some(gate) = &self.1.publish_gate
        {
            gate.0.notify_one();
            gate.1.notified().await;
        }
        tokio::task::yield_now().await;
        let mut store = self.0.lock().unwrap();
        let previous = store.get(key).map(|(v, _)| v.to_string());
        if previous.as_deref() != revision {
            return Ok(false);
        }
        let version = store.get(key).map_or(1, |(v, _)| v + 1);
        store.insert(key.into(), (version, value.to_vec()));
        self.1.wins.fetch_add(1, Ordering::SeqCst);
        Ok(true)
    }
    async fn create(&self, _: &str, _: &[u8]) -> Result<CreateOutcome, ServiceError> {
        unreachable!()
    }
    async fn get(&self, _: &str, _: usize) -> Result<Option<Vec<u8>>, ServiceError> {
        unreachable!()
    }
    async fn download_url(&self, _: &str, _: u64) -> Result<String, ServiceError> {
        unreachable!()
    }
}
struct Source {
    calls: AtomicUsize,
    binding: Mutex<String>,
    outcome: Mutex<Result<Semantic, CheckError>>,
    change_during_refresh: bool,
    binding_calls: AtomicUsize,
    fail_binding: bool,
    slow_binding: bool,
    binding_delays: Vec<std::time::Duration>,
    refresh_delay: std::time::Duration,
    binding_error: Option<CheckError>,
}
impl Source {
    fn new() -> Self {
        Self {
            calls: AtomicUsize::new(0),
            binding: Mutex::new("config-a".into()),
            outcome: Mutex::new(Ok(Semantic::NoDrop)),
            change_during_refresh: false,
            binding_calls: AtomicUsize::new(0),
            fail_binding: false,
            slow_binding: false,
            binding_delays: Vec::new(),
            refresh_delay: std::time::Duration::ZERO,
            binding_error: None,
        }
    }
}
#[async_trait]
impl AdvisorySource for Source {
    async fn binding(&self) -> Result<Binding, CheckError> {
        let call = self.binding_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(delay) = self.binding_delays.get(call) {
            tokio::time::sleep(*delay).await;
        }
        if self.slow_binding {
            tokio::time::sleep(std::time::Duration::from_secs(31)).await;
        }
        if let Some(error) = &self.binding_error {
            return Err(error.clone());
        }
        if self.fail_binding {
            return Err(CheckError::Unavailable);
        }
        Ok(Binding {
            commitment: self.binding.lock().unwrap().clone(),
            head: 1000,
            finalized: 990,
            max_age: 100,
        })
    }
    async fn refresh(&self) -> Result<Semantic, CheckError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if !self.refresh_delay.is_zero() {
            tokio::time::sleep(self.refresh_delay).await;
        }
        tokio::task::yield_now().await;
        if self.change_during_refresh {
            *self.binding.lock().unwrap() = "config-b".into();
        }
        self.outcome.lock().unwrap().clone()
    }
}
#[tokio::test]
async fn delayed_admission_must_not_start_a_scan_near_lease_expiry() {
    let store = Store::default();
    let mut source = Source::new();
    source.slow_binding = true;
    let result = check(&store, &source, "token", 100).await.unwrap();
    assert!(!result.fresh);
    assert_eq!(source.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn advisory_wire_fields_are_camel_case() {
    let value = serde_json::to_value(Semantic::Qualifying {
        reference_block: 950,
        observation_block: 975,
    })
    .unwrap();
    assert_eq!(value["referenceBlock"], 950);
    assert_eq!(value["observationBlock"], 975);
}

#[tokio::test]
async fn fresh_configuration_change_invalidates_even_before_sixty_seconds() {
    let store = Store::default();
    let source = Source::new();
    check(&store, &source, "token", 100).await.unwrap();
    *source.binding.lock().unwrap() = "config-b".into();
    let result = check(&store, &source, "token", 101).await.unwrap();
    assert!(!result.fresh);
    assert!(result.advisory.is_none());
    assert_eq!(source.calls.load(Ordering::SeqCst), 1);
    let refreshed = check(&store, &source, "token", 160).await.unwrap();
    assert!(refreshed.fresh);
    assert_eq!(refreshed.advisory.unwrap().configuration, "config-b");
}

#[tokio::test]
async fn concurrent_callers_share_one_scan_and_positive_snapshot() {
    let store = Arc::new(Store::default());
    let source = Arc::new(Source::new());
    *source.outcome.lock().unwrap() = Ok(Semantic::Qualifying {
        reference_block: 950,
        observation_block: 975,
    });
    let mut tasks = Vec::new();
    for _ in 0..64 {
        let store = store.clone();
        let source = source.clone();
        tasks.push(tokio::spawn(async move {
            check(store.as_ref(), source.as_ref(), "token", 100)
                .await
                .unwrap()
        }));
    }
    for task in tasks {
        task.await.unwrap();
    }
    assert_eq!(source.calls.load(Ordering::SeqCst), 1);
    let fresh = check(store.as_ref(), source.as_ref(), "token", 159)
        .await
        .unwrap();
    assert!(fresh.fresh);
    assert!(matches!(
        fresh.advisory.unwrap().result,
        Semantic::Qualifying {
            reference_block: 950,
            ..
        }
    ));
    *source.outcome.lock().unwrap() = Err(CheckError::Unavailable);
    let stale = check(store.as_ref(), source.as_ref(), "token", 160)
        .await
        .unwrap();
    assert!(!stale.fresh);
    assert!(stale.advisory.is_some());
}

#[tokio::test]
async fn failure_without_snapshot_is_throttled_and_never_fabricates_a_result() {
    for failure in [
        CheckError::Unavailable,
        CheckError::Active,
        CheckError::Unapproved,
    ] {
        let store = Store::default();
        let source = Source::new();
        *source.outcome.lock().unwrap() = Err(failure);
        for now in [100, 101, 159] {
            let result = check(&store, &source, "token", now).await.unwrap();
            assert!(!result.fresh);
            assert!(result.advisory.is_none());
        }
        assert_eq!(source.calls.load(Ordering::SeqCst), 1);
        check(&store, &source, "token", 160).await.unwrap();
        assert_eq!(source.calls.load(Ordering::SeqCst), 2);
    }
}

#[tokio::test]
async fn binding_rpc_failure_returns_only_retained_advisory() {
    let store = Store::default();
    let mut source = Source::new();
    check(&store, &source, "token", 100).await.unwrap();
    source.fail_binding = true;
    let result = check(&store, &source, "token", 101).await.unwrap();
    assert!(!result.fresh);
    assert_eq!(result.advisory.unwrap().checked_at, 100);
    assert!(
        check(&store, &source, "token", 3700)
            .await
            .unwrap()
            .advisory
            .is_none()
    );
}

#[tokio::test]
async fn config_change_during_scan_cannot_publish_a_mixed_snapshot() {
    let store = Store::default();
    let mut source = Source::new();
    source.change_during_refresh = true;
    let result = check(&store, &source, "token", 100).await.unwrap();
    assert!(!result.fresh);
    assert!(result.advisory.is_none());
}

#[tokio::test]
async fn invalid_positive_is_never_published_or_admitted() {
    for result in [
        Semantic::Qualifying {
            reference_block: 899,
            observation_block: 950,
        },
        Semantic::Qualifying {
            reference_block: 950,
            observation_block: 991,
        },
    ] {
        let store = Store::default();
        let source = Source::new();
        *source.outcome.lock().unwrap() = Ok(result);
        let result = check(&store, &source, "token", 100).await.unwrap();
        assert!(!result.fresh);
        assert!(result.advisory.is_none());
    }
}

#[tokio::test]
async fn failed_refresh_retains_snapshot_but_consumes_attempt_until_boundary_and_expires() {
    let store = Store::default();
    let source = Source::new();
    check(&store, &source, "token", 100).await.unwrap();
    *source.outcome.lock().unwrap() = Err(CheckError::Unavailable);
    let failed = check(&store, &source, "token", 160).await.unwrap();
    assert!(!failed.fresh);
    assert_eq!(failed.advisory.unwrap().checked_at, 100);
    let retry = check(&store, &source, "token", 219).await.unwrap();
    assert!(!retry.fresh);
    assert_eq!(source.calls.load(Ordering::SeqCst), 2);
    assert!(
        check(&store, &source, "token", 3699)
            .await
            .unwrap()
            .advisory
            .is_some()
    );
    assert!(
        check(&store, &source, "token", 3700)
            .await
            .unwrap()
            .advisory
            .is_none()
    );
}

#[tokio::test]
async fn shared_negative_is_fresh_until_exact_sixty_second_boundary() {
    let store = Arc::new(Store::default());
    let source = Source::new();
    let first = check(store.as_ref(), &source, "trusted-token", 100)
        .await
        .unwrap();
    assert!(first.fresh);
    assert_eq!(first.advisory.unwrap().result, Semantic::NoDrop);
    let cached = check(store.as_ref(), &source, "trusted-token", 159)
        .await
        .unwrap();
    assert!(cached.fresh);
    assert_eq!(source.calls.load(Ordering::SeqCst), 1);
    check(store.as_ref(), &source, "trusted-token", 160)
        .await
        .unwrap();
    assert_eq!(source.calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn identical_read_revisions_allow_exactly_one_reservation_winner() {
    let store = Store(
        Default::default(),
        Controls {
            initial_reads: Some(Arc::new(tokio::sync::Barrier::new(2))),
            ..Default::default()
        },
    );
    let source = Source::new();
    let (a, b) = tokio::join!(
        check(&store, &source, "token", 100),
        check(&store, &source, "token", 100)
    );
    assert_eq!(
        usize::from(a.unwrap().fresh) + usize::from(b.unwrap().fresh),
        1
    );
    assert_eq!(source.calls.load(Ordering::SeqCst), 1);
    assert_eq!(store.1.exchanges.load(Ordering::SeqCst), 3);
    assert_eq!(store.1.wins.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn old_publication_cannot_overwrite_a_takeover_owner() {
    let gate = Arc::new((tokio::sync::Notify::new(), tokio::sync::Notify::new()));
    let store = Arc::new(Store(
        Default::default(),
        Controls {
            publish_gate: Some(gate.clone()),
            ..Default::default()
        },
    ));
    let old_store = store.clone();
    let old =
        tokio::spawn(async move { check(old_store.as_ref(), &Source::new(), "token", 100).await });
    gate.0.notified().await;
    let source = Source::new();
    *source.outcome.lock().unwrap() = Ok(Semantic::Qualifying {
        reference_block: 950,
        observation_block: 975,
    });
    let winner = check(store.as_ref(), &source, "token", 160).await.unwrap();
    assert!(winner.fresh);
    let committed = store.0.lock().unwrap().clone();
    gate.1.notify_one();
    assert!(matches!(old.await.unwrap(), Err(CheckError::Unavailable)));
    assert_eq!(*store.0.lock().unwrap(), committed);
    let retained = check(store.as_ref(), &source, "token", 161).await.unwrap();
    assert_eq!(retained.advisory.unwrap().checked_at, 160);
    assert_eq!(store.1.wins.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn active_and_unapproved_binding_fail_closed_before_reserving() {
    for error in [CheckError::Active, CheckError::Unapproved] {
        let store = Store::default();
        let mut source = Source::new();
        source.binding_error = Some(error.clone());
        let result = check(&store, &source, "token", 100).await;
        assert!(matches!(
            (&error, result),
            (CheckError::Active, Err(CheckError::Active))
                | (CheckError::Unapproved, Err(CheckError::Unapproved))
        ));
        assert_eq!(source.binding_calls.load(Ordering::SeqCst), 1);
        assert_eq!(source.calls.load(Ordering::SeqCst), 0);
        assert_eq!(store.1.exchanges.load(Ordering::SeqCst), 0);
    }
}
