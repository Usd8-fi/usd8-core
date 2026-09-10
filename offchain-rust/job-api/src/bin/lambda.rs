#[path = "../admission_reconciliation.rs"]
mod admission_reconciliation;

use async_trait::async_trait;
use aws_sdk_ec2::types::{
    EnclaveOptionsRequest, HttpTokensState, IamInstanceProfileSpecification,
    InstanceMetadataEndpointState, InstanceMetadataTagsState,
    InstanceNetworkInterfaceSpecification, InstanceType, ResourceType, ShutdownBehavior, Tag,
    TagSpecification,
};
use aws_sdk_s3::error::ProvideErrorMetadata;
use aws_sdk_s3::presigning::PresigningConfig;
use aws_sdk_s3::primitives::ByteStream;
use aws_types::region::Region;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use lambda_http::{Body, Error, Request, Response, service_fn};
use std::env;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;
use usd8_settlement::Address;
use usd8_settlement::incident_open::{
    IncidentOpenError, IncidentOpenPrecheck, precheck_incident_open,
};
use usd8_settlement::rpc::HttpRpc;
use usd8_tee_job_api::{
    App, AppConfig, CanonicalRequest, CreateOutcome, InstanceLauncher, JobPaths, JobStore,
    LaunchTemplate, ServiceError, SettlementLocator, WorkerCapabilities, canonicalize_open_request,
};

const MAX_REQUEST_BYTES: usize = 4096;
const MAX_STORED_RESULT_BYTES: usize = 16 * 1024 * 1024;
const CAPABILITY_BOOT_MARGIN_SECONDS: u64 = 900;
const MAX_S3_PRESIGN_TTL_SECONDS: u64 = 604_800;
const SIGNER_OBJECT: &str = "secrets/signer.bin";
const DRPC_OBJECT: &str = "secrets/drpc.bin";
const PRECHECK_TIMEOUT_SECONDS: u64 = 24;

fn create_conflict_read_limit(key: &str) -> usize {
    if key.starts_with("settlements/") || key.starts_with("control/completions/") {
        MAX_STORED_RESULT_BYTES
    } else {
        MAX_REQUEST_BYTES
    }
}

struct OpenPrechecker {
    rpc: HttpRpc,
    registry: Address,
    configured_registry: String,
}

impl OpenPrechecker {
    async fn check(&self, body: &[u8]) -> Result<IncidentOpenPrecheck, OpenPrecheckError> {
        let request = canonicalize_open_request(body, &self.configured_registry)
            .map_err(|_| OpenPrecheckError::InvalidRequest)?;
        let CanonicalRequest::Open(request) = request else {
            return Err(OpenPrecheckError::InvalidRequest);
        };
        let insured_token = Address::from_str(&request.insured_token)
            .map_err(|_| OpenPrecheckError::InvalidRequest)?;
        tokio::time::timeout(
            Duration::from_secs(PRECHECK_TIMEOUT_SECONDS),
            precheck_incident_open(&self.rpc, self.registry, insured_token),
        )
        .await
        .map_err(|_| OpenPrecheckError::Unavailable)?
        .map_err(OpenPrecheckError::Incident)
    }
}

fn open_job_key(precheck: &IncidentOpenPrecheck) -> String {
    format!(
        "open:{}:{}",
        precheck.insured_token, precheck.reference_block
    )
}

#[derive(Debug)]
enum OpenPrecheckError {
    InvalidRequest,
    Incident(IncidentOpenError),
    Unavailable,
}

/// Constant-size, finalized admission check: no event replay or historical scan.
/// The enclave remains authoritative and recomputes all settlement inputs.
async fn settlement_preflight<R: usd8_settlement::rpc::Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    module: Address,
    incident_id: &str,
) -> Result<(), ServiceError> {
    use usd8_settlement::chain::{
        block_by_number, chain_id, defi_insurance_at, finalized_block, incident_at,
        incident_claim_deadline_at,
    };
    if chain_id(rpc).await.map_err(|_| ServiceError::Unavailable)?
        != usd8_tee_job_api::configured_chain_id()
    {
        return Err(ServiceError::Unavailable);
    }
    let head = finalized_block(rpc)
        .await
        .map_err(|_| ServiceError::Unavailable)?;
    if defi_insurance_at(rpc, registry, Some(head.number))
        .await
        .map_err(|_| ServiceError::Unavailable)?
        != module
    {
        return Err(ServiceError::Unavailable);
    }
    let id = incident_id
        .parse()
        .map_err(|_| ServiceError::InvalidRequest)?;
    let incident = incident_at(rpc, module, id, Some(head.number))
        .await
        .map_err(|_| ServiceError::Unavailable)?;
    if incident.insured_token.is_zero() {
        return Err(ServiceError::NotFound);
    }
    if incident.open_block > head.number || incident.reference_block > head.number {
        return Err(ServiceError::Unavailable);
    }
    let open = block_by_number(rpc, incident.open_block)
        .await
        .map_err(|_| ServiceError::Unavailable)?;
    let id = incident_id
        .parse()
        .map_err(|_| ServiceError::InvalidRequest)?;
    let deadline = incident_claim_deadline_at(rpc, module, &id, incident.open_block)
        .await
        .map_err(|_| ServiceError::Unavailable)?;
    let window = deadline
        .checked_sub(open.timestamp)
        .filter(|window| *window > 0)
        .ok_or(ServiceError::Unavailable)?;
    let settlement_deadline = deadline
        .checked_add(window)
        .ok_or(ServiceError::Unavailable)?;
    let unsettled = incident.root == format!("0x{}", "00".repeat(32));
    if head.timestamp <= deadline || (unsettled && head.timestamp > settlement_deadline) {
        return Err(ServiceError::SettlementNotEligible);
    }
    // Already-settled incidents may reconstruct their artifact after the phase
    // closes; do not confuse recovery with a new on-chain settlement attempt.
    if block_by_number(rpc, head.number)
        .await
        .map_err(|_| ServiceError::Unavailable)?
        != head
        || block_by_number(rpc, open.number)
            .await
            .map_err(|_| ServiceError::Unavailable)?
            != open
    {
        return Err(ServiceError::Unavailable);
    }
    Ok(())
}

struct S3Store {
    client: aws_sdk_s3::Client,
    bucket: String,
}

#[async_trait]
impl JobStore for S3Store {
    async fn get_versioned(
        &self,
        key: &str,
        max_bytes: usize,
    ) -> Result<Option<usd8_tee_job_api::VersionedObject>, ServiceError> {
        let output = match self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
        {
            Ok(output) => output,
            Err(error) if error.as_service_error().is_some_and(|e| e.is_no_such_key()) => {
                return Ok(None);
            }
            Err(_) => return Err(ServiceError::RequestReadUnavailable),
        };
        let revision = output
            .e_tag()
            .filter(|etag| !etag.is_empty())
            .ok_or(ServiceError::InvalidStoredResult)?
            .to_owned();
        if output
            .content_length()
            .is_some_and(|n| n < 0 || n as usize > max_bytes)
        {
            return Err(ServiceError::InvalidStoredResult);
        }
        // Bound actual streamed bytes as well as the declared Content-Length.
        use tokio::io::AsyncReadExt;
        let mut bytes = Vec::new();
        output
            .body
            .into_async_read()
            .take(max_bytes as u64 + 1)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| ServiceError::RequestReadUnavailable)?;
        if bytes.len() > max_bytes {
            return Err(ServiceError::InvalidStoredResult);
        }
        Ok(Some(usd8_tee_job_api::VersionedObject { bytes, revision }))
    }

    async fn compare_exchange(
        &self,
        key: &str,
        revision: Option<&str>,
        value: &[u8],
    ) -> Result<bool, ServiceError> {
        let put = self
            .client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .content_type("application/json")
            .body(ByteStream::from(value.to_vec()));
        let put = match revision {
            Some(etag) => put.if_match(etag),
            None => put.if_none_match("*"),
        };
        match put.send().await {
            Ok(_) => Ok(true),
            Err(error)
                if error
                    .raw_response()
                    .is_some_and(|response| matches!(response.status().as_u16(), 409 | 412)) =>
            {
                Ok(false)
            }
            // Ambiguous writes are NOT treated as ownership. A subsequent read
            // and CAS can recover; never launch on a transport failure.
            Err(_) => Err(ServiceError::RequestWriteUnavailable),
        }
    }

    async fn create(&self, key: &str, value: &[u8]) -> Result<CreateOutcome, ServiceError> {
        let put = self
            .client
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .content_type("application/json")
            .if_none_match("*")
            .body(ByteStream::from(value.to_vec()))
            .send()
            .await;
        match put {
            Ok(_) => Ok(CreateOutcome::Created),
            Err(_) => match self.get(key, create_conflict_read_limit(key)).await? {
                Some(existing) => Ok(CreateOutcome::Exists(existing)),
                None => Err(ServiceError::RequestWriteUnavailable),
            },
        }
    }

    async fn get(&self, key: &str, max_bytes: usize) -> Result<Option<Vec<u8>>, ServiceError> {
        let output = match self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
        {
            Ok(output) => output,
            Err(error)
                if error
                    .as_service_error()
                    .is_some_and(|error| error.is_no_such_key()) =>
            {
                return Ok(None);
            }
            Err(error)
                if error
                    .as_service_error()
                    .is_some_and(|error| error.code() == Some("AccessDenied")) =>
            {
                let message = error
                    .as_service_error()
                    .and_then(|error| error.message())
                    .unwrap_or_default();
                if !message.is_empty() {
                    return Err(ServiceError::RequestReadDeniedDetail(message.to_owned()));
                }
                if message.contains("no identity-based policy") {
                    return Err(ServiceError::RequestReadIdentityDenied);
                }
                if message.contains("explicit deny") {
                    return Err(ServiceError::RequestReadExplicitDenied);
                }
                return Err(ServiceError::RequestReadDenied);
            }
            Err(_) => return Err(ServiceError::RequestReadUnavailable),
        };
        if output
            .content_length()
            .is_some_and(|length| length < 0 || length as usize > max_bytes)
        {
            return Err(ServiceError::InvalidStoredResult);
        }
        let bytes = output
            .body
            .collect()
            .await
            .map_err(|_| ServiceError::RequestReadUnavailable)?
            .into_bytes();
        if bytes.len() > max_bytes {
            return Err(ServiceError::InvalidStoredResult);
        }
        Ok(Some(bytes.to_vec()))
    }

    async fn download_url(&self, key: &str, ttl_seconds: u64) -> Result<String, ServiceError> {
        let config = PresigningConfig::expires_in(Duration::from_secs(ttl_seconds))
            .map_err(|_| ServiceError::Unavailable)?;
        let request = self
            .client
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .presigned(config)
            .await
            .map_err(|_| ServiceError::Unavailable)?;
        Ok(request.uri().to_string())
    }
}

struct Ec2Launcher {
    client: aws_sdk_ec2::Client,
    precheck_rpc: HttpRpc,
    registry: Address,
    module: Address,
    s3: aws_sdk_s3::Client,
    bucket: String,
    image_id: String,
    instance_type: String,
    instance_profile: String,
    subnet_id: String,
    security_group_id: String,
    launch_template: LaunchTemplate,
    capability_ttl_seconds: u64,
    ec2_ambiguity_seconds: Option<u64>,
}

fn capability_ttl_seconds(job_ttl_seconds: u64) -> Result<u64, ServiceError> {
    job_ttl_seconds
        .checked_add(CAPABILITY_BOOT_MARGIN_SECONDS)
        .filter(|ttl| *ttl <= MAX_S3_PRESIGN_TTL_SECONDS)
        .ok_or(ServiceError::InvalidRequest)
}

impl Ec2Launcher {
    // Called by the admission trait hook with the immutable ledger deadline.
    async fn reconcile_reservation(
        &self,
        job_id: &str,
        launch_until: u64,
        now: u64,
    ) -> Result<bool, ServiceError> {
        if self.ec2_ambiguity_seconds.is_none() {
            // No claimed visibility bound: retain the conservative legacy mode.
            if now <= launch_until.saturating_add(900) {
                return Ok(false);
            }
            return self.is_terminated(job_id).await;
        }
        admission_reconciliation::no_active_instances(
            &self.client,
            job_id,
            launch_until,
            now,
            self.ec2_ambiguity_seconds,
        )
        .await
    }

    async fn presign_get(&self, key: &str) -> Result<String, ServiceError> {
        let config = PresigningConfig::expires_in(Duration::from_secs(self.capability_ttl_seconds))
            .map_err(|_| ServiceError::CapabilitiesUnavailable)?;
        self.s3
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .presigned(config)
            .await
            .map(|request| request.uri().to_string())
            .map_err(|_| ServiceError::CapabilitiesUnavailable)
    }

    async fn presign_terminal_put(&self, key: &str) -> Result<String, ServiceError> {
        let config = PresigningConfig::expires_in(Duration::from_secs(self.capability_ttl_seconds))
            .map_err(|_| ServiceError::CapabilitiesUnavailable)?;
        self.s3
            .put_object()
            .bucket(&self.bucket)
            .key(key)
            .content_type("application/json")
            .if_none_match("*")
            .presigned(config)
            .await
            .map(|request| request.uri().to_string())
            .map_err(|_| ServiceError::CapabilitiesUnavailable)
    }

    async fn new_capabilities(&self, job_id: &str) -> Result<WorkerCapabilities, ServiceError> {
        let paths = JobPaths::new(job_id).map_err(|_| ServiceError::InvalidRequest)?;
        Ok(WorkerCapabilities {
            request_get_url: self.presign_get(&paths.request).await?,
            signer_get_url: self.presign_get(SIGNER_OBJECT).await?,
            drpc_get_url: self.presign_get(DRPC_OBJECT).await?,
            terminal_put_url: self.presign_terminal_put(&paths.terminal).await?,
        })
    }

    async fn capabilities(&self, job_id: &str) -> Result<WorkerCapabilities, ServiceError> {
        let key = format!("launch/{job_id}.json");
        let capabilities = self.new_capabilities(job_id).await?;
        let body =
            serde_json::to_vec(&capabilities).map_err(|_| ServiceError::CapabilitiesUnavailable)?;
        let created = self
            .s3
            .put_object()
            .bucket(&self.bucket)
            .key(&key)
            .content_type("application/json")
            .if_none_match("*")
            .body(ByteStream::from(body))
            .send()
            .await;
        if created.is_ok() {
            return Ok(capabilities);
        }
        let existing = self
            .s3
            .get_object()
            .bucket(&self.bucket)
            .key(key)
            .send()
            .await
            .map_err(|_| ServiceError::CapabilitiesUnavailable)?
            .body
            .collect()
            .await
            .map_err(|_| ServiceError::CapabilitiesUnavailable)?
            .into_bytes();
        if existing.len() > 20_000 {
            return Err(ServiceError::InvalidStoredResult);
        }
        serde_json::from_slice(&existing).map_err(|_| ServiceError::InvalidStoredResult)
    }
}

#[async_trait]
impl InstanceLauncher for Ec2Launcher {
    async fn can_release_reservation(
        &self,
        job_id: &str,
        launch_until: u64,
        now: u64,
    ) -> Result<bool, ServiceError> {
        self.reconcile_reservation(job_id, launch_until, now).await
    }

    async fn precheck(&self, request: &CanonicalRequest) -> Result<(), ServiceError> {
        let CanonicalRequest::Settlement(request) = request else {
            return Ok(());
        };
        if Address::from_str(&request.registry).map_err(|_| ServiceError::InvalidRequest)?
            != self.registry
        {
            return Err(ServiceError::InvalidRequest);
        }
        tokio::time::timeout(
            Duration::from_secs(PRECHECK_TIMEOUT_SECONDS),
            settlement_preflight(
                &self.precheck_rpc,
                self.registry,
                self.module,
                &request.incident_id,
            ),
        )
        .await
        .map_err(|_| ServiceError::Unavailable)?
    }

    async fn is_terminated(&self, job_id: &str) -> Result<bool, ServiceError> {
        JobPaths::new(job_id).map_err(|_| ServiceError::InvalidRequest)?;
        let output = tokio::time::timeout(
            Duration::from_secs(10),
            self.client
                .describe_instances()
                .filters(
                    aws_sdk_ec2::types::Filter::builder()
                        .name("tag:JobId")
                        .values(job_id)
                        .build(),
                )
                .send(),
        )
        .await
        .map_err(|_| ServiceError::Unavailable)?
        .map_err(|_| ServiceError::Unavailable)?;
        // Refuse partial or negative inventories: a missing instance is not proof
        // of termination, including after an ambiguous RunInstances response.
        if output.next_token().is_some() {
            return Ok(false);
        }
        let instances: Vec<_> = output
            .reservations()
            .iter()
            .flat_map(|r| r.instances())
            .collect();
        Ok(!instances.is_empty()
            && instances.iter().all(|instance| {
                instance.state().and_then(|s| s.name())
                    == Some(&aws_sdk_ec2::types::InstanceStateName::Terminated)
                    && instance
                        .tags()
                        .iter()
                        .any(|tag| tag.key() == Some("JobId") && tag.value() == Some(job_id))
            }))
    }

    async fn launch(&self, _job_id: &str) -> Result<(), ServiceError> {
        // Production callers must supply the immutable attempt launch horizon.
        Err(ServiceError::InvalidRequest)
    }

    async fn launch_before(&self, job_id: &str, deadline: u64) -> Result<(), ServiceError> {
        let now = || {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|time| time.as_secs())
                .map_err(|_| ServiceError::Unavailable)
        };
        if now()? >= deadline {
            return Err(ServiceError::LaunchUnavailable);
        }
        let capabilities = self.capabilities(job_id).await?;
        let user_data = self.launch_template.user_data(job_id, &capabilities)?;
        let network = InstanceNetworkInterfaceSpecification::builder()
            .device_index(0)
            .associate_public_ip_address(true)
            .delete_on_termination(true)
            .subnet_id(&self.subnet_id)
            .groups(&self.security_group_id)
            .build();
        let tags = TagSpecification::builder()
            .resource_type(ResourceType::Instance)
            .tags(Tag::builder().key("Project").value("USD8-TEE").build())
            .tags(Tag::builder().key("JobId").value(job_id).build())
            .build();
        if now()? >= deadline {
            return Err(ServiceError::LaunchUnavailable);
        }
        let output = self
            .client
            .run_instances()
            .image_id(&self.image_id)
            .instance_type(InstanceType::from(self.instance_type.as_str()))
            .min_count(1)
            .max_count(1)
            .client_token(job_id)
            .instance_initiated_shutdown_behavior(ShutdownBehavior::Terminate)
            .enclave_options(EnclaveOptionsRequest::builder().enabled(true).build())
            .iam_instance_profile(
                IamInstanceProfileSpecification::builder()
                    .name(&self.instance_profile)
                    .build(),
            )
            .metadata_options(
                aws_sdk_ec2::types::InstanceMetadataOptionsRequest::builder()
                    .http_endpoint(InstanceMetadataEndpointState::Enabled)
                    .http_tokens(HttpTokensState::Required)
                    .http_put_response_hop_limit(1)
                    .instance_metadata_tags(InstanceMetadataTagsState::Disabled)
                    .build(),
            )
            .network_interfaces(network)
            .tag_specifications(tags)
            .user_data(BASE64.encode(user_data))
            .send()
            .await
            .map_err(|error| {
                let detail = error
                    .as_service_error()
                    .and_then(|error| error.message())
                    .unwrap_or("EC2 RunInstances transport failure")
                    .to_owned();
                ServiceError::LaunchUnavailableDetail(detail)
            })?;
        if output.instances().len() != 1 || output.instances()[0].instance_id().is_none() {
            return Err(ServiceError::LaunchUnavailable);
        }
        Ok(())
    }
}

fn required(name: &str) -> Result<String, Error> {
    env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing required environment variable: {name}").into())
}

fn json_response(status: u16, value: &impl serde::Serialize) -> Result<Response<Body>, Error> {
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("cache-control", "no-store")
        .body(Body::Text(serde_json::to_string(value)?))?)
}

fn error_response(error: ServiceError) -> Result<Response<Body>, Error> {
    let (status, code) = match error {
        ServiceError::RequestReadDeniedDetail(_) => (503, "REQUEST_READ_DENIED"),
        ServiceError::LaunchUnavailableDetail(_) => (503, "WORKER_LAUNCH_UNAVAILABLE"),
        ServiceError::InvalidRequest => (400, "INVALID_REQUEST"),
        ServiceError::NotFound => (404, "NOT_FOUND"),
        ServiceError::AdmissionLimited => (429, "WORKER_BUDGET_EXHAUSTED"),
        ServiceError::SettlementNotEligible => (422, "SETTLEMENT_NOT_ELIGIBLE"),
        ServiceError::Unavailable => (503, "UNAVAILABLE"),
        ServiceError::RequestWriteUnavailable => (503, "REQUEST_WRITE_UNAVAILABLE"),
        ServiceError::RequestReadUnavailable => (503, "REQUEST_READ_UNAVAILABLE"),
        ServiceError::RequestReadDenied => (503, "REQUEST_READ_DENIED"),
        ServiceError::RequestReadIdentityDenied => (503, "REQUEST_READ_IDENTITY_DENIED"),
        ServiceError::RequestReadExplicitDenied => (503, "REQUEST_READ_EXPLICIT_DENIED"),
        ServiceError::CapabilitiesUnavailable => (503, "CAPABILITIES_UNAVAILABLE"),
        ServiceError::LaunchUnavailable => (503, "WORKER_LAUNCH_UNAVAILABLE"),
        ServiceError::InvalidStoredResult => (500, "INVALID_JOB_STATE"),
    };
    json_response(status, &serde_json::json!({ "error": code }))
}

fn precheck_error_response(error: OpenPrecheckError) -> Result<Response<Body>, Error> {
    let (status, code) = match error {
        OpenPrecheckError::InvalidRequest => (400, "INVALID_REQUEST"),
        OpenPrecheckError::Incident(IncidentOpenError::InsufficientPriceDrop { .. }) => {
            (422, "PRICE_DROP_NOT_DETECTED")
        }
        OpenPrecheckError::Incident(IncidentOpenError::ActiveIncident) => {
            (409, "INCIDENT_ALREADY_ACTIVE")
        }
        OpenPrecheckError::Incident(IncidentOpenError::UnapprovedToken) => {
            (400, "UNAPPROVED_TOKEN")
        }
        OpenPrecheckError::Incident(_) | OpenPrecheckError::Unavailable => {
            (503, "PRICE_PRECHECK_UNAVAILABLE")
        }
    };
    json_response(status, &serde_json::json!({ "error": code }))
}

fn parse_settlement_route(path: &str) -> Result<SettlementLocator, ServiceError> {
    let mut segments = path
        .strip_prefix("/settlements/")
        .ok_or(ServiceError::InvalidRequest)?
        .split('/');
    let chain_id = segments
        .next()
        .ok_or(ServiceError::InvalidRequest)?
        .parse::<u64>()
        .map_err(|_| ServiceError::InvalidRequest)?;
    let registry = segments.next().ok_or(ServiceError::InvalidRequest)?;
    let defi_insurance = segments.next().ok_or(ServiceError::InvalidRequest)?;
    let incident_id = segments.next().ok_or(ServiceError::InvalidRequest)?;
    let root = segments.next().ok_or(ServiceError::InvalidRequest)?;
    if segments.next().is_some() {
        return Err(ServiceError::InvalidRequest);
    }
    SettlementLocator::new(chain_id, registry, defi_insurance, incident_id, root)
        .map_err(|_| ServiceError::InvalidRequest)
}

async fn handle(
    app: Arc<App<S3Store, Ec2Launcher>>,
    open_prechecker: Arc<OpenPrechecker>,
    request: Request,
) -> Result<Response<Body>, Error> {
    let method = request.method().as_str();
    let path = request.uri().path();
    let outcome = if method == "POST" && matches!(path, "/jobs" | "/jobs/settlement" | "/jobs/open")
    {
        let key = request
            .headers()
            .get("idempotency-key")
            .and_then(|value| value.to_str().ok())
            .ok_or(ServiceError::InvalidRequest);
        match key {
            Ok(key) if request.body().as_ref().len() <= MAX_REQUEST_BYTES => {
                let submitted = if path == "/jobs/open" {
                    let precheck = match open_prechecker.check(request.body().as_ref()).await {
                        Ok(precheck) => precheck,
                        Err(error) => {
                            eprintln!("incident-open precheck failed: {error:?}");
                            return precheck_error_response(error);
                        }
                    };
                    app.submit_open(&open_job_key(&precheck), request.body().as_ref())
                        .await
                } else {
                    app.submit(key, request.body().as_ref()).await
                };
                submitted.and_then(|value| {
                    json_response(202, &value).map_err(|_| ServiceError::Unavailable)
                })
            }
            Ok(_) | Err(_) => Err(ServiceError::InvalidRequest),
        }
    } else if method == "GET" {
        if path.starts_with("/settlements/") {
            match parse_settlement_route(path) {
                Ok(locator) => app
                    .settlement(
                        locator.chain_id,
                        &locator.registry,
                        &locator.defi_insurance,
                        &locator.incident_id,
                        &locator.root,
                    )
                    .await
                    .and_then(|value| {
                        json_response(200, &value).map_err(|_| ServiceError::Unavailable)
                    }),
                Err(error) => Err(error),
            }
        } else {
            match path
                .strip_prefix("/jobs/")
                .filter(|job_id| !job_id.contains('/'))
            {
                Some(job_id) => app.poll(job_id).await.and_then(|value| {
                    json_response(200, &value).map_err(|_| ServiceError::Unavailable)
                }),
                None => Err(ServiceError::InvalidRequest),
            }
        }
    } else {
        return json_response(404, &serde_json::json!({ "error": "NOT_FOUND" }));
    };
    match outcome {
        Ok(response) => Ok(response),
        Err(error) => error_response(error),
    }
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    let region = required("AWS_REGION")?;
    let bucket = required("USD8_JOB_BUCKET")?;
    let secret = BASE64
        .decode(required("USD8_JOB_HMAC_KEY_B64")?)
        .map_err(|_| "USD8_JOB_HMAC_KEY_B64 is not valid base64")?;
    let job_ttl_seconds = env::var("USD8_TEE_MAX_AGE_SECONDS")
        .unwrap_or_else(|_| "1800".to_owned())
        .parse::<u64>()?;
    let capability_ttl_seconds = capability_ttl_seconds(job_ttl_seconds)?;
    let sdk = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(Region::new(region.clone()))
        .load()
        .await;
    let registry = required("USD8_REGISTRY")?;
    let open_prechecker = Arc::new(OpenPrechecker {
        rpc: HttpRpc::new_with_retry_delay(
            &required("USD8_PRECHECK_RPC_URL")?,
            None,
            3_000,
            1,
            100,
        )?,
        registry: Address::from_str(&registry).map_err(|_| "USD8_REGISTRY is invalid")?,
        configured_registry: registry.clone(),
    });
    let defi_insurance = required("USD8_DEFI_INSURANCE")?;
    let admission_policy = usd8_tee_job_api::AdmissionPolicy {
        // Explicit 0 selects cost-only admission; positive values retain the
        // conservative, fenced EC2 reconciliation policy. Configuration remains required.
        max_active_workers: required("USD8_MAX_ACTIVE_WORKERS")?.parse()?,
        max_starts_per_hour: required("USD8_MAX_STARTS_PER_HOUR")?.parse()?,
    };
    let completion_verifier = Arc::new(
        usd8_tee_job_api::completion_verifier::RpcCompletionVerifier::new(
            HttpRpc::new_with_retry_delay(
                &required("USD8_PRECHECK_RPC_URL")?,
                None,
                3_000,
                1,
                100,
            )?,
            usd8_tee_job_api::settlement_verifier::PromotionPolicy {
                chain_id: usd8_tee_job_api::configured_chain_id(),
                registry: open_prechecker.registry,
                defi_insurance: Address::from_str(&defi_insurance)
                    .map_err(|_| "USD8_DEFI_INSURANCE is invalid")?,
            },
            std::time::Duration::from_secs(12),
        )?,
    );
    let app = Arc::new(
        App::new(
            AppConfig {
                registry,
                defi_insurance: defi_insurance.clone(),
                job_secret: secret,
                max_result_bytes: MAX_STORED_RESULT_BYTES,
                max_inline_result_bytes: 5 * 1024 * 1024,
                result_url_ttl_seconds: 300,
                job_ttl_seconds,
            },
            Arc::new(S3Store {
                client: aws_sdk_s3::Client::new(&sdk),
                bucket: bucket.clone(),
            }),
            Arc::new(Ec2Launcher {
                client: aws_sdk_ec2::Client::from_conf(
                    aws_sdk_ec2::config::Builder::from(&sdk)
                        .retry_config(
                            aws_sdk_ec2::config::retry::RetryConfig::standard()
                                .with_max_attempts(2),
                        )
                        .timeout_config(
                            aws_sdk_ec2::config::timeout::TimeoutConfig::builder()
                                .operation_timeout(Duration::from_secs(30))
                                .operation_attempt_timeout(Duration::from_secs(10))
                                .build(),
                        )
                        .build(),
                ),
                precheck_rpc: HttpRpc::new_with_retry_delay(
                    &required("USD8_PRECHECK_RPC_URL")?,
                    None,
                    3_000,
                    1,
                    100,
                )?,
                registry: open_prechecker.registry,
                module: Address::from_str(&defi_insurance)
                    .map_err(|_| "USD8_DEFI_INSURANCE is invalid")?,
                s3: aws_sdk_s3::Client::new(&sdk),
                bucket,
                image_id: required("USD8_TEE_AMI_ID")?,
                instance_type: required("USD8_TEE_INSTANCE_TYPE")?,
                instance_profile: required("USD8_TEE_INSTANCE_PROFILE")?,
                subnet_id: required("USD8_TEE_SUBNET_ID")?,
                security_group_id: required("USD8_TEE_SECURITY_GROUP_ID")?,
                launch_template: LaunchTemplate::new(region)?,
                capability_ttl_seconds,
                // Explicit operator attestation; AWS does not publish a hard
                // eventual-visibility bound. Absent => positive evidence only.
                ec2_ambiguity_seconds: env::var("USD8_EC2_RECONCILIATION_BOUND_SECONDS")
                    .ok()
                    .map(|value| value.parse::<u64>())
                    .transpose()?
                    .map(|value| {
                        if value > 0 {
                            Ok(value)
                        } else {
                            Err("EC2 reconciliation bound must be positive")
                        }
                    })
                    .transpose()?,
            }),
        )?
        .with_admission_policy(admission_policy)?
        .with_completion_verifier(completion_verifier),
    );
    lambda_http::run(service_fn(move |request| {
        handle(app.clone(), open_prechecker.clone(), request)
    }))
    .await
}

#[cfg(test)]
mod tests {
    async fn local_s3(
        response: impl Into<String>,
    ) -> (super::S3Store, tokio::task::JoinHandle<String>, String) {
        local_s3_responses(vec![response.into()]).await
    }

    async fn local_s3_responses(
        responses: Vec<String>,
    ) -> (super::S3Store, tokio::task::JoinHandle<String>, String) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let mut requests = String::new();
            for response in responses {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new();
                loop {
                    let mut buf = [0; 4096];
                    let n = stream.read(&mut buf).await.unwrap();
                    if n == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&buf[..n]);
                    if let Some(end) = bytes.windows(4).position(|b| b == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&bytes[..end]).to_ascii_lowercase();
                        let length = headers
                            .lines()
                            .find_map(|line| {
                                line.strip_prefix("content-length:")
                                    .and_then(|v| v.trim().parse::<usize>().ok())
                            })
                            .unwrap_or(0);
                        if bytes.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                stream.write_all(response.as_bytes()).await.unwrap();
                requests.push_str(&String::from_utf8(bytes).unwrap().to_ascii_lowercase());
            }
            requests
        });
        let config = aws_sdk_s3::Config::builder()
            .behavior_version(aws_config::BehaviorVersion::latest())
            .region(aws_types::region::Region::new("eu-central-1"))
            .credentials_provider(aws_sdk_s3::config::Credentials::new(
                "test", "test", None, None, "test",
            ))
            .endpoint_url(format!("http://{address}"))
            .force_path_style(true)
            .retry_config(aws_sdk_s3::config::retry::RetryConfig::standard().with_max_attempts(1))
            .build();
        (
            super::S3Store {
                client: aws_sdk_s3::Client::from_conf(config),
                bucket: "test-bucket".into(),
            },
            server,
            format!("http://{address}"),
        )
    }

    #[tokio::test]
    async fn s3_durable_completion_conflicts_read_large_exact_bytes() {
        use usd8_tee_job_api::{CreateOutcome, JobStore};
        let body = "x".repeat(8192);
        let (store, server, _) = local_s3_responses(vec![
            "HTTP/1.1 412 Precondition Failed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .into(),
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            ),
        ])
        .await;
        let result = store.create("control/completions/job.json", b"{}").await;
        let requests = server.await.unwrap();
        assert!(requests.contains("put /test-bucket/control/completions/job.json"));
        assert!(requests.contains("get /test-bucket/control/completions/job.json"));
        assert!(requests.contains("if-none-match: *"));
        assert!(matches!(result, Ok(CreateOutcome::Exists(bytes)) if bytes == body.as_bytes()));
        assert_eq!(
            super::create_conflict_read_limit("control/completions/job.json"),
            16 * 1024 * 1024
        );
    }

    #[tokio::test]
    async fn s3_completion_conflict_limits_reject_oversized_results_and_requests() {
        use usd8_tee_job_api::JobStore;
        for (key, cap) in [
            ("control/completions/job.json", 16 * 1024 * 1024),
            ("control/completion-requests/job.json", 4096),
        ] {
            assert_eq!(super::create_conflict_read_limit(key), cap);
            let (store, server, _) = local_s3_responses(vec![
                "HTTP/1.1 412 Precondition Failed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
                format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", cap + 1),
            ]).await;
            assert!(matches!(
                store.create(key, b"{}").await,
                Err(ServiceError::InvalidStoredResult)
            ));
            assert!(
                server
                    .await
                    .unwrap()
                    .contains(&format!("get /test-bucket/{key}"))
            );
        }
    }

    fn test_launcher(store: super::S3Store, endpoint: &str) -> super::Ec2Launcher {
        let config = aws_sdk_ec2::Config::builder()
            .behavior_version(aws_config::BehaviorVersion::latest())
            .region(aws_types::region::Region::new("eu-central-1"))
            .credentials_provider(aws_sdk_ec2::config::Credentials::new(
                "test", "test", None, None, "test",
            ))
            .endpoint_url(endpoint)
            .retry_config(aws_sdk_ec2::config::retry::RetryConfig::standard().with_max_attempts(1))
            .build();
        super::Ec2Launcher {
            client: aws_sdk_ec2::Client::from_conf(config),
            precheck_rpc: super::HttpRpc::new_with_retry_delay(endpoint, None, 3_000, 0, 0)
                .unwrap(),
            registry: "0x1111111111111111111111111111111111111111"
                .parse()
                .unwrap(),
            module: "0x2222222222222222222222222222222222222222"
                .parse()
                .unwrap(),
            s3: store.client,
            bucket: store.bucket,
            image_id: "ami-test".into(),
            instance_type: "m6i.xlarge".into(),
            instance_profile: "test".into(),
            subnet_id: "subnet-test".into(),
            security_group_id: "sg-test".into(),
            launch_template: usd8_tee_job_api::LaunchTemplate::new("eu-central-1").unwrap(),
            capability_ttl_seconds: 2700,
            ec2_ambiguity_seconds: Some(300),
        }
    }

    #[tokio::test]
    async fn production_reclamation_requires_positive_exact_job_termination() {
        use usd8_tee_job_api::InstanceLauncher;
        let body = "<DescribeInstancesResponse xmlns=\"http://ec2.amazonaws.com/doc/2016-11-15/\"><reservationSet><item><instancesSet><item><instanceId>i-test</instanceId><instanceState><code>48</code><name>terminated</name></instanceState><tagSet><item><key>JobId</key><value>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</value></item></tagSet></item></instancesSet></item></reservationSet></DescribeInstancesResponse>";
        for (body, expected) in [
            (body.to_owned(), true),
            (body.replace("terminated", "running"), false),
            (body.replace(&"a".repeat(64), &"b".repeat(64)), false),
            ("<DescribeInstancesResponse xmlns=\"http://ec2.amazonaws.com/doc/2016-11-15/\"><reservationSet/></DescribeInstancesResponse>".to_owned(), false),
        ] {
            let response = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            let (store, server, endpoint) = local_s3(response).await;
            let launcher = test_launcher(store, &endpoint);
            assert_eq!(launcher.is_terminated(&"a".repeat(64)).await.unwrap(), expected);
            let request = server.await.unwrap();
            assert!(request.contains("describeinstances"));
            assert!(request.contains("tag%3ajobid"));
        }
    }

    #[tokio::test]
    async fn production_empty_inventory_needs_explicit_bound_and_strict_fence() {
        use usd8_tee_job_api::InstanceLauncher;
        let body = "<DescribeInstancesResponse xmlns=\"http://ec2.amazonaws.com/doc/2016-11-15/\"><reservationSet/></DescribeInstancesResponse>";
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let (store, server, endpoint) = local_s3(response).await;
        let launcher = test_launcher(store, &endpoint);
        assert!(
            !launcher
                .can_release_reservation(&"a".repeat(64), 100, 1300)
                .await
                .unwrap()
        );
        assert!(!server.is_finished());
        assert!(
            launcher
                .can_release_reservation(&"a".repeat(64), 100, 1301)
                .await
                .unwrap()
        );
        assert!(server.await.unwrap().contains("describeinstances"));
    }

    #[tokio::test]
    async fn production_absent_bound_keeps_empty_inventory_reserved() {
        use usd8_tee_job_api::InstanceLauncher;
        let body = "<DescribeInstancesResponse xmlns=\"http://ec2.amazonaws.com/doc/2016-11-15/\"><reservationSet/></DescribeInstancesResponse>";
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let (store, server, endpoint) = local_s3(response).await;
        let mut launcher = test_launcher(store, &endpoint);
        launcher.ec2_ambiguity_seconds = None;
        assert!(
            !launcher
                .can_release_reservation(&"a".repeat(64), 100, 100_000)
                .await
                .unwrap()
        );
        assert!(server.await.unwrap().contains("describeinstances"));
    }

    #[tokio::test]
    async fn expired_launch_deadline_stops_before_capability_or_ec2_io() {
        use usd8_tee_job_api::InstanceLauncher;
        let (store, server, endpoint) =
            local_s3("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
        let launcher = test_launcher(store, &endpoint);
        assert!(launcher.launch_before(&"a".repeat(64), 0).await.is_err());
        assert!(
            !server.is_finished(),
            "expired attempt must not touch S3 or EC2"
        );
        server.abort();
    }

    #[tokio::test]
    async fn s3_cas_create_and_transient_failures_are_not_confused_with_ownership() {
        use usd8_tee_job_api::JobStore;
        for (status, expected) in [
            (200, Ok(true)),
            (409, Ok(false)),
            (500, Err(ServiceError::RequestWriteUnavailable)),
        ] {
            let response =
                format!("HTTP/1.1 {status} Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            let (store, server, _) = local_s3(response).await;
            assert_eq!(
                store
                    .compare_exchange("control/work/test.json", None, b"{}")
                    .await,
                expected
            );
            let request = server.await.unwrap();
            assert!(request.contains("if-none-match: *"));
            assert!(!request.contains("if-match:"));
        }
        let (store, server, _) =
            local_s3("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
        assert!(matches!(
            store.get_versioned("control/test", 10).await,
            Err(ServiceError::InvalidStoredResult)
        ));
        server.await.unwrap();
        let (store, server, _) = local_s3("HTTP/1.1 200 OK\r\nContent-Length: 20\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n01234567890123456789").await;
        assert!(matches!(
            store.get_versioned("control/test", 10).await,
            Err(ServiceError::InvalidStoredResult)
        ));
        server.await.unwrap();
    }

    struct PreflightRpc {
        exists: bool,
        settled: bool,
        finalized_time: u64,
        wrong_module: bool,
        wrong_chain: bool,
        calls: std::sync::atomic::AtomicUsize,
    }
    #[async_trait::async_trait]
    impl usd8_settlement::rpc::Rpc for PreflightRpc {
        async fn request(
            &self,
            method: &str,
            params: serde_json::Value,
        ) -> Result<serde_json::Value, usd8_settlement::rpc::RpcError> {
            use sha3::{Digest, Keccak256};
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let registry = "0x1111111111111111111111111111111111111111";
            match method {
                "eth_chainId" => Ok(serde_json::json!(format!(
                    "0x{:x}",
                    if self.wrong_chain {
                        999
                    } else {
                        usd8_tee_job_api::configured_chain_id()
                    }
                ))),
                "eth_getBlockByNumber" => {
                    let open = params[0] == "0xa";
                    Ok(
                        serde_json::json!({"number": if open { "0xa" } else { "0x64" }, "timestamp": format!("0x{:x}", if open { 1000 } else { self.finalized_time }), "hash": format!("0x{}", if open { "11" } else { "22" }.repeat(32))}),
                    )
                }
                "eth_call" if params[0]["to"] == registry => Ok(serde_json::json!(format!(
                    "0x{}{}",
                    "00".repeat(12),
                    if self.wrong_module { "33" } else { "22" }.repeat(20)
                ))),
                "eth_call" => {
                    let data = params[0]["data"].as_str().unwrap();
                    if data.starts_with(&format!(
                        "0x{}",
                        hex::encode(&Keccak256::digest(b"incidents(uint256)")[..4])
                    )) {
                        let mut words = vec!["00".repeat(32); 10];
                        if self.exists {
                            words[0] = format!("{}{}", "00".repeat(12), "33".repeat(20));
                        }
                        words[2] = format!("{:064x}", 5);
                        words[3] = format!("{:064x}", 10);
                        words[4] = format!("{:064x}", 1100);
                        if self.settled {
                            words[5] = "44".repeat(32);
                        }
                        Ok(serde_json::json!(format!("0x{}", words.concat())))
                    } else {
                        Ok(serde_json::json!(format!("0x{:064x}", 100)))
                    }
                }
                _ => panic!("unexpected preflight method {method}"),
            }
        }
        fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
            Default::default()
        }
    }

    #[tokio::test]
    async fn settlement_preflight_is_pinned_bounded_and_preserves_settled_recovery() {
        for (exists, settled, time, wrong_module, wrong_chain, allowed) in [
            (true, false, 1101, false, false, true),
            (false, false, 1101, false, false, false),
            (true, false, 1100, false, false, false),
            (true, false, 1201, false, false, false),
            (true, true, 1400, false, false, true),
            (true, false, 1101, true, false, false),
            (true, false, 1101, false, true, false),
        ] {
            let rpc = PreflightRpc {
                exists,
                settled,
                finalized_time: time,
                wrong_module,
                wrong_chain,
                calls: Default::default(),
            };
            let result = super::settlement_preflight(
                &rpc,
                "0x1111111111111111111111111111111111111111"
                    .parse()
                    .unwrap(),
                "0x2222222222222222222222222222222222222222"
                    .parse()
                    .unwrap(),
                "7",
            )
            .await;
            assert_eq!(
                result.is_ok(),
                allowed,
                "exists={exists}, settled={settled}, time={time}: {result:?}"
            );
            assert!(rpc.calls.load(std::sync::atomic::Ordering::SeqCst) <= 10);
        }
    }

    #[tokio::test]
    async fn durable_s3_cas_uses_exact_etag_and_reports_contention() {
        use usd8_tee_job_api::JobStore;
        let (store, server, _endpoint) = local_s3("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nETag: \"revision-1\"\r\nConnection: close\r\n\r\n{}").await;
        let object = store
            .get_versioned("control/work/test.json", 4096)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(object.revision, "\"revision-1\"");
        assert_eq!(object.bytes, b"{}");
        assert!(
            server
                .await
                .unwrap()
                .starts_with("get /test-bucket/control/work/test.json")
        );
        let (store, server, _endpoint) = local_s3(
            "HTTP/1.1 412 Precondition Failed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert!(
            !store
                .compare_exchange("control/work/test.json", Some(&object.revision), b"{}")
                .await
                .unwrap()
        );
        let request = server.await.unwrap();
        assert!(request.contains("if-match: \"revision-1\""));
        assert!(!request.contains("if-none-match:"));
    }

    use super::{
        OpenPrecheckError, capability_ttl_seconds, create_conflict_read_limit, error_response,
        open_job_key, parse_settlement_route, precheck_error_response,
    };
    use lambda_http::Body;
    use usd8_settlement::incident_open::{IncidentOpenError, IncidentOpenPrecheck};
    use usd8_tee_job_api::ServiceError;

    #[test]
    fn capability_ttl_outlives_maximum_job_lifetime() {
        let ttl = capability_ttl_seconds(86_400).unwrap();
        assert!(ttl > 86_400);
        assert!(ttl <= 604_800);
    }

    #[test]
    fn settlement_route_uses_public_chain_incident_and_root_identity() {
        let locator = parse_settlement_route(
            "/settlements/11155111/0x1111111111111111111111111111111111111111/0x2222222222222222222222222222222222222222/7/0x3333333333333333333333333333333333333333333333333333333333333333",
        )
        .unwrap();
        assert_eq!(locator.chain_id, 11_155_111);
        assert_eq!(locator.incident_id, "7");
        assert_eq!(
            locator.root,
            "0x3333333333333333333333333333333333333333333333333333333333333333"
        );
    }

    #[test]
    fn settlement_create_conflicts_can_read_the_complete_existing_artifact() {
        assert_eq!(
            create_conflict_read_limit("settlements/v1/11155111/registry/module/7/root.json"),
            16 * 1024 * 1024
        );
        assert_eq!(create_conflict_read_limit("requests/job.json"), 4_096);
    }

    #[test]
    fn price_drop_rejection_is_safe_and_specific() {
        let response = precheck_error_response(OpenPrecheckError::Incident(
            IncidentOpenError::InsufficientPriceDrop {
                minimum_drop_bps: 2_000,
            },
        ))
        .unwrap();
        assert_eq!(response.status(), 422);
        assert_eq!(
            response.body(),
            &Body::Text(r#"{"error":"PRICE_DROP_NOT_DETECTED"}"#.to_owned())
        );
    }

    #[test]
    fn aws_service_details_are_not_returned_to_public_callers() {
        for (error, code) in [
            (
                ServiceError::RequestReadDeniedDetail(
                    "denied for arn:aws:iam::123456789012:role/private".to_owned(),
                ),
                "REQUEST_READ_DENIED",
            ),
            (
                ServiceError::LaunchUnavailableDetail(
                    "subnet subnet-private in account 123456789012".to_owned(),
                ),
                "WORKER_LAUNCH_UNAVAILABLE",
            ),
        ] {
            let response = error_response(error).unwrap();
            assert_eq!(response.status(), 503);
            assert_eq!(
                response.body(),
                &Body::Text(format!(r#"{{"error":"{code}"}}"#))
            );
        }
    }

    #[test]
    fn successful_prechecks_share_one_job_per_token_and_reference_block() {
        let precheck = IncidentOpenPrecheck {
            chain_id: 11_155_111,
            registry: "0x1111111111111111111111111111111111111111".to_owned(),
            defi_insurance: "0x2222222222222222222222222222222222222222".to_owned(),
            insured_token: "0x3333333333333333333333333333333333333333".to_owned(),
            reference_block: 12_345_678,
            observation_block: 12_352_878,
            baseline_twap: "100".to_owned(),
            distress_twap: "79".to_owned(),
            sample_count: 24,
            twap_blocks: 7_200,
            sample_step_blocks: 300,
            minimum_drop_bps: 2_000,
        };
        assert_eq!(
            open_job_key(&precheck),
            "open:0x3333333333333333333333333333333333333333:12345678"
        );
    }
}
