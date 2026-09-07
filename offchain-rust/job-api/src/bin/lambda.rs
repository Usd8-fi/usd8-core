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
    if key.starts_with("settlements/") {
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

struct S3Store {
    client: aws_sdk_s3::Client,
    bucket: String,
}

#[async_trait]
impl JobStore for S3Store {
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
    s3: aws_sdk_s3::Client,
    bucket: String,
    image_id: String,
    instance_type: String,
    instance_profile: String,
    subnet_id: String,
    security_group_id: String,
    launch_template: LaunchTemplate,
    capability_ttl_seconds: u64,
}

fn capability_ttl_seconds(job_ttl_seconds: u64) -> Result<u64, ServiceError> {
    job_ttl_seconds
        .checked_add(CAPABILITY_BOOT_MARGIN_SECONDS)
        .filter(|ttl| *ttl <= MAX_S3_PRESIGN_TTL_SECONDS)
        .ok_or(ServiceError::InvalidRequest)
}

impl Ec2Launcher {
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
    async fn launch(&self, job_id: &str) -> Result<(), ServiceError> {
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
    let app = Arc::new(App::new(
        AppConfig {
            registry,
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
            client: aws_sdk_ec2::Client::new(&sdk),
            s3: aws_sdk_s3::Client::new(&sdk),
            bucket,
            image_id: required("USD8_TEE_AMI_ID")?,
            instance_type: required("USD8_TEE_INSTANCE_TYPE")?,
            instance_profile: required("USD8_TEE_INSTANCE_PROFILE")?,
            subnet_id: required("USD8_TEE_SUBNET_ID")?,
            security_group_id: required("USD8_TEE_SECURITY_GROUP_ID")?,
            launch_template: LaunchTemplate::new(region)?,
            capability_ttl_seconds,
        }),
    )?);
    lambda_http::run(service_fn(move |request| {
        handle(app.clone(), open_prechecker.clone(), request)
    }))
    .await
}

#[cfg(test)]
mod tests {
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
