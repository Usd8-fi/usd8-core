use num_bigint::BigUint;
use std::str::FromStr;
use usd8_score_api::{
    IncrementalScoreError, advance_token_checkpoint, new_token_checkpoint, token_numerator,
};
use usd8_settlement::Address;
use usd8_settlement::chain::{RatePoint, ScoredToken, TokenTransfer};

fn address(value: &str) -> Address {
    Address::from_str(value).unwrap()
}

fn token() -> ScoredToken {
    ScoredToken {
        token: address("0x0000000000000000000000000000000000001000"),
        decimals: 18,
        rates: vec![
            RatePoint {
                from_block: 2,
                rate: BigUint::from(2_000_000_000_000_000_000u64),
            },
            RatePoint {
                from_block: 6,
                rate: BigUint::from(1_000_000_000_000_000_000u64),
            },
        ],
    }
}

fn transfers(account: Address) -> Vec<TokenTransfer> {
    vec![
        TokenTransfer {
            from: account,
            to: address("0x000000000000000000000000000000000000b0b0"),
            value: BigUint::from(40u8),
            block_number: 4,
            log_index: 1,
        },
        TokenTransfer {
            from: address("0x000000000000000000000000000000000000b0b0"),
            to: account,
            value: BigUint::from(10u8),
            block_number: 8,
            log_index: 2,
        },
    ]
}

#[test]
fn persisted_incremental_checkpoint_matches_one_shot_replay() {
    let account = address("0x000000000000000000000000000000000000a11c");
    let scored = token();
    let mut one_shot =
        new_token_checkpoint(&scored, 2, BigUint::from(100u8), format!("0x{:064x}", 2));
    advance_token_checkpoint(
        &mut one_shot,
        &scored,
        account,
        &transfers(account),
        10,
        format!("0x{:064x}", 10),
    )
    .unwrap();

    let mut incremental =
        new_token_checkpoint(&scored, 2, BigUint::from(100u8), format!("0x{:064x}", 2));
    advance_token_checkpoint(
        &mut incremental,
        &scored,
        account,
        &transfers(account)[..1],
        5,
        format!("0x{:064x}", 5),
    )
    .unwrap();
    advance_token_checkpoint(
        &mut incremental,
        &scored,
        account,
        &transfers(account)[1..],
        10,
        format!("0x{:064x}", 10),
    )
    .unwrap();

    assert_eq!(incremental, one_shot);
    assert_eq!(
        token_numerator(&incremental, &scored, 10).unwrap(),
        BigUint::from(900u16) * BigUint::from(1_000_000_000_000_000_000u64),
    );
}

#[test]
fn persisted_checkpoint_rejects_historical_rate_edits() {
    let account = address("0x000000000000000000000000000000000000a11c");
    let scored = token();
    let mut checkpoint =
        new_token_checkpoint(&scored, 2, BigUint::from(100u8), format!("0x{:064x}", 2));
    let mut edited = scored.clone();
    edited.rates[0].rate += BigUint::from(1u8);
    let error = advance_token_checkpoint(
        &mut checkpoint,
        &edited,
        account,
        &[],
        3,
        format!("0x{:064x}", 3),
    )
    .unwrap_err();
    assert!(matches!(error, IncrementalScoreError::RateHistoryMismatch));
}

#[test]
fn persisted_checkpoint_rejects_malformed_numeric_state() {
    let scored = token();
    let mut checkpoint =
        new_token_checkpoint(&scored, 2, BigUint::from(100u8), format!("0x{:064x}", 2));
    checkpoint.account.balance = "01".to_owned();
    let error = token_numerator(&checkpoint, &scored, 2).unwrap_err();
    assert!(matches!(
        error,
        IncrementalScoreError::Malformed("account.balance")
    ));
}

#[test]
fn persisted_checkpoint_rejects_retroactive_rate_append() {
    let account = address("0x000000000000000000000000000000000000a11c");
    let scored = token();
    let mut checkpoint =
        new_token_checkpoint(&scored, 2, BigUint::from(100u8), format!("0x{:064x}", 2));
    advance_token_checkpoint(
        &mut checkpoint,
        &scored,
        account,
        &[],
        7,
        format!("0x{:064x}", 7),
    )
    .unwrap();
    checkpoint.rates.pop();
    let error = advance_token_checkpoint(
        &mut checkpoint,
        &scored,
        account,
        &[],
        8,
        format!("0x{:064x}", 8),
    )
    .unwrap_err();
    assert!(matches!(error, IncrementalScoreError::RetroactiveRate));
}
