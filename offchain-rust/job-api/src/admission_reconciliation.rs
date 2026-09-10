//! Bounded EC2 no-live-instance proof (not a janitor and not a TTL release).
//!
//! SAFETY CONTRACT: the immutable launch deadline is checked immediately before
//! every RunInstances send; only this trusted Lambda role launches the JobId, in
//! this account/region, and its invocation cannot survive 900 seconds. JobId tags
//! cannot be removed/reassigned by workers; privileged administrators are trusted.
//! The operator-supplied ambiguity bound covers remaining SDK/network/service
//! acceptance after invocation death, eventual visibility of ALL accepted live
//! instances, and clock skew. Inventory must be authoritative and complete across
//! pages. AWS documents eventual consistency, NOT a guaranteed finite SLA: do not
//! enable negative proofs without accepting/establishing these assumptions.
//! SDK timeouts bound client work but do not prove server-side cancellation.
//!
//! Only a scan STARTED strictly after deadline + 900 + bound can accept empty
//! inventory, including never-launched slots and aged-out terminated instances.
//! All nonterminated/unknown states, errors, cycles and incomplete scans fail
//! closed. The absence of new launches after the fence makes cleanup CAS races
//! safe: a losing writer must reread; the immutable old JobId cannot launch again.
//! Tests use the real AWS SDK against a loopback Query API.
use aws_sdk_ec2::Client;
use usd8_tee_job_api::ServiceError;

pub async fn no_active_instances(
    client: &Client,
    job_id: &str,
    launch_until: u64,
    now: u64,
    ambiguity_seconds: Option<u64>,
) -> Result<bool, ServiceError> {
    usd8_tee_job_api::JobPaths::new(job_id).map_err(|_| ServiceError::InvalidRequest)?;
    let Some(bound) = ambiguity_seconds.filter(|bound| *bound > 0) else {
        return Ok(false);
    };
    let Some(fence) = launch_until
        .checked_add(900)
        .and_then(|v| v.checked_add(bound))
    else {
        return Ok(false);
    };
    if now <= fence {
        return Ok(false);
    }
    tokio::time::timeout(std::time::Duration::from_secs(10), async {
        let mut token = None;
        let mut seen_tokens = std::collections::HashSet::new();
        // Bound work and fail closed rather than treating a truncated inventory
        // as complete. The filter is repeated on EVERY page; no state filter.
        for _ in 0..32 {
            let output = client
                .describe_instances()
                .filters(
                    aws_sdk_ec2::types::Filter::builder()
                        .name("tag:JobId")
                        .values(job_id)
                        .build(),
                )
                .max_results(1000)
                .set_next_token(token)
                .send()
                .await
                .map_err(|_| ServiceError::Unavailable)?;
            for instance in output.reservations().iter().flat_map(|r| r.instances()) {
                if instance.instance_id().is_none_or(|id| id.is_empty())
                    || instance.state().and_then(|s| s.name())
                        != Some(&aws_sdk_ec2::types::InstanceStateName::Terminated)
                    || !instance
                        .tags()
                        .iter()
                        .any(|tag| tag.key() == Some("JobId") && tag.value() == Some(job_id))
                {
                    return Ok(false);
                }
            }
            match output.next_token() {
                None => return Ok(true),
                Some(next) if !next.is_empty() && seen_tokens.insert(next.to_owned()) => {
                    token = Some(next.to_owned())
                }
                Some(_) => return Err(ServiceError::Unavailable),
            }
        }
        Err(ServiceError::Unavailable)
    })
    .await
    .map_err(|_| ServiceError::Unavailable)?
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const JOB: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    async fn ec2(pages: Vec<(u16, String)>) -> (Client, tokio::task::JoinHandle<Vec<String>>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let mut requests = Vec::new();
            for (status, body) in pages {
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
                requests.push(String::from_utf8(bytes).unwrap());
                let response = format!(
                    "HTTP/1.1 {status} Test\r\nContent-Type: text/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).await.unwrap();
            }
            requests
        });
        let config = aws_sdk_ec2::Config::builder()
            .behavior_version(aws_config::BehaviorVersion::latest())
            .region(aws_sdk_ec2::config::Region::new("eu-central-1"))
            .credentials_provider(aws_sdk_ec2::config::Credentials::new(
                "test", "test", None, None, "test",
            ))
            .endpoint_url(format!("http://{addr}"))
            .retry_config(aws_sdk_ec2::config::retry::RetryConfig::standard().with_max_attempts(1))
            .build();
        (Client::from_conf(config), server)
    }

    fn page(instances: &str, next: &str) -> String {
        format!(
            "<DescribeInstancesResponse xmlns=\"http://ec2.amazonaws.com/doc/2016-11-15/\"><requestId>test</requestId><reservationSet>{instances}</reservationSet>{next}</DescribeInstancesResponse>"
        )
    }

    fn instance(state: &str, job: &str) -> String {
        format!(
            "<item><instancesSet><item><instanceId>i-test</instanceId><instanceState><name>{state}</name></instanceState><tagSet><item><key>JobId</key><value>{job}</value></item></tagSet></item></instancesSet></item>"
        )
    }

    #[tokio::test]
    async fn paginated_terminated_inventory_recovers() {
        let (client, server) = ec2(vec![
            (
                200,
                page(
                    &instance("terminated", JOB),
                    "<nextToken>page-two</nextToken>",
                ),
            ),
            (200, page(&instance("terminated", JOB), "")),
        ])
        .await;
        assert!(
            no_active_instances(&client, JOB, 100, 1301, Some(300))
                .await
                .unwrap()
        );
        let requests = server.await.unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[1].contains("NextToken=page-two"));
        assert!(
            requests
                .iter()
                .all(|r| r.contains("tag%3AJobId") && r.contains(JOB))
        );
    }

    #[tokio::test]
    async fn running_on_later_page_and_unknown_or_mismatched_state_fail_closed() {
        for (state, job) in [
            ("running", JOB),
            ("pending", JOB),
            ("stopped", JOB),
            ("shutting-down", JOB),
            ("future-state", JOB),
            ("", JOB),
            ("terminated", "other"),
        ] {
            let (client, server) = ec2(vec![
                (200, page("", "<nextToken>page-two</nextToken>")),
                (200, page(&instance(state, job), "")),
            ])
            .await;
            assert!(
                !no_active_instances(&client, JOB, 100, 1301, Some(300))
                    .await
                    .unwrap()
            );
            assert_eq!(server.await.unwrap().len(), 2);
        }
    }

    #[tokio::test]
    async fn missing_bound_zero_bound_overflow_and_delayed_prelaunch_fail_closed() {
        let (client, server) = ec2(vec![]).await;
        for (deadline, now, bound) in [
            (100, u64::MAX, None),
            (100, 1301, Some(0)),
            (u64::MAX, u64::MAX, Some(300)),
            (100, 999, Some(300)),
            (100, 1200, Some(300)),
        ] {
            assert!(
                !no_active_instances(&client, JOB, deadline, now, bound)
                    .await
                    .unwrap()
            );
        }
        assert!(server.await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn partial_inventory_errors_or_repeated_tokens_never_prove_absence() {
        for last in [
            (
                503,
                "<Response><Errors><Error><Code>Unavailable</Code></Error></Errors></Response>"
                    .to_string(),
            ),
            (200, page("", "<nextToken>page-two</nextToken>")),
            (200, "not xml".to_string()),
        ] {
            let (client, server) = ec2(vec![
                (200, page("", "<nextToken>page-two</nextToken>")),
                last,
            ])
            .await;
            assert!(
                no_active_instances(&client, JOB, 100, 1301, Some(300))
                    .await
                    .is_err()
            );
            assert_eq!(server.await.unwrap().len(), 2);
        }
    }

    #[tokio::test]
    async fn never_launched_or_aged_out_recovers_only_after_fence() {
        let (client, server) = ec2(vec![(200, page("", ""))]).await;
        // 100 immutable deadline + 900 Lambda lifetime + 300 trusted ambiguity bound.
        assert!(
            !no_active_instances(&client, JOB, 100, 1300, Some(300))
                .await
                .unwrap()
        );
        assert!(
            no_active_instances(&client, JOB, 100, 1301, Some(300))
                .await
                .unwrap()
        );
        let requests = server.await.unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0].contains("Action=DescribeInstances"));
        assert!(requests[0].contains(JOB));
        assert!(requests[0].contains("tag%3AJobId"));
    }
}
