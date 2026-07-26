#![cfg(feature = "worker")]

use cbc::cipher::{BlockEncryptMut, KeyIvInit, block_padding::Pkcs7};
use rand_core::OsRng;
use rsa::{Oaep, RsaPrivateKey, RsaPublicKey};
use sha2::Sha256;
use usd8_tee_job_api::{
    KmsRecipientEnvelope, decrypt_kms_recipient_envelope, parse_kms_recipient_cms,
};

const AWS_KMS_RECIPIENT_BER_HEX: &str = "308006092a864886f70d010703a08030800201023182016b3082016702010280207087b55df94ba3255cdf3c01840a2aa3ec93620625d601cf56f97bde7a3d2eb1303c06092a864886f70d010107302fa00f300d06096086480165030402010500a11c301a06092a864886f70d010108300d0609608648016503040201050004820100a0614593a030ee336bfff076618b0130d045de9f4d183d83c5da882f13abc1f4bf0d13645869393442ab582e6a04d697d52d5623e367e7e92db6ebd2bd07735b153f2826bee5df8e16c713a1e85cb6ba85e88681335c7e941a94abf0c0113e030916e2b6e1826db4ffb919b8e1b6f59ec277e58de40b0ffeecaa0d94fbcb290374ed3dfc35d31a8f43ae1300fe20fdd986d4b8565657451f9dc693e134678920221c58a28da5e71ab6b31caa445825a6385c6c4f5d5d5ebbc2c2570e9647fded36b559647bcb27e58886255f582c63d863ecec307d15763abce0b1b812a550938ca4e2d28a74563db52367558d3e2e82ac2a27fe5c9391a007c15f75b90ab0dd308006092a864886f70d010701301d060960864801650304012a0410688c6d5f7f31b0fecedf09f2e7c99ac9a080043070e5caaffd49ad24efe15bf903be9d19895b777d269b57b025f6f67e7ef93f94464515f2ebe034ea0b7621a1ff19292e00000000000000000000";

fn aws_kms_recipient_ber() -> Vec<u8> {
    hex::decode(AWS_KMS_RECIPIENT_BER_HEX).unwrap()
}

#[test]
fn parses_aws_kms_recipient_ber_envelope() {
    let encoded = aws_kms_recipient_ber();
    let envelope = parse_kms_recipient_cms(&encoded).unwrap();
    assert_eq!(
        hex::encode(envelope.encrypted_key),
        "a0614593a030ee336bfff076618b0130d045de9f4d183d83c5da882f13abc1f4bf0d13645869393442ab582e6a04d697d52d5623e367e7e92db6ebd2bd07735b153f2826bee5df8e16c713a1e85cb6ba85e88681335c7e941a94abf0c0113e030916e2b6e1826db4ffb919b8e1b6f59ec277e58de40b0ffeecaa0d94fbcb290374ed3dfc35d31a8f43ae1300fe20fdd986d4b8565657451f9dc693e134678920221c58a28da5e71ab6b31caa445825a6385c6c4f5d5d5ebbc2c2570e9647fded36b559647bcb27e58886255f582c63d863ecec307d15763abce0b1b812a550938ca4e2d28a74563db52367558d3e2e82ac2a27fe5c9391a007c15f75b90ab0dd"
    );
    assert_eq!(hex::encode(envelope.iv), "688c6d5f7f31b0fecedf09f2e7c99ac9");
    assert_eq!(
        hex::encode(envelope.ciphertext),
        "70e5caaffd49ad24efe15bf903be9d19895b777d269b57b025f6f67e7ef93f94464515f2ebe034ea0b7621a1ff19292e"
    );
}

#[test]
fn decrypts_rsa_oaep_aes256_cbc_recipient_envelope() {
    let private_key = RsaPrivateKey::new(&mut OsRng, 2048).unwrap();
    let public_key = RsaPublicKey::from(&private_key);
    let symmetric_key = [0x42u8; 32];
    let iv = [0x24u8; 16];
    let plaintext = b"kms recipient plaintext";
    let encrypted_key = public_key
        .encrypt(&mut OsRng, Oaep::new::<Sha256>(), &symmetric_key)
        .unwrap();
    let ciphertext = cbc::Encryptor::<aes::Aes256>::new_from_slices(&symmetric_key, &iv)
        .unwrap()
        .encrypt_padded_vec_mut::<Pkcs7>(plaintext);
    let envelope = KmsRecipientEnvelope {
        encrypted_key,
        iv: iv.to_vec(),
        ciphertext,
    };

    let decrypted = decrypt_kms_recipient_envelope(&private_key, &envelope).unwrap();

    assert_eq!(decrypted.as_slice(), plaintext);
}

fn mutate_nth(haystack: &mut [u8], needle: &[u8], occurrence: usize, index: usize, value: u8) {
    let mut seen = 0;
    for start in 0..=haystack.len() - needle.len() {
        if &haystack[start..start + needle.len()] == needle {
            if seen == occurrence {
                haystack[start + index] = value;
                return;
            }
            seen += 1;
        }
    }
    panic!("fixture marker not found");
}

#[test]
fn rejects_non_sha256_oaep_hash() {
    let mut encoded = aws_kms_recipient_ber();
    let sha256_oid = hex::decode("608648016503040201").unwrap();
    mutate_nth(&mut encoded, &sha256_oid, 0, 8, 2);
    assert!(parse_kms_recipient_cms(&encoded).is_err());
}

#[test]
fn rejects_non_mgf1_or_non_sha256_mgf() {
    let mut wrong_mgf = aws_kms_recipient_ber();
    let mgf1_oid = hex::decode("2a864886f70d010108").unwrap();
    mutate_nth(&mut wrong_mgf, &mgf1_oid, 0, 8, 9);
    assert!(parse_kms_recipient_cms(&wrong_mgf).is_err());

    let mut wrong_mgf_hash = aws_kms_recipient_ber();
    let sha256_oid = hex::decode("608648016503040201").unwrap();
    mutate_nth(&mut wrong_mgf_hash, &sha256_oid, 1, 8, 2);
    assert!(parse_kms_recipient_cms(&wrong_mgf_hash).is_err());
}

#[test]
fn rejects_missing_or_nonempty_oaep_label_policy() {
    let mut missing_parameters = aws_kms_recipient_ber();
    let params_prefix = hex::decode("302fa00f").unwrap();
    mutate_nth(&mut missing_parameters, &params_prefix, 0, 0, 5);
    assert!(parse_kms_recipient_cms(&missing_parameters).is_err());

    let mut nonempty_label_declaration = aws_kms_recipient_ber();
    let mgf_context = hex::decode("a11c").unwrap();
    mutate_nth(&mut nonempty_label_declaration, &mgf_context, 0, 0, 0xa2);
    assert!(parse_kms_recipient_cms(&nonempty_label_declaration).is_err());
}

fn with_pspecified_label(label: &[u8]) -> Vec<u8> {
    let mut encoded = aws_kms_recipient_ber();
    let recipient_prefix = hex::decode("3182016b30820167").unwrap();
    let recipient_start = encoded
        .windows(recipient_prefix.len())
        .position(|window| window == recipient_prefix)
        .unwrap();
    let key_algorithm_prefix = hex::decode("303c06092a864886f70d010107").unwrap();
    let key_algorithm_start = encoded
        .windows(key_algorithm_prefix.len())
        .position(|window| window == key_algorithm_prefix)
        .unwrap();
    let parameters_prefix = hex::decode("302fa00f").unwrap();
    let parameters_start = encoded[key_algorithm_start..]
        .windows(parameters_prefix.len())
        .position(|window| window == parameters_prefix)
        .map(|offset| key_algorithm_start + offset)
        .unwrap();
    let encrypted_key_prefix = hex::decode("04820100").unwrap();
    let encrypted_key_start = encoded[key_algorithm_start..]
        .windows(encrypted_key_prefix.len())
        .position(|window| window == encrypted_key_prefix)
        .map(|offset| key_algorithm_start + offset)
        .unwrap();

    let mut source_algorithm_content = hex::decode("06092a864886f70d010109").unwrap();
    source_algorithm_content.extend_from_slice(&definite_tlv(0x04, label));
    let source_algorithm = definite_tlv(0x30, &source_algorithm_content);
    let source_context = definite_tlv(0xa2, &source_algorithm);
    let extra = source_context.len() as u16;

    let recipient_set_len = 0x016bu16 + extra;
    let recipient_len = 0x0167u16 + extra;
    encoded[recipient_start + 2..recipient_start + 4]
        .copy_from_slice(&recipient_set_len.to_be_bytes());
    encoded[recipient_start + 6..recipient_start + 8].copy_from_slice(&recipient_len.to_be_bytes());
    encoded[key_algorithm_start + 1] = 0x3c + extra as u8;
    encoded[parameters_start + 1] = 0x2f + extra as u8;
    encoded.splice(encrypted_key_start..encrypted_key_start, source_context);
    encoded
}

#[test]
fn accepts_only_empty_pspecified_oaep_label() {
    parse_kms_recipient_cms(&with_pspecified_label(&[])).unwrap();
    assert!(parse_kms_recipient_cms(&with_pspecified_label(&[0])).is_err());
}

fn definite_tlv(tag: u8, content: &[u8]) -> Vec<u8> {
    let mut encoded = vec![tag];
    if content.len() < 128 {
        encoded.push(content.len() as u8);
    } else {
        let bytes = content.len().to_be_bytes();
        let first = bytes.iter().position(|byte| *byte != 0).unwrap();
        encoded.push(0x80 | (bytes.len() - first) as u8);
        encoded.extend_from_slice(&bytes[first..]);
    }
    encoded.extend_from_slice(content);
    encoded
}

#[test]
fn rejects_excessively_nested_constructed_encrypted_content() {
    let encoded = aws_kms_recipient_ber();
    let marker = hex::decode("a0800430").unwrap();
    let start = encoded
        .windows(marker.len())
        .position(|window| window == marker)
        .unwrap();
    let primitive_end = start + marker.len() + 48;
    let mut constructed = encoded[start + 2..primitive_end].to_vec();
    for _ in 0..20 {
        constructed = definite_tlv(0xa0, &constructed);
    }
    let mut nested = Vec::new();
    nested.extend_from_slice(&encoded[..start]);
    nested.extend_from_slice(&constructed);
    nested.extend_from_slice(&encoded[primitive_end + 2..]);
    assert!(parse_kms_recipient_cms(&nested).is_err());
}
