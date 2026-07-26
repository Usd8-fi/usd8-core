use serde_json::json;
use usd8_tee_job_api::{ArtifactError, AttestedDigestKind, extract_attested_digest};

fn artifact() -> serde_json::Value {
    json!({
        "schemaVersion": 1,
        "settlementDigest": format!("0x{}", "42".repeat(32)),
        "nitroAttestedDigest": format!("0x{}", "42".repeat(32)),
        "teePcrHash": format!("0x{}", "11".repeat(32)),
        "measuredTeePcrHash": format!("0x{}", "11".repeat(32)),
        "nitroAttestationDocument": "0x0102"
    })
}

#[test]
fn signer_accepts_only_attested_artifact_with_matching_digest_and_pcr() {
    assert_eq!(
        extract_attested_digest(&artifact(), AttestedDigestKind::Settlement).unwrap(),
        [0x42; 32]
    );

    let mut wrong = artifact();
    wrong["nitroAttestedDigest"] = json!(format!("0x{}", "43".repeat(32)));
    assert_eq!(
        extract_attested_digest(&wrong, AttestedDigestKind::Settlement).unwrap_err(),
        ArtifactError::Mismatch
    );

    let mut wrong = artifact();
    wrong["measuredTeePcrHash"] = json!(format!("0x{}", "12".repeat(32)));
    assert_eq!(
        extract_attested_digest(&wrong, AttestedDigestKind::Settlement).unwrap_err(),
        ArtifactError::Mismatch
    );
}

#[test]
fn signer_rejects_plain_compute_or_malformed_artifacts() {
    let mut plain = artifact();
    plain
        .as_object_mut()
        .unwrap()
        .remove("nitroAttestationDocument");
    assert_eq!(
        extract_attested_digest(&plain, AttestedDigestKind::Settlement).unwrap_err(),
        ArtifactError::Invalid
    );
    assert_eq!(
        extract_attested_digest(&json!([]), AttestedDigestKind::Settlement).unwrap_err(),
        ArtifactError::Invalid
    );
}

#[test]
fn signer_accepts_exactly_one_attested_open_digest() {
    let open = json!({
        "schemaVersion": 1,
        "artifactType": "incidentOpen",
        "openDigest": format!("0x{}", "52".repeat(32)),
        "nitroAttestedDigest": format!("0x{}", "52".repeat(32)),
        "teePcrHash": format!("0x{}", "11".repeat(32)),
        "measuredTeePcrHash": format!("0x{}", "11".repeat(32)),
        "nitroAttestationDocument": "0x0102"
    });
    assert_eq!(
        extract_attested_digest(&open, AttestedDigestKind::IncidentOpen).unwrap(),
        [0x52; 32]
    );
    assert_eq!(
        extract_attested_digest(&open, AttestedDigestKind::Settlement).unwrap_err(),
        ArtifactError::Invalid
    );

    let mut ambiguous = open;
    ambiguous["settlementDigest"] = json!(format!("0x{}", "52".repeat(32)));
    assert_eq!(
        extract_attested_digest(&ambiguous, AttestedDigestKind::IncidentOpen).unwrap_err(),
        ArtifactError::Invalid
    );
}
