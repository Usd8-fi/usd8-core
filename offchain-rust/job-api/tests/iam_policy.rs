use serde_json::{Value, json};

fn assert_reconciliation_permissions(policy: &Value) {
    let statements = policy["Statement"].as_array().unwrap();
    let observers: Vec<_> = statements
        .iter()
        .filter(|statement| statement["Sid"] == "ObserveWorkerTermination")
        .collect();
    assert_eq!(observers.len(), 1);
    assert_eq!(
        observers[0],
        &json!({
            "Sid": "ObserveWorkerTermination",
            "Effect": "Allow",
            "Action": "ec2:DescribeInstances",
            "Resource": "*"
        })
    );
    let mut seen_sids = std::collections::HashSet::new();
    for statement in statements {
        assert!(
            seen_sids.insert(statement["Sid"].as_str().unwrap()),
            "duplicate grant Sid"
        );
        assert!(statement.get("NotAction").is_none());
        assert!(statement.get("NotResource").is_none());
        let actions = match &statement["Action"] {
            Value::String(action) => vec![action.as_str()],
            Value::Array(actions) => actions
                .iter()
                .map(|action| action.as_str().unwrap())
                .collect(),
            _ => panic!("explicit actions required"),
        };
        for action in actions {
            assert!(!action.contains(['*', '?']), "wildcard action: {action}");
            if action.to_ascii_lowercase().starts_with("ec2:") {
                match statement["Sid"].as_str().unwrap() {
                    "ObserveWorkerTermination" => assert_eq!(action, "ec2:DescribeInstances"),
                    "UseApprovedWorkerInfrastructure" | "LaunchTaggedWorkers" => {
                        assert_eq!(action, "ec2:RunInstances");
                    }
                    "TagLaunchedWorkers" => assert_eq!(action, "ec2:CreateTags"),
                    sid => panic!("unexpected EC2 grant: {sid}"),
                }
            }
        }
    }
}

fn assert_kms_role_separation(policy: &Value) {
    let statements = policy["Statement"].as_array().unwrap();
    assert_eq!(statements.len(), 3, "no additional KMS grants permitted");
    let expected = [
        json!({
            "Sid": "TrustedCloudKeyAdministration",
            "Effect": "Allow",
            "Principal": {"AWS": "arn:aws:iam::919437049909:root"},
            "Action": [
                "kms:CancelKeyDeletion", "kms:CreateAlias", "kms:DeleteAlias",
                "kms:DescribeKey", "kms:DisableKey", "kms:EnableKey", "kms:GetKeyPolicy",
                "kms:GetKeyRotationStatus", "kms:ListAliases", "kms:ListKeyPolicies",
                "kms:ListResourceTags", "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion",
                "kms:TagResource", "kms:UntagResource", "kms:UpdateAlias", "kms:UpdateKeyDescription"
            ],
            "Resource": "*"
        }),
        json!({
            "Sid": "ReadOnlyGrantAudit",
            "Effect": "Allow",
            "Principal": {"AWS": "arn:aws:iam::919437049909:user/hermes-tee-agent"},
            "Action": "kms:ListGrants",
            "Resource": "*"
        }),
        json!({
            "Sid": "AttestedEnclaveDecryptOnly",
            "Effect": "Allow",
            "Principal": {"AWS": "arn:aws:iam::919437049909:role/USD8TeeInstanceRole"},
            "Action": "kms:Decrypt",
            "Resource": "*",
            "Condition": {"StringEqualsIgnoreCase": {
                "kms:RecipientAttestation:ImageSha384": "03a117faac28842c59ef241ec504e9ecbc1034e16fea4311786fdc7e7766bb9198aa15a36a6abc975d5bf5e0a80bdbf0",
                "kms:RecipientAttestation:PCR3": "1dc0aeefd8ca0b888ba8ed140ea3a1793eafd569a833d8b19a176e2a2cf8e95919561e4369d635546f97e1107c981c6b"
            }}
        }),
    ];
    for expected in expected {
        let matching: Vec<_> = statements
            .iter()
            .filter(|statement| statement["Sid"] == expected["Sid"])
            .collect();
        assert_eq!(
            matching,
            vec![&expected],
            "exact grant required: {}",
            expected["Sid"]
        );
    }
}

#[test]
fn kms_policy_rejects_extra_grants() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/kms-key-policy.json")).unwrap();
    assert_kms_role_separation(&policy);
    for action in [
        "kms:Decrypt",
        "kms:PutKeyPolicy",
        "kms:CreateGrant",
        "kms:*",
        "kms:ListGrants",
    ] {
        let mut mutated = policy.clone();
        mutated["Statement"].as_array_mut().unwrap().push(json!({
            "Sid": "ExtraOperatorGrant",
            "Effect": "Allow",
            "Principal": {"AWS": "arn:aws:iam::919437049909:user/hermes-tee-agent"},
            "Action": action,
            "Resource": "*"
        }));
        assert!(
            std::panic::catch_unwind(|| assert_kms_role_separation(&mutated)).is_err(),
            "accepted extra grant: {action}"
        );
    }
}

#[test]
fn kms_policy_rejects_broadened_audit_and_decryption_grants() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/kms-key-policy.json")).unwrap();
    assert_kms_role_separation(&policy);
    for (sid, field, value) in [
        (
            "ReadOnlyGrantAudit",
            "Action",
            json!(["kms:ListGrants", "kms:Decrypt"]),
        ),
        ("ReadOnlyGrantAudit", "Action", json!("kms:*")),
        ("ReadOnlyGrantAudit", "Principal", json!({"AWS": "*"})),
        (
            "ReadOnlyGrantAudit",
            "Resource",
            json!("arn:aws:kms:eu-central-1:919437049909:key/other"),
        ),
        ("ReadOnlyGrantAudit", "NotAction", json!("kms:ListGrants")),
        (
            "TrustedCloudKeyAdministration",
            "Action",
            json!(["kms:PutKeyPolicy", "kms:Decrypt"]),
        ),
        (
            "AttestedEnclaveDecryptOnly",
            "Principal",
            json!({"AWS": "arn:aws:iam::919437049909:user/hermes-tee-agent"}),
        ),
        ("AttestedEnclaveDecryptOnly", "Condition", json!({})),
    ] {
        let mut mutated = policy.clone();
        let statement = mutated["Statement"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|statement| statement["Sid"] == sid)
            .unwrap();
        statement[field] = value;
        assert!(
            std::panic::catch_unwind(|| assert_kms_role_separation(&mutated)).is_err(),
            "accepted mutation: {sid}.{field}"
        );
    }
    for key in [
        "kms:RecipientAttestation:ImageSha384",
        "kms:RecipientAttestation:PCR3",
    ] {
        let mut mutated = policy.clone();
        let statement = mutated["Statement"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|statement| statement["Sid"] == "AttestedEnclaveDecryptOnly")
            .unwrap();
        statement["Condition"]["StringEqualsIgnoreCase"]
            .as_object_mut()
            .unwrap()
            .remove(key);
        assert!(
            std::panic::catch_unwind(|| assert_kms_role_separation(&mutated)).is_err(),
            "accepted missing attestation: {key}"
        );
    }
}

#[test]
fn api_reconciliation_rejects_extra_ec2_grants() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/lambda-role-policy.json")).unwrap();
    assert_reconciliation_permissions(&policy);
    for (sid, action) in [
        ("ExtraGrant", "ec2:TerminateInstances"),
        ("ExtraGrant", "ec2:DescribeInstances"),
        ("ExtraGrant", "ec2:*"),
        ("ExtraGrant", "*"),
        ("ObserveWorkerTermination", "ec2:DescribeInstances"),
        ("LaunchTaggedWorkers", "ec2:RunInstances"),
    ] {
        let mut mutated = policy.clone();
        mutated["Statement"].as_array_mut().unwrap().push(json!({
            "Sid": sid, "Effect": "Allow", "Action": action, "Resource": "*"
        }));
        assert!(
            std::panic::catch_unwind(|| assert_reconciliation_permissions(&mutated)).is_err(),
            "accepted extra grant: {sid}/{action}"
        );
    }
}

#[test]
fn api_reconciliation_rejects_changed_observer_scope() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/lambda-role-policy.json")).unwrap();
    assert_reconciliation_permissions(&policy);
    for (field, value) in [
        (
            "Action",
            json!(["ec2:DescribeInstances", "ec2:TerminateInstances"]),
        ),
        (
            "Resource",
            json!("arn:aws:ec2:eu-central-1:919437049909:instance/*"),
        ),
        ("Principal", json!("*")),
        ("NotAction", json!("ec2:DescribeInstances")),
        ("NotResource", json!("*")),
    ] {
        let mut mutated = policy.clone();
        let observer = mutated["Statement"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|statement| statement["Sid"] == "ObserveWorkerTermination")
            .unwrap();
        observer[field] = value;
        assert!(
            std::panic::catch_unwind(|| assert_reconciliation_permissions(&mutated)).is_err(),
            "accepted changed observer scope: {field}"
        );
    }
}

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
    assert_reconciliation_permissions(&serde_json::from_str(api).unwrap());
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

#[test]
fn final_kms_policy_separates_cloud_administration_from_the_release_operator() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/kms-key-policy.json")).unwrap();
    let encoded = serde_json::to_string(&policy).unwrap();

    assert_kms_role_separation(&policy);
    assert!(encoded.contains("arn:aws:iam::919437049909:root"));
    assert!(encoded.contains("kms:PutKeyPolicy"));
    assert!(encoded.contains("kms:Decrypt"));
    assert!(encoded.contains("kms:RecipientAttestation:ImageSha384"));
    assert!(encoded.contains("kms:RecipientAttestation:PCR3"));
}

#[test]
fn persistent_operator_policy_cannot_bypass_the_enclave_boundary() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/operator-persistent-policy.json")).unwrap();
    let encoded = serde_json::to_string(&policy).unwrap();

    for forbidden in [
        "kms:PutKeyPolicy",
        "kms:Decrypt",
        "kms:Encrypt",
        "iam:PutRolePolicy",
        "iam:AttachRolePolicy",
        "secrets/*",
    ] {
        assert!(!encoded.contains(forbidden));
    }
}
