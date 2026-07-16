use async_trait::async_trait;
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use usd8_settlement::rpc::{
    HttpRpc, LogFilter, Rpc, RpcError, RpcMetrics, get_logs_chunked, validate_rpc_endpoint,
};

async fn mock_http(responses: Vec<String>) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let captured = Arc::clone(&requests);
    tokio::spawn(async move {
        for response in responses {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0u8; 4096];
            loop {
                let count = stream.read(&mut buffer).await.unwrap();
                if count == 0 {
                    break;
                }
                bytes.extend_from_slice(&buffer[..count]);
                if let Some(header_end) = bytes.windows(4).position(|window| window == b"\r\n\r\n")
                {
                    let headers = String::from_utf8_lossy(&bytes[..header_end + 4]);
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(str::to_owned)
                        })
                        .and_then(|value| value.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    if bytes.len() >= header_end + 4 + length {
                        break;
                    }
                }
            }
            captured
                .lock()
                .unwrap()
                .push(String::from_utf8(bytes).unwrap());
            stream.write_all(response.as_bytes()).await.unwrap();
        }
    });
    (format!("http://{address}"), requests)
}

fn response(status: &str, body: &str, extra_headers: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{extra_headers}\r\n{body}",
        body.len()
    )
}

#[test]
fn drpc_key_is_restricted_to_exact_trusted_https_endpoint() {
    assert!(validate_rpc_endpoint("https://lb.drpc.org/ogrpc?network=ethereum", true).is_ok());
    for endpoint in [
        "https://arbitrary.example",
        "http://lb.drpc.org/ogrpc?network=ethereum",
        "https://lb.drpc.org:8443/ogrpc?network=ethereum",
        "https://user@lb.drpc.org/ogrpc?network=ethereum",
        "https://lb.drpc.org.evil.example/",
    ] {
        assert!(
            validate_rpc_endpoint(endpoint, true)
                .unwrap_err()
                .to_string()
                .contains("refusing to send DRPC_KEY"),
            "accepted {endpoint}"
        );
    }

    assert!(
        HttpRpc::new("http://127.0.0.1:1", None, 120_001)
            .err()
            .unwrap()
            .to_string()
            .contains("120000")
    );
    assert!(
        HttpRpc::new_with_retry_delay("http://127.0.0.1:1", None, 1_000, 9, 1)
            .err()
            .unwrap()
            .to_string()
            .contains("retry policy")
    );
}

#[tokio::test]
async fn http_transport_retries_without_counting_extra_logical_requests() {
    let ok = r#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#;
    let (url, requests) = mock_http(vec![
        response("500 Internal Server Error", "temporary", ""),
        response("200 OK", ok, ""),
    ])
    .await;
    let rpc = HttpRpc::new_with_retry_delay(&url, None, 1_000, 5, 1).unwrap();

    assert_eq!(rpc.request("eth_chainId", json!([])).await.unwrap(), "0x1");
    assert_eq!(
        rpc.metrics(),
        RpcMetrics {
            logical_requests: 1,
            transport_attempts: 2,
            transport_responses: 2,
            transport_retries: 1,
        }
    );
    let captured = requests.lock().unwrap();
    assert_eq!(captured.len(), 2);
    assert!(
        captured
            .iter()
            .all(|request| request.contains("eth_chainId"))
    );
}

#[tokio::test]
async fn redirects_and_malformed_json_rpc_responses_fail_closed() {
    let (redirect_url, _) = mock_http(vec![response(
        "302 Found",
        "",
        "Location: http://127.0.0.1:9/stolen\r\n",
    )])
    .await;
    let redirect = HttpRpc::new_with_retry_delay(&redirect_url, None, 1_000, 0, 1).unwrap();
    assert!(redirect.request("eth_chainId", json!([])).await.is_err());

    let wrong_id = r#"{"jsonrpc":"2.0","id":99,"result":"0x1"}"#;
    let (bad_url, _) = mock_http(vec![response("200 OK", wrong_id, "")]).await;
    let bad = HttpRpc::new_with_retry_delay(&bad_url, None, 1_000, 0, 1).unwrap();
    assert!(
        bad.request("eth_chainId", json!([]))
            .await
            .unwrap_err()
            .to_string()
            .contains("response id")
    );
}

#[tokio::test]
async fn response_body_is_capped_and_truncated_body_is_retried() {
    let ok = r#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#;
    let (oversized_url, _) = mock_http(vec![response("200 OK", ok, "")]).await;
    let oversized =
        HttpRpc::new_with_retry_delay_and_response_limit(&oversized_url, None, 1_000, 0, 1, 32)
            .unwrap();
    assert!(
        oversized
            .request("eth_chainId", json!([]))
            .await
            .unwrap_err()
            .to_string()
            .contains("response exceeds")
    );

    let chunked = format!(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n{}\r\n0\r\n\r\n",
        ok.len(),
        ok
    );
    let (chunked_url, _) = mock_http(vec![chunked]).await;
    let chunked =
        HttpRpc::new_with_retry_delay_and_response_limit(&chunked_url, None, 1_000, 0, 1, 32)
            .unwrap();
    assert!(
        chunked
            .request("eth_chainId", json!([]))
            .await
            .unwrap_err()
            .to_string()
            .contains("response exceeds")
    );

    let truncated = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        ok.len() + 10,
        &ok[..ok.len() / 2]
    );
    let (retry_url, requests) = mock_http(vec![truncated, response("200 OK", ok, "")]).await;
    let retry =
        HttpRpc::new_with_retry_delay_and_response_limit(&retry_url, None, 1_000, 1, 1, 1_024)
            .unwrap();
    assert_eq!(
        retry.request("eth_chainId", json!([])).await.unwrap(),
        "0x1"
    );
    assert_eq!(requests.lock().unwrap().len(), 2);
    assert_eq!(retry.metrics().transport_retries, 1);
}

#[derive(Clone)]
struct FakeLogs {
    logs: Arc<Vec<Value>>,
    cap: usize,
    calls: Arc<Mutex<Vec<(u64, u64)>>>,
    error: Option<String>,
}

#[async_trait]
impl Rpc for FakeLogs {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        assert_eq!(method, "eth_getLogs");
        let filter = &params[0];
        let from = u64::from_str_radix(
            filter["fromBlock"]
                .as_str()
                .unwrap()
                .trim_start_matches("0x"),
            16,
        )
        .unwrap();
        let to = u64::from_str_radix(
            filter["toBlock"].as_str().unwrap().trim_start_matches("0x"),
            16,
        )
        .unwrap();
        self.calls.lock().unwrap().push((from, to));
        if let Some(message) = &self.error {
            return Err(RpcError::JsonRpc {
                code: -32000,
                message: message.clone(),
            });
        }
        Ok(Value::Array(
            self.logs
                .iter()
                .filter(|log| {
                    let block = u64::from_str_radix(
                        log["blockNumber"]
                            .as_str()
                            .unwrap()
                            .trim_start_matches("0x"),
                        16,
                    )
                    .unwrap();
                    block >= from && block <= to
                })
                .take(self.cap)
                .cloned()
                .collect(),
        ))
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

#[derive(Clone)]
struct StaticLogs {
    logs: Arc<Vec<Value>>,
}

#[async_trait]
impl Rpc for StaticLogs {
    async fn request(&self, method: &str, _params: Value) -> Result<Value, RpcError> {
        assert_eq!(method, "eth_getLogs");
        Ok(Value::Array(self.logs.as_ref().clone()))
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

#[derive(Clone, Default)]
struct Http408Logs {
    calls: Arc<Mutex<u64>>,
}

#[async_trait]
impl Rpc for Http408Logs {
    async fn request(&self, method: &str, _params: Value) -> Result<Value, RpcError> {
        assert_eq!(method, "eth_getLogs");
        *self.calls.lock().unwrap() += 1;
        Err(RpcError::HttpStatus {
            method: method.to_owned(),
            status: 408,
        })
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

async fn rejected_static_logs(logs: Vec<Value>, filter: LogFilter) -> String {
    get_logs_chunked(
        &StaticLogs {
            logs: Arc::new(logs),
        },
        &filter,
        1,
        2,
        1_000,
        1_000,
    )
    .await
    .unwrap_err()
    .to_string()
}

fn log(block: u64, index: u64) -> Value {
    json!({
        "address": "0x0000000000000000000000000000000000000001",
        "topics": [format!("0x{}", "11".repeat(32))],
        "data": "0x",
        "blockNumber": format!("0x{block:x}"),
        "transactionHash": format!("0x{index:064x}"),
        "logIndex": format!("0x{index:x}"),
        "removed": false
    })
}

fn filter() -> LogFilter {
    LogFilter {
        address: "0x0000000000000000000000000000000000000001".to_owned(),
        topics: vec![],
    }
}

#[tokio::test]
async fn chunked_logs_recover_silent_caps_and_preserve_order() {
    let source = vec![
        log(1, 0),
        log(2, 1),
        log(3, 2),
        log(4, 3),
        log(5, 4),
        log(6, 5),
    ];
    let rpc = FakeLogs {
        logs: Arc::new(source),
        cap: 3,
        calls: Arc::new(Mutex::new(Vec::new())),
        error: None,
    };
    let (logs, metrics) = get_logs_chunked(&rpc, &filter(), 1, 6, 1000, 3)
        .await
        .unwrap();
    assert_eq!(logs.len(), 6);
    assert_eq!(
        logs.iter()
            .map(|entry| entry.block_number)
            .collect::<Vec<_>>(),
        vec![1, 2, 3, 4, 5, 6]
    );
    assert!(metrics.bisections > 0);
    assert!(rpc.calls.lock().unwrap().len() > 1);
}

#[tokio::test]
async fn single_block_cap_and_unrelated_errors_fail_without_retry_tree() {
    let rpc = FakeLogs {
        logs: Arc::new(vec![log(5, 0), log(5, 1), log(5, 2), log(5, 3)]),
        cap: 3,
        calls: Arc::new(Mutex::new(Vec::new())),
        error: None,
    };
    assert!(
        get_logs_chunked(&rpc, &filter(), 5, 5, 1000, 3)
            .await
            .unwrap_err()
            .to_string()
            .contains("cannot prove completeness")
    );

    let failing = FakeLogs {
        logs: Arc::new(vec![]),
        cap: 3,
        calls: Arc::new(Mutex::new(Vec::new())),
        error: Some("rate limit exceeded".to_owned()),
    };
    assert!(
        get_logs_chunked(&failing, &filter(), 1, 20, 1000, 3)
            .await
            .is_err()
    );
    assert_eq!(failing.calls.lock().unwrap().len(), 1);

    let timeout = FakeLogs {
        logs: Arc::new(vec![]),
        cap: 3,
        calls: Arc::new(Mutex::new(Vec::new())),
        error: Some("request timed out".to_owned()),
    };
    assert!(
        get_logs_chunked(&timeout, &filter(), 1, 20, 1_000, 3)
            .await
            .is_err()
    );
    assert_eq!(timeout.calls.lock().unwrap().len(), 1);

    let http_408 = Http408Logs::default();
    assert!(
        get_logs_chunked(&http_408, &filter(), 1, 20, 1_000, 3)
            .await
            .is_err()
    );
    assert_eq!(*http_408.calls.lock().unwrap(), 1);
}

#[tokio::test]
async fn returned_logs_are_bound_to_requested_range_filter_and_position() {
    let outside = rejected_static_logs(vec![log(3, 0)], filter()).await;
    assert!(outside.contains("outside requested range"));

    let mut wrong_address = log(1, 0);
    wrong_address["address"] = json!("0x0000000000000000000000000000000000000002");
    let address = rejected_static_logs(vec![wrong_address], filter()).await;
    assert!(address.contains("does not match requested address"));

    let mut wrong_topic = log(1, 0);
    wrong_topic["topics"][0] = json!(format!("0x{}", "22".repeat(32)));
    let topic_filter = LogFilter {
        address: "0x0000000000000000000000000000000000000001".to_owned(),
        topics: vec![json!(format!("0x{}", "11".repeat(32)))],
    };
    let topic = rejected_static_logs(vec![wrong_topic], topic_filter).await;
    assert!(topic.contains("does not match requested topics"));

    let mut missing_removed = log(1, 0);
    missing_removed.as_object_mut().unwrap().remove("removed");
    let removed = rejected_static_logs(vec![missing_removed], filter()).await;
    assert!(removed.contains("missing removed"));

    let mut too_many_topics = log(1, 0);
    too_many_topics["topics"] = Value::Array(
        (0..5)
            .map(|index| json!(format!("0x{index:064x}")))
            .collect(),
    );
    let topics = rejected_static_logs(vec![too_many_topics], filter()).await;
    assert!(topics.contains("more than four topics"));

    let first = log(1, 0);
    let mut conflicting = log(1, 1);
    conflicting["logIndex"] = json!("0x0");
    let duplicate = rejected_static_logs(vec![first, conflicting], filter()).await;
    assert!(duplicate.contains("duplicate log position"));
}
