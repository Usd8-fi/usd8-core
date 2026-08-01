use aws_sdk_dynamodb::types::AttributeValue;
use aws_types::region::Region;
use lambda_http::{Body, Error, Request, Response, service_fn};
use std::env;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use usd8_score_api::{IncrementalScoreError, UserCheckpoint, compute_incremental_score};
use usd8_settlement::Address;
use usd8_settlement::config::CHAIN_ID;
use usd8_settlement::rpc::HttpRpc;

#[cfg(feature = "sepolia")]
const DEFAULT_RPC_URL: &str = "https://sepolia.drpc.org";
const MAX_CHECKPOINT_BYTES: usize = 128 * 1024;
const CHECKPOINT_TTL_SECONDS: u64 = 180 * 24 * 60 * 60;

struct StoredCheckpoint {
    checkpoint: UserCheckpoint,
    version: u64,
}

struct App {
    dynamodb: aws_sdk_dynamodb::Client,
    table: String,
    rpc: HttpRpc,
    registry: Address,
    allowed_origin: String,
}

fn required(name: &str) -> Result<String, Error> {
    env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing required environment variable: {name}").into())
}

fn rpc_url() -> Result<String, Error> {
    if let Ok(value) = env::var("USD8_SCORE_RPC_URL")
        && !value.is_empty()
    {
        return Ok(value);
    }
    #[cfg(feature = "sepolia")]
    {
        Ok(DEFAULT_RPC_URL.to_owned())
    }
    #[cfg(not(feature = "sepolia"))]
    {
        Err("missing required environment variable: USD8_SCORE_RPC_URL".into())
    }
}

fn account_from_path(path: &str) -> Option<Result<Address, ()>> {
    path.strip_prefix("/score/")
        .filter(|account| !account.is_empty() && !account.contains('/'))
        .map(Address::from_str)
}

fn checkpoint_key(registry: Address, account: Address) -> String {
    format!("{CHAIN_ID}#{registry}#{account}")
}

impl App {
    async fn load(&self, account: Address) -> Result<Option<StoredCheckpoint>, Error> {
        let output = self
            .dynamodb
            .get_item()
            .table_name(&self.table)
            .key(
                "pk",
                AttributeValue::S(checkpoint_key(self.registry, account)),
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
        let checkpoint = serde_json::from_str(payload)?;
        Ok(Some(StoredCheckpoint {
            checkpoint,
            version,
        }))
    }

    async fn save(
        &self,
        account: Address,
        checkpoint: &UserCheckpoint,
        cursor_block: u64,
        expected_version: Option<u64>,
    ) -> Result<bool, Error> {
        let payload = serde_json::to_string(checkpoint)?;
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
                AttributeValue::S(checkpoint_key(self.registry, account)),
            )
            .item("payload", AttributeValue::S(payload))
            .item("version", AttributeValue::N(next_version.to_string()))
            .item("cursorBlock", AttributeValue::N(cursor_block.to_string()))
            .item("expiresAt", AttributeValue::N(expires_at.to_string()));
        request = if let Some(version) = expected_version {
            request
                .condition_expression(
                    "#version = :expected AND (attribute_not_exists(#cursor) OR #cursor <= :cursor)",
                )
                .expression_attribute_names("#version", "version")
                .expression_attribute_names("#cursor", "cursorBlock")
                .expression_attribute_values(":expected", AttributeValue::N(version.to_string()))
                .expression_attribute_values(
                    ":cursor",
                    AttributeValue::N(cursor_block.to_string()),
                )
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
    cacheable: bool,
) -> Result<Response<Body>, Error> {
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("access-control-allow-origin", origin)
        .header("vary", "origin")
        .header(
            "cache-control",
            if cacheable {
                "public, max-age=15, s-maxage=15"
            } else {
                "no-store"
            },
        )
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

async fn calculate(app: &App, account: Address) -> Result<serde_json::Value, Error> {
    for attempt in 0..2 {
        let stored = app.load(account).await?;
        let previous = stored.as_ref().map(|value| value.checkpoint.clone());
        let computed = compute_incremental_score(&app.rpc, app.registry, account, previous).await;
        let (snapshot, checkpoint) = match computed {
            Ok(value) => value,
            Err(error) if stored.is_some() && stale_checkpoint(&error) => {
                eprintln!("discarding stale score checkpoint for {account}: {error}");
                compute_incremental_score(&app.rpc, app.registry, account, None).await?
            }
            Err(error) => return Err(error.into()),
        };
        let should_persist = snapshot.cache_status != "hit";
        let cursor_block = snapshot.score_cutoff_block.parse::<u64>()?;
        let value = serde_json::to_value(snapshot)?;
        if !should_persist {
            return Ok(value);
        }
        if app
            .save(
                account,
                &checkpoint,
                cursor_block,
                stored.as_ref().map(|value| value.version),
            )
            .await?
        {
            return Ok(value);
        }
        if attempt == 0 {
            continue;
        }
        eprintln!("score checkpoint update contention for {account}; returning computed snapshot");
        return Ok(value);
    }
    unreachable!("score checkpoint retry loop always returns")
}

async fn handle(app: Arc<App>, request: Request) -> Result<Response<Body>, Error> {
    if request.method().as_str() != "GET" {
        return response(
            405,
            &serde_json::json!({ "error": "METHOD_NOT_ALLOWED" }),
            &app.allowed_origin,
            false,
        );
    }
    let account = match account_from_path(request.uri().path()) {
        Some(Ok(account)) => account,
        Some(Err(())) => {
            return response(
                400,
                &serde_json::json!({ "error": "INVALID_ADDRESS" }),
                &app.allowed_origin,
                false,
            );
        }
        None => {
            return response(
                404,
                &serde_json::json!({ "error": "NOT_FOUND" }),
                &app.allowed_origin,
                false,
            );
        }
    };
    match calculate(&app, account).await {
        Ok(value) => response(200, &value, &app.allowed_origin, true),
        Err(error) => {
            eprintln!("score calculation failed for {account}: {error}");
            response(
                503,
                &serde_json::json!({ "error": "SCORE_UNAVAILABLE" }),
                &app.allowed_origin,
                false,
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
    let registry = Address::from_str(&required("USD8_REGISTRY")?)
        .map_err(|()| "USD8_REGISTRY is not a canonical address")?;
    let app = Arc::new(App {
        dynamodb: aws_sdk_dynamodb::Client::new(&sdk),
        table: required("USD8_SCORE_TABLE")?,
        rpc: HttpRpc::new(&rpc_url()?, None, 10_000)?,
        registry,
        allowed_origin: required("USD8_ALLOWED_ORIGIN")?,
    });
    lambda_http::run(service_fn(move |request| handle(app.clone(), request))).await
}

#[cfg(test)]
mod tests {
    use super::{account_from_path, checkpoint_key};
    use std::str::FromStr;
    use usd8_settlement::Address;

    #[test]
    fn route_accepts_exactly_one_address_segment() {
        let account = "0x1111111111111111111111111111111111111111";
        assert_eq!(
            account_from_path(&format!("/score/{account}"))
                .unwrap()
                .unwrap()
                .to_string(),
            account
        );
        assert!(account_from_path("/score/not-an-address").unwrap().is_err());
        assert!(account_from_path(&format!("/score/{account}/extra")).is_none());
    }

    #[test]
    fn dynamodb_key_is_chain_registry_and_account_scoped() {
        let registry = Address::from_str("0x2222222222222222222222222222222222222222").unwrap();
        let account = Address::from_str("0x1111111111111111111111111111111111111111").unwrap();
        let key = checkpoint_key(registry, account);
        assert!(key.ends_with(
            "#0x2222222222222222222222222222222222222222#0x1111111111111111111111111111111111111111"
        ));
    }
}
