use num_bigint::BigUint;
use std::str::FromStr;
use usd8_settlement::{
    Address, ClaimEvent, ClaimInput, EventKind, KernelInput, MerkleRow, PoolInput, SettlementTree,
    allocate, claim_set_hash, settlement_input_hash,
};

fn n(value: &str) -> BigUint {
    BigUint::from_str(value).unwrap()
}

fn wad(value: u64) -> BigUint {
    BigUint::from(value) * n("1000000000000000000")
}

fn address(value: &str) -> Address {
    Address::from_str(value).unwrap()
}

const BOB: &str = "0x000000000000000000000000000000000000b0b0";
const CAROL: &str = "0x000000000000000000000000000000000000ca50";

#[test]
fn capped_geometric_allocation_matches_golden_vector() {
    let input = KernelInput {
        incident_id: 1u8.into(),
        coverage_bps: 8_000u16.into(),
        insured_decimals: 18,
        twap_ratio: wad(1),
        underlying_usd: wad(1),
        max_cover_pool_payout_bps: 10_000u16.into(),
        pools: vec![PoolInput {
            balance: wad(100),
            asset_usd: wad(1),
            asset_decimals: 18,
        }],
        claims: vec![
            ClaimInput {
                claim_id: 1u8.into(),
                user: address(BOB),
                escrow_amount: wad(100),
                min_held: wad(100),
                gross_earned_score: 60u8.into(),
                spent_score: 0u8.into(),
                score_to_spend: 60u8.into(),
                booster_amount: 0u8.into(),
            },
            ClaimInput {
                claim_id: 2u8.into(),
                user: address(CAROL),
                escrow_amount: wad(100),
                min_held: wad(100),
                gross_earned_score: 40u8.into(),
                spent_score: 0u8.into(),
                score_to_spend: 40u8.into(),
                booster_amount: 0u8.into(),
            },
        ],
    };

    let output = allocate(&input).unwrap();
    assert_eq!(output.rows[0].payout_usd, n("55051025721816600736"));
    assert_eq!(output.rows[1].payout_usd, n("44948974278183399263"));
    assert_eq!(output.pool_payouts, vec![wad(100) - BigUint::from(1u8)]);
}

#[test]
fn booster_changes_payout_score_without_inflating_raw_score_spent() {
    let input = KernelInput {
        incident_id: 1u8.into(),
        coverage_bps: 8_000u16.into(),
        insured_decimals: 18,
        twap_ratio: wad(1),
        underlying_usd: wad(1),
        max_cover_pool_payout_bps: 10_000u16.into(),
        pools: vec![PoolInput {
            balance: wad(1_000),
            asset_usd: wad(1),
            asset_decimals: 18,
        }],
        claims: vec![ClaimInput {
            claim_id: 1u8.into(),
            user: address(BOB),
            escrow_amount: wad(100),
            min_held: wad(100),
            gross_earned_score: 100u8.into(),
            spent_score: 40u8.into(),
            score_to_spend: 1_000u16.into(),
            booster_amount: 2u8.into(),
        }],
    };

    let output = allocate(&input).unwrap();
    assert_eq!(output.rows[0].earned_score, 60u8.into());
    assert_eq!(output.rows[0].score_spent, 60u8.into());
    assert_eq!(output.rows[0].boosted_score, 61u8.into());
}

#[test]
fn standard_merkle_root_and_proofs_match_golden_vectors() {
    let rows = vec![
        MerkleRow {
            claim_id: 1u8.into(),
            user: address(BOB),
            amounts: vec![wad(60)],
            score_spent: 60u8.into(),
            boosted_score: 61u8.into(),
            eligible_amount: wad(100),
        },
        MerkleRow {
            claim_id: 2u8.into(),
            user: address(CAROL),
            amounts: vec![wad(40)],
            score_spent: 40u8.into(),
            boosted_score: 40u8.into(),
            eligible_amount: wad(100),
        },
    ];
    let tree = SettlementTree::new(&1u8.into(), &rows).unwrap();
    assert_eq!(
        tree.root_hex(),
        "0xf1856ac31823baefec4176cc5c01403c974256e16e0f03572ce8da482595a695"
    );
    assert_eq!(
        tree.proof_hex(&1u8.into()).unwrap(),
        vec!["0x83b69733304617e45b299fb7cbbce4257c570a16409cced96d5af3bb632f8c7c"]
    );
    assert_eq!(
        tree.proof_hex(&2u8.into()).unwrap(),
        vec!["0x4c007f1bddb62260585589d89bd932ab65daafafb39744cd88ba5b5d667d5c59"]
    );
}

#[test]
fn canonical_input_and_claim_set_hashes_match_golden_vectors() {
    let score_rows = vec![(address(BOB), 60u8.into()), (address(CAROL), 40u8.into())];
    assert_eq!(
        settlement_input_hash(&score_rows).unwrap(),
        "0x6fdf7088dad356db1a44c02996b33691d1ead1c10b008cf67abc2d456ba4eca0"
    );
    assert_eq!(
        settlement_input_hash(&[]).unwrap(),
        "0xc6df19a9e5cc2e1575f8bc5ee97cc5b352e49114c858bb010d9874784ccd5fc7"
    );

    let events = vec![
        ClaimEvent {
            kind: EventKind::Register,
            claim_id: 1u8.into(),
            user: address(BOB),
            amount: wad(100),
            score_to_spend: 60u8.into(),
            booster_amount: 0u8.into(),
            block_number: 10,
            log_index: 0,
        },
        ClaimEvent {
            kind: EventKind::Register,
            claim_id: 2u8.into(),
            user: address(CAROL),
            amount: wad(50),
            score_to_spend: 40u8.into(),
            booster_amount: 2u8.into(),
            block_number: 11,
            log_index: 1,
        },
        ClaimEvent {
            kind: EventKind::Cancel,
            claim_id: 2u8.into(),
            user: address(CAROL),
            amount: 0u8.into(),
            score_to_spend: 0u8.into(),
            booster_amount: 0u8.into(),
            block_number: 12,
            log_index: 2,
        },
    ];
    assert_eq!(
        claim_set_hash(&events).unwrap(),
        "0x60add87f3115dee2fe6429564dec04a70c356a31bacddf469e8523377897c4e7"
    );
}

#[test]
fn duplicate_canonical_input_user_is_rejected() {
    let rows = vec![(address(BOB), 1u8.into()), (address(BOB), 2u8.into())];
    assert!(
        settlement_input_hash(&rows)
            .unwrap_err()
            .to_string()
            .contains("duplicate settlement input user")
    );
}
