use crate::{hash_hex, keccak256};
#[cfg(any(target_os = "linux", test))]
use ciborium::value::Value;
#[cfg(any(target_os = "linux", test))]
use serde::Deserialize;
#[cfg(any(target_os = "linux", test))]
use serde_bytes::ByteBuf;
#[cfg(any(target_os = "linux", test))]
use std::collections::BTreeMap;
use thiserror::Error;

pub const PCR_BYTE_LENGTH: usize = 48;
const PCR_HASH_DOMAIN: &[u8] = b"USD8_TEE_PCR0_2_V1";
#[cfg(any(target_os = "linux", test))]
const FRESH_NONCE_LENGTH: usize = 32;

#[derive(Debug, Error)]
pub enum TeeError {
    #[error("PCR{index} must be {PCR_BYTE_LENGTH} bytes, got {actual}")]
    InvalidPcrLength { index: u8, actual: usize },
    #[error("Nitro NSM unavailable: {0}")]
    NsmUnavailable(String),
    #[error("Nitro NSM returned an invalid attestation: {0}")]
    InvalidAttestation(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FreshAttestation {
    pub document: Vec<u8>,
    pub pcr_hash: String,
}

#[cfg(any(target_os = "linux", test))]
#[derive(Deserialize)]
struct AttestationPayload {
    digest: String,
    pcrs: BTreeMap<usize, ByteBuf>,
    certificate: ByteBuf,
    cabundle: Vec<ByteBuf>,
    user_data: Option<ByteBuf>,
    nonce: Option<ByteBuf>,
}

/// Canonical USD8 code-identity commitment:
/// keccak256("USD8_TEE_PCR0_2_V1" || PCR0 || PCR1 || PCR2).
/// PCR values are fixed-width SHA-384 measurements, so concatenation is unambiguous.
pub fn pcr0_2_hash(pcr0: &[u8], pcr1: &[u8], pcr2: &[u8]) -> Result<String, TeeError> {
    let pcrs = [pcr0, pcr1, pcr2];
    for (index, pcr) in pcrs.iter().enumerate() {
        if pcr.len() != PCR_BYTE_LENGTH {
            return Err(TeeError::InvalidPcrLength {
                index: index as u8,
                actual: pcr.len(),
            });
        }
    }
    let mut preimage = Vec::with_capacity(PCR_HASH_DOMAIN.len() + 3 * PCR_BYTE_LENGTH);
    preimage.extend_from_slice(PCR_HASH_DOMAIN);
    for pcr in pcrs {
        preimage.extend_from_slice(pcr);
    }
    Ok(hash_hex(keccak256(preimage)))
}

#[cfg(any(target_os = "linux", test))]
fn parse_fresh_attestation(
    document: &[u8],
    expected_nonce: &[u8],
    expected_user_data: &[u8],
) -> Result<String, TeeError> {
    let decoded: Value = ciborium::de::from_reader(document)
        .map_err(|error| TeeError::InvalidAttestation(format!("invalid COSE_Sign1: {error}")))?;
    let envelope = match decoded {
        Value::Tag(18, value) => *value,
        Value::Tag(tag, _) => {
            return Err(TeeError::InvalidAttestation(format!(
                "unexpected COSE tag {tag}"
            )));
        }
        value => value,
    };
    let fields = match envelope {
        Value::Array(fields) if fields.len() == 4 => fields,
        _ => {
            return Err(TeeError::InvalidAttestation(
                "COSE_Sign1 must be a four-element array".to_owned(),
            ));
        }
    };
    let payload_bytes = match &fields[2] {
        Value::Bytes(bytes) => bytes,
        _ => {
            return Err(TeeError::InvalidAttestation(
                "COSE_Sign1 payload must be bytes".to_owned(),
            ));
        }
    };
    if !matches!(&fields[3], Value::Bytes(signature) if !signature.is_empty()) {
        return Err(TeeError::InvalidAttestation(
            "COSE_Sign1 signature is empty".to_owned(),
        ));
    }
    let payload: AttestationPayload = ciborium::de::from_reader(payload_bytes.as_slice())
        .map_err(|error| TeeError::InvalidAttestation(format!("invalid payload: {error}")))?;
    if payload.digest != "SHA384" {
        return Err(TeeError::InvalidAttestation(format!(
            "unexpected PCR digest {}",
            payload.digest
        )));
    }
    if payload.certificate.is_empty() || payload.cabundle.is_empty() {
        return Err(TeeError::InvalidAttestation(
            "certificate chain is empty".to_owned(),
        ));
    }
    if payload.nonce.as_ref().map(|nonce| nonce.as_slice()) != Some(expected_nonce) {
        return Err(TeeError::InvalidAttestation(
            "attestation nonce mismatch".to_owned(),
        ));
    }
    if payload.user_data.as_ref().map(|data| data.as_slice()) != Some(expected_user_data) {
        return Err(TeeError::InvalidAttestation(
            "attestation user_data mismatch".to_owned(),
        ));
    }
    let pcr = |index: usize| {
        payload.pcrs.get(&index).ok_or_else(|| {
            TeeError::InvalidAttestation(format!("attestation is missing locked PCR{index}"))
        })
    };
    pcr0_2_hash(pcr(0)?.as_ref(), pcr(1)?.as_ref(), pcr(2)?.as_ref())
}

#[cfg(any(target_os = "linux", test))]
trait NsmClient {
    fn get_random(&mut self) -> Result<Vec<u8>, TeeError>;
    fn attest(&mut self, nonce: &[u8], user_data: &[u8]) -> Result<Vec<u8>, TeeError>;
}

#[cfg(any(target_os = "linux", test))]
fn fresh_nitro_attestation_with<N: NsmClient>(
    nsm: &mut N,
    user_data: &[u8],
) -> Result<FreshAttestation, TeeError> {
    let random = nsm.get_random()?;
    if random.len() < FRESH_NONCE_LENGTH {
        return Err(TeeError::NsmUnavailable(format!(
            "GetRandom returned {} bytes, need at least {FRESH_NONCE_LENGTH}",
            random.len()
        )));
    }
    let nonce = &random[..FRESH_NONCE_LENGTH];
    let document = nsm.attest(nonce, user_data)?;
    let pcr_hash = parse_fresh_attestation(&document, nonce, user_data)?;
    Ok(FreshAttestation { document, pcr_hash })
}

/// Request a nonce-bound attestation from the local Nitro Security Module and
/// derive the exact PCR commitment later bound into the settlement signature.
#[cfg(target_os = "linux")]
pub fn fresh_nitro_attestation(user_data: &[u8]) -> Result<FreshAttestation, TeeError> {
    use aws_nitro_enclaves_nsm_api::api::{Request, Response};
    use aws_nitro_enclaves_nsm_api::driver::{nsm_exit, nsm_init, nsm_process_request};

    struct DriverNsm(i32);

    impl DriverNsm {
        fn open() -> Result<Self, TeeError> {
            let fd = nsm_init();
            if fd < 0 {
                return Err(TeeError::NsmUnavailable(
                    "cannot open /dev/nsm; run inside a Nitro Enclave".to_owned(),
                ));
            }
            Ok(Self(fd))
        }
    }

    impl Drop for DriverNsm {
        fn drop(&mut self) {
            nsm_exit(self.0);
        }
    }

    impl NsmClient for DriverNsm {
        fn get_random(&mut self) -> Result<Vec<u8>, TeeError> {
            match nsm_process_request(self.0, Request::GetRandom) {
                Response::GetRandom { random } => Ok(random),
                Response::Error(error) => Err(TeeError::NsmUnavailable(format!(
                    "GetRandom failed: {error:?}"
                ))),
                response => Err(TeeError::InvalidAttestation(format!(
                    "unexpected GetRandom response: {response:?}"
                ))),
            }
        }

        fn attest(&mut self, nonce: &[u8], user_data: &[u8]) -> Result<Vec<u8>, TeeError> {
            match nsm_process_request(
                self.0,
                Request::Attestation {
                    user_data: Some(ByteBuf::from(user_data.to_vec())),
                    nonce: Some(ByteBuf::from(nonce.to_vec())),
                    public_key: None,
                },
            ) {
                Response::Attestation { document } => Ok(document),
                Response::Error(error) => Err(TeeError::NsmUnavailable(format!(
                    "Attestation failed: {error:?}"
                ))),
                response => Err(TeeError::InvalidAttestation(format!(
                    "unexpected attestation response: {response:?}"
                ))),
            }
        }
    }

    fresh_nitro_attestation_with(&mut DriverNsm::open()?, user_data)
}

#[cfg(not(target_os = "linux"))]
pub fn fresh_nitro_attestation(_user_data: &[u8]) -> Result<FreshAttestation, TeeError> {
    Err(TeeError::NsmUnavailable(
        "Nitro NSM is available only inside a Linux Nitro Enclave".to_owned(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Serialize;

    #[derive(Serialize)]
    struct TestPayload {
        module_id: String,
        digest: String,
        timestamp: u64,
        pcrs: BTreeMap<usize, ByteBuf>,
        certificate: ByteBuf,
        cabundle: Vec<ByteBuf>,
        public_key: Option<ByteBuf>,
        user_data: Option<ByteBuf>,
        nonce: Option<ByteBuf>,
    }

    fn document(nonce: &[u8], user_data: &[u8], digest: &str) -> Vec<u8> {
        let pcrs = [
            (0, ByteBuf::from(vec![0x00; PCR_BYTE_LENGTH])),
            (1, ByteBuf::from(vec![0x11; PCR_BYTE_LENGTH])),
            (2, ByteBuf::from(vec![0x22; PCR_BYTE_LENGTH])),
        ]
        .into_iter()
        .collect();
        let mut payload = Vec::new();
        ciborium::ser::into_writer(
            &TestPayload {
                module_id: "test".to_owned(),
                digest: digest.to_owned(),
                timestamp: 1,
                pcrs,
                certificate: ByteBuf::from(vec![1]),
                cabundle: vec![ByteBuf::from(vec![2])],
                public_key: None,
                user_data: Some(ByteBuf::from(user_data.to_vec())),
                nonce: Some(ByteBuf::from(nonce.to_vec())),
            },
            &mut payload,
        )
        .unwrap();
        let envelope = Value::Tag(
            18,
            Box::new(Value::Array(vec![
                Value::Bytes(vec![0xa0]),
                Value::Map(vec![]),
                Value::Bytes(payload),
                Value::Bytes(vec![3]),
            ])),
        );
        let mut document = Vec::new();
        ciborium::ser::into_writer(&envelope, &mut document).unwrap();
        document
    }

    #[test]
    fn fresh_attestation_parser_binds_nonce_user_data_and_pcrs() {
        let nonce = [7u8; FRESH_NONCE_LENGTH];
        let user_data = [9u8; 32];
        let valid = document(&nonce, &user_data, "SHA384");
        assert_eq!(
            parse_fresh_attestation(&valid, &nonce, &user_data).unwrap(),
            "0x20446d8b062e02dfab69a51bdd645d914a93ea2a6f9cd9979dfeaba332e49397"
        );
        assert!(parse_fresh_attestation(&valid, &[8u8; 32], &user_data).is_err());
        assert!(parse_fresh_attestation(&valid, &nonce, &[8u8; 32]).is_err());
        assert!(
            parse_fresh_attestation(&document(&nonce, &user_data, "SHA256"), &nonce, &user_data)
                .is_err()
        );
    }

    struct MockNsm {
        random: Vec<u8>,
        document: Vec<u8>,
        attested_nonce: Option<Vec<u8>>,
        attested_user_data: Option<Vec<u8>>,
    }

    impl NsmClient for MockNsm {
        fn get_random(&mut self) -> Result<Vec<u8>, TeeError> {
            Ok(self.random.clone())
        }

        fn attest(&mut self, nonce: &[u8], user_data: &[u8]) -> Result<Vec<u8>, TeeError> {
            self.attested_nonce = Some(nonce.to_vec());
            self.attested_user_data = Some(user_data.to_vec());
            Ok(self.document.clone())
        }
    }

    #[test]
    fn mocked_nsm_binds_fresh_random_nonce_and_result_into_attestation() {
        let nonce = vec![7u8; FRESH_NONCE_LENGTH];
        let user_data = vec![9u8; 32];
        let mut nsm = MockNsm {
            random: nonce.clone(),
            document: document(&nonce, &user_data, "SHA384"),
            attested_nonce: None,
            attested_user_data: None,
        };
        let actual = fresh_nitro_attestation_with(&mut nsm, &user_data).unwrap();
        assert_eq!(nsm.attested_nonce, Some(nonce));
        assert_eq!(nsm.attested_user_data, Some(user_data));
        assert_eq!(
            actual.pcr_hash,
            "0x20446d8b062e02dfab69a51bdd645d914a93ea2a6f9cd9979dfeaba332e49397"
        );
    }

    #[test]
    fn mocked_nsm_rejects_short_randomness_before_attesting() {
        let mut nsm = MockNsm {
            random: vec![7u8; FRESH_NONCE_LENGTH - 1],
            document: vec![],
            attested_nonce: None,
            attested_user_data: None,
        };
        assert!(matches!(
            fresh_nitro_attestation_with(&mut nsm, &[9u8; 32]),
            Err(TeeError::NsmUnavailable(_))
        ));
        assert_eq!(nsm.attested_nonce, None);
        assert_eq!(nsm.attested_user_data, None);
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn nsm_request_fails_closed_outside_a_nitro_enclave() {
        assert!(matches!(
            fresh_nitro_attestation(&[0u8; 32]),
            Err(TeeError::NsmUnavailable(_))
        ));
    }
}
