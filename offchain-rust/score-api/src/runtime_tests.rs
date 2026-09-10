use super::*;

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn concurrent_calculations_enter_work_once_and_failure_retry_is_not_free() {
    let app = local_app().await;
    let (network, account, _, _) = fixture();
    let network = Arc::new(network);
    let started_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let mut tasks = vec![];
    for _ in 0..20 {
        let (app, network) = (app.clone(), network.clone());
        tasks.push(tokio::spawn(async move {
            calculate(&app, &network, account, true).await.is_err()
        }));
    }
    for task in tasks {
        assert!(task.await.unwrap());
    }
    assert!(calculate(&app, &network, account, true).await.is_err());
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    // Include every window touched by execution, even on a slow boundary-crossing run.
    let window = app.work_policy.budget_window_seconds;
    let mut used = 0;
    for bucket in started_at / window..=now / window {
        let item = app
            .dynamodb
            .get_item()
            .table_name(&app.table)
            .key("pk", AttributeValue::S(format!("work-budget#{bucket}")))
            .consistent_read(true)
            .send()
            .await
            .unwrap();
        used += item
            .item
            .and_then(|mut i| i.remove("used"))
            .map(|v| v.as_n().unwrap().parse::<u64>().unwrap())
            .unwrap_or(0);
    }
    assert_eq!(used, 1, "one replay entry, including post-failure retries");
}

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn expired_at_save_construction_cannot_commit_and_stale_read_cannot_acquire() {
    let app = local_app().await;
    let (network, account, checkpoint, snapshot) = fixture();
    let key = checkpoint_key(1, network.registry, account);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    // Already expired before save construction; not a delayed pre-expiry request test.
    let expired = app
        .acquire(&key, 86400, None, now - 31)
        .await
        .unwrap()
        .unwrap();
    assert!(
        !app.save(
            &network,
            account,
            &checkpoint,
            &snapshot,
            86400,
            1,
            None,
            None,
            &expired
        )
        .await
        .unwrap()
    );
    assert!(app.load(&network, account).await.unwrap().is_none());
    let fresh = app
        .acquire(&key, 86400, None, now + 30)
        .await
        .unwrap()
        .unwrap();
    assert!(
        app.save(
            &network,
            account,
            &checkpoint,
            &snapshot,
            86400,
            1,
            None,
            None,
            &fresh
        )
        .await
        .unwrap()
    );
    assert!(
        app.acquire(&key, 86400, None, now + 30)
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        app.acquire(&key, 86400, Some(1), now + 30)
            .await
            .unwrap()
            .is_some()
    );
}

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn cold_running_account_returns_bounded_public_retry_without_rpc() {
    let mut app = local_app().await;
    let (network, account, _, _) = fixture();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    app.acquire(
        &checkpoint_key(1, network.registry, account),
        completed_utc_epoch(now).unwrap(),
        None,
        now,
    )
    .await
    .unwrap()
    .unwrap();
    Arc::get_mut(&mut app).unwrap().networks.insert(1, network);
    let request = lambda_http::http::Request::builder()
        .uri(format!("/score/1/{account}"))
        .body(Body::Empty)
        .unwrap();
    let result = handle(app, request).await.unwrap();
    assert_eq!(result.status(), 503);
    assert_eq!(
        result
            .headers()
            .get("retry-after")
            .expect("bounded retry header"),
        "60"
    );
    assert_eq!(result.headers()["cache-control"], "no-store");
}

#[test]
fn policy_rejects_unbounded_work_and_honors_operator_limits() {
    let raw = r#"{"calculationTimeoutMs":1000,"leaseSeconds":10,"failureCooldownSeconds":5,"budgetWindowSeconds":60,"budgetMaxAttempts":2}"#;
    let policy = WorkPolicy::from_json(Some(raw)).unwrap();
    assert_eq!(policy.budget_max_attempts, 2);
    assert!(WorkPolicy::from_json(Some(&raw.replace("1000", "30000"))).is_err());
    assert!(
        WorkPolicy::from_json(Some(&raw.replace("leaseSeconds\":10", "leaseSeconds\":1"))).is_err()
    );
    assert!(
        WorkPolicy::from_json(Some(
            &raw.replace("budgetMaxAttempts\":2", "budgetMaxAttempts\":0")
        ))
        .is_err()
    );
    assert!(
        WorkPolicy::from_json(Some(
            &raw.replace("budgetWindowSeconds\":60", "budgetWindowSeconds\":0")
        ))
        .is_err()
    );
    assert!(WorkPolicy::from_json(Some("{}")).is_err());
    assert!(WorkPolicy::from_json(None).is_ok());
}

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn total_deadline_cancels_rpc_retries_and_retains_attempt_cooldown() {
    let mut app = local_app().await;
    Arc::get_mut(&mut app)
        .unwrap()
        .work_policy
        .calculation_timeout_ms = 5_000;
    let (mut network, account, _, _) = fixture();
    // Accept the RPC connection but never respond. A longer per-RPC timeout makes
    // the application deadline, not a connection failure/retry, terminate replay.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    network.rpc = HttpRpc::new(
        &format!("http://{}", listener.local_addr().unwrap()),
        None,
        30_000,
    )
    .unwrap();
    let (entered_tx, mut entered_rx) = tokio::sync::oneshot::channel();
    let slow_rpc = tokio::spawn(async move {
        let (_socket, _) = listener.accept().await.unwrap();
        entered_tx.send(()).unwrap();
        std::future::pending::<()>().await;
    });
    let start = tokio::time::Instant::now();
    let result = calculate(&app, &network, account, false).await;
    slow_rpc.abort();
    let _ = slow_rpc.await;
    assert!(
        entered_rx.try_recv().is_ok(),
        "admission must reach local RPC before cancellation"
    );
    assert_eq!(
        result.err().unwrap().to_string(),
        "score calculation deadline exceeded"
    );
    assert!(
        start.elapsed() < std::time::Duration::from_secs(10),
        "total deadline must cancel the stalled RPC before its own timeout"
    );
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    assert!(
        app.acquire(
            &checkpoint_key(1, network.registry, account),
            completed_utc_epoch(now).unwrap(),
            None,
            now
        )
        .await
        .unwrap()
        .is_none()
    );
}

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn fresh_cache_and_running_snapshot_need_no_rpc_or_budget() {
    let app = local_app().await;
    let (network, account, checkpoint, snapshot) = fixture(); // deliberately unreachable RPC
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let epoch = completed_utc_epoch(now).unwrap();
    let key = checkpoint_key(1, network.registry, account);
    let lease = app.acquire(&key, epoch, None, now).await.unwrap().unwrap();
    assert!(
        app.save(
            &network,
            account,
            &checkpoint,
            &snapshot,
            epoch,
            1,
            None,
            None,
            &lease
        )
        .await
        .unwrap()
    );
    for _ in 0..10 {
        assert!(app.reserve_budget(now).await.unwrap());
    }
    let hit = calculate(&app, &network, account, false)
        .await
        .expect("cache hit must not call unreachable RPC");
    assert_eq!(hit.value["cacheStatus"], "daily-hit");
    let _running = app
        .acquire(&key, epoch, Some(1), now)
        .await
        .unwrap()
        .unwrap();
    let hit = calculate(&app, &network, account, true)
        .await
        .expect("running refresh serves snapshot without RPC");
    assert_eq!(hit.value["cacheStatus"], "updating");
    assert_eq!(hit.cache_max_age, 0);
}

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn distinct_accounts_share_atomic_budget_and_next_window_recovers() {
    let app = local_app().await;
    let mut tasks = Vec::new();
    for account in 0..40 {
        let app = app.clone();
        tasks.push(tokio::spawn(async move {
            assert!(
                app.acquire(&format!("address-{account}"), 86400, None, 1200)
                    .await
                    .unwrap()
                    .is_some()
            );
            app.reserve_budget(1200).await.unwrap()
        }));
    }
    let mut admitted = 0;
    for task in tasks {
        admitted += usize::from(task.await.unwrap());
    }
    assert_eq!(admitted, 10);
    assert!(!app.reserve_budget(1259).await.unwrap());
    assert!(app.reserve_budget(1260).await.unwrap());
}

fn fixture() -> (
    RuntimeNetwork,
    Address,
    UserCheckpoint,
    CachedInsuranceScoreSnapshot,
) {
    let registry = Address::from_str("0x2222222222222222222222222222222222222222").unwrap();
    let account = Address::from_str("0x1111111111111111111111111111111111111111").unwrap();
    let network = RuntimeNetwork {
        score: ScoreNetwork {
            chain_id: 1,
            name: "test".into(),
        },
        registry,
        rpc: HttpRpc::new("http://127.0.0.1:1", None, 100).unwrap(),
    };
    let checkpoint = UserCheckpoint {
        schema_version: 3,
        chain_id: "1".into(),
        registry: registry.to_string(),
        account: account.to_string(),
        tokens: vec![],
        visible_tokens: vec![],
    };
    let snapshot: CachedInsuranceScoreSnapshot = serde_json::from_value(serde_json::json!({
        "snapshotVersion": usd8_score_api::SCORE_SNAPSHOT_VERSION, "network": "test", "chainId": "1", "registry": registry.to_string(), "account": account.to_string(),
        "referenceBlock": "1", "referenceBlockHash": "0x00", "scoreCutoffBlock": "0", "scoreCutoffBlockHash": "0x00", "minHoldingRequired": "0", "grossEarnedScore": "0", "maturedGrossEarnedScore": "0", "scoreSpent": "0", "availableScore": "0", "scoredTokens": [], "logRequests": "0", "cacheStatus": "computed"
    })).unwrap();
    (network, account, checkpoint, snapshot)
}

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn lease_holder_commits_but_stale_generation_cannot() {
    let app = local_app().await;
    let (network, account, checkpoint, snapshot) = fixture();
    let key = checkpoint_key(1, network.registry, account);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let old = app
        .acquire(&key, 86400, None, now - 60)
        .await
        .unwrap()
        .unwrap();
    let new = app.acquire(&key, 86400, None, now).await.unwrap().unwrap();
    assert!(
        !app.save(
            &network,
            account,
            &checkpoint,
            &snapshot,
            86400,
            1,
            None,
            None,
            &old
        )
        .await
        .unwrap()
    );
    assert!(
        app.save(
            &network,
            account,
            &checkpoint,
            &snapshot,
            86400,
            1,
            None,
            None,
            &new
        )
        .await
        .unwrap()
    );
    assert!(
        !app.save(
            &network,
            account,
            &checkpoint,
            &snapshot,
            86400,
            1,
            Some(1),
            None,
            &old
        )
        .await
        .unwrap()
    );
    assert_eq!(
        app.load(&network, account).await.unwrap().unwrap().version,
        1
    );
}

use aws_sdk_dynamodb::types::{
    AttributeDefinition, BillingMode, KeySchemaElement, KeyType, ScalarAttributeType,
};

async fn local_app() -> Arc<App> {
    let endpoint =
        env::var("USD8_TEST_DYNAMODB_ENDPOINT").expect("explicit local DynamoDB endpoint required");
    assert!(endpoint.starts_with("http://127.0.0.1:"));
    let config = aws_sdk_dynamodb::config::Builder::new()
        .behavior_version_latest()
        .region(Region::new("us-east-1"))
        .credentials_provider(aws_sdk_dynamodb::config::Credentials::new(
            "local", "local", None, None, "test",
        ))
        .endpoint_url(endpoint)
        .build();
    let dynamodb = aws_sdk_dynamodb::Client::from_conf(config);
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let table = format!(
        "score-test-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    dynamodb
        .create_table()
        .table_name(&table)
        .attribute_definitions(
            AttributeDefinition::builder()
                .attribute_name("pk")
                .attribute_type(ScalarAttributeType::S)
                .build()
                .unwrap(),
        )
        .key_schema(
            KeySchemaElement::builder()
                .attribute_name("pk")
                .key_type(KeyType::Hash)
                .build()
                .unwrap(),
        )
        .billing_mode(BillingMode::PayPerRequest)
        .send()
        .await
        .unwrap();
    for _ in 0..100 {
        let status = dynamodb
            .describe_table()
            .table_name(&table)
            .send()
            .await
            .unwrap();
        if status
            .table()
            .and_then(|t| t.table_status())
            .is_some_and(|s| s.as_str() == "ACTIVE")
        {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    Arc::new(App {
        dynamodb,
        table,
        work_policy: WorkPolicy::default(),
        networks: BTreeMap::new(),
        allowed_origin: "https://usd8.fi".into(),
    })
}

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn concurrent_account_attempts_acquire_one_replay_lease() {
    let app = local_app().await;
    let mut tasks = Vec::new();
    for _ in 0..20 {
        let app = app.clone();
        tasks.push(tokio::spawn(async move {
            app.acquire("1#registry#account", 86400, None, 1000)
                .await
                .unwrap()
                .is_some()
        }));
    }
    let mut winners = 0;
    for task in tasks {
        winners += usize::from(task.await.unwrap());
    }
    assert_eq!(winners, 1, "only one request may begin replay");
}

#[tokio::test]
#[ignore = "requires local DynamoDB emulator; no AWS"]
async fn failed_attempt_cooldown_then_expired_lease_recovers() {
    let app = local_app().await;
    let first = app
        .acquire("failed", 86400, None, 1000)
        .await
        .unwrap()
        .unwrap();
    assert!(
        app.acquire("failed", 86400, None, 1030)
            .await
            .unwrap()
            .is_none(),
        "failure or cancellation must retain cooldown beyond lease expiry"
    );
    let next = app
        .acquire("failed", 172800, None, 1060)
        .await
        .unwrap()
        .unwrap();
    assert!(next.generation > first.generation);
}
