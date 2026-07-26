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
use std::sync::Arc;
use std::time::Duration;
use usd8_tee_job_api::{
    App, AppConfig, CreateOutcome, InstanceLauncher, JobPaths, JobStore, LaunchTemplate,
    ServiceError, WorkerCapabilities,
};

const MAX_REQUEST_BYTES: usize = 4096;
const CAPABILITY_BOOT_MARGIN_SECONDS: u64 = 900;
const MAX_S3_PRESIGN_TTL_SECONDS: u64 = 604_800;
const SIGNER_OBJECT: &str = "secrets/signer.bin";
const DRPC_OBJECT: &str = "secrets/drpc.bin";

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
            Err(_) => match self.get(key, MAX_REQUEST_BYTES).await? {
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
        ServiceError::RequestReadDeniedDetail(detail) => {
            return json_response(
                503,
                &serde_json::json!({ "error": "REQUEST_READ_DENIED", "detail": detail }),
            );
        }
        ServiceError::LaunchUnavailableDetail(detail) => {
            return json_response(
                503,
                &serde_json::json!({ "error": "WORKER_LAUNCH_UNAVAILABLE", "detail": detail }),
            );
        }
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

async fn handle(
    app: Arc<App<S3Store, Ec2Launcher>>,
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
                    app.submit_open(key, request.body().as_ref()).await
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
        match path
            .strip_prefix("/jobs/")
            .filter(|job_id| !job_id.contains('/'))
        {
            Some(job_id) => app.poll(job_id).await.and_then(|value| {
                json_response(200, &value).map_err(|_| ServiceError::Unavailable)
            }),
            None => Err(ServiceError::InvalidRequest),
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
    let app = Arc::new(App::new(
        AppConfig {
            registry: required("USD8_REGISTRY")?,
            job_secret: secret,
            max_result_bytes: 16 * 1024 * 1024,
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
    lambda_http::run(service_fn(move |request| handle(app.clone(), request))).await
}

#[cfg(test)]
mod tests {
    use super::capability_ttl_seconds;

    #[test]
    fn capability_ttl_outlives_maximum_job_lifetime() {
        let ttl = capability_ttl_seconds(86_400).unwrap();
        assert!(ttl > 86_400);
        assert!(ttl <= 604_800);
    }
}
