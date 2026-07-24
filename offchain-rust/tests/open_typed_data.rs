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
    };
    assert_eq!(
        incident_open_digest(&input).unwrap(),
        "0x23817acb0898da281c3cc8e24c57f11dd566a8b0d87dc6a247add82d3ed85fac"
    );
}
