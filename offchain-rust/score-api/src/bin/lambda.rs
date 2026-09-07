use aws_sdk_dynamodb::types::AttributeValue;
use aws_types::region::Region;
use lambda_http::{Body, Error, Request, Response, service_fn};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use usd8_score_api::{
    CachedInsuranceScoreSnapshot, IncrementalScoreError, ScoreNetwork, UserCheckpoint,
    compute_incremental_score_at,
};
use usd8_settlement::Address;
use usd8_settlement::chain::{
    ChainError, block_at_or_before_timestamp, block_by_number, finalized_block,
};
use usd8_settlement::rpc::{HttpRpc, RpcError};

const MAX_CHECKPOINT_BYTES: usize = 128 * 1024;
const CHECKPOINT_TTL_SECONDS: u64 = 180 * 24 * 60 * 60;
const DAILY_EPOCH_SECONDS: u64 = 24 * 60 * 60;
const REFRESH_COOLDOWN_SECONDS: u64 = 5 * 60;
const LEGACY_SEPOLIA_CHAIN_ID: u64 = 11_155_111;
const DEFAULT_SEPOLIA_SCORE_RPC_URL: &str = "https://rpc.sepolia.ethpandaops.io";

fn completed_utc_epoch(finalized_timestamp: u64) -> Option<u64> {
    let epoch = finalized_timestamp / DAILY_EPOCH_SECONDS * DAILY_EPOCH_SECONDS;
    (epoch >= DAILY_EPOCH_SECONDS).then_some(epoch)
}

fn daily_cache_max_age(epoch: u64, now: u64) -> u64 {
    epoch
        .saturating_add(DAILY_EPOCH_SECONDS)
        .saturating_sub(now)
}

fn is_current_daily_snapshot(
    snapshot_epoch: Option<u64>,
    snapshot_version: u32,
    epoch: u64,
) -> bool {
    snapshot_epoch == Some(epoch) && snapshot_version == usd8_score_api::SCORE_SNAPSHOT_VERSION
}

fn refresh_requested(query: Option<&str>) -> bool {
    query.is_some_and(|query| query.split('&').any(|parameter| parameter == "refresh=1"))
}

fn refresh_throttled(last_refresh_at: Option<u64>, now: u64) -> bool {
    last_refresh_at
        .is_some_and(|timestamp| now < timestamp.saturating_add(REFRESH_COOLDOWN_SECONDS))
}

struct StoredCheckpoint {
    checkpoint: UserCheckpoint,
    snapshot: Option<CachedInsuranceScoreSnapshot>,
    snapshot_epoch: Option<u64>,
    last_refresh_at: Option<u64>,
    version: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedCheckpoint {
    checkpoint: UserCheckpoint,
    snapshot: Option<CachedInsuranceScoreSnapshot>,
    snapshot_epoch: Option<u64>,
}

fn decode_checkpoint_payload(
    payload: &str,
) -> Result<
    (
        UserCheckpoint,
        Option<CachedInsuranceScoreSnapshot>,
        Option<u64>,
    ),
    serde_json::Error,
> {
    if let Ok(persisted) = serde_json::from_str::<PersistedCheckpoint>(payload) {
        return Ok((
            persisted.checkpoint,
            persisted.snapshot,
            persisted.snapshot_epoch,
        ));
    }
    let value: serde_json::Value = serde_json::from_str(payload)?;
    if let Some(checkpoint) = value.get("checkpoint") {
        return Ok((serde_json::from_value(checkpoint.clone())?, None, None));
    }
    Ok((serde_json::from_value(value)?, None, None))
}

struct CalculatedScore {
    value: serde_json::Value,
    cache_max_age: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ScoreNetworkConfig {
    chain_id: u64,
    name: String,
    registry: String,
    rpc_url: String,
}

struct RuntimeNetwork {
    score: ScoreNetwork,
    registry: Address,
    rpc: HttpRpc,
}

struct App {
    dynamodb: aws_sdk_dynamodb::Client,
    table: String,
    networks: BTreeMap<u64, RuntimeNetwork>,
    allowed_origin: String,
}

fn required(name: &str) -> Result<String, Error> {
    env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing required environment variable: {name}").into())
}

fn network_configs_from_json(raw: &str) -> Result<BTreeMap<u64, ScoreNetworkConfig>, Error> {
    let configs: Vec<ScoreNetworkConfig> = serde_json::from_str(raw)?;
    if configs.is_empty() {
        return Err("USD8_SCORE_NETWORKS_JSON must configure at least one network".into());
    }
    let mut by_chain_id = BTreeMap::new();
    for config in configs {
        if config.chain_id == 0
            || config.name.trim().is_empty()
            || config.rpc_url.trim().is_empty()
            || Address::from_str(&config.registry).is_err()
        {
            return Err("USD8_SCORE_NETWORKS_JSON contains an invalid network profile".into());
        }
        if by_chain_id.insert(config.chain_id, config).is_some() {
            return Err("USD8_SCORE_NETWORKS_JSON contains a duplicate chain ID".into());
        }
    }
    Ok(by_chain_id)
}

fn configured_networks(
    network_json: Option<&str>,
    legacy_registry: Option<&str>,
    legacy_rpc_url: Option<&str>,
) -> Result<BTreeMap<u64, ScoreNetworkConfig>, Error> {
    if let Some(network_json) = network_json.filter(|value| !value.is_empty()) {
        return network_configs_from_json(network_json);
    }
    let registry = legacy_registry
        .filter(|value| !value.is_empty())
        .ok_or_else(|| -> Error {
            "missing required environment variable: USD8_SCORE_NETWORKS_JSON or USD8_REGISTRY"
                .into()
        })?;
    let rpc_url = legacy_rpc_url
        .filter(|value| !value.is_empty())
        .unwrap_or(DEFAULT_SEPOLIA_SCORE_RPC_URL);
    Ok(BTreeMap::from([(
        LEGACY_SEPOLIA_CHAIN_ID,
        ScoreNetworkConfig {
            chain_id: LEGACY_SEPOLIA_CHAIN_ID,
            name: "Sepolia".to_owned(),
            registry: registry.to_owned(),
            rpc_url: rpc_url.to_owned(),
        },
    )]))
}

fn runtime_networks_from_configs(
    configs: BTreeMap<u64, ScoreNetworkConfig>,
) -> Result<BTreeMap<u64, RuntimeNetwork>, Error> {
    configs
        .into_values()
        .map(|config| {
            let registry = Address::from_str(&config.registry)
                .map_err(|()| "USD8_SCORE_NETWORKS_JSON has an invalid Registry address")?;
            Ok((
                config.chain_id,
                RuntimeNetwork {
                    score: ScoreNetwork {
                        chain_id: config.chain_id,
                        name: config.name,
                    },
                    registry,
                    rpc: HttpRpc::new(&config.rpc_url, None, 10_000)?,
                },
            ))
        })
        .collect()
}

fn runtime_networks() -> Result<BTreeMap<u64, RuntimeNetwork>, Error> {
    let network_json = env::var("USD8_SCORE_NETWORKS_JSON").ok();
    let legacy_registry = env::var("USD8_REGISTRY").ok();
    let legacy_rpc_url = env::var("USD8_SCORE_RPC_URL").ok();
    runtime_networks_from_configs(configured_networks(
        network_json.as_deref(),
        legacy_registry.as_deref(),
        legacy_rpc_url.as_deref(),
    )?)
}

enum ScoreRequest {
    Explicit { chain_id: u64, account: Address },
    Legacy { account: Address },
}

fn score_request_from_path(path: &str) -> Option<Result<ScoreRequest, ()>> {
    let mut segments = path.strip_prefix("/score/")?.split('/');
    let first = segments.next()?;
    let second = segments.next();
    if segments.next().is_some() {
        return None;
    }
    Some(match second {
        None => Address::from_str(first).map(|account| ScoreRequest::Legacy { account }),
        Some(account) => match (first.parse::<u64>(), Address::from_str(account)) {
            (Ok(chain_id), Ok(account)) if chain_id != 0 => {
                Ok(ScoreRequest::Explicit { chain_id, account })
            }
            _ => Err(()),
        },
    })
}

fn checkpoint_key(chain_id: u64, registry: Address, account: Address) -> String {
    format!("{chain_id}#{registry}#{account}")
}

impl App {
    async fn load(
        &self,
        network: &RuntimeNetwork,
        account: Address,
    ) -> Result<Option<StoredCheckpoint>, Error> {
        let output = self
            .dynamodb
            .get_item()
            .table_name(&self.table)
            .key(
                "pk",
                AttributeValue::S(checkpoint_key(
                    network.score.chain_id,
                    network.registry,
                    account,
                )),
            )
            .consistent_read(true)
            .send()
            .await?;
        let Some(item) = output.item else {
            return Ok(None);
        };
        let payload = item
            .get("payload")
            .and_then(|value| value.as_s().ok())
            .ok_or("checkpoint payload missing")?;
        if payload.len() > MAX_CHECKPOINT_BYTES {
            return Err("checkpoint payload exceeds size limit".into());
        }
        let version = item
            .get("version")
            .and_then(|value| value.as_n().ok())
            .ok_or("checkpoint version missing")?
            .parse::<u64>()?;
        let last_refresh_at = item
            .get("lastRefreshAt")
            .and_then(|value| value.as_n().ok())
            .and_then(|value| value.parse::<u64>().ok());
        let (checkpoint, snapshot, snapshot_epoch) = decode_checkpoint_payload(payload)?;
        Ok(Some(StoredCheckpoint {
            checkpoint,
            snapshot,
            snapshot_epoch,
            last_refresh_at,
            version,
        }))
    }

    // Keep checkpoint payload and optimistic-concurrency metadata explicit at this persistence boundary.
    #[allow(clippy::too_many_arguments)]
    async fn save(
        &self,
        network: &RuntimeNetwork,
        account: Address,
        checkpoint: &UserCheckpoint,
        snapshot: &CachedInsuranceScoreSnapshot,
        snapshot_epoch: u64,
        cursor_block: u64,
        expected_version: Option<u64>,
        last_refresh_at: Option<u64>,
    ) -> Result<bool, Error> {
        let payload = serde_json::to_string(&PersistedCheckpoint {
            checkpoint: checkpoint.clone(),
            snapshot: Some(snapshot.clone()),
            snapshot_epoch: Some(snapshot_epoch),
        })?;
        if payload.len() > MAX_CHECKPOINT_BYTES {
            return Err("checkpoint payload exceeds size limit".into());
        }
        let next_version = expected_version.unwrap_or(0).saturating_add(1);
        let expires_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)?
            .as_secs()
            .saturating_add(CHECKPOINT_TTL_SECONDS);
        let mut request = self
            .dynamodb
            .put_item()
            .table_name(&self.table)
            .item(
                "pk",
                AttributeValue::S(checkpoint_key(
                    network.score.chain_id,
                    network.registry,
                    account,
                )),
            )
            .item("payload", AttributeValue::S(payload))
            .item("version", AttributeValue::N(next_version.to_string()))
            .item("cursorBlock", AttributeValue::N(cursor_block.to_string()))
            .item(
                "snapshotEpoch",
                AttributeValue::N(snapshot_epoch.to_string()),
            )
            .item("expiresAt", AttributeValue::N(expires_at.to_string()));
        if let Some(last_refresh_at) = last_refresh_at {
            request = request.item(
                "lastRefreshAt",
                AttributeValue::N(last_refresh_at.to_string()),
            );
        }
        request = if let Some(version) = expected_version {
            request
                .condition_expression("#version = :expected")
                .expression_attribute_names("#version", "version")
                .expression_attribute_values(":expected", AttributeValue::N(version.to_string()))
        } else {
            request
                .condition_expression("attribute_not_exists(#pk)")
                .expression_attribute_names("#pk", "pk")
        };
        match request.send().await {
            Ok(_) => Ok(true),
            Err(error)
                if error
                    .as_service_error()
                    .is_some_and(|error| error.is_conditional_check_failed_exception()) =>
            {
                Ok(false)
            }
            Err(error) => Err(error.into()),
        }
    }
}

fn response(
    status: u16,
    value: &impl serde::Serialize,
    origin: &str,
    cache_max_age: Option<u64>,
) -> Result<Response<Body>, Error> {
    let cache_control = cache_max_age.map_or_else(
        || "no-store".to_owned(),
        |seconds| format!("public, max-age={seconds}, s-maxage={seconds}"),
    );
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("access-control-allow-origin", origin)
        .header("vary", "origin")
        .header("cache-control", cache_control)
        .body(Body::Text(serde_json::to_string(value)?))?)
}

fn stale_checkpoint(error: &IncrementalScoreError) -> bool {
    matches!(
        error,
        IncrementalScoreError::Malformed(_)
            | IncrementalScoreError::TokenMismatch
            | IncrementalScoreError::DecimalsMismatch
            | IncrementalScoreError::RateHistoryMismatch
            | IncrementalScoreError::RetroactiveRate
            | IncrementalScoreError::CursorRollback
            | IncrementalScoreError::CheckpointIdentity
            | IncrementalScoreError::CheckpointBlockHash
    )
}

fn unavailable_checkpoint_history(error: &IncrementalScoreError) -> bool {
    matches!(
        error,
        IncrementalScoreError::Chain(ChainError::Rpc(RpcError::JsonRpc { code: -32_000, message }))
            if message.to_ascii_lowercase().contains("historical state")
                && message.to_ascii_lowercase().contains("not available")
    )
}

async fn calculate(
    app: &App,
    network: &RuntimeNetwork,
    account: Address,
    force_refresh: bool,
) -> Result<CalculatedScore, Error> {
    let finalized = finalized_block(&network.rpc).await?;
    let epoch = completed_utc_epoch(finalized.timestamp)
        .ok_or("finalized score head predates the first completed UTC day")?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let cache_max_age = daily_cache_max_age(epoch, now);
    for attempt in 0..2 {
        let stored = app.load(network, account).await?;
        if let Some(mut snapshot) = stored
            .as_ref()
            .filter(|value| {
                is_current_daily_snapshot(
                    value.snapshot_epoch,
                    value
                        .snapshot
                        .as_ref()
                        .map_or(0, |snapshot| snapshot.snapshot_version),
                    epoch,
                ) && (!force_refresh || refresh_throttled(value.last_refresh_at, now))
            })
            .and_then(|value| value.snapshot.clone())
        {
            snapshot.cache_status = if force_refresh {
                "refresh-throttled"
            } else {
                "daily-hit"
            }
            .to_owned();
            snapshot.log_requests = "0".to_owned();
            return Ok(CalculatedScore {
                value: serde_json::to_value(snapshot)?,
                cache_max_age: if force_refresh { 0 } else { cache_max_age },
            });
        }
        let reference = if force_refresh {
            finalized.clone()
        } else {
            let reference_number = block_at_or_before_timestamp(
                &network.rpc,
                epoch.saturating_sub(1),
                finalized.number,
            )
            .await?;
            block_by_number(&network.rpc, reference_number).await?
        };
        let previous = stored.as_ref().map(|value| value.checkpoint.clone());
        let computed = compute_incremental_score_at(
            &network.rpc,
            &network.score,
            network.registry,
            account,
            reference.clone(),
            previous,
        )
        .await;
        let (snapshot, checkpoint) = match computed {
            Ok(value) => value,
            Err(error)
                if stored.is_some()
                    && (stale_checkpoint(&error) || unavailable_checkpoint_history(&error)) =>
            {
                eprintln!(
                    "discarding unavailable score checkpoint for chain {} account {account}: {error}",
                    network.score.chain_id,
                );
                compute_incremental_score_at(
                    &network.rpc,
                    &network.score,
                    network.registry,
                    account,
                    reference,
                    None,
                )
                .await?
            }
            Err(error) => return Err(error.into()),
        };
        let cursor_block = snapshot.reference_block.parse::<u64>()?;
        let value = serde_json::to_value(&snapshot)?;
        if app
            .save(
                network,
                account,
                &checkpoint,
                &snapshot,
                epoch,
                cursor_block,
                stored.as_ref().map(|value| value.version),
                force_refresh.then_some(now),
            )
            .await?
        {
            return Ok(CalculatedScore {
                value,
                cache_max_age: if force_refresh { 0 } else { cache_max_age },
            });
        }
        if attempt == 0 {
            continue;
        }
        eprintln!(
            "score checkpoint update contention for chain {} account {account}; returning computed snapshot",
            network.score.chain_id,
        );
        return Ok(CalculatedScore {
            value,
            cache_max_age: if force_refresh { 0 } else { cache_max_age },
        });
    }
    unreachable!("score checkpoint retry loop always returns")
}

async fn handle(app: Arc<App>, request: Request) -> Result<Response<Body>, Error> {
    if request.method().as_str() != "GET" {
        return response(
            405,
            &serde_json::json!({ "error": "METHOD_NOT_ALLOWED" }),
            &app.allowed_origin,
            None,
        );
    }
    let score_request = match score_request_from_path(request.uri().path()) {
        Some(Ok(request)) => request,
        Some(Err(())) => {
            return response(
                400,
                &serde_json::json!({ "error": "INVALID_REQUEST" }),
                &app.allowed_origin,
                None,
            );
        }
        None => {
            return response(
                404,
                &serde_json::json!({ "error": "NOT_FOUND" }),
                &app.allowed_origin,
                None,
            );
        }
    };
    let (chain_id, account) = match score_request {
        ScoreRequest::Explicit { chain_id, account } => (chain_id, account),
        ScoreRequest::Legacy { account } if app.networks.len() == 1 => (
            *app.networks
                .keys()
                .next()
                .expect("single network is nonempty"),
            account,
        ),
        ScoreRequest::Legacy { .. } => {
            return response(
                404,
                &serde_json::json!({ "error": "LEGACY_ROUTE_AMBIGUOUS" }),
                &app.allowed_origin,
                None,
            );
        }
    };
    let Some(network) = app.networks.get(&chain_id) else {
        return response(
            404,
            &serde_json::json!({ "error": "UNSUPPORTED_CHAIN" }),
            &app.allowed_origin,
            None,
        );
    };
    let force_refresh = refresh_requested(request.uri().query());
    match calculate(&app, network, account, force_refresh).await {
        Ok(calculated) => response(
            200,
            &calculated.value,
            &app.allowed_origin,
            Some(calculated.cache_max_age),
        ),
        Err(error) => {
            eprintln!("score calculation failed for chain {chain_id} account {account}: {error}");
            response(
                503,
                &serde_json::json!({ "error": "SCORE_UNAVAILABLE" }),
                &app.allowed_origin,
                None,
            )
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    let region = required("AWS_REGION")?;
    let sdk = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(Region::new(region))
        .load()
        .await;
    let app = Arc::new(App {
        dynamodb: aws_sdk_dynamodb::Client::new(&sdk),
        table: required("USD8_SCORE_TABLE")?,
        networks: runtime_networks()?,
        allowed_origin: required("USD8_ALLOWED_ORIGIN")?,
    });
    lambda_http::run(service_fn(move |request| handle(app.clone(), request))).await
}

#[cfg(test)]
mod tests {
    use super::{
        DAILY_EPOCH_SECONDS, IncrementalScoreError, ScoreRequest, checkpoint_key,
        completed_utc_epoch, configured_networks, daily_cache_max_age, decode_checkpoint_payload,
        is_current_daily_snapshot, network_configs_from_json, refresh_requested, refresh_throttled,
        response, score_request_from_path, unavailable_checkpoint_history,
    };
    use std::str::FromStr;
    use usd8_settlement::Address;
    use usd8_settlement::chain::ChainError;
    use usd8_settlement::rpc::RpcError;

    #[test]
    fn route_accepts_the_existing_legacy_api_gateway_shape_or_an_explicit_chain() {
        let account = "0x1111111111111111111111111111111111111111";
        let explicit = score_request_from_path(&format!("/score/11155111/{account}"))
            .unwrap()
            .unwrap();
        match explicit {
            ScoreRequest::Explicit {
                chain_id,
                account: parsed,
            } => {
                assert_eq!(chain_id, 11_155_111);
                assert_eq!(parsed.to_string(), account);
            }
            ScoreRequest::Legacy { .. } => panic!("expected an explicit-chain route"),
        }
        assert!(
            score_request_from_path(&format!("/score/not-a-chain/{account}"))
                .unwrap()
                .is_err()
        );
        let legacy = score_request_from_path(&format!("/score/{account}"))
            .unwrap()
            .unwrap();
        assert!(matches!(legacy, ScoreRequest::Legacy { .. }));
        assert!(score_request_from_path(&format!("/score/11155111/{account}/extra")).is_none());
    }

    #[test]
    fn refresh_query_requires_an_explicit_one_value() {
        assert!(refresh_requested(Some("refresh=1")));
        assert!(refresh_requested(Some("other=x&refresh=1")));
        assert!(!refresh_requested(None));
        assert!(!refresh_requested(Some("refresh=0")));
        assert!(!refresh_requested(Some("refresh=true")));
    }

    #[test]
    fn refresh_is_throttled_for_five_minutes_after_the_latest_snapshot() {
        assert!(refresh_throttled(Some(1000), 1299));
        assert!(!refresh_throttled(Some(1000), 1300));
        assert!(!refresh_throttled(None, 1001));
    }

    #[test]
    fn incompatible_cached_snapshot_keeps_its_incremental_checkpoint() {
        let payload = r#"{
            "checkpoint": {
                "schemaVersion": 1,
                "chainId": "11155111",
                "registry": "0x2222222222222222222222222222222222222222",
                "account": "0x1111111111111111111111111111111111111111",
                "tokens": [],
                "visibleTokens": []
            },
            "snapshot": {},
            "snapshotEpoch": 1786320000
        }"#;

        let (checkpoint, snapshot, snapshot_epoch) = decode_checkpoint_payload(payload).unwrap();

        assert_eq!(checkpoint.chain_id, "11155111");
        assert!(snapshot.is_none());
        assert!(snapshot_epoch.is_none());
    }

    #[test]
    fn fixed_daily_epoch_uses_the_completed_utc_day() {
        assert_eq!(completed_utc_epoch(DAILY_EPOCH_SECONDS - 1), None);
        assert_eq!(
            completed_utc_epoch(7 * DAILY_EPOCH_SECONDS + 12),
            Some(7 * DAILY_EPOCH_SECONDS)
        );
    }

    #[test]
    fn daily_snapshot_cache_expires_at_the_next_utc_epoch() {
        let epoch = 7 * DAILY_EPOCH_SECONDS;
        assert_eq!(
            daily_cache_max_age(epoch, epoch + 3),
            DAILY_EPOCH_SECONDS - 3
        );
        assert_eq!(daily_cache_max_age(epoch, epoch + DAILY_EPOCH_SECONDS), 0);
    }

    #[test]
    fn daily_snapshot_is_only_reused_for_the_same_epoch() {
        let epoch = 7 * DAILY_EPOCH_SECONDS;
        assert!(is_current_daily_snapshot(
            Some(epoch),
            usd8_score_api::SCORE_SNAPSHOT_VERSION,
            epoch
        ));
        assert!(!is_current_daily_snapshot(Some(epoch), 0, epoch));
        assert!(!is_current_daily_snapshot(
            Some(epoch),
            usd8_score_api::SCORE_SNAPSHOT_VERSION,
            epoch + DAILY_EPOCH_SECONDS
        ));
        assert!(!is_current_daily_snapshot(
            None,
            usd8_score_api::SCORE_SNAPSHOT_VERSION,
            epoch
        ));
    }

    #[test]
    fn daily_snapshot_response_expires_at_the_requested_epoch_boundary() {
        let response = response(
            200,
            &serde_json::json!({ "score": "1" }),
            "https://usd8.fi",
            Some(86_123),
        )
        .unwrap();
        assert_eq!(
            response.headers().get("cache-control").unwrap(),
            "public, max-age=86123, s-maxage=86123"
        );
    }

    #[test]
    fn existing_sepolia_environment_is_a_safe_single_chain_fallback() {
        let configs = configured_networks(
            None,
            Some("0x2222222222222222222222222222222222222222"),
            None,
        )
        .unwrap();
        let config = configs.get(&11_155_111).unwrap();
        assert_eq!(config.name, "Sepolia");
        assert_eq!(
            config.registry,
            "0x2222222222222222222222222222222222222222"
        );
        assert_eq!(config.rpc_url, "https://rpc.sepolia.ethpandaops.io");
    }

    #[test]
    fn unavailable_historical_checkpoint_is_recomputed_without_the_cache() {
        let error = IncrementalScoreError::Chain(ChainError::Rpc(RpcError::JsonRpc {
            code: -32_000,
            message: "historical state 0x123 is not available".to_owned(),
        }));
        assert!(unavailable_checkpoint_history(&error));
        let current_state_error =
            IncrementalScoreError::Chain(ChainError::Rpc(RpcError::JsonRpc {
                code: -32_000,
                message: "execution reverted".to_owned(),
            }));
        assert!(!unavailable_checkpoint_history(&current_state_error));
    }

    #[test]
    fn dynamodb_key_is_chain_registry_and_account_scoped() {
        let registry = Address::from_str("0x2222222222222222222222222222222222222222").unwrap();
        let account = Address::from_str("0x1111111111111111111111111111111111111111").unwrap();
        let key = checkpoint_key(11_155_111, registry, account);
        assert!(key.ends_with(
            "#0x2222222222222222222222222222222222222222#0x1111111111111111111111111111111111111111"
        ));
        assert_ne!(key, checkpoint_key(1, registry, account));
    }

    #[test]
    fn startup_configuration_is_an_allowlist_with_unique_chain_ids() {
        let config = network_configs_from_json(
            r#"[{"chainId":11155111,"name":"Sepolia","registry":"0x2222222222222222222222222222222222222222","rpcUrl":"https://ethereum-sepolia-rpc.publicnode.com"}]"#,
        )
        .unwrap();
        assert_eq!(config.get(&11_155_111).unwrap().name, "Sepolia");
        assert!(network_configs_from_json(
            r#"[{"chainId":1,"name":"Ethereum","registry":"0x2222222222222222222222222222222222222222","rpcUrl":"https://ethereum-rpc.publicnode.com"},{"chainId":1,"name":"Ethereum","registry":"0x3333333333333333333333333333333333333333","rpcUrl":"https://ethereum-rpc.publicnode.com"}]"#,
        )
        .is_err());
    }
}
