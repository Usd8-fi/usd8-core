use alloy_primitives::{Address as AlloyAddress, B256, U256};
use alloy_sol_types::{SolType, SolValue, sol};
use num_bigint::BigUint;
use std::str::FromStr;
use usd8_settlement::ffi;
use usd8_settlement::{Address, MerkleRow, SettlementTree};

type Bytes32Type = sol!(bytes32);
type Bytes32ArrayType = sol!(bytes32[]);
type ClaimSetPayload = sol!((uint8[],uint256[],address[],uint256[],uint256[],uint256[]));

fn hex_payload(bytes: Vec<u8>) -> String {
    format!("0x{}", hex::encode(bytes))
}

#[test]
fn ffi_root_and_proof_round_trip_abi_payloads() {
    let bob = AlloyAddress::from([0x11; 20]);
    let carol = AlloyAddress::from([0x22; 20]);
    let payload = hex_payload(
        (
            U256::from(7),
            vec![U256::from(1), U256::from(2)],
            vec![bob, carol],
            vec![vec![U256::from(90)], vec![U256::from(60)]],
            vec![U256::from(60), U256::from(40)],
            vec![U256::from(61), U256::from(40)],
            vec![U256::from(100), U256::from(100)],
        )
            .abi_encode_params(),
    );
    let rows = vec![
        MerkleRow {
            claim_id: BigUint::from(1u8),
            user: Address::from_bytes(bob.into_array()),
            amounts: vec![BigUint::from(90u8)],
            score_spent: BigUint::from(60u8),
            boosted_score: BigUint::from(61u8),
            eligible_amount: BigUint::from(100u8),
        },
        MerkleRow {
            claim_id: BigUint::from(2u8),
            user: Address::from_bytes(carol.into_array()),
            amounts: vec![BigUint::from(60u8)],
            score_spent: BigUint::from(40u8),
            boosted_score: BigUint::from(40u8),
            eligible_amount: BigUint::from(100u8),
        },
    ];
    let expected = SettlementTree::new(&BigUint::from(7u8), &rows).unwrap();

    let root_output = ffi::run("root", &payload, None).unwrap();
    let root = <Bytes32Type as SolType>::abi_decode(
        &hex::decode(root_output.strip_prefix("0x").unwrap()).unwrap(),
    )
    .unwrap();
    assert_eq!(
        root,
        B256::from_str(&expected.root_hex()).expect("valid root")
    );

    let proof_output = ffi::run("proof", &payload, Some("1")).unwrap();
    let proof = <Bytes32ArrayType as SolType>::abi_decode(
        &hex::decode(proof_output.strip_prefix("0x").unwrap()).unwrap(),
    )
    .unwrap();
    let expected_proof = expected
        .proof_hex(&BigUint::from(1u8))
        .unwrap()
        .into_iter()
        .map(|value| B256::from_str(&value).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(proof, expected_proof);
}

#[test]
fn ffi_claimset_validates_kind_and_aligned_arrays() {
    let user = AlloyAddress::from([0x33; 20]);
    let payload = hex_payload(<ClaimSetPayload as SolType>::abi_encode_params(&(
        vec![0u8, 1u8],
        vec![U256::from(1), U256::from(1)],
        vec![user, user],
        vec![U256::from(100), U256::ZERO],
        vec![U256::from(60), U256::ZERO],
        vec![U256::ZERO, U256::ZERO],
    )));
    let output = ffi::run("claimset", &payload, None).unwrap();
    let decoded = <Bytes32Type as SolType>::abi_decode(
        &hex::decode(output.strip_prefix("0x").unwrap()).unwrap(),
    )
    .unwrap();
    assert_ne!(decoded, B256::ZERO);

    let bad_payload = hex_payload(<ClaimSetPayload as SolType>::abi_encode_params(&(
        vec![2u8],
        vec![U256::from(1)],
        vec![user],
        vec![U256::ZERO],
        vec![U256::ZERO],
        vec![U256::ZERO],
    )));
    assert!(ffi::run("claimset", &bad_payload, None).is_err());
}
