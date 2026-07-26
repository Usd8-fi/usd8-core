use serde_json::Value;

#[test]
fn worker_role_has_no_cross_job_s3_permissions() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/instance-role-policy.json")).unwrap();
    let statements = policy["Statement"].as_array().unwrap();
    let encoded = serde_json::to_string(statements).unwrap();

    assert!(!encoded.contains("s3:GetObject"));
    assert!(!encoded.contains("s3:PutObject"));
    assert!(!encoded.contains("requests/*"));
    assert!(!encoded.contains("terminal/*"));
    assert!(encoded.contains("kms:Decrypt"));
}

#[test]
fn control_plane_can_mint_immutable_short_lived_capabilities() {
    let lambda: Value =
        serde_json::from_str(include_str!("../deploy/lambda-role-policy.json")).unwrap();
    let bucket: Value = serde_json::from_str(include_str!("../deploy/bucket-policy.json")).unwrap();
    let lifecycle: Value =
        serde_json::from_str(include_str!("../deploy/bucket-lifecycle.json")).unwrap();
    let lambda = serde_json::to_string(&lambda).unwrap();
    let bucket = serde_json::to_string(&bucket).unwrap();
    let lifecycle = serde_json::to_string(&lifecycle).unwrap();

    for prefix in ["requests/*", "terminal/*", "launch/*", "secrets/*"] {
        assert!(lambda.contains(prefix));
    }
    assert!(bucket.contains("launch/*"));
    assert!(bucket.contains("s3:if-none-match"));
    assert!(lifecycle.contains("ExpireLaunchCapabilities"));
    assert!(lifecycle.contains("\"Days\":1"));
}

#[test]
fn api_and_janitor_roles_are_least_privilege_and_disjoint() {
    let api = include_str!("../deploy/lambda-role-policy.json");
    let janitor = include_str!("../deploy/janitor-role-policy.json");
    serde_json::from_str::<Value>(api).unwrap();
    serde_json::from_str::<Value>(janitor).unwrap();

    assert!(!api.contains("ec2:TerminateInstances"));
    assert!(!api.contains("ec2:DescribeInstances"));
    assert!(!api.contains("usd8-tee-janitor"));
    assert!(api.contains("usd8-tee-job-api"));
    assert!(janitor.contains("ec2:TerminateInstances"));
    assert!(janitor.contains("ec2:DescribeInstances"));
    assert!(janitor.contains("ec2:ResourceTag/Project"));
    assert!(janitor.contains("usd8-tee-janitor"));
    assert!(!janitor.contains("usd8-tee-job-api"));
    for forbidden in ["ec2:RunInstances", "ec2:CreateTags", "iam:PassRole", "s3:"] {
        assert!(!janitor.contains(forbidden));
    }
}

#[test]
fn request_retention_outlives_terminal_retention() {
    let lifecycle: Value =
        serde_json::from_str(include_str!("../deploy/bucket-lifecycle.json")).unwrap();
    let rules = lifecycle["Rules"].as_array().unwrap();
    let days = |id: &str| {
        rules
            .iter()
            .find(|rule| rule["ID"] == id)
            .and_then(|rule| rule["Expiration"]["Days"].as_u64())
            .unwrap()
    };

    assert_eq!(days("ExpireRequests"), 31);
    assert_eq!(days("ExpireTerminal"), 30);
}
