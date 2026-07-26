use num_bigint::BigUint;
use std::str::FromStr;
use usd8_settlement::{
    Address,
    typed_data::{IncidentOpenDigestInput, incident_open_digest},
};

#[test]
fn incident_open_digest_matches_solidity_and_cast_vector() {
    let input = IncidentOpenDigestInput {
        chain_id: 11_155_111,
        verifying_contract: Address::from_str("0x250cebdd9d6997ffd45c60d6e713f42e44e383ec")
            .unwrap(),
        insured_token: Address::from_str("0x5300000000000000000000000000000000000004").unwrap(),
        reference_block: 1_234_567,
        incident_id: BigUint::from(1u8),
        tee_pcr_hash: "0x97f92ff2d9622568c12c8acb7e352e0f4786c2cd683021cafc391077f30b915d"
            .to_owned(),
        eligibility_hash: format!("0x{}", "55".repeat(32)),
    };
    assert_eq!(
        incident_open_digest(&input).unwrap(),
        "0xd6398a2db6e7a92da2fd70f6784763537c3202477194e695dc5716d0e574a4e1"
    );
}
