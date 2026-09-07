use serde_json::Value;

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
