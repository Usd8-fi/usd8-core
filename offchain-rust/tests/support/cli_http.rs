use serde_json::{Value, json};
use usd8_settlement::rpc::Rpc;

pub async fn serve<R: Rpc + Send + Sync + 'static>(
    rpc: R,
) -> (String, tokio::task::JoinHandle<()>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let request = loop {
                let mut buf = [0; 4096];
                let n = stream.read(&mut buf).await.unwrap();
                assert_ne!(n, 0);
                bytes.extend_from_slice(&buf[..n]);
                if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&bytes[..end]);
                    let len: usize = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
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
            let batch = request.is_array();
            let members = if batch {
                request.as_array().unwrap().clone()
            } else {
                vec![request]
            };
            let mut responses = Vec::new();
            for member in members {
                let result = rpc
                    .request(member["method"].as_str().unwrap(), member["params"].clone())
                    .await;
                responses.push(match result {
                    Ok(value) => json!({"jsonrpc":"2.0","id":member["id"],"result":value}),
                    Err(error) => json!({"jsonrpc":"2.0","id":member["id"],"error":{"code":-32000,"message":error.to_string()}}),
                });
            }
            responses.reverse();
            let body = if batch {
                json!(responses)
            } else {
                responses.remove(0)
            }
            .to_string();
            let wire = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(wire.as_bytes()).await.unwrap();
        }
    });
    (url, task)
}

pub async fn run(
    mode: &'static str,
    account: &'static str,
    registry: &'static str,
    url: String,
    extra: Vec<String>,
) -> std::process::Output {
    tokio::task::spawn_blocking(move || {
        std::process::Command::new(env!("CARGO_BIN_EXE_usd8-settlement"))
            .env("DRPC_KEY", "test-inherited-key-must-not-be-sent")
            .env("SCORE_CHECKPOINT_PATH", "/must-not-read-checkpoint")
            .env("USD8_EXPECTED_SIGNER", "must-not-read-signer")
            .args([
                mode,
                account,
                "--registry",
                registry,
                "--rpc-url",
                &url,
                "--no-drpc-key",
                "--timeout-ms",
                "2000",
            ])
            .args(extra)
            .output()
            .unwrap()
    })
    .await
    .unwrap()
}
