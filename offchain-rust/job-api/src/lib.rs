use async_trait::async_trait;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

mod kms_recipient_cms;
#[cfg(feature = "worker")]
pub use kms_recipient_cms::decrypt_kms_recipient_envelope;
pub use kms_recipient_cms::{KmsRecipientEnvelope, parse_kms_recipient_cms};

const MAX_UINT256: &str =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935";
const JOB_ID_DOMAIN: &[u8] = b"USD8_TEE_JOB_V3\0";
const REQUEST_COMMITMENT_DOMAIN: &[u8] = b"USD8_TEE_REQUEST_V1\0";

pub const JOB_WIRE_SCHEMA_VERSION: u32 = 3;
pub const STORED_REQUEST_SCHEMA_VERSION: u32 = 3;

pub const MAX_STORED_REQUEST_BYTES: usize = 4_096;
pub const MAX_CIPHERTEXT_BYTES: usize = 65_536;
pub const MAX_CIPHERTEXT_B64_BYTES: usize = 4 * MAX_CIPHERTEXT_BYTES.div_ceil(3);
pub const MAX_ACCESS_KEY_ID_BYTES: usize = 256;
pub const MAX_SECRET_ACCESS_KEY_BYTES: usize = 256;
pub const MAX_SESSION_TOKEN_BYTES: usize = 4_096;
const MAX_JSON_ESCAPE_EXPANSION: usize = 6;
const MAX_WIRE_JSON_OVERHEAD_BYTES: usize = 1_024;
pub const MAX_WIRE_REQUEST_BYTES: usize = MAX_WIRE_JSON_OVERHEAD_BYTES
    + MAX_STORED_REQUEST_BYTES
    + MAX_JSON_ESCAPE_EXPANSION
        * (MAX_ACCESS_KEY_ID_BYTES + MAX_SECRET_ACCESS_KEY_BYTES + MAX_SESSION_TOKEN_BYTES)
    + 2 * MAX_CIPHERTEXT_B64_BYTES;

#[cfg(not(feature = "sepolia"))]
pub const fn settlement_rpc_url() -> &'static str {
    "https://lb.drpc.org/ogrpc?network=ethereum"
}

#[cfg(not(feature = "sepolia"))]
pub const fn settlement_rpc_requires_drpc_key() -> bool {
    true
}

#[cfg(not(feature = "sepolia"))]
pub const fn settlement_rpc_authority() -> &'static str {
    "lb.drpc.org:443"
}

#[cfg(feature = "sepolia")]
pub const fn settlement_rpc_url() -> &'static str {
    "https://rpc.sepolia.ethpandaops.io"
}

#[cfg(feature = "sepolia")]
pub const fn settlement_rpc_requires_drpc_key() -> bool {
    false
}

#[cfg(feature = "sepolia")]
pub const fn settlement_rpc_authority() -> &'static str {
    "rpc.sepolia.ethpandaops.io:443"
}

type HmacSha256 = Hmac<Sha256>;

pub fn is_expired(launched_at_secs: i64, now_secs: i64, ttl_secs: i64) -> bool {
    ttl_secs > 0 && now_secs.saturating_sub(launched_at_secs) > ttl_secs
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct JobWireRequest {
    pub schema_version: u32,
    pub stored_request: StoredRequest,
    pub region: String,
    pub access_key_id: String,
    pub secret_access_key: String,
    pub session_token: String,
    pub signer_ciphertext_b64: String,
    pub drpc_ciphertext_b64: String,
}

impl std::fmt::Debug for JobWireRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("JobWireRequest")
            .field("schema_version", &self.schema_version)
            .field("stored_request", &self.stored_request)
            .field("region", &self.region)
            .field("credentials", &"[REDACTED]")
            .field("ciphertexts", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum WireError {
    #[error("wire I/O failed")]
    Io,
    #[error("wire frame exceeds limit")]
    TooLarge,
    #[error("wire JSON is invalid")]
    InvalidJson,
}

pub fn connect_proxy_port(request: &[u8]) -> Option<u32> {
    if request.len() > 4096 || !request.ends_with(b"\r\n\r\n") {
        return None;
    }
    let first_line_end = request.windows(2).position(|window| window == b"\r\n")?;
    let line = &request[..first_line_end];
    if line == b"CONNECT kms.eu-central-1.amazonaws.com:443 HTTP/1.1" {
        return Some(9001);
    }
    let rpc_connect = format!("CONNECT {} HTTP/1.1", settlement_rpc_authority());
    (line == rpc_connect.as_bytes()).then_some(9002)
}

pub async fn write_frame_async<W: tokio::io::AsyncWrite + Unpin, T: Serialize>(
    writer: &mut W,
    value: &T,
    max_bytes: usize,
) -> Result<(), WireError> {
    use tokio::io::AsyncWriteExt;

    let bytes = serde_json::to_vec(value).map_err(|_| WireError::InvalidJson)?;
    if bytes.is_empty() || bytes.len() > max_bytes || bytes.len() > u32::MAX as usize {
        return Err(WireError::TooLarge);
    }
    writer
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await
        .map_err(|_| WireError::Io)?;
    writer.write_all(&bytes).await.map_err(|_| WireError::Io)?;
    writer.flush().await.map_err(|_| WireError::Io)
}

pub async fn read_frame_async<R: tokio::io::AsyncRead + Unpin, T: for<'de> Deserialize<'de>>(
    reader: &mut R,
    max_bytes: usize,
) -> Result<T, WireError> {
    use tokio::io::AsyncReadExt;

    let mut length = [0u8; 4];
    reader
        .read_exact(&mut length)
        .await
        .map_err(|_| WireError::Io)?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > max_bytes {
        return Err(WireError::TooLarge);
    }
    let mut bytes = vec![0u8; length];
    reader
        .read_exact(&mut bytes)
        .await
        .map_err(|_| WireError::Io)?;
    serde_json::from_slice(&bytes).map_err(|_| WireError::InvalidJson)
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EthereumSignature {
    pub digest: String,
    pub signer: String,
    pub signature: String,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum SigningError {
    #[error("invalid private key")]
    InvalidPrivateKey,
    #[error("digest must be 32 bytes")]
    InvalidDigest,
    #[error("unsupported recovery identifier")]
    InvalidRecoveryId,
}

pub fn ethereum_address(private_key: &[u8]) -> Result<String, SigningError> {
    use k256::ecdsa::SigningKey;
    use sha3::{Digest, Keccak256};

    let signing_key =
        SigningKey::from_slice(private_key).map_err(|_| SigningError::InvalidPrivateKey)?;
    let public_key = signing_key.verifying_key().to_encoded_point(false);
    let digest = Keccak256::digest(&public_key.as_bytes()[1..]);
    Ok(format!("0x{}", hex::encode(&digest[12..])))
}

pub fn sign_digest(private_key: &[u8], digest: &[u8]) -> Result<EthereumSignature, SigningError> {
    use k256::ecdsa::SigningKey;

    let digest: &[u8; 32] = digest.try_into().map_err(|_| SigningError::InvalidDigest)?;
    let signing_key =
        SigningKey::from_slice(private_key).map_err(|_| SigningError::InvalidPrivateKey)?;
    let (mut signature, mut recovery_id) = signing_key
        .sign_prehash_recoverable(digest)
        .map_err(|_| SigningError::InvalidDigest)?;
    if let Some(normalized) = signature.normalize_s() {
        signature = normalized;
        recovery_id =
            k256::ecdsa::RecoveryId::new(!recovery_id.is_y_odd(), recovery_id.is_x_reduced());
    }
    if recovery_id.is_x_reduced() {
        return Err(SigningError::InvalidRecoveryId);
    }
    let mut bytes = signature.to_bytes().to_vec();
    bytes.push(27 + u8::from(recovery_id.is_y_odd()));
    Ok(EthereumSignature {
        digest: format!("0x{}", hex::encode(digest)),
        signer: ethereum_address(private_key)?,
        signature: format!("0x{}", hex::encode(bytes)),
    })
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ArtifactError {
    #[error("attested artifact is invalid")]
    Invalid,
    #[error("attested artifact bindings mismatch")]
    Mismatch,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttestedDigestKind {
    Settlement,
    IncidentOpen,
}

pub fn extract_attested_digest(
    artifact: &serde_json::Value,
    expected: AttestedDigestKind,
) -> Result<[u8; 32], ArtifactError> {
    let object = artifact.as_object().ok_or(ArtifactError::Invalid)?;
    if object
        .get("schemaVersion")
        .and_then(serde_json::Value::as_u64)
        != Some(match expected {
            AttestedDigestKind::Settlement => 2,
            AttestedDigestKind::IncidentOpen => 1,
        })
    {
        return Err(ArtifactError::Invalid);
    }
    let text = |name: &str| {
        object
            .get(name)
            .and_then(serde_json::Value::as_str)
            .ok_or(ArtifactError::Invalid)
    };
    let settlement_digest = object
        .get("settlementDigest")
        .and_then(serde_json::Value::as_str);
    let open_digest = object.get("openDigest").and_then(serde_json::Value::as_str);
    let digest = match (expected, settlement_digest, open_digest) {
        (AttestedDigestKind::Settlement, Some(digest), None) => digest,
        (AttestedDigestKind::IncidentOpen, None, Some(digest))
            if object
                .get("artifactType")
                .and_then(serde_json::Value::as_str)
                == Some("incidentOpen") =>
        {
            digest
        }
        _ => return Err(ArtifactError::Invalid),
    };
    if !digest.eq_ignore_ascii_case(text("nitroAttestedDigest")?)
        || !text("teePcrHash")?.eq_ignore_ascii_case(text("measuredTeePcrHash")?)
    {
        return Err(ArtifactError::Mismatch);
    }
    let document = text("nitroAttestationDocument")?
        .strip_prefix("0x")
        .ok_or(ArtifactError::Invalid)?;
    if document.is_empty()
        || document.len() % 2 != 0
        || !document.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(ArtifactError::Invalid);
    }
    let digest = digest.strip_prefix("0x").ok_or(ArtifactError::Invalid)?;
    let mut bytes = [0u8; 32];
    hex::decode_to_slice(digest, &mut bytes).map_err(|_| ArtifactError::Invalid)?;
    Ok(bytes)
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum CanonicalRequest {
    Settlement(CanonicalSettlementRequest),
    Open(CanonicalOpenRequest),
}

pub const fn enclave_timeout_seconds(request: &CanonicalRequest) -> u64 {
    match request {
        CanonicalRequest::Settlement(_) => 1_100,
        CanonicalRequest::Open(_) => 300,
    }
}

pub const fn parent_timeout_seconds(request: &CanonicalRequest) -> u64 {
    match request {
        CanonicalRequest::Settlement(_) => 1_200,
        CanonicalRequest::Open(_) => 360,
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CanonicalSettlementRequest {
    pub incident_id: String,
    pub registry: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CanonicalOpenRequest {
    pub insured_token: String,
    pub registry: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SettlementApiRequest {
    incident_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OpenApiRequest {
    insured_token: String,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ProtocolError {
    #[error("invalid request JSON")]
    InvalidJson,
    #[error("invalid incidentId")]
    InvalidIncidentId,
    #[error("invalid Registry address")]
    InvalidRegistry,
    #[error("invalid insured token address")]
    InvalidInsuredToken,

    #[error("request Registry does not match the configured Registry")]
    RegistryMismatch,
    #[error("job secret must contain at least 32 bytes")]
    WeakSecret,
    #[error("invalid idempotency key")]
    InvalidIdempotencyKey,
    #[error("invalid job ID")]
    InvalidJobId,
    #[error("invalid chain ID")]
    InvalidChainId,
    #[error("invalid DefiInsurance address")]
    InvalidDefiInsurance,
    #[error("invalid settlement root")]
    InvalidSettlementRoot,
}

pub fn canonicalize_request(
    body: &[u8],
    configured_registry: &str,
) -> Result<CanonicalRequest, ProtocolError> {
    let request: SettlementApiRequest =
        serde_json::from_slice(body).map_err(|_| ProtocolError::InvalidJson)?;
    validate_incident_id(&request.incident_id)?;
    Ok(CanonicalRequest::Settlement(CanonicalSettlementRequest {
        incident_id: request.incident_id,
        registry: normalize_registry(configured_registry)?,
    }))
}

pub fn canonicalize_open_request(
    body: &[u8],
    configured_registry: &str,
) -> Result<CanonicalRequest, ProtocolError> {
    let request: OpenApiRequest =
        serde_json::from_slice(body).map_err(|_| ProtocolError::InvalidJson)?;
    let insured_token = normalize_address(&request.insured_token)
        .map_err(|_| ProtocolError::InvalidInsuredToken)?;
    Ok(CanonicalRequest::Open(CanonicalOpenRequest {
        insured_token,
        registry: normalize_registry(configured_registry)?,
    }))
}

fn validate_incident_id(value: &str) -> Result<(), ProtocolError> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || value.len() > MAX_UINT256.len()
        || (value.len() == MAX_UINT256.len() && value > MAX_UINT256)
    {
        return Err(ProtocolError::InvalidIncidentId);
    }
    Ok(())
}

fn normalize_address(value: &str) -> Result<String, ProtocolError> {
    let Some(hex) = value.strip_prefix("0x") else {
        return Err(ProtocolError::InvalidRegistry);
    };
    if hex.len() != 40 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ProtocolError::InvalidRegistry);
    }
    if hex.bytes().all(|byte| byte == b'0') {
        return Err(ProtocolError::InvalidRegistry);
    }
    Ok(format!("0x{}", hex.to_ascii_lowercase()))
}

fn normalize_registry(value: &str) -> Result<String, ProtocolError> {
    normalize_address(value).map_err(|_| ProtocolError::InvalidRegistry)
}

pub fn derive_job_id(
    secret: &[u8],
    idempotency_key: &str,
    request: &CanonicalRequest,
) -> Result<String, ProtocolError> {
    if secret.len() < 32 {
        return Err(ProtocolError::WeakSecret);
    }
    if idempotency_key.is_empty()
        || idempotency_key.len() > 128
        || !idempotency_key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._:".contains(&byte))
    {
        return Err(ProtocolError::InvalidIdempotencyKey);
    }
    let canonical = serde_json::to_vec(request).map_err(|_| ProtocolError::InvalidJson)?;
    let mut mac = HmacSha256::new_from_slice(secret).map_err(|_| ProtocolError::WeakSecret)?;
    mac.update(JOB_ID_DOMAIN);
    mac.update(idempotency_key.as_bytes());
    mac.update(&[0]);
    mac.update(&canonical);
    let opaque = mac.finalize().into_bytes();
    let commitment = request_commitment(&canonical);
    Ok(format!(
        "{}{}",
        hex::encode(&opaque[..16]),
        hex::encode(commitment)
    ))
}

fn request_commitment(canonical_request: &[u8]) -> [u8; 16] {
    let mut hash = Sha256::new();
    hash.update(REQUEST_COMMITMENT_DOMAIN);
    hash.update(canonical_request);
    let digest = hash.finalize();
    let mut commitment = [0_u8; 16];
    commitment.copy_from_slice(&digest[..16]);
    commitment
}

pub fn verify_job_request_binding(
    job_id: &str,
    request: &CanonicalRequest,
) -> Result<(), ProtocolError> {
    JobPaths::new(job_id)?;
    let canonical = serde_json::to_vec(request).map_err(|_| ProtocolError::InvalidJson)?;
    let expected = request_commitment(&canonical);
    let encoded = hex::decode(job_id).map_err(|_| ProtocolError::InvalidJobId)?;
    if encoded[16..] != expected {
        return Err(ProtocolError::InvalidJobId);
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JobPaths {
    pub request: String,
    pub terminal: String,
}

impl JobPaths {
    pub fn new(job_id: &str) -> Result<Self, ProtocolError> {
        if job_id.len() != 64
            || !job_id
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err(ProtocolError::InvalidJobId);
        }
        Ok(Self {
            request: format!("requests/{job_id}.json"),
            terminal: format!("terminal/{job_id}.json"),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SettlementLocator {
    pub chain_id: u64,
    pub registry: String,
    pub defi_insurance: String,
    pub incident_id: String,
    pub root: String,
}

impl SettlementLocator {
    pub fn new(
        chain_id: u64,
        registry: &str,
        defi_insurance: &str,
        incident_id: &str,
        root: &str,
    ) -> Result<Self, ProtocolError> {
        if chain_id == 0 {
            return Err(ProtocolError::InvalidChainId);
        }
        validate_incident_id(incident_id)?;
        let registry = normalize_registry(registry)?;
        let defi_insurance =
            normalize_address(defi_insurance).map_err(|_| ProtocolError::InvalidDefiInsurance)?;
        let root_hex = root
            .strip_prefix("0x")
            .ok_or(ProtocolError::InvalidSettlementRoot)?;
        if root_hex.len() != 64
            || !root_hex.bytes().all(|byte| byte.is_ascii_hexdigit())
            || root_hex.bytes().all(|byte| byte == b'0')
        {
            return Err(ProtocolError::InvalidSettlementRoot);
        }
        Ok(Self {
            chain_id,
            registry,
            defi_insurance,
            incident_id: incident_id.to_owned(),
            root: format!("0x{}", root_hex.to_ascii_lowercase()),
        })
    }

    pub fn key(&self) -> String {
        format!(
            "settlements/v1/{}/{}/{}/{}/{}.json",
            self.chain_id, self.registry, self.defi_insurance, self.incident_id, self.root
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaunchTemplate {
    region: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkerCapabilities {
    pub request_get_url: String,
    pub signer_get_url: String,
    pub drpc_get_url: String,
    pub terminal_put_url: String,
}

impl LaunchTemplate {
    pub fn new(region: impl Into<String>) -> Result<Self, ServiceError> {
        let region = region.into();
        if !valid_dns_label(&region, 3, 32) {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(Self { region })
    }

    pub fn user_data(
        &self,
        job_id: &str,
        capabilities: &WorkerCapabilities,
    ) -> Result<String, ServiceError> {
        JobPaths::new(job_id).map_err(|_| ServiceError::InvalidRequest)?;
        let request_path = format!("/requests/{job_id}.json");
        let terminal_path = format!("/terminal/{job_id}.json");
        if !valid_capability_url(&capabilities.request_get_url)
            || !valid_capability_url(&capabilities.signer_get_url)
            || !valid_capability_url(&capabilities.drpc_get_url)
            || !valid_capability_url(&capabilities.terminal_put_url)
            || !capabilities.request_get_url.contains(&request_path)
            || !capabilities.terminal_put_url.contains(&terminal_path)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let script = format!(
            "#!/bin/bash\nset -euo pipefail\numask 077\ninstall -d -m 0700 /run/usd8\ncat > /run/usd8/job.env <<'USD8_JOB_ENV'\nUSD8_JOB_ID={job_id}\nAWS_REGION={}\nUSD8_REQUEST_GET_URL_HEX={}\nUSD8_SIGNER_GET_URL_HEX={}\nUSD8_DRPC_GET_URL_HEX={}\nUSD8_TERMINAL_PUT_URL_HEX={}\nUSD8_JOB_ENV\nchmod 0600 /run/usd8/job.env\nsystemctl start usd8-tee-job.service\n",
            self.region,
            hex::encode(&capabilities.request_get_url),
            hex::encode(&capabilities.signer_get_url),
            hex::encode(&capabilities.drpc_get_url),
            hex::encode(&capabilities.terminal_put_url),
        );
        if script.len() > 16 * 1024 {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(script)
    }
}

fn valid_capability_url(value: &str) -> bool {
    value.len() <= 4096
        && value.starts_with("https://")
        && !value.bytes().any(|byte| byte.is_ascii_control())
}

fn valid_dns_label(value: &str, min: usize, max: usize) -> bool {
    value.len() >= min
        && value.len() <= max
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric)
}

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub registry: String,
    pub job_secret: Vec<u8>,
    pub max_result_bytes: usize,
    pub max_inline_result_bytes: usize,
    pub result_url_ttl_seconds: u64,
    pub job_ttl_seconds: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CreateOutcome {
    Created,
    Exists(Vec<u8>),
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum ServiceError {
    #[error("invalid request")]
    InvalidRequest,
    #[error("job not found")]
    NotFound,
    #[error("service unavailable")]
    Unavailable,
    #[error("request write unavailable")]
    RequestWriteUnavailable,
    #[error("request read unavailable")]
    RequestReadUnavailable,
    #[error("request read denied")]
    RequestReadDenied,
    #[error("request read denied: {0}")]
    RequestReadDeniedDetail(String),
    #[error("request read denied by identity policy")]
    RequestReadIdentityDenied,
    #[error("request read explicitly denied")]
    RequestReadExplicitDenied,
    #[error("worker capabilities unavailable")]
    CapabilitiesUnavailable,
    #[error("worker launch unavailable")]
    LaunchUnavailable,
    #[error("worker launch unavailable: {0}")]
    LaunchUnavailableDetail(String),
    #[error("stored job state is invalid")]
    InvalidStoredResult,
}

#[async_trait]
pub trait JobStore: Send + Sync {
    async fn create(&self, key: &str, value: &[u8]) -> Result<CreateOutcome, ServiceError>;
    async fn get(&self, key: &str, max_bytes: usize) -> Result<Option<Vec<u8>>, ServiceError>;
    async fn download_url(&self, key: &str, ttl_seconds: u64) -> Result<String, ServiceError>;
}

#[async_trait]
pub trait InstanceLauncher: Send + Sync {
    /// Must use `job_id` as EC2 RunInstances.ClientToken so retries cannot launch duplicates.
    async fn launch(&self, job_id: &str) -> Result<(), ServiceError>;
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredRequest {
    pub schema_version: u32,
    pub job_id: String,
    pub request: CanonicalRequest,
    pub created_at: u64,
    pub expires_at: u64,
}

pub fn stored_request_is_live(request: &StoredRequest, now: u64) -> bool {
    request.schema_version == STORED_REQUEST_SCHEMA_VERSION
        && request.created_at < request.expires_at
        && now <= request.expires_at
        && JobPaths::new(&request.job_id).is_ok()
        && verify_job_request_binding(&request.job_id, &request.request).is_ok()
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmitOutcome {
    pub accepted: bool,
    pub job_id: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PollOutcome {
    pub job_id: String,
    pub status: String,
    /// Structural validation only; clients must verify signature and attestation.
    pub api_verified: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub download: Option<ResultDownload>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResultDownload {
    pub url: String,
    pub sha256: String,
    pub bytes: usize,
    pub expires_in_seconds: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TerminalEnvelope {
    pub schema_version: u32,
    pub job_id: String,
    pub status: TerminalStatus,
    pub payload: serde_json::Value,
}

impl TerminalEnvelope {
    pub fn completed(job_id: &str, payload: serde_json::Value) -> Self {
        Self {
            schema_version: 1,
            job_id: job_id.to_owned(),
            status: TerminalStatus::Completed,
            payload,
        }
    }

    pub fn failed(job_id: &str, code: &str) -> Self {
        Self {
            schema_version: 1,
            job_id: job_id.to_owned(),
            status: TerminalStatus::Failed,
            payload: serde_json::json!({ "code": code }),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TerminalStatus {
    Completed,
    Failed,
}

fn settlement_locator_from_terminal(
    terminal: &TerminalEnvelope,
    configured_registry: &str,
) -> Result<Option<SettlementLocator>, ServiceError> {
    if terminal.status != TerminalStatus::Completed {
        return Ok(None);
    }
    let Some(artifact) = terminal.payload.get("artifact") else {
        return Ok(None);
    };
    if artifact.get("root").is_none() {
        return Ok(None);
    }
    let attested_digest = extract_attested_digest(artifact, AttestedDigestKind::Settlement)
        .map_err(|_| ServiceError::InvalidStoredResult)?;
    let payload_digest = terminal
        .payload
        .get("digest")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| value.strip_prefix("0x"))
        .ok_or(ServiceError::InvalidStoredResult)?;
    let mut payload_digest_bytes = [0u8; 32];
    hex::decode_to_slice(payload_digest, &mut payload_digest_bytes)
        .map_err(|_| ServiceError::InvalidStoredResult)?;
    if payload_digest_bytes != attested_digest {
        return Err(ServiceError::InvalidStoredResult);
    }
    let signature = terminal
        .payload
        .get("signature")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| value.strip_prefix("0x"))
        .ok_or(ServiceError::InvalidStoredResult)?;
    if signature.len() != 130 || !signature.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ServiceError::InvalidStoredResult);
    }
    let signer = terminal
        .payload
        .get("signer")
        .and_then(serde_json::Value::as_str)
        .ok_or(ServiceError::InvalidStoredResult)?;
    normalize_address(signer).map_err(|_| ServiceError::InvalidStoredResult)?;

    let chain_id = artifact
        .get("chainId")
        .and_then(serde_json::Value::as_u64)
        .ok_or(ServiceError::InvalidStoredResult)?;
    let registry = artifact
        .get("registry")
        .and_then(serde_json::Value::as_str)
        .ok_or(ServiceError::InvalidStoredResult)?;
    let defi_insurance = artifact
        .get("defiInsurance")
        .and_then(serde_json::Value::as_str)
        .ok_or(ServiceError::InvalidStoredResult)?;
    let incident_id = artifact
        .get("incidentId")
        .and_then(serde_json::Value::as_str)
        .ok_or(ServiceError::InvalidStoredResult)?;
    let root = artifact
        .get("root")
        .and_then(serde_json::Value::as_str)
        .ok_or(ServiceError::InvalidStoredResult)?;
    let locator = SettlementLocator::new(chain_id, registry, defi_insurance, incident_id, root)
        .map_err(|_| ServiceError::InvalidStoredResult)?;
    let configured_registry =
        normalize_registry(configured_registry).map_err(|_| ServiceError::InvalidRequest)?;
    if locator.registry != configured_registry {
        return Err(ServiceError::InvalidStoredResult);
    }
    Ok(Some(locator))
}

pub struct App<S, L> {
    config: AppConfig,
    store: Arc<S>,
    launcher: Arc<L>,
}

impl<S: JobStore, L: InstanceLauncher> App<S, L> {
    pub fn new(config: AppConfig, store: Arc<S>, launcher: Arc<L>) -> Result<Self, ServiceError> {
        normalize_registry(&config.registry).map_err(|_| ServiceError::InvalidRequest)?;
        if config.job_secret.len() < 32
            || config.max_result_bytes == 0
            || config.max_inline_result_bytes == 0
            || config.max_inline_result_bytes > config.max_result_bytes
            || !(1..=3600).contains(&config.result_url_ttl_seconds)
            || !(300..=86_400).contains(&config.job_ttl_seconds)
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(Self {
            config,
            store,
            launcher,
        })
    }

    pub async fn submit(
        &self,
        idempotency_key: &str,
        body: &[u8],
    ) -> Result<SubmitOutcome, ServiceError> {
        let request = canonicalize_request(body, &self.config.registry)
            .map_err(|_| ServiceError::InvalidRequest)?;
        self.submit_canonical(idempotency_key, request).await
    }

    pub async fn submit_open(
        &self,
        idempotency_key: &str,
        body: &[u8],
    ) -> Result<SubmitOutcome, ServiceError> {
        let request = canonicalize_open_request(body, &self.config.registry)
            .map_err(|_| ServiceError::InvalidRequest)?;
        self.submit_canonical(idempotency_key, request).await
    }

    async fn submit_canonical(
        &self,
        idempotency_key: &str,
        request: CanonicalRequest,
    ) -> Result<SubmitOutcome, ServiceError> {
        let job_id = derive_job_id(&self.config.job_secret, idempotency_key, &request)
            .map_err(|_| ServiceError::InvalidRequest)?;
        let paths = JobPaths::new(&job_id).map_err(|_| ServiceError::InvalidRequest)?;
        let created_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ServiceError::Unavailable)?
            .as_secs();
        let stored = StoredRequest {
            schema_version: STORED_REQUEST_SCHEMA_VERSION,
            job_id: job_id.clone(),
            request: request.clone(),
            created_at,
            expires_at: created_at.saturating_add(self.config.job_ttl_seconds),
        };
        let bytes = serde_json::to_vec(&stored).map_err(|_| ServiceError::InvalidRequest)?;
        let stored = match self.store.create(&paths.request, &bytes).await? {
            CreateOutcome::Created => stored,
            CreateOutcome::Exists(existing) => serde_json::from_slice::<StoredRequest>(&existing)
                .map_err(|_| ServiceError::InvalidStoredResult)?,
        };
        if stored.schema_version != STORED_REQUEST_SCHEMA_VERSION
            || stored.job_id != job_id
            || stored.request != request
            || stored.expires_at.saturating_sub(stored.created_at) != self.config.job_ttl_seconds
        {
            return Err(ServiceError::InvalidStoredResult);
        }
        if self
            .store
            .get(&paths.terminal, self.config.max_result_bytes)
            .await?
            .is_some()
        {
            return Ok(SubmitOutcome {
                accepted: true,
                job_id,
            });
        }
        if created_at > stored.expires_at {
            return Ok(SubmitOutcome {
                accepted: true,
                job_id,
            });
        }
        self.launcher.launch(&job_id).await?;
        Ok(SubmitOutcome {
            accepted: true,
            job_id,
        })
    }

    pub async fn poll(&self, job_id: &str) -> Result<PollOutcome, ServiceError> {
        let paths = JobPaths::new(job_id).map_err(|_| ServiceError::InvalidRequest)?;
        let terminal = self
            .store
            .get(&paths.terminal, self.config.max_result_bytes)
            .await?;
        let bytes = match terminal {
            Some(bytes) => bytes,
            None => {
                let request = self
                    .store
                    .get(&paths.request, self.config.max_result_bytes)
                    .await?
                    .ok_or(ServiceError::NotFound)?;
                let stored: StoredRequest = serde_json::from_slice(&request)
                    .map_err(|_| ServiceError::InvalidStoredResult)?;
                if stored.schema_version != STORED_REQUEST_SCHEMA_VERSION
                    || stored.job_id != job_id
                    || verify_job_request_binding(job_id, &stored.request).is_err()
                    || stored.expires_at.saturating_sub(stored.created_at)
                        != self.config.job_ttl_seconds
                {
                    return Err(ServiceError::InvalidStoredResult);
                }
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(|_| ServiceError::Unavailable)?
                    .as_secs();
                return Ok(PollOutcome {
                    job_id: job_id.to_owned(),
                    status: if now > stored.expires_at {
                        "expired"
                    } else {
                        "pending"
                    }
                    .to_owned(),
                    api_verified: false,
                    payload: None,
                    download: None,
                });
            }
        };
        let terminal = self.parse_terminal(&bytes, Some(job_id))?;
        self.publish_settlement(&paths, &bytes, &terminal).await?;
        self.terminal_outcome(&paths.terminal, bytes, terminal)
            .await
    }

    pub async fn settlement(
        &self,
        chain_id: u64,
        registry: &str,
        defi_insurance: &str,
        incident_id: &str,
        root: &str,
    ) -> Result<PollOutcome, ServiceError> {
        let locator = SettlementLocator::new(chain_id, registry, defi_insurance, incident_id, root)
            .map_err(|_| ServiceError::InvalidRequest)?;
        if locator.registry
            != normalize_registry(&self.config.registry)
                .map_err(|_| ServiceError::InvalidRequest)?
        {
            return Err(ServiceError::InvalidRequest);
        }
        let key = locator.key();
        let bytes = self
            .store
            .get(&key, self.config.max_result_bytes)
            .await?
            .ok_or(ServiceError::NotFound)?;
        let terminal = self.parse_terminal(&bytes, None)?;
        if terminal.status != TerminalStatus::Completed
            || settlement_locator_from_terminal(&terminal, &self.config.registry)? != Some(locator)
        {
            return Err(ServiceError::InvalidStoredResult);
        }
        self.terminal_outcome(&key, bytes, terminal).await
    }

    fn parse_terminal(
        &self,
        bytes: &[u8],
        expected_job_id: Option<&str>,
    ) -> Result<TerminalEnvelope, ServiceError> {
        if bytes.len() > self.config.max_result_bytes {
            return Err(ServiceError::InvalidStoredResult);
        }
        let terminal: TerminalEnvelope =
            serde_json::from_slice(bytes).map_err(|_| ServiceError::InvalidStoredResult)?;
        if terminal.schema_version != 1
            || expected_job_id.is_some_and(|job_id| terminal.job_id != job_id)
            || JobPaths::new(&terminal.job_id).is_err()
            || !terminal.payload.is_object()
        {
            return Err(ServiceError::InvalidStoredResult);
        }
        Ok(terminal)
    }

    async fn publish_settlement(
        &self,
        paths: &JobPaths,
        bytes: &[u8],
        terminal: &TerminalEnvelope,
    ) -> Result<(), ServiceError> {
        let Some(locator) = settlement_locator_from_terminal(terminal, &self.config.registry)?
        else {
            return Ok(());
        };
        let request_bytes = self
            .store
            .get(&paths.request, self.config.max_result_bytes)
            .await?
            .ok_or(ServiceError::InvalidStoredResult)?;
        let stored: StoredRequest = serde_json::from_slice(&request_bytes)
            .map_err(|_| ServiceError::InvalidStoredResult)?;
        let request_matches = matches!(
            &stored.request,
            CanonicalRequest::Settlement(request)
                if request.incident_id == locator.incident_id
                    && request.registry == locator.registry
        );
        if stored.schema_version != STORED_REQUEST_SCHEMA_VERSION
            || stored.job_id != terminal.job_id
            || verify_job_request_binding(&stored.job_id, &stored.request).is_err()
            || !request_matches
        {
            return Err(ServiceError::InvalidStoredResult);
        }

        let key = locator.key();
        if let CreateOutcome::Exists(existing) = self.store.create(&key, bytes).await? {
            let existing_terminal = self.parse_terminal(&existing, None)?;
            if existing_terminal.status != TerminalStatus::Completed
                || settlement_locator_from_terminal(&existing_terminal, &self.config.registry)?
                    != Some(locator)
            {
                return Err(ServiceError::InvalidStoredResult);
            }
        }
        Ok(())
    }

    async fn terminal_outcome(
        &self,
        key: &str,
        bytes: Vec<u8>,
        terminal: TerminalEnvelope,
    ) -> Result<PollOutcome, ServiceError> {
        let status = match terminal.status {
            TerminalStatus::Completed => "completed",
            TerminalStatus::Failed => "failed",
        };
        let job_id = terminal.job_id;
        let (payload, download) = if bytes.len() <= self.config.max_inline_result_bytes {
            (Some(terminal.payload), None)
        } else {
            let url = self
                .store
                .download_url(key, self.config.result_url_ttl_seconds)
                .await?;
            (
                None,
                Some(ResultDownload {
                    url,
                    sha256: hex::encode(Sha256::digest(&bytes)),
                    bytes: bytes.len(),
                    expires_in_seconds: self.config.result_url_ttl_seconds,
                }),
            )
        };
        Ok(PollOutcome {
            job_id,
            status: status.to_owned(),
            api_verified: false,
            payload,
            download,
        })
    }
}
