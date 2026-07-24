use aws_sdk_ec2::types::Filter;
use aws_types::region::Region;
use lambda_runtime::{Error, LambdaEvent, service_fn};
use serde_json::{Value, json};
use std::env;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use usd8_tee_job_api::is_expired;

struct Janitor {
    ec2: aws_sdk_ec2::Client,
    ttl_secs: i64,
}

impl Janitor {
    async fn run(&self) -> Result<usize, Error> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as i64;
        let mut next_token = None;
        let mut terminated = 0;
        loop {
            let output = self
                .ec2
                .describe_instances()
                .filters(
                    Filter::builder()
                        .name("tag:Project")
                        .values("USD8-TEE")
                        .build(),
                )
                .filters(
                    Filter::builder()
                        .name("instance-state-name")
                        .values("pending")
                        .values("running")
                        .values("stopping")
                        .values("stopped")
                        .build(),
                )
                .set_next_token(next_token)
                .send()
                .await?;
            let ids = output
                .reservations()
                .iter()
                .flat_map(|reservation| reservation.instances())
                .filter(|instance| {
                    instance
                        .launch_time()
                        .is_some_and(|time| is_expired(time.secs(), now, self.ttl_secs))
                })
                .filter_map(|instance| instance.instance_id().map(str::to_owned))
                .collect::<Vec<_>>();
            if !ids.is_empty() {
                self.ec2
                    .terminate_instances()
                    .set_instance_ids(Some(ids.clone()))
                    .send()
                    .await?;
                terminated += ids.len();
            }
            next_token = output.next_token().map(str::to_owned);
            if next_token.is_none() {
                break;
            }
        }
        Ok(terminated)
    }
}

async fn handle(janitor: Arc<Janitor>, _event: LambdaEvent<Value>) -> Result<Value, Error> {
    let terminated = janitor.run().await?;
    Ok(json!({"terminated": terminated}))
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    let region = env::var("AWS_REGION")?;
    let ttl_secs = env::var("USD8_TEE_MAX_AGE_SECONDS")
        .unwrap_or_else(|_| "1800".to_owned())
        .parse::<i64>()?;
    if !(300..=86_400).contains(&ttl_secs) {
        return Err("USD8_TEE_MAX_AGE_SECONDS must be between 300 and 86400".into());
    }
    let sdk = aws_config::defaults(aws_config::BehaviorVersion::latest())
        .region(Region::new(region))
        .load()
        .await;
    let janitor = Arc::new(Janitor {
        ec2: aws_sdk_ec2::Client::new(&sdk),
        ttl_secs,
    });
    lambda_runtime::run(service_fn(move |event| handle(janitor.clone(), event))).await
}

#[cfg(test)]
mod tests {
    use lambda_runtime::{Context, LambdaEvent};
    use serde_json::{Value, json};

    #[test]
    fn scheduled_event_uses_lambda_runtime_eventbridge_envelope() {
        let event: LambdaEvent<Value> = LambdaEvent::new(
            json!({"source": "aws.events", "detail-type": "Scheduled Event"}),
            Context::default(),
        );
        assert_eq!(event.payload["source"], "aws.events");
    }
}
