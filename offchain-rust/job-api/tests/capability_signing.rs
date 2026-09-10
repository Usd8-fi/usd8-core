#![cfg(feature = "lambda")]

use aws_sdk_s3::config::Credentials;
use aws_sdk_s3::presigning::PresigningConfig;
use aws_types::region::Region;
use std::time::Duration;

#[tokio::test]
async fn terminal_capability_binds_exact_key_and_create_only_headers() {
    let config = aws_sdk_s3::Config::builder()
        .behavior_version(aws_config::BehaviorVersion::latest())
        .region(Region::new("eu-central-1"))
        .credentials_provider(Credentials::new(
            "test-access-key",
            "test-secret-key",
            Some("test-session-token".to_owned()),
            None,
            "test",
        ))
        .endpoint_url("https://s3.eu-central-1.amazonaws.com")
        .build();
    let job_id = "a".repeat(64);
    let key = format!("terminal/{job_id}.json");
    let request = aws_sdk_s3::Client::from_conf(config)
        .put_object()
        .bucket("valid-test-bucket")
        .key(&key)
        .content_type("application/json")
        .if_none_match("*")
        .presigned(PresigningConfig::expires_in(Duration::from_secs(3_600)).unwrap())
        .await
        .unwrap();

    let headers: std::collections::HashMap<_, _> = request.headers().collect();
    assert!(request.uri().contains(&key));
    assert_eq!(headers.get("content-type"), Some(&"application/json"));
    assert_eq!(headers.get("if-none-match"), Some(&"*"));
    assert!(
        headers
            .keys()
            .all(|name| matches!(*name, "content-type" | "if-none-match"))
    );
    assert!(request.uri().contains("X-Amz-Signature="));
}
