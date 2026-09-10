use serde_json::Value;

#[test]
fn runtime_can_atomically_update_only_the_dedicated_score_table() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/score-runtime-policy.json")).unwrap();
    assert!(has_exact_runtime_permissions(&policy));
}

#[test]
fn runtime_rejects_an_extra_wildcard_statement() {
    let mut policy: Value =
        serde_json::from_str(include_str!("../deploy/score-runtime-policy.json")).unwrap();
    policy["Statement"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({
            "Sid": "MaliciousExtraGrant",
            "Effect": "Allow",
            "Action": ["dynamodb:*"],
            "Resource": "*"
        }));
    assert!(!has_exact_runtime_permissions(&policy));
}

fn has_exact_runtime_permissions(policy: &Value) -> bool {
    let mut permissions = Vec::new();
    for statement in policy["Statement"].as_array().unwrap() {
        // Fail closed on inverse grants or malformed actions, including in other Sids.
        if statement.get("NotAction").is_some() || statement.get("NotResource").is_some() {
            return false;
        }
        let actions = match &statement["Action"] {
            Value::Array(actions) => actions.clone(),
            Value::String(action) => vec![Value::String(action.clone())],
            _ => return false,
        };
        if actions.is_empty() || actions.iter().any(|action| !action.is_string()) {
            return false;
        }
        // Logs-only statements cannot grant DynamoDB access. Inspect everything else,
        // so service-wide '*' and extra statements cannot hide behind a different Sid.
        if actions
            .iter()
            .all(|action| action.as_str().unwrap().starts_with("logs:"))
        {
            continue;
        }
        let mut permission = statement.clone();
        permission.as_object_mut().unwrap().remove("Sid");
        let mut actions = actions;
        actions.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
        permission["Action"] = Value::Array(actions);
        permissions.push(permission);
    }
    permissions
        == vec![serde_json::json!({
            "Effect": "Allow",
            "Action": ["dynamodb:GetItem", "dynamodb:UpdateItem"],
            "Resource": "arn:aws:dynamodb:eu-central-1:919437049909:table/usd8-score-checkpoints-sepolia"
        })]
}

#[test]
fn provisioner_cannot_create_or_rewrite_the_lambda_execution_role() {
    let policy: Value =
        serde_json::from_str(include_str!("../deploy/hermes-provisioner-policy.json")).unwrap();
    let encoded = serde_json::to_string(&policy).unwrap();

    for forbidden in [
        "iam:CreateRole",
        "iam:PutRolePolicy",
        "iam:AttachRolePolicy",
        "iam:PutRolePermissionsBoundary",
    ] {
        assert!(!encoded.contains(forbidden));
    }
    assert!(encoded.contains("iam:GetRole"));
    assert!(encoded.contains("iam:PassRole"));
    assert!(encoded.contains("iam:PassedToService"));
}
