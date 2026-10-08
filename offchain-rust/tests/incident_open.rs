use alloy_primitives::{Address as AlloyAddress, Bytes, U256};
use alloy_sol_types::SolCall;
use async_trait::async_trait;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Mutex;
use usd8_settlement::Address;
use usd8_settlement::abi::{IDefiInsurance, IMulticall3, IRegistry};
use usd8_settlement::config::CHAIN_ID;
use usd8_settlement::incident_open::{build_incident_open, precheck_incident_open};
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};

#[path = "support/cli_http.rs"]
mod cli_http;

#[tokio::test]
async fn detect_price_drop_cli_returns_only_precheck_over_http() {
    let expected = open_value(&fixture(false), false).await;
    let (url, server) = cli_http::serve(fixture(false)).await;
    let output = cli_http::run("detect_price_drop", TOKEN, REGISTRY, url, vec![]).await;
    server.abort();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value, expected);
    assert_eq!(value["insuredToken"], TOKEN);
    assert_eq!(value["referenceBlock"], REFERENCE_BLOCK);
    assert_eq!(value["baselineTwap"], "1000000000000000000");
    assert_eq!(value["distressTwap"], "790000000000000000");
    for key in value.as_object().unwrap().keys() {
        let key = key.to_lowercase();
        assert!(
            !["digest", "signature", "attestation", "authorization", "pcr"]
                .iter()
                .any(|part| key.contains(part))
        );
    }
    println!(
        "local HTTP CLI result: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    let path = std::env::temp_dir().join(format!(
        "usd8-detect_price_drop-success-{}.json",
        std::process::id()
    ));
    let (url, server) = cli_http::serve(fixture(false)).await;
    let saved = cli_http::run(
        "detect_price_drop",
        TOKEN,
        REGISTRY,
        url,
        vec!["--output".into(), path.display().to_string()],
    )
    .await;
    server.abort();
    assert!(
        saved.status.success(),
        "{}",
        String::from_utf8_lossy(&saved.stderr)
    );
    assert!(saved.stdout.is_empty());
    let readback: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(readback, value);
    std::fs::remove_file(path).unwrap();
}

#[tokio::test]
async fn detect_price_drop_cli_failures_do_not_emit_or_replace_output() {
    for (case, message) in [
        ("no-drop", "below the required"),
        ("active", "active incident"),
        ("invalid", "configuration is invalid"),
        ("reorg", "changed during"),
    ] {
        let mut rpc = fixture(case == "active");
        match case {
            "no-drop" => rpc.distress_ratio = 1_000_000_000_000_000_000,
            "invalid" => set_price_config(&mut rpc, 10, 0, 2000),
            "reorg" => rpc.change_finalized_hash = true,
            _ => {}
        }
        let path =
            std::env::temp_dir().join(format!("usd8-detect-{}-{case}.json", std::process::id()));
        std::fs::write(&path, "untouched").unwrap();
        let (url, server) = cli_http::serve(rpc).await;
        let output = cli_http::run(
            "detect_price_drop",
            TOKEN,
            REGISTRY,
            url,
            vec!["--output".into(), path.display().to_string()],
        )
        .await;
        server.abort();
        assert_eq!(
            output.status.code(),
            Some(1),
            "{case}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(output.stdout.is_empty());
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(message),
            "{case}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "untouched");
        std::fs::remove_file(path).unwrap();
    }
}

const REGISTRY: &str = "0x3Fa82eC1842f72c36580D84E03377b10B5E2F590";
const DEFI: &str = "0x250cebdd9d6997ffd45c60d6e713f42e44e383ec";
const TOKEN: &str = "0x5300000000000000000000000000000000000004";
const SIGNER: &str = "0xEa29C49787Df66003Af40e3409A1E1766Bfda193";
const CONVERSION: &str = "0x1111111111111111111111111111111111112222";
const REFERENCE_BLOCK: u64 = 1_234_560;
const MULTICALL3: &str = "0xca11bde05977b3631167028862be2a173976ca11";

// Real HTTP envelope boundary; the fixture only supplies deterministic chain state.
async fn serve_open(
    fixture: OpenRpc,
) -> (
    usd8_settlement::rpc::HttpRpc,
    std::sync::Arc<Mutex<Vec<Value>>>,
    tokio::task::JoinHandle<()>,
) {
    serve_open_fault(fixture, None).await
}

async fn serve_open_fault(
    fixture: OpenRpc,
    fault: Option<&'static str>,
) -> (
    usd8_settlement::rpc::HttpRpc,
    std::sync::Arc<Mutex<Vec<Value>>>,
    tokio::task::JoinHandle<()>,
) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let captured = std::sync::Arc::new(Mutex::new(Vec::new()));
    let requests = captured.clone();
    let task = tokio::spawn(async move {
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let body = loop {
                let mut buf = [0; 4096];
                let n = stream.read(&mut buf).await.unwrap();
                assert_ne!(n, 0);
                bytes.extend_from_slice(&buf[..n]);
                if let Some(end) = bytes.windows(4).position(|b| b == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&bytes[..end]);
                    assert!(headers.starts_with("POST / HTTP/1.1"));
                    let len: usize = headers
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(str::to_owned)
                        })
                        .unwrap()
                        .parse()
                        .unwrap();
                    if bytes.len() >= end + 4 + len {
                        break serde_json::from_slice::<Value>(&bytes[end + 4..end + 4 + len])
                            .unwrap();
                    }
                }
            };
            requests.lock().unwrap().push(body.clone());
            let batch = body.is_array();
            let members = if batch {
                body.as_array().unwrap().clone()
            } else {
                vec![body]
            };
            let mut responses = Vec::new();
            for member in members {
                let result = fixture
                    .request(member["method"].as_str().unwrap(), member["params"].clone())
                    .await
                    .unwrap();
                responses.push(json!({"jsonrpc":"2.0", "id":member["id"], "result":result}));
            }
            responses.reverse(); // Providers need not preserve input order.
            let mut body = if batch {
                json!(responses)
            } else {
                responses.remove(0)
            };
            if batch {
                match fault {
                    Some("partial") => {
                        body.as_array_mut().unwrap().pop();
                    }
                    Some("duplicate") => body[1] = body[0].clone(),
                    Some("extra") => {
                        body.as_array_mut()
                            .unwrap()
                            .push(json!({"jsonrpc":"2.0","id":999,"result":"0x1"}));
                    }
                    Some("unknown") => body[0]["id"] = json!(999),
                    Some("string-id") => body[0]["id"] = json!("6"),
                    Some("no-id") => {
                        body[0].as_object_mut().unwrap().remove("id");
                    }
                    Some("version") => body[0]["jsonrpc"] = json!("1.0"),
                    Some("error") => {
                        body[0].as_object_mut().unwrap().remove("result");
                        body[0]["error"] =
                            json!({"code":-32000,"message":"provider credential secret"});
                    }
                    Some("both") => body[0]["error"] = json!({"code":-32000,"message":"bad"}),
                    Some("malformed-error") => {
                        body[0].as_object_mut().unwrap().remove("result");
                        body[0]["error"] = json!({"code":-32000});
                    }
                    Some("missing-result") => {
                        body[0].as_object_mut().unwrap().remove("result");
                    }
                    Some("zero") => body[0]["result"] = json!(format!("0x{}", "00".repeat(32))),
                    Some("short") => body[0]["result"] = json!("0x01"),
                    Some("long") => body[0]["result"] = json!(format!("0x{}", "01".repeat(33))),
                    Some("null") => body[0]["result"] = Value::Null,
                    Some("nonhex") => body[0]["result"] = json!("not hex"),
                    Some("unsupported") => {
                        body = json!({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"batch unsupported"}})
                    }
                    None => {}
                    _ => panic!("unknown batch fault"),
                }
            }
            let body = body.to_string();
            let wire = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(wire.as_bytes()).await.unwrap();
        }
    });
    (
        usd8_settlement::rpc::HttpRpc::new_with_retry_delay(&url, None, 2_000, 0, 0).unwrap(),
        captured,
        task,
    )
}

async fn open_value<R: Rpc>(rpc: &R, authoritative: bool) -> Value {
    let registry = Address::from_str(REGISTRY).unwrap();
    let token = Address::from_str(TOKEN).unwrap();
    if authoritative {
        serde_json::to_value(
            build_incident_open(rpc, registry, token, Address::from_str(SIGNER).unwrap())
                .await
                .unwrap(),
        )
        .unwrap()
    } else {
        serde_json::to_value(precheck_incident_open(rpc, registry, token).await.unwrap()).unwrap()
    }
}

#[tokio::test]
async fn historical_batch_faults_stop_before_authorization_without_fallback() {
    for authoritative in [false, true] {
        for fault in [
            "partial",
            "duplicate",
            "extra",
            "unknown",
            "string-id",
            "no-id",
            "version",
            "error",
            "both",
            "malformed-error",
            "missing-result",
            "zero",
            "short",
            "long",
            "null",
            "nonhex",
            "unsupported",
        ] {
            let (rpc, captured, task) = serve_open_fault(fixture(false), Some(fault)).await;
            let error = run_open(&rpc, authoritative).await.expect_err(fault);
            assert!(!error.to_string().contains("credential secret"));
            let bodies = captured.lock().unwrap();
            assert_eq!(
                bodies.len(),
                6,
                "{fault}: no anchor checks or serial fallback after failed discovery"
            );
            assert!(bodies.last().unwrap().is_array());
            assert_eq!(rpc.metrics().transport_attempts, 6);
            task.abort();
        }
    }
}

#[tokio::test]
async fn canonical_169_point_discovery_is_one_http_post() {
    let mut fixture = fixture_with_finalized(false, 1_234_500);
    fixture.latest_number = 1_234_500;
    fixture.conversion_reference = 1_215_000;
    set_price_config(&mut fixture, 7200, 300, 2000);
    set_max_reference_block_age(&mut fixture, 43200);
    let (rpc, captured, task) = serve_open(fixture).await;
    let actual = open_value(&rpc, true).await;
    assert_eq!(actual["referenceBlock"], 1_214_700);
    assert_eq!(actual["baselineTwap"], "1000000000000000000");
    assert_eq!(actual["distressTwap"], "798750000000000000");
    let bodies = captured.lock().unwrap();
    let batches: Vec<_> = bodies.iter().filter_map(Value::as_array).collect();
    assert_eq!(batches.len(), 1);
    assert_eq!(batches[0].len(), 169);
    for (i, member) in batches[0].iter().enumerate() {
        assert_eq!(member["method"], "eth_call");
        assert_eq!(
            member["params"],
            json!([{"to":CONVERSION,"data":"0x12345678"},format!("0x{:x}",1_184_100 + i * 300)])
        );
    }
    assert_eq!(rpc.metrics().transport_attempts, 8);
    assert_eq!(rpc.metrics().logical_requests, 176);
    task.abort();
}

#[tokio::test]
async fn historical_discovery_uses_one_http_post_and_preserves_authorization() {
    for authoritative in [false, true] {
        let make = || {
            let mut rpc = fixture(false);
            rpc.sample_ratios = Some([
                1_010_000_000_000_000_001,
                990_000_000_000_000_003,
                780_000_000_000_000_005,
                790_000_000_000_000_007,
            ]);
            rpc
        };
        let expected = open_value(&make(), authoritative).await;
        let (rpc, captured, task) = serve_open(make()).await;
        let actual = open_value(&rpc, authoritative).await;
        assert_eq!(actual, expected);
        let bodies = captured.lock().unwrap().clone();
        let conversion_posts: Vec<_> = bodies
            .iter()
            .filter(|v| v.is_array() || v["params"][0]["to"] == CONVERSION)
            .collect();
        assert_eq!(
            conversion_posts.len(),
            1,
            "all historical conversions must share ONE HTTP POST"
        );
        let members = conversion_posts[0]
            .as_array()
            .expect("JSON-RPC array envelope");
        let expected_fixture = make();
        run_open(&expected_fixture, authoritative).await.unwrap();
        let calls = expected_fixture.calls.lock().unwrap();
        let expected_calls: Vec<_> = calls.iter().filter(|p| p[0]["to"] == CONVERSION).collect();
        assert_eq!(
            members.iter().map(|m| &m["params"]).collect::<Vec<_>>(),
            expected_calls
        );
        assert_eq!(rpc.metrics().transport_attempts, bodies.len() as u64);
        assert_eq!(
            rpc.metrics().logical_requests,
            (bodies.len() - 1 + members.len()) as u64
        );
        task.abort();
    }
}

fn a(value: &str) -> AlloyAddress {
    AlloyAddress::from_str(value).unwrap()
}

fn encoded<C: SolCall>(value: &C::Return) -> Value {
    json!(format!("0x{}", hex::encode(C::abi_encode_returns(value))))
}

#[derive(Clone, Copy, Debug)]
enum AggregateFault {
    Trailing,
    Empty,
    Malformed,
    RpcRevert,
    MissingResult,
    ExtraResult,
    Reverted(usize),
    EmptyResult(usize),
    MalformedResult(usize),
    TrailingResult(usize),
}

#[tokio::test]
async fn aggregate_response_requires_exact_abi_encoding() {
    for authoritative in [false, true] {
        let mut rpc = fixture(false);
        rpc.aggregate_fault = Some((1, AggregateFault::Trailing));
        let error = run_open(&rpc, authoritative).await.unwrap_err();
        assert!(error.to_string().contains("ABI response"));
        assert_eq!(
            rpc.calls.lock().unwrap().len(),
            2,
            "must stop without fallback or price discovery"
        );
    }
}

#[tokio::test]
async fn aggregate_failures_never_fallback_or_produce_authorization() {
    for authoritative in [false, true] {
        for round in [1, 2] {
            let width = if round == 2 {
                2
            } else if authoritative {
                8
            } else {
                5
            };
            let mut faults = vec![
                AggregateFault::Empty,
                AggregateFault::Malformed,
                AggregateFault::RpcRevert,
                AggregateFault::MissingResult,
                AggregateFault::ExtraResult,
            ];
            for i in 0..width {
                faults.extend([
                    AggregateFault::Reverted(i),
                    AggregateFault::EmptyResult(i),
                    AggregateFault::MalformedResult(i),
                    AggregateFault::TrailingResult(i),
                ]);
            }
            for fault in faults {
                let mut rpc = fixture(round == 2);
                rpc.aggregate_fault = Some((round, fault));
                let error = run_open(&rpc, authoritative).await.unwrap_err();
                assert!(
                    matches!(
                        error,
                        usd8_settlement::incident_open::IncidentOpenError::Chain(_)
                    ),
                    "{fault:?}: {error}"
                );
                let calls = rpc.calls.lock().unwrap();
                assert_eq!(
                    calls.len(),
                    round + 1,
                    "{authoritative}/{round}/{fault:?}: no serial fallback or conversion calls"
                );
                assert!(
                    calls[1..]
                        .iter()
                        .all(|p| p[0]["to"].as_str().unwrap().to_ascii_lowercase() == MULTICALL3)
                );
            }
        }
    }
}

fn override_call<C: SolCall>(rpc: &mut OpenRpc, target: &str, value: &C::Return) {
    rpc.responses.insert(
        (
            target.to_ascii_lowercase(),
            format!("0x{}", hex::encode(C::SELECTOR)),
        ),
        encoded::<C>(value),
    );
}

#[tokio::test]
async fn batched_reads_preserve_protocol_rejections() {
    for authoritative in [false, true] {
        for (case, expected) in [
            (0, "reverse Registry binding mismatch"),
            (1, "nextIncidentId is zero"),
            (2, "configuration is invalid"),
            (3, "insured token is not approved"),
            (4, "active incident"),
        ] {
            let mut rpc = fixture(case == 4);
            match case {
                0 => override_call::<IDefiInsurance::registryCall>(&mut rpc, DEFI, &a(TOKEN)),
                1 => override_call::<IDefiInsurance::nextIncidentIdCall>(&mut rpc, DEFI, &0),
                2 => set_price_config(&mut rpc, 10, 0, 2_000),
                3 => override_call::<IDefiInsurance::getInsuredTokenCall>(
                    &mut rpc,
                    DEFI,
                    &IDefiInsurance::InsuredToken {
                        maxCoverageBps: 0,
                        underlyingPriceOracle: a(TOKEN),
                        underlyingConversionAddress: a(CONVERSION),
                        underlyingConversionCallData: Bytes::from_static(&[0x12, 0x34, 0x56, 0x78]),
                    },
                ),
                _ => {}
            }
            let error = run_open(&rpc, authoritative).await.unwrap_err();
            assert!(error.to_string().contains(expected), "{case}: {error}");
            assert!(
                rpc.calls.lock().unwrap().iter().all(|p| p[0]["to"]
                    .as_str()
                    .unwrap()
                    .to_ascii_lowercase()
                    != CONVERSION)
            );
        }
    }
    for zero_pcr in [false, true] {
        let mut rpc = fixture(false);
        if zero_pcr {
            override_call::<IRegistry::teePcrHashCall>(&mut rpc, REGISTRY, &[0; 32].into());
        } else {
            override_call::<IDefiInsurance::isTeeSignerCall>(&mut rpc, DEFI, &false);
        }
        // Admission is not authorization: these fields are only checked by the
        // measured authoritative path, which must independently reread them.
        run_open(&rpc, false).await.unwrap();
        rpc.calls.lock().unwrap().clear();
        let error = run_open(&rpc, true).await.unwrap_err();
        assert!(error.to_string().contains(if zero_pcr {
            "PCR commitment is zero"
        } else {
            "signer is not authorized"
        }));
        assert_eq!(rpc.calls.lock().unwrap().len(), 2);
    }
}

#[tokio::test]
async fn precheck_still_rechecks_both_block_anchors() {
    for finalized in [false, true] {
        let mut rpc = fixture(false);
        rpc.change_finalized_hash = finalized;
        rpc.change_latest_hash = !finalized;
        let error = run_open(&rpc, false).await.unwrap_err();
        assert!(error.to_string().contains(if finalized {
            "finalized block changed"
        } else {
            "latest block changed"
        }));
    }
}

#[tokio::test]
async fn subcall_scalar_widths_and_dynamic_offsets_fail_closed() {
    for authoritative in [false, true] {
        for (target, selector, bytes) in [
            (
                DEFI,
                IDefiInsurance::nextIncidentIdCall::SELECTOR,
                vec![0xff; 32],
            ),
            (DEFI, IDefiInsurance::registryCall::SELECTOR, vec![0xff; 32]),
            (
                DEFI,
                IDefiInsurance::getInsuredTokenCall::SELECTOR,
                vec![0xff; 192],
            ),
            (
                REGISTRY,
                IRegistry::incidentTimingConfigCall::SELECTOR,
                vec![0xff; 64],
            ),
        ] {
            let mut rpc = fixture(false);
            rpc.responses.insert(
                (
                    target.to_ascii_lowercase(),
                    format!("0x{}", hex::encode(selector)),
                ),
                json!(format!("0x{}", hex::encode(bytes))),
            );
            let error = run_open(&rpc, authoritative).await.unwrap_err();
            assert!(error.to_string().contains("ABI response"));
            assert_eq!(rpc.calls.lock().unwrap().len(), 2);
        }
    }
    let mut rpc = fixture(false);
    rpc.responses.insert(
        (
            DEFI.to_owned(),
            format!(
                "0x{}",
                hex::encode(IDefiInsurance::isTeeSignerCall::SELECTOR)
            ),
        ),
        json!(format!("0x{:064x}", 2)),
    );
    assert!(
        run_open(&rpc, true)
            .await
            .unwrap_err()
            .to_string()
            .contains("ABI response")
    );
    assert_eq!(rpc.calls.lock().unwrap().len(), 2);
}

struct OpenRpc {
    aggregate_fault: Option<(usize, AggregateFault)>,
    calls: Mutex<Vec<Value>>,
    responses: HashMap<(String, String), Value>,
    active: bool,
    previous_phase_deadline: u64,
    latest_timestamp: u64,
    latest_number: u64,
    conversion_reference: u64,
    finalized_number: u64,
    change_finalized_hash: bool,
    change_latest_hash: bool,
    finalized_unavailable: bool,
    distress_ratio: u64,
    sample_ratios: Option<[u64; 4]>,
    multiple_drop_episodes: bool,
}

impl OpenRpc {
    fn canned_call(&self, to: &str, data: &str) -> Result<Value, RpcError> {
        let selector = data[..10].to_owned();
        if self.active
            && to == DEFI
            && selector == format!("0x{}", hex::encode(IDefiInsurance::incidentsCall::SELECTOR))
        {
            return Ok(encoded::<IDefiInsurance::incidentsCall>(
                &IDefiInsurance::incidentsReturn {
                    insuredToken: a(TOKEN),
                    resolvedAt: 0,
                    referenceBlock: 1_200_000,
                    openBlock: 1_200_001,
                    phaseDeadline: self.previous_phase_deadline,
                    root: [0u8; 32].into(),
                    unresolvedClaims: U256::from(1),
                    claimSetHash: [0u8; 32].into(),
                    teePcrHash: [0x44; 32].into(),
                    protocolFeeShareBps: 2_000,
                },
            ));
        }
        self.responses
            .get(&(to.to_owned(), selector))
            .cloned()
            .ok_or_else(|| RpcError::JsonRpc {
                code: -32000,
                message: "missing canned call".to_owned(),
            })
    }
}

#[async_trait]
impl Rpc for OpenRpc {
    async fn batch_request(
        &self,
        method: &str,
        params: Vec<Value>,
    ) -> Result<Vec<Value>, RpcError> {
        // Explicit fixture emulation; production transports must implement a real batch.
        let mut results = Vec::new();
        for param in params {
            results.push(self.request(method, param).await?);
        }
        Ok(results)
    }

    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match method {
            "eth_chainId" => Ok(json!(format!("0x{CHAIN_ID:x}"))),
            "eth_getBlockByNumber" => {
                let tag = params[0].as_str().unwrap();
                if tag == "finalized" && self.finalized_unavailable {
                    return Ok(Value::Null);
                }
                let finalized = tag == "finalized"
                    || tag == format!("0x{:x}", self.finalized_number)
                    || (tag == "latest" && self.finalized_number == self.latest_number);
                Ok(json!({
                    "number": if finalized {
                        format!("0x{:x}", self.finalized_number)
                    } else {
                        format!("0x{:x}", self.latest_number)
                    },
                    "timestamp": if finalized {
                        "0x384".to_owned()
                    } else {
                        format!("0x{:x}", self.latest_timestamp)
                    },
                    "hash": format!("0x{}", if finalized && self.change_finalized_hash && tag != "finalized" {
                        "33"
                    } else if finalized {
                        "22"
                    } else if self.change_latest_hash && tag != "latest" {
                        "44"
                    } else {
                        "11"
                    }.repeat(32))
                }))
            }
            "eth_call" => {
                self.calls.lock().unwrap().push(params.clone());
                let to = params[0]["to"].as_str().unwrap().to_ascii_lowercase();
                if to == CONVERSION.to_ascii_lowercase() {
                    let block = u64::from_str_radix(
                        params[1].as_str().unwrap().trim_start_matches("0x"),
                        16,
                    )
                    .unwrap();
                    let ratio = if let Some(ratios) = self.sample_ratios {
                        let sample_index = match block {
                            block if block == REFERENCE_BLOCK - 10 => Some(0),
                            block if block == REFERENCE_BLOCK - 5 => Some(1),
                            block if block == REFERENCE_BLOCK + 5 => Some(2),
                            block if block == REFERENCE_BLOCK + 10 => Some(3),
                            _ => None,
                        };
                        sample_index.map_or_else(
                            || {
                                if block <= REFERENCE_BLOCK {
                                    1_000_000_000_000_000_000u64
                                } else {
                                    self.distress_ratio
                                }
                            },
                            |index| ratios[index],
                        )
                    } else if self.multiple_drop_episodes
                        && ((1_234_510..=1_234_520).contains(&block) || block > REFERENCE_BLOCK)
                    {
                        self.distress_ratio
                    } else if block <= self.conversion_reference {
                        1_000_000_000_000_000_000u64
                    } else {
                        self.distress_ratio
                    };
                    return Ok(json!(format!("0x{ratio:064x}")));
                }
                assert_eq!(params[1], json!(format!("0x{:x}", self.latest_number)));
                let data = params[0]["data"].as_str().unwrap();
                if to == MULTICALL3 {
                    let round = self
                        .calls
                        .lock()
                        .unwrap()
                        .iter()
                        .filter(|p| p[0]["to"].as_str().unwrap().to_ascii_lowercase() == MULTICALL3)
                        .count();
                    assert_eq!(&data[..10], "0x82ad56cb");
                    let call = IMulticall3::aggregate3Call::abi_decode_validate(
                        &hex::decode(&data[2..]).unwrap(),
                    )
                    .unwrap();
                    let mut results = call
                        .calls
                        .iter()
                        .map(|call| {
                            assert!(!call.allowFailure);
                            assert_ne!(call.target, a(CONVERSION));
                            let response = self.canned_call(
                                &format!("{:#x}", call.target),
                                &format!("0x{}", hex::encode(&call.callData)),
                            )?;
                            Ok(IMulticall3::Result {
                                success: true,
                                returnData: hex::decode(
                                    response.as_str().unwrap().trim_start_matches("0x"),
                                )
                                .unwrap()
                                .into(),
                            })
                        })
                        .collect::<Result<Vec<_>, RpcError>>()?;
                    let fault = self
                        .aggregate_fault
                        .filter(|(n, _)| *n == round)
                        .map(|(_, f)| f);
                    match fault {
                        Some(AggregateFault::Empty) => return Ok(json!("0x")),
                        Some(AggregateFault::Malformed) => return Ok(json!("0x1234")),
                        Some(AggregateFault::RpcRevert) => {
                            return Err(RpcError::JsonRpc {
                                code: -32000,
                                message: "aggregate reverted".to_owned(),
                            });
                        }
                        Some(AggregateFault::MissingResult) => {
                            results.pop();
                        }
                        Some(AggregateFault::ExtraResult) => results.push(IMulticall3::Result {
                            success: true,
                            returnData: Bytes::from(vec![0; 32]),
                        }),
                        Some(AggregateFault::Reverted(i)) => results[i].success = false,
                        Some(AggregateFault::EmptyResult(i)) => {
                            results[i].returnData = Bytes::new()
                        }
                        Some(AggregateFault::MalformedResult(i)) => {
                            results[i].returnData = Bytes::from(vec![0xff; 31])
                        }
                        Some(AggregateFault::TrailingResult(i)) => {
                            let mut bytes = results[i].returnData.to_vec();
                            bytes.push(0);
                            results[i].returnData = bytes.into();
                        }
                        _ => {}
                    }
                    let response = encoded::<IMulticall3::aggregate3Call>(&results);
                    return if matches!(fault, Some(AggregateFault::Trailing)) {
                        Ok(json!(format!("{}00", response.as_str().unwrap())))
                    } else {
                        Ok(response)
                    };
                }
                self.canned_call(&to, data)
            }
            _ => panic!("unexpected RPC method {method}"),
        }
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

fn fixture_with_finalized(active: bool, finalized_number: u64) -> OpenRpc {
    let mut responses = HashMap::new();
    let mut insert = |to: &str, selector: [u8; 4], value: Value| {
        responses.insert(
            (
                to.to_ascii_lowercase(),
                format!("0x{}", hex::encode(selector)),
            ),
            value,
        );
    };
    insert(
        REGISTRY,
        IRegistry::defiInsuranceCall::SELECTOR,
        encoded::<IRegistry::defiInsuranceCall>(&a(DEFI)),
    );
    insert(
        REGISTRY,
        IRegistry::teePcrHashCall::SELECTOR,
        encoded::<IRegistry::teePcrHashCall>(&[0x44; 32].into()),
    );
    insert(
        REGISTRY,
        IRegistry::incidentTimingConfigCall::SELECTOR,
        encoded::<IRegistry::incidentTimingConfigCall>(&IRegistry::IncidentTimingConfig {
            phaseWindow: 259_200,
            maxReferenceBlockAge: 100,
        }),
    );
    insert(
        REGISTRY,
        IRegistry::incidentOpenPriceConfigCall::SELECTOR,
        encoded::<IRegistry::incidentOpenPriceConfigCall>(&IRegistry::IncidentOpenPriceConfig {
            twapBlocks: 10,
            sampleStepBlocks: 5,
            minimumDropBps: 2_000,
        }),
    );
    insert(
        DEFI,
        IDefiInsurance::registryCall::SELECTOR,
        encoded::<IDefiInsurance::registryCall>(&a(REGISTRY)),
    );
    insert(
        DEFI,
        IDefiInsurance::nextIncidentIdCall::SELECTOR,
        encoded::<IDefiInsurance::nextIncidentIdCall>(&(if active { 2 } else { 1 })),
    );
    insert(
        DEFI,
        IDefiInsurance::incidentPhaseWindowCall::SELECTOR,
        encoded::<IDefiInsurance::incidentPhaseWindowCall>(&259_200),
    );
    insert(
        DEFI,
        IDefiInsurance::getInsuredTokenCall::SELECTOR,
        encoded::<IDefiInsurance::getInsuredTokenCall>(&IDefiInsurance::InsuredToken {
            maxCoverageBps: 8_000,
            underlyingPriceOracle: a("0x1111111111111111111111111111111111111111"),
            underlyingConversionAddress: a(CONVERSION),
            underlyingConversionCallData: Bytes::from_static(&[0x12, 0x34, 0x56, 0x78]),
        }),
    );
    insert(
        DEFI,
        IDefiInsurance::isTeeSignerCall::SELECTOR,
        encoded::<IDefiInsurance::isTeeSignerCall>(&true),
    );
    insert(
        DEFI,
        IDefiInsurance::incidentOpenEligibilityHashCall::SELECTOR,
        encoded::<IDefiInsurance::incidentOpenEligibilityHashCall>(&[0x55; 32].into()),
    );

    OpenRpc {
        aggregate_fault: None,
        calls: Mutex::new(Vec::new()),
        responses,
        active,
        previous_phase_deadline: 2_000,
        latest_timestamp: 1_000,
        latest_number: 1_234_600,
        conversion_reference: REFERENCE_BLOCK,
        finalized_number,
        change_finalized_hash: false,
        change_latest_hash: false,
        finalized_unavailable: false,
        distress_ratio: 790_000_000_000_000_000,
        sample_ratios: None,
        multiple_drop_episodes: false,
    }
}

fn fixture(active: bool) -> OpenRpc {
    fixture_with_finalized(active, 1_234_580)
}

fn set_price_config(
    rpc: &mut OpenRpc,
    twap_blocks: u64,
    sample_step_blocks: u64,
    minimum_drop_bps: u16,
) {
    rpc.responses.insert(
        (
            REGISTRY.to_ascii_lowercase(),
            format!(
                "0x{}",
                hex::encode(IRegistry::incidentOpenPriceConfigCall::SELECTOR)
            ),
        ),
        encoded::<IRegistry::incidentOpenPriceConfigCall>(&IRegistry::IncidentOpenPriceConfig {
            twapBlocks: twap_blocks,
            sampleStepBlocks: sample_step_blocks,
            minimumDropBps: minimum_drop_bps,
        }),
    );
}

fn set_max_reference_block_age(rpc: &mut OpenRpc, max_reference_block_age: u64) {
    rpc.responses.insert(
        (
            REGISTRY.to_ascii_lowercase(),
            format!(
                "0x{}",
                hex::encode(IRegistry::incidentTimingConfigCall::SELECTOR)
            ),
        ),
        encoded::<IRegistry::incidentTimingConfigCall>(&IRegistry::IncidentTimingConfig {
            phaseWindow: 259_200,
            maxReferenceBlockAge: max_reference_block_age,
        }),
    );
}

#[tokio::test]
async fn open_authorization_is_derived_from_live_contract_state() {
    let rpc = fixture(false);
    let authorization = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(authorization.incident_id, U256::from(1).to_string());
    assert_eq!(authorization.chain_id, CHAIN_ID);
    assert_eq!(authorization.observation_block, REFERENCE_BLOCK + 10);
    assert_eq!(authorization.baseline_twap, "1000000000000000000");
    assert_eq!(authorization.distress_twap, "790000000000000000");
    assert_eq!(authorization.reference_block, REFERENCE_BLOCK);
    assert_eq!(authorization.twap_blocks, 10);
    assert_eq!(authorization.sample_step_blocks, 5);
    assert_eq!(authorization.minimum_drop_bps, 2_000);
    assert_eq!(
        authorization.eligibility_hash,
        format!("0x{}", "55".repeat(32))
    );
    assert_eq!(
        authorization.open_digest,
        if cfg!(feature = "sepolia") {
            "0x6d915f44c772287c33ef7e8f3e74620e216d4fef0a9c0c4e69937ec9c26dc8f4"
        } else {
            "0x0fe2fcd8777d55fbec1db684244dd8e031d966ea3ab587887e3412e9790d1963"
        }
    );
    assert_eq!(authorization.tee_pcr_hash, format!("0x{}", "44".repeat(32)));
    assert_open_requests(&rpc, true, false);
    let calls = rpc.calls.lock().unwrap();
    let config_calls = calls
        .iter()
        .filter(|p| p[0]["to"].as_str().unwrap().to_ascii_lowercase() != CONVERSION)
        .count();
    assert_eq!(
        config_calls, 2,
        "resolve Registry then aggregate same-block configuration"
    );
}

#[tokio::test]
async fn open_precheck_reuses_the_authoritative_drop_selection_without_a_signer() {
    let rpc = fixture(false);
    let result = precheck_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
    )
    .await
    .unwrap();

    assert_eq!(result.reference_block, REFERENCE_BLOCK);
    assert_eq!(result.sample_count, 2);
    assert_eq!(result.minimum_drop_bps, 2_000);
    assert_open_requests(&rpc, false, false);
    let calls = rpc.calls.lock().unwrap();
    let config_calls = calls
        .iter()
        .filter(|p| p[0]["to"].as_str().unwrap().to_ascii_lowercase() != CONVERSION)
        .count();
    assert_eq!(
        config_calls, 2,
        "precheck also batches its five independent reads"
    );
}

#[tokio::test]
async fn open_authorization_selects_the_first_transition_in_the_latest_drop_episode() {
    let mut rpc = fixture(false);
    rpc.multiple_drop_episodes = true;
    let authorization = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(authorization.reference_block, REFERENCE_BLOCK);
}

#[tokio::test]
async fn open_authorization_applies_identity_ratio_before_threshold_decision() {
    let mut rpc = fixture(false);
    rpc.responses.insert(
        (
            DEFI.to_ascii_lowercase(),
            format!(
                "0x{}",
                hex::encode(IDefiInsurance::getInsuredTokenCall::SELECTOR)
            ),
        ),
        encoded::<IDefiInsurance::getInsuredTokenCall>(&IDefiInsurance::InsuredToken {
            maxCoverageBps: 8_000,
            underlyingPriceOracle: a("0x1111111111111111111111111111111111111111"),
            underlyingConversionAddress: AlloyAddress::ZERO,
            underlyingConversionCallData: Bytes::new(),
        }),
    );
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("price drop is below the required 2000 bps")
    );
}

#[tokio::test]
async fn open_authorization_rejects_an_unbounded_sample_configuration() {
    let mut rpc = fixture(false);
    set_price_config(&mut rpc, 600, 1, 2_000);
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("configuration is invalid"));
}

#[tokio::test]
async fn open_authorization_rejects_a_single_sample_twap_configuration() {
    let mut rpc = fixture(false);
    set_price_config(&mut rpc, 10, 10, 2_000);
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("configuration is invalid"));
}

#[tokio::test]
async fn open_authorization_compares_unrounded_twap_sums() {
    let mut rpc = fixture(false);
    rpc.sample_ratios = Some([1, 2, 1, 1]);
    let authorization = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(authorization.baseline_ratio_sum, "3");
    assert_eq!(authorization.distress_ratio_sum, "2");
    assert_eq!(authorization.sample_count, 2);
    assert_eq!(authorization.baseline_twap, "1");
    assert_eq!(authorization.distress_twap, "1");
}

#[tokio::test]
async fn open_authorization_rejects_a_price_drop_of_exactly_twenty_percent() {
    let mut rpc = fixture(false);
    rpc.distress_ratio = 800_000_000_000_000_000;
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("price drop"));
}

#[tokio::test]
async fn open_authorization_rejects_an_active_incident() {
    assert!(
        build_incident_open(
            &fixture(true),
            Address::from_str(REGISTRY).unwrap(),
            Address::from_str(TOKEN).unwrap(),
            Address::from_str(SIGNER).unwrap(),
        )
        .await
        .unwrap_err()
        .to_string()
        .contains("active incident")
    );
}

#[tokio::test]
async fn open_authorization_uses_previous_incident_snapshotted_phase_window() {
    let mut rpc = fixture(true);
    rpc.previous_phase_deadline = 900;
    rpc.responses.insert(
        (
            DEFI.to_ascii_lowercase(),
            format!(
                "0x{}",
                hex::encode(IDefiInsurance::incidentPhaseWindowCall::SELECTOR)
            ),
        ),
        encoded::<IDefiInsurance::incidentPhaseWindowCall>(&50),
    );

    build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap();
}

fn assert_open_requests(rpc: &OpenRpc, authoritative: bool, dependent: bool) {
    let calls = rpc.calls.lock().unwrap();
    let config: Vec<_> = calls
        .iter()
        .filter(|p| p[0]["to"].as_str().unwrap().to_ascii_lowercase() != CONVERSION)
        .collect();
    assert_eq!(config.len(), if dependent { 3 } else { 2 });
    assert!(config.iter().all(|p| p[1] == "0x12d6a8"));
    assert!(
        calls
            .iter()
            .all(|p| p[0].get("from").is_none() && p[0].get("value").is_none())
    );
    assert_eq!(
        config[0][0]["to"].as_str().unwrap().to_ascii_lowercase(),
        REGISTRY.to_ascii_lowercase()
    );
    assert_eq!(
        config[0][0]["data"],
        format!(
            "0x{}",
            hex::encode(IRegistry::defiInsuranceCall {}.abi_encode())
        )
    );
    assert_eq!(
        config[1][0]["to"].as_str().unwrap().to_ascii_lowercase(),
        MULTICALL3
    );
    let first = IMulticall3::aggregate3Call::abi_decode_validate(
        &hex::decode(
            config[1][0]["data"]
                .as_str()
                .unwrap()
                .trim_start_matches("0x"),
        )
        .unwrap(),
    )
    .unwrap();
    let mut expected = vec![
        (a(DEFI), IDefiInsurance::registryCall {}.abi_encode()),
        (a(DEFI), IDefiInsurance::nextIncidentIdCall {}.abi_encode()),
        (
            a(REGISTRY),
            IRegistry::incidentTimingConfigCall {}.abi_encode(),
        ),
        (
            a(REGISTRY),
            IRegistry::incidentOpenPriceConfigCall {}.abi_encode(),
        ),
        (
            a(DEFI),
            IDefiInsurance::getInsuredTokenCall { token: a(TOKEN) }.abi_encode(),
        ),
    ];
    if authoritative {
        expected.extend([
            (
                a(DEFI),
                IDefiInsurance::incidentOpenEligibilityHashCall {
                    insuredToken: a(TOKEN),
                }
                .abi_encode(),
            ),
            (
                a(DEFI),
                IDefiInsurance::isTeeSignerCall { signer: a(SIGNER) }.abi_encode(),
            ),
            (a(REGISTRY), IRegistry::teePcrHashCall {}.abi_encode()),
        ]);
    }
    assert_eq!(first.calls.len(), expected.len());
    for (actual, (target, data)) in first.calls.iter().zip(expected) {
        assert_eq!(actual.target, target);
        assert_eq!(actual.callData.as_ref(), data);
        assert!(!actual.allowFailure);
    }
    let history: Vec<_> = calls
        .iter()
        .filter(|p| p[0]["to"].as_str().unwrap().to_ascii_lowercase() == CONVERSION)
        .collect();
    let expected_blocks: Vec<_> = (1_234_490..=1_234_580)
        .step_by(5)
        .map(|n| format!("0x{n:x}"))
        .collect();
    assert_eq!(
        history
            .iter()
            .map(|p| p[1].as_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        expected_blocks
    );
    assert!(history.iter().all(|p| p[0]["data"] == "0x12345678"));
    println!(
        "authoritative={authoritative} dependent={dependent}: config eth_calls={} historical eth_calls={} total eth_calls={}",
        config.len(),
        history.len(),
        calls.len()
    );
}

async fn run_open<R: Rpc>(
    rpc: &R,
    authoritative: bool,
) -> Result<(), usd8_settlement::incident_open::IncidentOpenError> {
    let registry = Address::from_str(REGISTRY).unwrap();
    let token = Address::from_str(TOKEN).unwrap();
    if authoritative {
        build_incident_open(rpc, registry, token, Address::from_str(SIGNER).unwrap())
            .await
            .map(|_| ())
    } else {
        precheck_incident_open(rpc, registry, token)
            .await
            .map(|_| ())
    }
}

#[tokio::test]
async fn previous_incident_reads_use_a_second_pinned_aggregate() {
    for authoritative in [false, true] {
        let mut rpc = fixture(true);
        rpc.previous_phase_deadline = 900;
        rpc.responses.insert(
            (
                DEFI.to_owned(),
                format!(
                    "0x{}",
                    hex::encode(IDefiInsurance::incidentPhaseWindowCall::SELECTOR)
                ),
            ),
            encoded::<IDefiInsurance::incidentPhaseWindowCall>(&50),
        );
        run_open(&rpc, authoritative).await.unwrap();
        assert_open_requests(&rpc, authoritative, true);
        let calls = rpc.calls.lock().unwrap();
        let config: Vec<_> = calls
            .iter()
            .filter(|p| p[0]["to"].as_str().unwrap().to_ascii_lowercase() != CONVERSION)
            .collect();
        assert_eq!(
            config.len(),
            3,
            "dependent incident reads must share a second aggregate"
        );
        assert!(config.iter().all(|p| p[1] == "0x12d6a8"));
        assert_eq!(
            config[2][0]["to"].as_str().unwrap().to_ascii_lowercase(),
            MULTICALL3
        );
        let second = IMulticall3::aggregate3Call::abi_decode_validate(
            &hex::decode(
                config[2][0]["data"]
                    .as_str()
                    .unwrap()
                    .trim_start_matches("0x"),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(second.calls.len(), 2);
        assert!(second.calls.iter().all(|c| c.target == a(DEFI)));
        assert_eq!(
            IDefiInsurance::incidentsCall::abi_decode_validate(&second.calls[0].callData)
                .unwrap()
                .incidentId,
            U256::from(1)
        );
        assert_eq!(
            IDefiInsurance::incidentPhaseWindowCall::abi_decode_validate(&second.calls[1].callData)
                .unwrap()
                .incidentId,
            U256::from(1)
        );
    }
}

#[tokio::test]
async fn previous_incident_terminal_deadline_uses_solidity_width() {
    let mut rpc = fixture(true);
    rpc.previous_phase_deadline = u64::MAX - 10;
    rpc.latest_timestamp = u64::MAX - 5;
    rpc.responses.insert(
        (
            DEFI.to_ascii_lowercase(),
            format!(
                "0x{}",
                hex::encode(IDefiInsurance::incidentPhaseWindowCall::SELECTOR)
            ),
        ),
        encoded::<IDefiInsurance::incidentPhaseWindowCall>(&50),
    );

    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("active incident"));
}

#[tokio::test]
async fn open_authorization_rejects_when_finality_lags_beyond_the_search_window() {
    let error = build_incident_open(
        &fixture_with_finalized(false, 1_234_500),
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("no finalized candidate window"));
}

#[tokio::test]
async fn open_authorization_rejects_discovery_above_the_price_point_cap() {
    let mut rpc = fixture(false);
    set_max_reference_block_age(&mut rpc, 2_000);
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("maximum is 256"));
}

#[tokio::test]
async fn open_authorization_fails_closed_without_a_finalized_head() {
    let mut rpc = fixture(false);
    rpc.finalized_unavailable = true;
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("block finalized not found"));
}

#[tokio::test]
async fn open_authorization_rechecks_the_finalized_anchor_hash() {
    let mut rpc = fixture(false);
    rpc.change_finalized_hash = true;
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("finalized block changed"));
}

#[tokio::test]
async fn open_authorization_rechecks_the_latest_anchor_hash() {
    let mut rpc = fixture(false);
    rpc.change_latest_hash = true;
    let error = build_incident_open(
        &rpc,
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("latest block changed"));
}

#[tokio::test]
async fn open_authorization_rejects_a_finalized_head_ahead_of_latest() {
    let error = build_incident_open(
        &fixture_with_finalized(false, 1_234_700),
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(TOKEN).unwrap(),
        Address::from_str(SIGNER).unwrap(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("ahead of latest"));
}
