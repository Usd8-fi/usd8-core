use usd8_tee_job_api::{LaunchTemplate, ServiceError, WorkerCapabilities};

fn capabilities(job_id: &str) -> WorkerCapabilities {
    WorkerCapabilities {
        request_get_url: format!("https://jobs.example/requests/{job_id}.json?sig=request"),
        signer_get_url: "https://jobs.example/secrets/signer.bin?sig=signer".to_owned(),
        drpc_get_url: "https://jobs.example/secrets/drpc.bin?sig=drpc".to_owned(),
        terminal_put_url: format!("https://jobs.example/terminal/{job_id}.json?sig=terminal"),
    }
}

#[test]
fn bootstrap_contains_only_exact_job_capabilities() {
    let job_id = "a".repeat(64);
    let other_job_id = "b".repeat(64);
    let template = LaunchTemplate::new("eu-central-1").unwrap();
    let script = template.user_data(&job_id, &capabilities(&job_id)).unwrap();
    assert!(script.starts_with("#!/bin/bash\nset -euo pipefail\numask 077\n"));
    assert!(script.contains("USD8_JOB_ID=aaaaaaaa"));
    assert!(script.contains("AWS_REGION=eu-central-1"));
    assert!(!script.contains("USD8_JOB_BUCKET"));
    assert!(!script.contains(&other_job_id));
    for url in [
        capabilities(&job_id).request_get_url,
        capabilities(&job_id).signer_get_url,
        capabilities(&job_id).drpc_get_url,
        capabilities(&job_id).terminal_put_url,
    ] {
        assert!(script.contains(&hex::encode(url)));
    }
    assert!(script.contains("systemctl start usd8-tee-job.service"));
    assert!(!script.contains("curl"));
    assert!(!script.contains("ssh"));
}

#[test]
fn bootstrap_rejects_invalid_region_job_id_and_capability_urls() {
    assert_eq!(
        LaunchTemplate::new("eu-central-1;id").unwrap_err(),
        ServiceError::InvalidRequest
    );
    let template = LaunchTemplate::new("eu-central-1").unwrap();
    assert_eq!(
        template
            .user_data("../escape", &capabilities(&"a".repeat(64)))
            .unwrap_err(),
        ServiceError::InvalidRequest
    );
    let job_id = "a".repeat(64);
    for invalid in [
        "http://jobs.example/request",
        "https://jobs.example/request\nUSD8_JOB_ID=evil",
        "not-a-url",
    ] {
        let mut caps = capabilities(&job_id);
        caps.request_get_url = invalid.to_owned();
        assert_eq!(
            template.user_data(&job_id, &caps).unwrap_err(),
            ServiceError::InvalidRequest
        );
    }

    let mut oversized = capabilities(&job_id);
    let padding = "x".repeat(2_200);
    oversized.request_get_url.push_str(&padding);
    oversized.signer_get_url.push_str(&padding);
    oversized.drpc_get_url.push_str(&padding);
    oversized.terminal_put_url.push_str(&padding);
    assert_eq!(
        template.user_data(&job_id, &oversized).unwrap_err(),
        ServiceError::InvalidRequest
    );
}
