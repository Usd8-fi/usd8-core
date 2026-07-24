#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("usd8-tee-parent requires Linux");
    std::process::exit(2);
}

#[cfg(target_os = "linux")]
mod linux {
    use aws_credential_types::provider::ProvideCredentials;

    use aws_types::region::Region;
    use base64::Engine;
    use sha2::{Digest, Sha256};
    use std::env;
    use std::fs::File;
    use std::io::Read;
    use std::path::Path;
    use std::process::Stdio;
    use std::time::Duration;
    use tokio::io::copy_bidirectional;
    use tokio::net::TcpStream;
    use tokio::process::Command;
    use tokio::time::{sleep, timeout};
    use tokio_vsock::{VsockAddr, VsockListener, VsockStream};
    use usd8_tee_job_api::{
        JobPaths, JobWireRequest, MAX_CIPHERTEXT_BYTES, MAX_STORED_REQUEST_BYTES,
        MAX_WIRE_REQUEST_BYTES, StoredRequest, TerminalEnvelope, parent_timeout_seconds,
        read_frame_async, settlement_rpc_authority, write_frame_async,
    };

    type Error = Box<dyn std::error::Error + Send + Sync>;
    const ENCLAVE_CID: u32 = 16;
    const JOB_PORT: u32 = 5000;
    const KMS_PROXY_PORT: u32 = 9001;
    const DRPC_PROXY_PORT: u32 = 9002;
    const MAX_RESPONSE: usize = 16 * 1024 * 1024;

    struct Config {
        job_id: String,
        region: String,
        eif_path: String,
        eif_sha256: String,
        request_get_url: String,
        signer_get_url: String,
        drpc_get_url: String,
        terminal_put_url: String,
    }

    impl Config {
        fn load() -> Result<Self, Error> {
            let value = Self {
                job_id: env::var("USD8_JOB_ID")?,
                region: env::var("AWS_REGION")?,
                eif_path: env::var("USD8_EIF_PATH")
                    .unwrap_or_else(|_| "/opt/usd8/enclave.eif".to_owned()),
                eif_sha256: env::var("USD8_EIF_SHA256")?.to_ascii_lowercase(),
                request_get_url: capability_url("USD8_REQUEST_GET_URL_HEX")?,
                signer_get_url: capability_url("USD8_SIGNER_GET_URL_HEX")?,
                drpc_get_url: capability_url("USD8_DRPC_GET_URL_HEX")?,
                terminal_put_url: capability_url("USD8_TERMINAL_PUT_URL_HEX")?,
            };
            JobPaths::new(&value.job_id)?;
            if value.region != "eu-central-1"
                || value.eif_sha256.len() != 64
                || !value
                    .eif_sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
                || !Path::new(&value.eif_path).is_absolute()
            {
                return Err("invalid parent configuration".into());
            }
            Ok(value)
        }
    }

    fn capability_url(name: &str) -> Result<String, Error> {
        let value = String::from_utf8(hex::decode(env::var(name)?)?)?;
        if value.len() > 4096
            || !value.starts_with("https://")
            || value.bytes().any(|byte| byte.is_ascii_control())
        {
            return Err("invalid worker capability".into());
        }
        Ok(value)
    }

    fn verify_eif(path: &str, expected: &str) -> Result<(), Error> {
        let mut file = File::open(path)?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let read = file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        if hex::encode(hasher.finalize()) != expected {
            return Err("EIF checksum mismatch".into());
        }
        Ok(())
    }

    async fn get_capability(
        client: &reqwest::Client,
        url: &str,
        max_bytes: usize,
    ) -> Result<Vec<u8>, Error> {
        let response = client.get(url).send().await?.error_for_status()?;
        if response
            .content_length()
            .is_some_and(|length| length as usize > max_bytes)
        {
            return Err("capability response exceeds limit".into());
        }
        let bytes = response.bytes().await?.to_vec();
        if bytes.len() > max_bytes {
            return Err("capability response exceeds limit".into());
        }
        Ok(bytes)
    }

    async fn put_terminal(
        client: &reqwest::Client,
        url: &str,
        terminal: &TerminalEnvelope,
    ) -> Result<(), Error> {
        let response = client
            .put(url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header(reqwest::header::IF_NONE_MATCH, "*")
            .body(serde_json::to_vec(terminal)?)
            .send()
            .await?;
        if response.status().is_success()
            || response.status() == reqwest::StatusCode::PRECONDITION_FAILED
        {
            Ok(())
        } else {
            Err(format!("terminal capability failed: {}", response.status()).into())
        }
    }

    async fn proxy(listener: VsockListener, destination: &'static str) -> Result<(), Error> {
        loop {
            let (mut enclave, _) = listener.accept().await?;
            tokio::spawn(async move {
                if let Ok(mut upstream) = TcpStream::connect(destination).await {
                    let _ = copy_bidirectional(&mut enclave, &mut upstream).await;
                }
            });
        }
    }

    async fn connect_enclave() -> Result<VsockStream, Error> {
        for _ in 0..120 {
            match VsockStream::connect(VsockAddr::new(ENCLAVE_CID, JOB_PORT)).await {
                Ok(stream) => return Ok(stream),
                Err(_) => sleep(Duration::from_secs(1)).await,
            }
        }
        Err("enclave did not become ready".into())
    }

    async fn execute(
        config: &Config,
        client: &reqwest::Client,
        sdk: &aws_config::SdkConfig,
    ) -> Result<TerminalEnvelope, Error> {
        verify_eif(&config.eif_path, &config.eif_sha256)?;
        let request_bytes =
            get_capability(client, &config.request_get_url, MAX_STORED_REQUEST_BYTES).await?;
        let request: StoredRequest = serde_json::from_slice(&request_bytes)?;
        if request.schema_version != 2 || request.job_id != config.job_id {
            return Err("stored request binding mismatch".into());
        }
        let signer = get_capability(client, &config.signer_get_url, MAX_CIPHERTEXT_BYTES).await?;
        let drpc = get_capability(client, &config.drpc_get_url, MAX_CIPHERTEXT_BYTES).await?;
        let provider = sdk
            .credentials_provider()
            .ok_or("AWS credentials unavailable")?;
        let credentials = provider.provide_credentials().await?;
        let token = credentials
            .session_token()
            .ok_or("session token required")?;
        let response_timeout = parent_timeout_seconds(&request.request);
        let wire = JobWireRequest {
            schema_version: 2,
            stored_request: request,
            region: config.region.clone(),
            access_key_id: credentials.access_key_id().to_owned(),
            secret_access_key: credentials.secret_access_key().to_owned(),
            session_token: token.to_owned(),
            signer_ciphertext_b64: base64::engine::general_purpose::STANDARD.encode(signer),
            drpc_ciphertext_b64: base64::engine::general_purpose::STANDARD.encode(drpc),
        };

        let kms_proxy = VsockListener::bind(VsockAddr::new(libc::VMADDR_CID_ANY, KMS_PROXY_PORT))?;
        let drpc_proxy =
            VsockListener::bind(VsockAddr::new(libc::VMADDR_CID_ANY, DRPC_PROXY_PORT))?;
        tokio::spawn(proxy(kms_proxy, "kms.eu-central-1.amazonaws.com:443"));
        tokio::spawn(proxy(drpc_proxy, settlement_rpc_authority()));
        let status = Command::new("/usr/bin/nitro-cli")
            .args([
                "run-enclave",
                "--eif-path",
                &config.eif_path,
                "--cpu-count",
                "2",
                "--memory",
                "3072",
                "--enclave-cid",
                &ENCLAVE_CID.to_string(),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await?;
        if !status.success() {
            return Err("nitro-cli failed to start enclave".into());
        }
        let mut stream = connect_enclave().await?;
        write_frame_async(&mut stream, &wire, MAX_WIRE_REQUEST_BYTES).await?;
        let terminal = timeout(
            Duration::from_secs(response_timeout),
            read_frame_async::<_, TerminalEnvelope>(&mut stream, MAX_RESPONSE),
        )
        .await??;
        if terminal.schema_version != 1 || terminal.job_id != config.job_id {
            return Err("enclave response binding mismatch".into());
        }
        Ok(terminal)
    }

    pub async fn run() -> Result<(), Error> {
        let config = Config::load()?;
        let sdk = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(Region::new(config.region.clone()))
            .load()
            .await;
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(60))
            .build()?;
        let terminal = match execute(&config, &client, &sdk).await {
            Ok(terminal) => terminal,
            Err(_) => TerminalEnvelope::failed(&config.job_id, "PARENT_FAILED"),
        };
        put_terminal(&client, &config.terminal_put_url, &terminal).await
    }
}

#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() {
    if linux::run().await.is_err() {
        std::process::exit(1);
    }
}
