#[cfg(any(target_os = "linux", test))]
fn settlement_score_mode() -> usd8_settlement::engine::ScoreMode {
    usd8_settlement::engine::ScoreMode::Bulk
}

#[cfg(any(target_os = "linux", test))]
fn terminal_error_code(detail: &str) -> &str {
    match detail {
        "CMS_PARSE_FAILED"
        | "CMS_KEY_OR_IV_LENGTH"
        | "CMS_CONTENT_DECRYPT_FAILED"
        | "RSA_UNWRAP_FAILED" => "KMS_RECIPIENT_DECRYPT_FAILED",
        "ENCLAVE_VALIDATE_FAILED"
        | "DRPC_DECRYPT_FAILED"
        | "LOCAL_RSA_FAILED"
        | "NSM_ATTESTATION_FAILED"
        | "KMS_ACCESS_DENIED"
        | "KMS_SERVICE_FAILED"
        | "KMS_SERVICE_UNMODELED"
        | "KMS_TRANSPORT_FAILED"
        | "KMS_CONSTRUCTION_FAILED"
        | "KMS_TIMEOUT_FAILED"
        | "KMS_DISPATCH_TIMEOUT"
        | "KMS_DISPATCH_IO"
        | "KMS_IO_NO_PROXY_ACCEPT"
        | "KMS_IO_PROXY_REQUEST_READ"
        | "KMS_IO_PROXY_REQUEST_PARSE"
        | "KMS_IO_VSOCK_CONNECT"
        | "KMS_IO_CONNECT_RESPONSE"
        | "KMS_IO_TUNNEL"
        | "KMS_IO_TUNNEL_EOF"
        | "KMS_DISPATCH_USER"
        | "KMS_DISPATCH_OTHER"
        | "KMS_RESPONSE_PARSE_FAILED"
        | "KMS_RESPONSE_FAILED"
        | "OPEN_COMPUTE_FAILED"
        | "OPEN_ARTIFACT_FAILED"
        | "SIGNER_DECRYPT_FAILED"
        | "SIGNER_FAILED" => detail,
        _ => "ENCLAVE_FAILED",
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("usd8-tee-enclave requires Linux and /dev/nsm");
    std::process::exit(2);
}

#[cfg(target_os = "linux")]
mod linux {
    use aws_credential_types::Credentials;
    use aws_nitro_enclaves_nsm_api::api::{Request, Response};
    use aws_nitro_enclaves_nsm_api::driver::{nsm_exit, nsm_init, nsm_process_request};
    use aws_sdk_kms::error::ProvideErrorMetadata;
    use aws_sdk_kms::primitives::Blob;
    use aws_sdk_kms::types::{KeyEncryptionMechanism, RecipientInfo};
    use aws_smithy_http_client::{
        Builder as HttpClientBuilder, Connector, proxy::ProxyConfig, tls,
    };
    use aws_types::region::Region;
    use base64::Engine;
    use rand_core::OsRng;
    use rsa::pkcs8::EncodePublicKey;
    use rsa::{RsaPrivateKey, RsaPublicKey};
    use serde_bytes::ByteBuf;
    use serde_json::json;
    use sha2::{Digest, Sha256};
    use std::env;
    use std::io;
    use std::mem::MaybeUninit;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::sync::atomic::{AtomicU8, Ordering};

    use std::time::{Duration, SystemTime, UNIX_EPOCH};
    use tokio::io::{AsyncReadExt, AsyncWriteExt, copy_bidirectional};
    use tokio::net::TcpListener;

    use tokio::time::timeout;
    use tokio_vsock::{VsockAddr, VsockListener, VsockStream};
    use usd8_tee_job_api::{
        AttestedDigestKind, CanonicalRequest, JOB_WIRE_SCHEMA_VERSION, JobPaths, JobWireRequest,
        MAX_ACCESS_KEY_ID_BYTES, MAX_CIPHERTEXT_BYTES, MAX_SECRET_ACCESS_KEY_BYTES,
        MAX_SESSION_TOKEN_BYTES, MAX_WIRE_REQUEST_BYTES, TerminalEnvelope,
        canonicalize_open_request, canonicalize_request, connect_proxy_port,
        decrypt_kms_recipient_envelope, enclave_timeout_seconds, extract_attested_digest,
        parse_kms_recipient_cms, read_frame_async, settlement_rpc_url, sign_digest,
        stored_request_is_live, verify_job_request_binding, write_frame_async,
    };
    use zeroize::{Zeroize, Zeroizing};

    type Error = Box<dyn std::error::Error + Send + Sync>;
    const MAX_ARTIFACT: usize = MAX_RESPONSE - 64 * 1024;
    const PARENT_CID: u32 = 3;
    const JOB_PORT: u32 = 5000;
    const MAX_RESPONSE: usize = 16 * 1024 * 1024;
    static PROXY_STAGE: AtomicU8 = AtomicU8::new(0);

    fn enable_loopback() -> io::Result<()> {
        // Nitro Enclaves have no external network device, and their loopback
        // interface is not guaranteed to be administratively up. The AWS SDK
        // reaches the fixed-destination vsock relay through this local TCP
        // listener, so fail closed if `lo` cannot be enabled.
        let raw_fd =
            unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0) };
        if raw_fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let fd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
        let mut request = MaybeUninit::<libc::ifreq>::zeroed();
        let request = unsafe { request.assume_init_mut() };
        request.ifr_name[0] = b'l' as libc::c_char;
        request.ifr_name[1] = b'o' as libc::c_char;

        if unsafe { libc::ioctl(fd.as_raw_fd(), libc::SIOCGIFFLAGS, &mut *request) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let flags = unsafe { request.ifr_ifru.ifru_flags };
        request.ifr_ifru.ifru_flags = flags | libc::IFF_UP as libc::c_short;
        if unsafe { libc::ioctl(fd.as_raw_fd(), libc::SIOCSIFFLAGS, &mut *request) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    const EXPECTED_REGISTRY: &str = env!(
        "USD8_REGISTRY",
        "USD8_REGISTRY must be fixed at compile time for the enclave"
    );

    fn validate(request: &JobWireRequest) -> Result<(Vec<u8>, Vec<u8>), Error> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        if !stored_request_is_live(&request.stored_request, now) {
            return Err("stored request is invalid or expired".into());
        }
        JobPaths::new(&request.stored_request.job_id)?;
        verify_job_request_binding(
            &request.stored_request.job_id,
            &request.stored_request.request,
        )?;
        let canonical = match &request.stored_request.request {
            CanonicalRequest::Settlement(settlement) => canonicalize_request(
                &serde_json::to_vec(&json!({
                    "incidentId": settlement.incident_id,
                }))?,
                EXPECTED_REGISTRY,
            )?,
            CanonicalRequest::Open(open) => canonicalize_open_request(
                &serde_json::to_vec(&json!({
                    "insuredToken": open.insured_token,
                }))?,
                EXPECTED_REGISTRY,
            )?,
        };
        if request.schema_version != JOB_WIRE_SCHEMA_VERSION
            || request.region != "eu-central-1"
            || canonical != request.stored_request.request
            || request.access_key_id.is_empty()
            || request.secret_access_key.is_empty()
            || request.session_token.is_empty()
            || request.access_key_id.len() > MAX_ACCESS_KEY_ID_BYTES
            || request.secret_access_key.len() > MAX_SECRET_ACCESS_KEY_BYTES
            || request.session_token.len() > MAX_SESSION_TOKEN_BYTES
        {
            return Err("invalid enclave request".into());
        }
        let signer =
            base64::engine::general_purpose::STANDARD.decode(&request.signer_ciphertext_b64)?;
        let drpc =
            base64::engine::general_purpose::STANDARD.decode(&request.drpc_ciphertext_b64)?;
        if signer.is_empty()
            || drpc.is_empty()
            || signer.len() > MAX_CIPHERTEXT_BYTES
            || drpc.len() > MAX_CIPHERTEXT_BYTES
        {
            return Err("invalid ciphertext".into());
        }
        Ok((signer, drpc))
    }

    fn binding(domain: &[u8], parts: &[&[u8]]) -> [u8; 32] {
        let mut hasher = Sha256::new();
        hasher.update(domain);
        for part in parts {
            hasher.update((part.len() as u64).to_be_bytes());
            hasher.update(part);
        }
        hasher.finalize().into()
    }

    fn attestation(public_key: &[u8], user_data: &[u8]) -> Result<Vec<u8>, Error> {
        let fd = nsm_init();
        if fd < 0 {
            return Err("NSM unavailable".into());
        }
        let response = nsm_process_request(
            fd,
            Request::Attestation {
                user_data: Some(ByteBuf::from(user_data.to_vec())),
                nonce: None,
                public_key: Some(ByteBuf::from(public_key.to_vec())),
            },
        );
        nsm_exit(fd);
        match response {
            Response::Attestation { document } if !document.is_empty() => Ok(document),
            _ => Err("NSM attestation failed".into()),
        }
    }

    async fn recipient_decrypt(
        kms: &aws_sdk_kms::Client,
        ciphertext: &[u8],
        purpose: &str,
        user_data: &[u8],
    ) -> Result<(Zeroizing<Vec<u8>>, Vec<u8>), Error> {
        let private_key = RsaPrivateKey::new(&mut OsRng, 2048).map_err(|_| "LOCAL_RSA_FAILED")?;
        let public_key = RsaPublicKey::from(&private_key)
            .to_public_key_der()
            .map_err(|_| "LOCAL_RSA_FAILED")?
            .as_bytes()
            .to_vec();
        let document = attestation(&public_key, user_data).map_err(|_| "NSM_ATTESTATION_FAILED")?;
        let recipient = RecipientInfo::builder()
            .key_encryption_algorithm(KeyEncryptionMechanism::RsaesOaepSha256)
            .attestation_document(Blob::new(document.clone()))
            .build();
        let output = kms
            .decrypt()
            .ciphertext_blob(Blob::new(ciphertext))
            .encryption_context("purpose", purpose)
            .recipient(recipient)
            .send()
            .await
            .map_err(|error| match &error {
                aws_sdk_kms::error::SdkError::ConstructionFailure(_) => "KMS_CONSTRUCTION_FAILED",
                aws_sdk_kms::error::SdkError::TimeoutError(_) => "KMS_TIMEOUT_FAILED",
                aws_sdk_kms::error::SdkError::DispatchFailure(dispatch) => {
                    if dispatch.is_timeout() {
                        "KMS_DISPATCH_TIMEOUT"
                    } else if dispatch.is_io() {
                        match PROXY_STAGE.load(Ordering::Relaxed) {
                            0 => "KMS_IO_NO_PROXY_ACCEPT",
                            1 => "KMS_IO_PROXY_REQUEST_READ",
                            2 => "KMS_IO_PROXY_REQUEST_PARSE",
                            3 => "KMS_IO_VSOCK_CONNECT",
                            4 => "KMS_IO_CONNECT_RESPONSE",
                            5 => "KMS_IO_TUNNEL",
                            _ => "KMS_IO_TUNNEL_EOF",
                        }
                    } else if dispatch.is_user() {
                        "KMS_DISPATCH_USER"
                    } else {
                        "KMS_DISPATCH_OTHER"
                    }
                }
                aws_sdk_kms::error::SdkError::ResponseError(_) => "KMS_RESPONSE_PARSE_FAILED",
                aws_sdk_kms::error::SdkError::ServiceError(service) => match service.err().code() {
                    Some("AccessDeniedException") => "KMS_ACCESS_DENIED",
                    Some(_) => "KMS_SERVICE_FAILED",
                    None => "KMS_SERVICE_UNMODELED",
                },
                _ => "KMS_TRANSPORT_FAILED",
            })?;
        let wrapped = output
            .ciphertext_for_recipient()
            .ok_or("KMS_RESPONSE_FAILED")?;
        let envelope = parse_kms_recipient_cms(wrapped.as_ref()).map_err(|_| "CMS_PARSE_FAILED")?;
        let plaintext = decrypt_kms_recipient_envelope(&private_key, &envelope)?;
        Ok((plaintext, document))
    }

    async fn connect_proxy(listener: TcpListener) -> Result<(), Error> {
        loop {
            let (mut local, _) = listener.accept().await?;
            PROXY_STAGE.fetch_max(1, Ordering::Relaxed);
            tokio::spawn(async move {
                let mut request = Vec::with_capacity(512);
                while request.len() < 4096 && !request.ends_with(b"\r\n\r\n") {
                    let mut chunk = [0u8; 512];
                    let Ok(read) = timeout(Duration::from_secs(5), local.read(&mut chunk)).await
                    else {
                        return;
                    };
                    let Ok(read) = read else { return };
                    if read == 0 {
                        return;
                    }
                    request.extend_from_slice(&chunk[..read]);
                }
                PROXY_STAGE.fetch_max(2, Ordering::Relaxed);
                let Some(parent_port) = connect_proxy_port(&request) else {
                    return;
                };
                PROXY_STAGE.fetch_max(3, Ordering::Relaxed);
                let Ok(mut parent) =
                    VsockStream::connect(VsockAddr::new(PARENT_CID, parent_port)).await
                else {
                    return;
                };
                PROXY_STAGE.fetch_max(4, Ordering::Relaxed);
                if local
                    .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    .await
                    .is_ok()
                {
                    PROXY_STAGE.fetch_max(5, Ordering::Relaxed);
                    let _ = copy_bidirectional(&mut local, &mut parent).await;
                    PROXY_STAGE.fetch_max(6, Ordering::Relaxed);
                }
            });
        }
    }

    async fn compute(request: &JobWireRequest, drpc_key: &str) -> Result<serde_json::Value, Error> {
        let request_timeout =
            Duration::from_secs(enclave_timeout_seconds(&request.stored_request.request));
        match &request.stored_request.request {
            CanonicalRequest::Settlement(settlement) => {
                let result = timeout(
                    request_timeout,
                    usd8_settlement::attested_runtime::settlement_artifact(
                        settlement_rpc_url(),
                        drpc_key,
                        &settlement.registry,
                        &settlement.incident_id,
                        super::settlement_score_mode(),
                        usd8_settlement::attested_runtime::AttestedRuntimeOptions {
                            proxy_url: Some("http://127.0.0.1:8080"),
                            maximum_artifact_bytes: MAX_ARTIFACT,
                        },
                    ),
                )
                .await;
                Ok(result??)
            }
            CanonicalRequest::Open(open) => Ok(timeout(
                request_timeout,
                usd8_settlement::attested_runtime::incident_open_artifact(
                    settlement_rpc_url(),
                    drpc_key,
                    &open.registry,
                    &open.insured_token,
                    &env::var("USD8_EXPECTED_SIGNER")?,
                    usd8_settlement::attested_runtime::AttestedRuntimeOptions {
                        proxy_url: Some("http://127.0.0.1:8080"),
                        maximum_artifact_bytes: MAX_ARTIFACT,
                    },
                ),
            )
            .await??),
        }
    }

    async fn process(request: &JobWireRequest) -> Result<TerminalEnvelope, Error> {
        let (mut signer_ciphertext, mut drpc_ciphertext) =
            validate(request).map_err(|_| "ENCLAVE_VALIDATE_FAILED")?;
        let credentials = Credentials::new(
            request.access_key_id.clone(),
            request.secret_access_key.clone(),
            Some(request.session_token.clone()),
            None,
            "usd8-parent-instance-role",
        );
        let proxy = ProxyConfig::https("http://127.0.0.1:8080")?;
        let http_client = HttpClientBuilder::new().build_with_connector_fn(
            move |settings, runtime_components| {
                let mut builder = Connector::builder().proxy_config(proxy.clone());
                if let Some(settings) = settings {
                    builder = builder.connector_settings(settings.clone());
                }
                if let Some(sleep) = runtime_components.and_then(|runtime| runtime.sleep_impl()) {
                    builder = builder.sleep_impl(sleep);
                }
                builder
                    .tls_provider(tls::Provider::Rustls(
                        tls::rustls_provider::CryptoMode::AwsLc,
                    ))
                    .build()
            },
        );
        let sdk = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(Region::new(request.region.clone()))
            .credentials_provider(credentials)
            .http_client(http_client)
            .load()
            .await;
        let kms = aws_sdk_kms::Client::new(&sdk);
        let canonical_request = serde_json::to_vec(&request.stored_request.request)?;
        let job_binding = binding(
            b"USD8_TEE_DRPC_V1\0",
            &[request.stored_request.job_id.as_bytes(), &canonical_request],
        );
        let (drpc_plaintext, _) =
            recipient_decrypt(&kms, &drpc_ciphertext, "usd8-tee-drpc-v1", &job_binding).await?;
        drpc_ciphertext.zeroize();
        let drpc_text =
            std::str::from_utf8(drpc_plaintext.as_slice()).map_err(|_| "invalid dRPC key")?;
        let drpc_key = Zeroizing::new(drpc_text.to_owned());
        if drpc_key.is_empty() || drpc_key.len() > 512 || drpc_key.contains('\0') {
            return Err("invalid dRPC key".into());
        }
        let artifact = compute(request, &drpc_key)
            .await
            .map_err(|_| "OPEN_COMPUTE_FAILED")?;
        let expected_kind = match &request.stored_request.request {
            CanonicalRequest::Settlement(_) => AttestedDigestKind::Settlement,
            CanonicalRequest::Open(_) => AttestedDigestKind::IncidentOpen,
        };
        let digest = extract_attested_digest(&artifact, expected_kind)
            .map_err(|_| "OPEN_ARTIFACT_FAILED")?;
        let signer_binding = binding(
            b"USD8_TEE_SIGNER_V1\0",
            &[request.stored_request.job_id.as_bytes(), &digest],
        );
        let (mut private_key, signer_attestation) = recipient_decrypt(
            &kms,
            &signer_ciphertext,
            "usd8-tee-signer-v1",
            &signer_binding,
        )
        .await
        .map_err(|_| "SIGNER_DECRYPT_FAILED")?;
        signer_ciphertext.zeroize();
        if private_key.len() != 32 {
            return Err("invalid signer key".into());
        }
        let signature = sign_digest(&private_key, &digest).map_err(|_| "SIGNER_FAILED")?;
        private_key.zeroize();
        let expected_signer = env::var("USD8_EXPECTED_SIGNER")
            .map_err(|_| "SIGNER_FAILED")?
            .to_ascii_lowercase();
        if signature.signer != expected_signer {
            return Err("signer address mismatch".into());
        }
        Ok(TerminalEnvelope::completed(
            &request.stored_request.job_id,
            json!({
                "artifact": artifact,
                "digest": signature.digest,
                "signer": signature.signer,
                "signature": signature.signature,
                "kmsRecipientAttestation": format!("0x{}", hex::encode(signer_attestation)),
            }),
        ))
    }

    pub async fn run() -> Result<(), Error> {
        enable_loopback()?;
        // Bind before accepting the parent request so the first KMS/RPC call
        // cannot race proxy startup inside the enclave.
        let proxy_listener = TcpListener::bind("127.0.0.1:8080").await?;
        tokio::spawn(connect_proxy(proxy_listener));
        let listener = VsockListener::bind(VsockAddr::new(libc::VMADDR_CID_ANY, JOB_PORT))?;
        let (mut stream, peer) = listener.accept().await?;
        if peer.cid() != PARENT_CID {
            return Err("unexpected vsock peer".into());
        }
        let request =
            read_frame_async::<_, JobWireRequest>(&mut stream, MAX_WIRE_REQUEST_BYTES).await?;
        let terminal = match process(&request).await {
            Ok(terminal) => terminal,
            Err(error) => {
                let detail = error.to_string();
                let code = super::terminal_error_code(&detail);
                TerminalEnvelope::failed(&request.stored_request.job_id, code)
            }
        };
        write_frame_async(&mut stream, &terminal, MAX_RESPONSE).await?;
        Ok(())
    }
}

#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() {
    if linux::run().await.is_err() {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn settlement_jobs_use_ephemeral_bulk_scoring_without_checkpoint_material() {
        assert_eq!(format!("{:?}", super::settlement_score_mode()), "Bulk");
    }

    #[test]
    fn recipient_crypto_failures_are_indistinguishable() {
        for detail in [
            "CMS_PARSE_FAILED",
            "CMS_KEY_OR_IV_LENGTH",
            "CMS_CONTENT_DECRYPT_FAILED",
            "RSA_UNWRAP_FAILED",
        ] {
            assert_eq!(
                super::terminal_error_code(detail),
                "KMS_RECIPIENT_DECRYPT_FAILED"
            );
        }
    }
}
