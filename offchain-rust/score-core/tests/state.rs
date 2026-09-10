use num_bigint::BigUint;
use usd8_score_core::{
    AccountScoreState, RatePoint, advance_account, apply_transfer, gross_score, projected_numerator,
};

fn rates() -> Vec<RatePoint> {
    vec![
        RatePoint {
            from_block: 2,
            rate: BigUint::from(2_000_000_000_000_000_000u64),
        },
        RatePoint {
            from_block: 6,
            rate: BigUint::from(1_000_000_000_000_000_000u64),
        },
    ]
}

#[test]
fn one_shot_and_incremental_advancement_are_exactly_equal() {
    let mut one_shot = AccountScoreState {
        balance: BigUint::from(100u8),
        last_block: 2,
        ..AccountScoreState::default()
    };
    apply_transfer(
        &mut one_shot,
        4,
        &BigUint::from(0u8),
        &BigUint::from(40u8),
        &rates(),
        18,
    )
    .unwrap();
    apply_transfer(
        &mut one_shot,
        8,
        &BigUint::from(10u8),
        &BigUint::from(0u8),
        &rates(),
        18,
    )
    .unwrap();
    advance_account(&mut one_shot, 10, &rates(), 18).unwrap();

    let mut incremental = AccountScoreState {
        balance: BigUint::from(100u8),
        last_block: 2,
        ..AccountScoreState::default()
    };
    apply_transfer(
        &mut incremental,
        4,
        &BigUint::from(0u8),
        &BigUint::from(40u8),
        &rates(),
        18,
    )
    .unwrap();
    advance_account(&mut incremental, 5, &rates(), 18).unwrap();
    apply_transfer(
        &mut incremental,
        8,
        &BigUint::from(10u8),
        &BigUint::from(0u8),
        &rates(),
        18,
    )
    .unwrap();
    advance_account(&mut incremental, 10, &rates(), 18).unwrap();

    assert_eq!(incremental, one_shot);
    assert_eq!(
        gross_score(projected_numerator(&incremental, 10, &rates(), 18).unwrap()),
        BigUint::from(900u16),
    );
}
