use usd8_tee_job_api::{
    CanonicalOpenRequest, CanonicalRequest, CanonicalSettlementRequest, JobPaths,
    canonicalize_open_request, canonicalize_request, derive_job_id, enclave_timeout_seconds,
    parent_timeout_seconds, verify_job_request_binding,
};

const REGISTRY: &str = "0x1111111111111111111111111111111111111111";

#[test]
fn request_timeouts_are_kind_specific_and_bounded() {
    let settlement = canonicalize_request(br#"{"incidentId":"7"}"#, REGISTRY).unwrap();
    let open = canonicalize_open_request(
        br#"{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":"123"}"#,
        REGISTRY,
    )
    .unwrap();
    assert_eq!(enclave_timeout_seconds(&settlement), 1_100);
    assert_eq!(parent_timeout_seconds(&settlement), 1_200);
    assert_eq!(enclave_timeout_seconds(&open), 300);
    assert_eq!(parent_timeout_seconds(&open), 360);
}

#[test]
fn accepts_only_canonical_fixed_registry_requests() {
    let body = br#"{"incidentId":"7"}"#;
    assert_eq!(
        canonicalize_request(body, REGISTRY).unwrap(),
        CanonicalRequest::Settlement(CanonicalSettlementRequest {
            incident_id: "7".into(),
            registry: REGISTRY.into(),
        })
    );

    for invalid in [
        br#"{"incidentId":"07"}"#.as_slice(),
        br#"{"incidentId":7}"#.as_slice(),
        br#"{"incidentId":"7","registry":"0x2222222222222222222222222222222222222222"}"#.as_slice(),
        br#"{"incidentId":"7","registry":"0x1111111111111111111111111111111111111111","rpcUrl":"https://evil"}"#.as_slice(),
    ] {
        assert!(canonicalize_request(invalid, REGISTRY).is_err());
    }
}

#[test]
fn rejects_incident_ids_outside_uint256() {
    let too_large = format!(r#"{{"incidentId":"1{}"}}"#, "0".repeat(78));
    assert!(canonicalize_request(too_large.as_bytes(), REGISTRY).is_err());
}

#[test]
fn job_id_binds_secret_idempotency_key_and_canonical_request() {
    let request = CanonicalRequest::Settlement(CanonicalSettlementRequest {
        incident_id: "7".into(),
        registry: REGISTRY.into(),
    });
    let id = derive_job_id(
        b"a sufficiently long deployment secret",
        "request-123",
        &request,
    )
    .unwrap();
    assert_eq!(id.len(), 64);
    assert!(
        id.bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    );
    assert_eq!(
        id,
        derive_job_id(
            b"a sufficiently long deployment secret",
            "request-123",
            &request
        )
        .unwrap()
    );
    assert_ne!(
        id,
        derive_job_id(
            b"a sufficiently long deployment secret",
            "request-124",
            &request
        )
        .unwrap()
    );
    assert!(derive_job_id(b"short", "request-123", &request).is_err());
    assert!(derive_job_id(b"a sufficiently long deployment secret", "", &request).is_err());
    assert!(
        derive_job_id(
            b"a sufficiently long deployment secret",
            &"x".repeat(129),
            &request
        )
        .is_err()
    );
}

#[test]
fn enclave_visible_job_id_commitment_rejects_request_substitution() {
    let original = CanonicalRequest::Settlement(CanonicalSettlementRequest {
        incident_id: "7".into(),
        registry: REGISTRY.into(),
    });
    let substituted = CanonicalRequest::Open(CanonicalOpenRequest {
        insured_token: "0x2222222222222222222222222222222222222222".into(),
        reference_block: "1234567".into(),
        registry: REGISTRY.into(),
    });
    let job_id = derive_job_id(
        b"a sufficiently long deployment secret",
        "request-123",
        &original,
    )
    .unwrap();

    verify_job_request_binding(&job_id, &original).unwrap();
    assert!(verify_job_request_binding(&job_id, &substituted).is_err());
}

#[test]
fn open_request_is_canonical_and_job_kind_is_domain_bound() {
    let body = br#"{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":"1234567"}"#;
    let open = canonicalize_open_request(body, REGISTRY).unwrap();
    assert_eq!(
        open,
        CanonicalRequest::Open(CanonicalOpenRequest {
            insured_token: "0x2222222222222222222222222222222222222222".into(),
            reference_block: "1234567".into(),
            registry: REGISTRY.into(),
        })
    );
    for invalid in [
        br#"{"insuredToken":"0x0000000000000000000000000000000000000000","referenceBlock":"1234567"}"#.as_slice(),
        br#"{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":1234567}"#.as_slice(),
        br#"{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":"0"}"#.as_slice(),
        br#"{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":"01"}"#.as_slice(),
        br#"{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":"18446744073709551616"}"#.as_slice(),
        br#"{"insuredToken":"0x2222222222222222222222222222222222222222","referenceBlock":"1234567","registry":"0x1111111111111111111111111111111111111111"}"#.as_slice(),
    ] {
        assert!(canonicalize_open_request(invalid, REGISTRY).is_err());
    }
    let settlement = CanonicalRequest::Settlement(CanonicalSettlementRequest {
        incident_id: "1234567".into(),
        registry: REGISTRY.into(),
    });
    assert_ne!(
        derive_job_id(b"a sufficiently long deployment secret", "same-key", &open).unwrap(),
        derive_job_id(
            b"a sufficiently long deployment secret",
            "same-key",
            &settlement
        )
        .unwrap()
    );
}

#[test]
fn job_paths_are_fixed_and_non_overlapping() {
    let paths = JobPaths::new(&"a".repeat(64)).unwrap();
    assert_eq!(paths.request, format!("requests/{}.json", "a".repeat(64)));
    assert_eq!(paths.terminal, format!("terminal/{}.json", "a".repeat(64)));
    assert!(JobPaths::new("../escape").is_err());
}
