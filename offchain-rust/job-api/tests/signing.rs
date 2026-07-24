use usd8_tee_job_api::{ethereum_address, sign_digest};

#[test]
fn secp256k1_signature_is_low_s_recoverable_and_ethereum_canonical() {
    let private_key = [0u8; 31].into_iter().chain([1]).collect::<Vec<_>>();
    let digest = [0x42u8; 32];
    let signed = sign_digest(&private_key, &digest).unwrap();
    assert_eq!(signed.signer, "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf");
    assert_eq!(signed.signature.len(), 132);
    assert!(signed.signature.starts_with("0x"));
    assert!(matches!(&signed.signature[130..], "1b" | "1c"));
    assert_eq!(signed.digest, format!("0x{}", hex::encode(digest)));
}

#[test]
fn signer_rejects_invalid_key_or_digest_and_derives_expected_address() {
    assert!(sign_digest(&[0u8; 32], &[1u8; 32]).is_err());
    assert!(sign_digest(&[1u8; 32], &[1u8; 31]).is_err());
    assert_eq!(
        ethereum_address(&[0u8; 31].into_iter().chain([1]).collect::<Vec<_>>()).unwrap(),
        "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"
    );
}
