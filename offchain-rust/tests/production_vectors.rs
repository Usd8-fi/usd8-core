use num_bigint::BigUint;
use std::str::FromStr;
use usd8_settlement::{
    Address, ClaimEvent, ClaimInput, EventKind, KernelInput, PoolInput, allocate_with_events,
};

fn n(value: &str) -> BigUint {
    BigUint::from_str(value).unwrap()
}

fn address(value: &str) -> Address {
    Address::from_str(value).unwrap()
}

fn claim(
    claim_id: u8,
    user: Address,
    escrow: &str,
    score_to_spend: u8,
    booster_amount: u8,
) -> ClaimInput {
    ClaimInput {
        claim_id: claim_id.into(),
        user,
        escrow_amount: n(escrow),
        min_held: n(escrow),
        gross_earned_score: score_to_spend.into(),
        spent_score: 0u8.into(),
        score_to_spend: score_to_spend.into(),
        booster_amount: booster_amount.into(),
        booster_held: booster_amount.into(),
    }
}

fn register(claim: &ClaimInput) -> ClaimEvent {
    ClaimEvent {
        kind: EventKind::Register,
        claim_id: claim.claim_id.clone(),
        user: claim.user,
        amount: claim.escrow_amount.clone(),
        score_to_spend: claim.score_to_spend.clone(),
        booster_amount: claim.booster_amount.clone(),
        block_number: 10,
        log_index: u64::try_from(claim.claim_id.clone()).unwrap(),
    }
}

fn cancel(claim_id: u8) -> ClaimEvent {
    ClaimEvent {
        kind: EventKind::Cancel,
        claim_id: claim_id.into(),
        user: address("0x0000000000000000000000000000000000000000"),
        amount: 0u8.into(),
        score_to_spend: 0u8.into(),
        booster_amount: 0u8.into(),
        block_number: 11,
        log_index: 1,
    }
}

fn input(claims: Vec<ClaimInput>) -> KernelInput {
    KernelInput {
        incident_id: 1u8.into(),
        coverage_bps: 8_000u16.into(),
        insured_decimals: 18,
        twap_ratio: n("1000000000000000000"),
        underlying_usd: n("1000000000000000000"),
        max_cover_pool_payout_bps: 10_000u16.into(),
        pools: vec![PoolInput {
            balance: n("100000000000000000000"),
            asset_usd: n("1000000000000000000"),
            asset_decimals: 18,
        }],
        claims,
    }
}

#[test]
fn cancelled_claim_is_removed_but_remains_in_claim_set_commitment() {
    let bob = claim(
        1,
        address("0x000000000000000000000000000000000000b0b0"),
        "100000000000000000000",
        60,
        0,
    );
    let carol = claim(
        2,
        address("0x000000000000000000000000000000000000ca50"),
        "50000000000000000000",
        40,
        2,
    );
    let events = vec![register(&bob), register(&carol), cancel(2)];

    let output = allocate_with_events(&input(vec![bob]), &events).unwrap();

    assert_eq!(output.rows.len(), 1);
    assert_eq!(output.rows[0].claim_id, BigUint::from(1u8));
    assert_eq!(
        output.claim_set_hash,
        "0x60add87f3115dee2fe6429564dec04a70c356a31bacddf469e8523377897c4e7"
    );
}

#[test]
fn resolved_claims_are_reordered_to_registration_order() {
    let first = claim(
        1,
        address("0x000000000000000000000000000000000000b0b0"),
        "100000000000000000000",
        60,
        0,
    );
    let second = claim(
        2,
        address("0x000000000000000000000000000000000000ca50"),
        "50000000000000000000",
        40,
        0,
    );
    let events = vec![register(&first), register(&second)];

    let output = allocate_with_events(&input(vec![second, first]), &events).unwrap();

    assert_eq!(output.rows[0].claim_id, BigUint::from(1u8));
    assert_eq!(output.rows[1].claim_id, BigUint::from(2u8));
}

#[test]
fn inconsistent_replayed_and_resolved_claim_sets_fail_closed() {
    let bob = claim(
        1,
        address("0x000000000000000000000000000000000000b0b0"),
        "100000000000000000000",
        60,
        0,
    );
    let mut wrong = bob.clone();
    wrong.escrow_amount += BigUint::from(1u8);
    let events = vec![register(&bob)];

    let error = allocate_with_events(&input(vec![wrong]), &events)
        .unwrap_err()
        .to_string();
    assert!(error.contains("resolved claim does not match replayed registration"));
}

#[test]
fn unknown_or_duplicate_cancellations_fail_closed() {
    let no_registration = allocate_with_events(&input(vec![]), &[cancel(9)])
        .unwrap_err()
        .to_string();
    assert!(no_registration.contains("cancellation references unknown claim 9"));

    let bob = claim(
        1,
        address("0x000000000000000000000000000000000000b0b0"),
        "100000000000000000000",
        60,
        0,
    );
    let first_cancel = cancel(1);
    let mut second_cancel = cancel(1);
    second_cancel.log_index += 1;
    let events = vec![register(&bob), first_cancel, second_cancel];
    let duplicate = allocate_with_events(&input(vec![]), &events)
        .unwrap_err()
        .to_string();
    assert!(duplicate.contains("duplicate cancellation for claim 1"));
}

#[test]
fn duplicate_chain_position_fails_closed() {
    let first = claim(
        1,
        address("0x000000000000000000000000000000000000b0b0"),
        "100000000000000000000",
        60,
        0,
    );
    let second = claim(
        2,
        address("0x000000000000000000000000000000000000ca50"),
        "50000000000000000000",
        40,
        0,
    );
    let first_event = register(&first);
    let mut second_event = register(&second);
    second_event.log_index = first_event.log_index;

    let error = allocate_with_events(&input(vec![first, second]), &[first_event, second_event])
        .unwrap_err()
        .to_string();
    assert!(error.contains("not strictly increasing"));
}
