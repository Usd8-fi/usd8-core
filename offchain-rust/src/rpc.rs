use crate::config::{MAX_LOG_RANGE, MAX_LOG_RESULT_CAP};
use async_trait::async_trait;
use reqwest::Url;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use reqwest::redirect::Policy;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use thiserror::Error;

const TRUSTED_DRPC_HOSTS: [&str; 2] = ["lb.drpc.org", "lb.drpc.live"];
const DRPC_HEADER: HeaderName = HeaderName::from_static("drpc-key");
const MAX_RPC_TIMEOUT_MS: u64 = 120_000;
const MAX_RPC_RETRIES: u32 = 8;
const MAX_RPC_RETRY_DELAY_MS: u64 = 10_000;
const DEFAULT_RPC_RESPONSE_BYTE_CAP: usize = 16 * 1024 * 1024;
const MAX_LOG_REQUESTS_PER_CHUNK: u64 = 4_096;
const MAX_LOG_BISECTIONS_PER_CHUNK: u64 = 2_048;
const MAX_LOG_TRANSPORT_ATTEMPTS_PER_CHUNK: u64 =
    MAX_LOG_REQUESTS_PER_CHUNK * (MAX_RPC_RETRIES as u64 + 1);
const MAX_LOG_CHUNK_DURATION: Duration = Duration::from_secs(300);
const MAX_TOPIC_OPTIONS: usize = 64;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RpcMetrics {
    pub logical_requests: u64,
    pub transport_attempts: u64,
    pub transport_responses: u64,
    pub transport_retries: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LogMetrics {
    pub requests: u64,
    pub bisections: u64,
    pub errors: u64,
    pub elapsed_ms: u64,
}

#[derive(Debug, Error)]
pub enum RpcError {
    #[error("invalid RPC endpoint")]
    InvalidEndpoint,
    #[error("unsupported RPC endpoint scheme")]
    UnsupportedScheme,
    #[error("refusing to send DRPC_KEY to untrusted RPC endpoint")]
    UntrustedDrpcEndpoint,
    #[error("RPC timeout must be between 1 and {maximum_ms} milliseconds")]
    InvalidTimeout { maximum_ms: u64 },
    #[error("invalid RPC retry policy")]
    InvalidRetryPolicy,
    #[error("RPC response-byte limit must be between 1 and {maximum} bytes")]
    InvalidResponseLimit { maximum: usize },
    #[error("invalid DRPC_KEY header value")]
    InvalidDrpcKey,
    #[error("RPC transport failed for {method}: {message}")]
    Transport { method: String, message: String },
    #[error("RPC HTTP status {status} for {method}")]
    HttpStatus { method: String, status: u16 },
    #[error("invalid JSON-RPC response for {method}: {message}")]
    InvalidResponse { method: String, message: String },
    #[error("RPC response exceeds {limit}-byte limit for {method}")]
    ResponseTooLarge { method: String, limit: usize },
    #[error("JSON-RPC error {code}: {message}")]
    JsonRpc { code: i64, message: String },
    #[error("invalid RPC log: {0}")]
    InvalidLog(String),
    #[error(
        "getLogs returned {count} >= result cap ({cap}) for single block {block}; cannot prove completeness"
    )]
    LogCompleteness {
        count: usize,
        cap: usize,
        block: u64,
    },
    #[error("max log range or result cap is outside supported bounds")]
    InvalidLogPolicy,
    #[error("eth_getLogs {0} budget exceeded")]
    LogBudgetExceeded(&'static str),
}

pub fn validate_rpc_endpoint(endpoint: &str, has_drpc_key: bool) -> Result<Url, RpcError> {
    let url = Url::parse(endpoint).map_err(|_| RpcError::InvalidEndpoint)?;
    if url.scheme() != "http" && url.scheme() != "https" {
        return Err(RpcError::UnsupportedScheme);
    }
    if has_drpc_key {
        let trusted = url.scheme() == "https"
            && url
                .host_str()
                .is_some_and(|host| TRUSTED_DRPC_HOSTS.contains(&host))
            && url.port().is_none_or(|port| port == 443)
            && url.username().is_empty()
            && url.password().is_none();
        if !trusted {
            return Err(RpcError::UntrustedDrpcEndpoint);
        }
    }
    Ok(url)
}

#[derive(Default)]
struct AtomicMetrics {
    logical_requests: AtomicU64,
    transport_attempts: AtomicU64,
    transport_responses: AtomicU64,
    transport_retries: AtomicU64,
}

impl AtomicMetrics {
    fn snapshot(&self) -> RpcMetrics {
        RpcMetrics {
            logical_requests: self.logical_requests.load(Ordering::Relaxed),
            transport_attempts: self.transport_attempts.load(Ordering::Relaxed),
            transport_responses: self.transport_responses.load(Ordering::Relaxed),
            transport_retries: self.transport_retries.load(Ordering::Relaxed),
        }
    }
}

pub struct HttpRpc {
    endpoint: Url,
    client: reqwest::Client,
    next_id: AtomicU64,
    metrics: Arc<AtomicMetrics>,
    retry_count: u32,
    retry_delay_ms: u64,
    response_byte_cap: usize,
}

impl HttpRpc {
    pub fn new(endpoint: &str, drpc_key: Option<&str>, timeout_ms: u64) -> Result<Self, RpcError> {
        Self::new_with_retry_delay(endpoint, drpc_key, timeout_ms, 5, 200)
    }

    pub fn new_with_retry_delay(
        endpoint: &str,
        drpc_key: Option<&str>,
        timeout_ms: u64,
        retry_count: u32,
        retry_delay_ms: u64,
    ) -> Result<Self, RpcError> {
        Self::new_with_retry_delay_and_response_limit(
            endpoint,
            drpc_key,
            timeout_ms,
            retry_count,
            retry_delay_ms,
            DEFAULT_RPC_RESPONSE_BYTE_CAP,
        )
    }

    pub fn new_with_retry_delay_and_response_limit(
        endpoint: &str,
        drpc_key: Option<&str>,
        timeout_ms: u64,
        retry_count: u32,
        retry_delay_ms: u64,
        response_byte_cap: usize,
    ) -> Result<Self, RpcError> {
        let proxy_url = (std::env::var("USD8_ENCLAVE_PROXY").as_deref() == Ok("1"))
            .then_some("http://127.0.0.1:8080");
        Self::new_inner(
            endpoint,
            drpc_key,
            timeout_ms,
            retry_count,
            retry_delay_ms,
            response_byte_cap,
            proxy_url,
        )
    }

    pub fn new_with_https_proxy(
        endpoint: &str,
        drpc_key: Option<&str>,
        timeout_ms: u64,
        proxy_url: &str,
    ) -> Result<Self, RpcError> {
        Self::new_inner(
            endpoint,
            drpc_key,
            timeout_ms,
            5,
            200,
            DEFAULT_RPC_RESPONSE_BYTE_CAP,
            Some(proxy_url),
        )
    }

    fn new_inner(
        endpoint: &str,
        drpc_key: Option<&str>,
        timeout_ms: u64,
        retry_count: u32,
        retry_delay_ms: u64,
        response_byte_cap: usize,
        proxy_url: Option<&str>,
    ) -> Result<Self, RpcError> {
        if timeout_ms == 0 || timeout_ms > MAX_RPC_TIMEOUT_MS {
            return Err(RpcError::InvalidTimeout {
                maximum_ms: MAX_RPC_TIMEOUT_MS,
            });
        }
        if retry_count > MAX_RPC_RETRIES || retry_delay_ms > MAX_RPC_RETRY_DELAY_MS {
            return Err(RpcError::InvalidRetryPolicy);
        }
        if response_byte_cap == 0 || response_byte_cap > DEFAULT_RPC_RESPONSE_BYTE_CAP {
            return Err(RpcError::InvalidResponseLimit {
                maximum: DEFAULT_RPC_RESPONSE_BYTE_CAP,
            });
        }
        let endpoint = validate_rpc_endpoint(endpoint, drpc_key.is_some())?;
        let mut headers = HeaderMap::new();
        if let Some(key) = drpc_key {
            let mut value = HeaderValue::from_str(key).map_err(|_| RpcError::InvalidDrpcKey)?;
            value.set_sensitive(true);
            headers.insert(DRPC_HEADER, value);
        }
        let mut client_builder = reqwest::Client::builder()
            .default_headers(headers)
            .redirect(Policy::none())
            .timeout(Duration::from_millis(timeout_ms));
        if let Some(proxy_url) = proxy_url {
            let proxy = reqwest::Proxy::https(proxy_url).map_err(|error| RpcError::Transport {
                method: "proxy initialization".to_owned(),
                message: error.to_string(),
            })?;
            client_builder = client_builder.proxy(proxy);
        }
        let client = client_builder
            .build()
            .map_err(|error| RpcError::Transport {
                method: "client initialization".to_owned(),
                message: error.to_string(),
            })?;
        Ok(Self {
            endpoint,
            client,
            next_id: AtomicU64::new(1),
            metrics: Arc::new(AtomicMetrics::default()),
            retry_count,
            retry_delay_ms,
            response_byte_cap,
        })
    }

    pub fn metrics(&self) -> RpcMetrics {
        self.metrics.snapshot()
    }

    fn transport_error(method: &str, error: &reqwest::Error) -> RpcError {
        RpcError::Transport {
            method: method.to_owned(),
            message: if error.is_timeout() {
                "request timed out".to_owned()
            } else if error.is_connect() {
                "connection failed".to_owned()
            } else if error.is_body() {
                "response body failed".to_owned()
            } else {
                "request failed".to_owned()
            },
        }
    }

    async fn send_attempt(
        &self,
        method: &str,
        body: &Value,
    ) -> Result<reqwest::Response, RpcError> {
        self.metrics
            .transport_attempts
            .fetch_add(1, Ordering::Relaxed);
        match self
            .client
            .post(self.endpoint.clone())
            .json(body)
            .send()
            .await
        {
            Ok(response) => {
                self.metrics
                    .transport_responses
                    .fetch_add(1, Ordering::Relaxed);
                Ok(response)
            }
            Err(error) => Err(Self::transport_error(method, &error)),
        }
    }

    async fn complete_attempt(&self, method: &str, body: &Value) -> Result<Value, RpcError> {
        let mut response = self.send_attempt(method, body).await?;
        let status = response.status();
        if !status.is_success() {
            return Err(RpcError::HttpStatus {
                method: method.to_owned(),
                status: status.as_u16(),
            });
        }
        if response
            .content_length()
            .is_some_and(|length| length > self.response_byte_cap as u64)
        {
            return Err(RpcError::ResponseTooLarge {
                method: method.to_owned(),
                limit: self.response_byte_cap,
            });
        }

        let mut bytes = Vec::with_capacity(
            response
                .content_length()
                .unwrap_or(0)
                .min(self.response_byte_cap as u64) as usize,
        );
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| Self::transport_error(method, &error))?
        {
            bytes
                .len()
                .checked_add(chunk.len())
                .filter(|length| *length <= self.response_byte_cap)
                .ok_or_else(|| RpcError::ResponseTooLarge {
                    method: method.to_owned(),
                    limit: self.response_byte_cap,
                })?;
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| RpcError::InvalidResponse {
            method: method.to_owned(),
            message: "body is not valid JSON".to_owned(),
        })
    }

    fn retryable(error: &RpcError) -> bool {
        match error {
            RpcError::Transport { .. } => true,
            RpcError::HttpStatus { status, .. } => {
                *status == 408 || *status == 429 || (500..=504).contains(status)
            }
            _ => false,
        }
    }
}

#[async_trait]
pub trait Rpc: Send + Sync {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError>;
    fn metrics(&self) -> RpcMetrics;
}

#[async_trait]
impl Rpc for HttpRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        self.metrics
            .logical_requests
            .fetch_add(1, Ordering::Relaxed);
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let body = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });

        let mut attempt = 0u32;
        let mut value = loop {
            let result = self.complete_attempt(method, &body).await;
            match result {
                Ok(value) => break value,
                Err(error) if attempt < self.retry_count && Self::retryable(&error) => {
                    self.metrics
                        .transport_retries
                        .fetch_add(1, Ordering::Relaxed);
                    let multiplier = 1u64 << attempt.min(10);
                    tokio::time::sleep(Duration::from_millis(
                        self.retry_delay_ms.saturating_mul(multiplier),
                    ))
                    .await;
                    attempt += 1;
                }
                Err(error) => return Err(error),
            }
        };

        if value.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            return Err(RpcError::InvalidResponse {
                method: method.to_owned(),
                message: "jsonrpc is not 2.0".to_owned(),
            });
        }
        if value.get("id").and_then(Value::as_u64) != Some(id) {
            return Err(RpcError::InvalidResponse {
                method: method.to_owned(),
                message: "response id does not match request".to_owned(),
            });
        }
        if let Some(error) = value.get("error") {
            let code = error.get("code").and_then(Value::as_i64).ok_or_else(|| {
                RpcError::InvalidResponse {
                    method: method.to_owned(),
                    message: "error object lacks integer code".to_owned(),
                }
            })?;
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unspecified provider error")
                .to_owned();
            return Err(RpcError::JsonRpc { code, message });
        }
        value
            .as_object_mut()
            .and_then(|object| object.remove("result"))
            .ok_or_else(|| RpcError::InvalidResponse {
                method: method.to_owned(),
                message: "missing result".to_owned(),
            })
    }

    fn metrics(&self) -> RpcMetrics {
        self.metrics()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RpcLog {
    pub address: String,
    pub topics: Vec<String>,
    pub data: String,
    pub block_number: u64,
    pub transaction_hash: String,
    pub log_index: u64,
}

#[derive(Clone, Debug, Default)]
pub struct LogFilter {
    pub address: String,
    pub topics: Vec<Value>,
}

fn hex_quantity(field: &str, value: &Value) -> Result<u64, RpcError> {
    let text = value
        .as_str()
        .and_then(|value| value.strip_prefix("0x"))
        .filter(|value| !value.is_empty())
        .ok_or_else(|| RpcError::InvalidLog(format!("missing {field}")))?;
    u64::from_str_radix(text, 16).map_err(|_| RpcError::InvalidLog(format!("invalid {field}")))
}

fn exact_hex(field: &str, value: &Value, bytes: usize) -> Result<String, RpcError> {
    let text = value
        .as_str()
        .ok_or_else(|| RpcError::InvalidLog(format!("missing {field}")))?;
    let raw = text
        .strip_prefix("0x")
        .filter(|raw| raw.len() == bytes.saturating_mul(2))
        .ok_or_else(|| RpcError::InvalidLog(format!("invalid {field}")))?;
    hex::decode(raw).map_err(|_| RpcError::InvalidLog(format!("invalid {field}")))?;
    Ok(text.to_ascii_lowercase())
}

fn canonical_topic_filter(value: &Value, index: usize) -> Result<Value, RpcError> {
    match value {
        Value::Null => Ok(Value::Null),
        Value::String(_) => Ok(Value::String(exact_hex(
            &format!("filter topics[{index}]"),
            value,
            32,
        )?)),
        Value::Array(options) if !options.is_empty() && options.len() <= MAX_TOPIC_OPTIONS => {
            options
                .iter()
                .enumerate()
                .map(|(option, value)| {
                    exact_hex(&format!("filter topics[{index}][{option}]"), value, 32)
                        .map(Value::String)
                })
                .collect::<Result<Vec<_>, _>>()
                .map(Value::Array)
        }
        _ => Err(RpcError::InvalidLog(format!(
            "invalid filter topics[{index}]"
        ))),
    }
}

fn canonical_filter(filter: &LogFilter) -> Result<LogFilter, RpcError> {
    if filter.topics.len() > 4 {
        return Err(RpcError::InvalidLog(
            "filter has more than four topics".to_owned(),
        ));
    }
    Ok(LogFilter {
        address: exact_hex("filter address", &Value::String(filter.address.clone()), 20)?,
        topics: filter
            .topics
            .iter()
            .enumerate()
            .map(|(index, topic)| canonical_topic_filter(topic, index))
            .collect::<Result<_, _>>()?,
    })
}

fn topic_matches(filter: &Value, topic: &str) -> bool {
    match filter {
        Value::Null => true,
        Value::String(expected) => expected == topic,
        Value::Array(options) => options
            .iter()
            .any(|expected| expected.as_str() == Some(topic)),
        _ => false,
    }
}

fn log_matches_filter(log: &RpcLog, filter: &LogFilter) -> bool {
    filter.topics.iter().enumerate().all(|(index, expected)| {
        log.topics
            .get(index)
            .is_some_and(|actual| topic_matches(expected, actual))
    })
}

fn parse_log(value: Value) -> Result<RpcLog, RpcError> {
    match value.get("removed").and_then(Value::as_bool) {
        Some(false) => {}
        Some(true) => {
            return Err(RpcError::InvalidLog(
                "removed log returned for pinned range".to_owned(),
            ));
        }
        None => return Err(RpcError::InvalidLog("missing removed flag".to_owned())),
    }
    let address = exact_hex("address", &value["address"], 20)?;
    let topic_values = value["topics"]
        .as_array()
        .ok_or_else(|| RpcError::InvalidLog("missing topics".to_owned()))?;
    if topic_values.len() > 4 {
        return Err(RpcError::InvalidLog(
            "log has more than four topics".to_owned(),
        ));
    }
    let topics = topic_values
        .iter()
        .enumerate()
        .map(|(index, topic)| exact_hex(&format!("topics[{index}]"), topic, 32))
        .collect::<Result<Vec<_>, _>>()?;
    let data = value["data"]
        .as_str()
        .filter(|value| {
            value
                .strip_prefix("0x")
                .is_some_and(|raw| raw.len().is_multiple_of(2) && hex::decode(raw).is_ok())
        })
        .ok_or_else(|| RpcError::InvalidLog("invalid data".to_owned()))?
        .to_ascii_lowercase();
    Ok(RpcLog {
        address,
        topics,
        data,
        block_number: hex_quantity("blockNumber", &value["blockNumber"])?,
        transaction_hash: exact_hex("transactionHash", &value["transactionHash"], 32)?,
        log_index: hex_quantity("logIndex", &value["logIndex"])?,
    })
}

async fn fetch_logs<R: Rpc + ?Sized>(
    rpc: &R,
    filter: &LogFilter,
    from: u64,
    to: u64,
) -> Result<Vec<RpcLog>, RpcError> {
    let mut request = json!({
        "address": filter.address,
        "fromBlock": format!("0x{from:x}"),
        "toBlock": format!("0x{to:x}")
    });
    if !filter.topics.is_empty() {
        request["topics"] = Value::Array(filter.topics.clone());
    }
    let result = rpc.request("eth_getLogs", json!([request])).await?;
    let values = match result {
        Value::Array(values) => values,
        _ => {
            return Err(RpcError::InvalidResponse {
                method: "eth_getLogs".to_owned(),
                message: "result is not an array".to_owned(),
            });
        }
    };
    let mut logs = Vec::with_capacity(values.len());
    for value in values {
        let log = parse_log(value)?;
        if log.block_number < from || log.block_number > to {
            return Err(RpcError::InvalidLog(format!(
                "log at block {} is outside requested range {from}..={to}",
                log.block_number
            )));
        }
        if log.address != filter.address {
            return Err(RpcError::InvalidLog(
                "log does not match requested address".to_owned(),
            ));
        }
        if !log_matches_filter(&log, filter) {
            return Err(RpcError::InvalidLog(
                "log does not match requested topics".to_owned(),
            ));
        }
        logs.push(log);
    }
    Ok(logs)
}

fn range_limited(error: &RpcError) -> bool {
    if matches!(error, RpcError::ResponseTooLarge { .. }) {
        return true;
    }
    let RpcError::JsonRpc { message, .. } = error else {
        return false;
    };
    let message = message.to_ascii_lowercase();
    [
        "block range",
        "range too large",
        "range is too large",
        "range too wide",
        "range is too wide",
        "too many results",
        "result size",
        "results size",
        "result set size",
        "result limit",
        "results limit",
        "response size",
        "response too large",
    ]
    .iter()
    .any(|needle| message.contains(needle))
}

pub async fn get_logs_chunked<R: Rpc + ?Sized>(
    rpc: &R,
    filter: &LogFilter,
    from_block: u64,
    to_block: u64,
    max_range: u64,
    result_cap: usize,
) -> Result<(Vec<RpcLog>, LogMetrics), RpcError> {
    if max_range == 0
        || max_range > MAX_LOG_RANGE
        || result_cap == 0
        || result_cap > MAX_LOG_RESULT_CAP as usize
    {
        return Err(RpcError::InvalidLogPolicy);
    }
    let filter = canonical_filter(filter)?;
    if from_block > to_block {
        return Ok((Vec::new(), LogMetrics::default()));
    }
    let started = Instant::now();
    let mut metrics = LogMetrics::default();
    let mut output = Vec::new();
    let mut chunk_start = from_block;

    while chunk_start <= to_block {
        let chunk_end = chunk_start.saturating_add(max_range - 1).min(to_block);
        let chunk_started = Instant::now();
        let transport_attempts_started = rpc.metrics().transport_attempts;
        let mut chunk_requests = 0u64;
        let mut chunk_bisections = 0u64;
        let mut pending = vec![(chunk_start, chunk_end)];
        while let Some((from, to)) = pending.pop() {
            if chunk_requests >= MAX_LOG_REQUESTS_PER_CHUNK {
                return Err(RpcError::LogBudgetExceeded("logical-request"));
            }
            let remaining = MAX_LOG_CHUNK_DURATION
                .checked_sub(chunk_started.elapsed())
                .ok_or(RpcError::LogBudgetExceeded("deadline"))?;
            if rpc
                .metrics()
                .transport_attempts
                .saturating_sub(transport_attempts_started)
                >= MAX_LOG_TRANSPORT_ATTEMPTS_PER_CHUNK
            {
                return Err(RpcError::LogBudgetExceeded("transport-attempt"));
            }
            chunk_requests += 1;
            metrics.requests += 1;
            let fetched = tokio::time::timeout(remaining, fetch_logs(rpc, &filter, from, to))
                .await
                .map_err(|_| RpcError::LogBudgetExceeded("deadline"))?;
            if rpc
                .metrics()
                .transport_attempts
                .saturating_sub(transport_attempts_started)
                > MAX_LOG_TRANSPORT_ATTEMPTS_PER_CHUNK
            {
                return Err(RpcError::LogBudgetExceeded("transport-attempt"));
            }
            let logs = match fetched {
                Ok(logs) => logs,
                Err(error) => {
                    metrics.errors += 1;
                    if range_limited(&error) && from < to {
                        if chunk_bisections >= MAX_LOG_BISECTIONS_PER_CHUNK {
                            return Err(RpcError::LogBudgetExceeded("bisection"));
                        }
                        chunk_bisections += 1;
                        metrics.bisections += 1;
                        let middle = from + (to - from) / 2;
                        pending.push((middle + 1, to));
                        pending.push((from, middle));
                        continue;
                    }
                    return Err(error);
                }
            };
            if logs.len() >= result_cap {
                if from == to {
                    return Err(RpcError::LogCompleteness {
                        count: logs.len(),
                        cap: result_cap,
                        block: from,
                    });
                }
                if chunk_bisections >= MAX_LOG_BISECTIONS_PER_CHUNK {
                    return Err(RpcError::LogBudgetExceeded("bisection"));
                }
                chunk_bisections += 1;
                metrics.bisections += 1;
                let middle = from + (to - from) / 2;
                pending.push((middle + 1, to));
                pending.push((from, middle));
            } else {
                output.extend(logs);
            }
        }
        if chunk_end == u64::MAX {
            break;
        }
        chunk_start = chunk_end + 1;
    }

    output.sort_by_key(|log| (log.block_number, log.log_index));
    let mut seen = HashSet::with_capacity(output.len());
    for log in &output {
        if !seen.insert((log.block_number, log.log_index)) {
            return Err(RpcError::InvalidLog(format!(
                "duplicate log position {}:{}",
                log.block_number, log.log_index
            )));
        }
    }
    metrics.elapsed_ms = started.elapsed().as_millis().try_into().unwrap_or(u64::MAX);
    Ok((output, metrics))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drpc_header_is_sensitive_and_never_part_of_url() {
        let endpoint =
            validate_rpc_endpoint("https://lb.drpc.org/ogrpc?network=ethereum", true).unwrap();
        assert!(!endpoint.as_str().contains("secret"));
        let mut value = HeaderValue::from_static("secret");
        value.set_sensitive(true);
        assert!(value.is_sensitive());
    }
}
