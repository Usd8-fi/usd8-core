use usd8_tee_job_api::{
    CanonicalRequest, CanonicalSettlementRequest, JobWireRequest, MAX_ACCESS_KEY_ID_BYTES,
    MAX_CIPHERTEXT_B64_BYTES, MAX_CIPHERTEXT_BYTES, MAX_SECRET_ACCESS_KEY_BYTES,
    MAX_SESSION_TOKEN_BYTES, MAX_WIRE_REQUEST_BYTES, StoredRequest, WireError, read_frame_async,
    write_frame_async,
};

fn request() -> JobWireRequest {
    JobWireRequest {
        schema_version: 2,
        stored_request: StoredRequest {
            schema_version: 2,
            job_id: "a".repeat(64),
            request: CanonicalRequest::Settlement(CanonicalSettlementRequest {
                incident_id: "7".into(),
                registry: "0x1111111111111111111111111111111111111111".into(),
            }),
            created_at: 1,
            expires_at: 1_801,
        },
        region: "eu-central-1".into(),
        access_key_id: "AKIA_TEST".into(),
        secret_access_key: "secret".into(),
        session_token: "token".into(),
        signer_ciphertext_b64: "c2lnbmVy".into(),
        drpc_ciphertext_b64: "ZHJwYw==".into(),
    }
}

#[tokio::test]
async fn frame_round_trip_is_length_delimited_and_bounded() {
    let (mut left, mut right) = tokio::io::duplex(4096);
    let value = request();
    let sent = value.clone();
    let writer = tokio::spawn(async move { write_frame_async(&mut left, &sent, 4096).await });
    assert_eq!(
        read_frame_async::<_, JobWireRequest>(&mut right, 4096)
            .await
            .unwrap(),
        value
    );
    writer.await.unwrap().unwrap();
}

#[tokio::test]
async fn maximum_valid_wire_request_accounts_for_base64_and_json_expansion() {
    let mut value = request();
    let escaped = "\u{0001}";
    value.access_key_id = escaped.repeat(MAX_ACCESS_KEY_ID_BYTES);
    value.secret_access_key = escaped.repeat(MAX_SECRET_ACCESS_KEY_BYTES);
    value.session_token = escaped.repeat(MAX_SESSION_TOKEN_BYTES);
    assert_eq!(
        MAX_CIPHERTEXT_B64_BYTES,
        4 * MAX_CIPHERTEXT_BYTES.div_ceil(3)
    );
    let ciphertext_b64 = format!(
        "{}==",
        "Q".repeat(MAX_CIPHERTEXT_B64_BYTES.saturating_sub(2))
    );
    value.signer_ciphertext_b64 = ciphertext_b64.clone();
    value.drpc_ciphertext_b64 = ciphertext_b64;
    assert!(serde_json::to_vec(&value).unwrap().len() <= MAX_WIRE_REQUEST_BYTES);

    let (mut left, mut right) = tokio::io::duplex(MAX_WIRE_REQUEST_BYTES + 4);
    let sent = value.clone();
    let writer =
        tokio::spawn(
            async move { write_frame_async(&mut left, &sent, MAX_WIRE_REQUEST_BYTES).await },
        );
    assert_eq!(
        read_frame_async::<_, JobWireRequest>(&mut right, MAX_WIRE_REQUEST_BYTES)
            .await
            .unwrap(),
        value
    );
    writer.await.unwrap().unwrap();
}

#[tokio::test]
async fn frame_rejects_oversized_and_truncated_payloads() {
    assert_eq!(
        write_frame_async(&mut tokio::io::sink(), &request(), 8)
            .await
            .unwrap_err(),
        WireError::TooLarge
    );
    let (mut left, mut right) = tokio::io::duplex(8);
    use tokio::io::AsyncWriteExt;
    left.write_all(&[0, 0, 0, 2, b'{']).await.unwrap();
    left.shutdown().await.unwrap();
    assert_eq!(
        read_frame_async::<_, JobWireRequest>(&mut right, 8)
            .await
            .unwrap_err(),
        WireError::Io
    );
}

#[test]
fn wire_request_debug_never_exposes_credentials_or_ciphertext() {
    let text = format!("{:?}", request());
    for secret in ["AKIA_TEST", "secret", "token", "c2lnbmVy", "ZHJwYw=="] {
        assert!(!text.contains(secret));
    }
    assert!(text.contains("[REDACTED]"));
}
