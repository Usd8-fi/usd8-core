use num_bigint::BigUint;
use std::str::FromStr;
use usd8_settlement::{
    Address,
    typed_data::{SettlementDigestInput, pools_hash, settlement_digest},
};

fn address(value: &str) -> Address {
    Address::from_str(value).unwrap()
}

fn n(value: u8) -> BigUint {
    value.into()
}

#[test]
fn pools_hash_and_full_digest_match_viem_and_solidity_vector() {
    let verifying = address("0x0000000000000000000000000000000000001115");
    let pools = vec![
        address("0x0000000000000000000000000000000000000a55"),
        verifying,
    ];
    assert_eq!(
        pools_hash(&pools),
        "0x0edf2defd7cee8c95b28ab36f03556297b85574740299cf9789000c9f54a2a94"
    );

    let input = SettlementDigestInput {
        chain_id: 1,
        verifying_contract: verifying,
        incident_id: n(7),
        root: format!("0x{}", "11".repeat(32)),
        unresolved: n(2),
        pool_payouts: vec![n(1), n(2)],
        pool_addrs: pools,
        claim_set: format!("0x{}", "22".repeat(32)),
        config_hash: format!("0x{}", "33".repeat(32)),
        settlement_input_hash: "0x6fdf7088dad356db1a44c02996b33691d1ead1c10b008cf67abc2d456ba4eca0"
            .to_owned(),
    };
    assert_eq!(
        settlement_digest(&input).unwrap(),
        "0x4d980a59007244ae1b9834e0b0668d248a0c250af222e33ca1ff96aba579b212"
    );
}

#[test]
fn typed_data_rejects_malformed_hashes_and_uint256_overflow() {
    let mut input = SettlementDigestInput {
        chain_id: 1,
        verifying_contract: address("0x0000000000000000000000000000000000001115"),
        incident_id: n(1),
        root: "0x12".to_owned(),
        unresolved: n(0),
        pool_payouts: vec![],
        pool_addrs: vec![],
        claim_set: format!("0x{}", "00".repeat(32)),
        config_hash: format!("0x{}", "00".repeat(32)),
        settlement_input_hash: format!("0x{}", "00".repeat(32)),
    };
    assert!(
        settlement_digest(&input)
            .unwrap_err()
            .to_string()
            .contains("root")
    );

    input.root = format!("0x{}", "00".repeat(32));
    input.incident_id = BigUint::from(1u8) << 256usize;
    assert!(
        settlement_digest(&input)
            .unwrap_err()
            .to_string()
            .contains("uint256")
    );
}
