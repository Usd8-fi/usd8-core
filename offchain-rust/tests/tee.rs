use serde::Deserialize;
use usd8_settlement::tee::{PCR_BYTE_LENGTH, pcr0_2_hash};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vector {
    pcr0: String,
    pcr1: String,
    pcr2: String,
    expected_hash: String,
}

#[derive(Deserialize)]
struct Fixture {
    vectors: Vec<Vector>,
}

fn bytes(value: &str) -> Vec<u8> {
    hex::decode(value.strip_prefix("0x").unwrap()).unwrap()
}

#[test]
fn pcr0_2_hash_is_domain_separated_and_ordered() {
    let pcr0 = vec![0x00; PCR_BYTE_LENGTH];
    let pcr1 = vec![0x11; PCR_BYTE_LENGTH];
    let pcr2 = vec![0x22; PCR_BYTE_LENGTH];

    assert_eq!(
        pcr0_2_hash(&pcr0, &pcr1, &pcr2).unwrap(),
        "0x20446d8b062e02dfab69a51bdd645d914a93ea2a6f9cd9979dfeaba332e49397"
    );
    assert_ne!(
        pcr0_2_hash(&pcr0, &pcr1, &pcr2).unwrap(),
        pcr0_2_hash(&pcr1, &pcr0, &pcr2).unwrap()
    );
}

#[test]
fn shared_pcr_vectors_match_golden_commitments() {
    let fixture: Fixture =
        serde_json::from_str(include_str!("../fixtures/tee-pcr-vectors.json")).unwrap();
    for vector in fixture.vectors {
        assert_eq!(
            pcr0_2_hash(
                &bytes(&vector.pcr0),
                &bytes(&vector.pcr1),
                &bytes(&vector.pcr2)
            )
            .unwrap(),
            vector.expected_hash
        );
    }
}

#[test]
fn pcr0_2_hash_rejects_non_sha384_measurements() {
    let good = vec![0u8; PCR_BYTE_LENGTH];
    let short = vec![0u8; PCR_BYTE_LENGTH - 1];
    assert!(pcr0_2_hash(&short, &good, &good).is_err());
}
