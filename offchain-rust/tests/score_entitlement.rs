use num_bigint::BigUint;
use std::str::FromStr;
use usd8_settlement::{Address, ClaimInput, KernelInput, PoolInput, allocate};

const MAX_COVERAGE_BPS: u64 = 8_000;
const BPS: u64 = 10_000;

fn wad(value: u64) -> BigUint {
    BigUint::from(value) * BigUint::from(10u8).pow(18)
}

fn n(value: &str) -> BigUint {
    BigUint::from_str(value).unwrap()
}

fn claimant(index: u16) -> Address {
    let mut bytes = [0u8; 20];
    bytes[18..].copy_from_slice(&index.to_be_bytes());
    Address::from_bytes(bytes)
}

fn scenario(pool_usd: u64, claims: &[(u64, u64)]) -> KernelInput {
    KernelInput {
        incident_id: 1u8.into(),
        coverage_bps: MAX_COVERAGE_BPS.into(),
        booster_boost_bps: 100u8.into(),
        insured_decimals: 18,
        twap_ratio: wad(1),
        underlying_usd: wad(1),
        max_cover_pool_payout_bps: BPS.into(),
        protocol_fee_share_bps: 0u8.into(),
        pools: vec![PoolInput {
            balance: wad(pool_usd),
            asset_usd: wad(1),
            asset_decimals: 18,
        }],
        claims: claims
            .iter()
            .enumerate()
            .map(|(index, (loss, score))| ClaimInput {
                claim_id: BigUint::from(index + 1),
                user: claimant(u16::try_from(index + 1).unwrap()),
                escrow_amount: wad(*loss),
                min_held: wad(*loss),
                gross_earned_score: (*score).into(),
                spent_score: 0u8.into(),
                score_to_spend: (*score).into(),
                booster_amount: 0u8.into(),
            })
            .collect(),
    }
}

fn assert_payouts(name: &str, pool_usd: u64, claims: &[(u64, u64)], expected: &[u64]) {
    let output = allocate(&scenario(pool_usd, claims)).unwrap();
    let actual = output
        .rows
        .iter()
        .map(|row| row.payout_usd.clone())
        .collect::<Vec<_>>();
    let expected = expected.iter().map(|value| wad(*value)).collect::<Vec<_>>();
    assert_eq!(actual, expected, "{name}: claimant payouts");
    assert_eq!(
        output.pool_payouts,
        vec![expected.iter().cloned().sum()],
        "{name}: aggregate pool payout"
    );
}

#[test]
fn solo_claimant_gets_full_score_share_bounded_only_by_capital_and_loss() {
    // A sole nonzero-score claimant owns 100% of claimant score.
    assert_payouts("scarce pool", 50, &[(100, 1)], &[50]);
    assert_payouts("abundant pool", 100, &[(40, 1)], &[32]);
    assert_payouts("empty pool", 0, &[(100, 1)], &[0]);
}

#[test]
fn many_claimant_score_share_benchmark_matches_hand_derived_payouts() {
    // Scores 1..10 total 55. A $550 budget therefore pays exactly $10 per
    // score unit while every $1,000 loss cap remains above entitlement.
    let claims = (1u64..=10).map(|score| (1_000, score)).collect::<Vec<_>>();
    assert_payouts(
        "ten claimants",
        550,
        &claims,
        &[10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
    );
}

#[test]
fn hundred_claimant_scale_benchmark_matches_exact_score_multiplier() {
    // Scores 1..100 total 5,050. A $505,000 budget therefore pays exactly
    // $100 per score unit; every $20,000 loss cap remains above entitlement.
    let claims = (1u64..=100)
        .map(|score| (20_000, score))
        .collect::<Vec<_>>();
    let expected = (1u64..=100).map(|score| score * 100).collect::<Vec<_>>();
    assert_payouts("hundred claimants", 505_000, &claims, &expected);
}

#[test]
fn sufficient_and_insufficient_pool_scenarios_preserve_score_priority() {
    // Scores 3:1 split initial entitlement 3:1. With $400 available both $100
    // 80%-of-loss caps bind and $240 stays in the pool; with $80 available payouts are
    // the uncapped $60:$20 score shares.
    assert_payouts("sufficient pool", 400, &[(100, 3), (100, 1)], &[80, 80]);
    assert_payouts("insufficient pool", 80, &[(100, 3), (100, 1)], &[60, 20]);
}

#[test]
fn high_score_small_loss_does_not_transfer_unused_entitlement() {
    // Scores 90:10 create $90:$10 entitlements. The first claimant's $20 loss
    // 80%-of-loss cap leaves $74 unused; the second claimant's large loss does not receive it.
    assert_payouts(
        "score priority with asymmetric losses",
        100,
        &[(20, 90), (1_000, 10)],
        &[16, 10],
    );
}

#[test]
fn zero_scores_and_integer_dust_cannot_create_or_redistribute_entitlement() {
    assert_payouts(
        "zero-score claimant",
        100,
        &[(100, 10), (1_000, 0)],
        &[80, 0],
    );
    assert_payouts("all zero scores", 100, &[(100, 0), (100, 0)], &[0, 0]);

    // Three equal scores split floor(100e18 / 3) each; the final one wei of USD
    // entitlement remains pooled.
    let output = allocate(&scenario(100, &[(100, 1), (100, 1), (100, 1)])).unwrap();
    let per_claim = n("33333333333333333333");
    assert_eq!(
        output
            .rows
            .iter()
            .map(|row| row.payout_usd.clone())
            .collect::<Vec<_>>(),
        vec![per_claim.clone(), per_claim.clone(), per_claim]
    );
    assert_eq!(output.pool_payouts, vec![n("99999999999999999999")]);
}

#[test]
fn protocol_fee_nets_claimant_capacity_and_grosses_pool_budget() {
    let mut input = scenario(100, &[(100, 1)]);
    input.coverage_bps = 8_000u16.into();
    input.max_cover_pool_payout_bps = 5_000u16.into();
    input.protocol_fee_share_bps = 2_000u16.into();

    let output = allocate(&input).unwrap();
    assert_eq!(output.rows[0].payout_usd, wad(40));
    assert_eq!(output.rows[0].amounts, vec![wad(40)]);
    assert_eq!(output.pool_payouts, vec![wad(50)]);
}
