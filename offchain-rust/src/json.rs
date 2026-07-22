use crate::{
    Address, ClaimInput, KernelError, KernelInput, KernelOutput, PoolInput, allocate, uint256_word,
};
use num_bigint::BigUint;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::str::FromStr;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct JsonKernelInput {
    incident_id: String,
    coverage_bps: String,
    insured_decimals: u32,
    twap_ratio: String,
    underlying_usd: String,
    max_cover_pool_payout_bps: String,
    pools: Vec<JsonPoolInput>,
    claims: Vec<JsonClaimInput>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct JsonPoolInput {
    balance: String,
    asset_usd: String,
    asset_decimals: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct JsonClaimInput {
    claim_id: String,
    user: String,
    escrow_amount: String,
    min_held: String,
    gross_earned_score: String,
    spent_score: String,
    score_to_spend: String,
    booster_amount: String,
    #[serde(default, rename = "boosterHeld")]
    _booster_held: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonKernelOutput {
    rows: Vec<JsonSettledRow>,
    pool_payouts: Vec<String>,
    claim_set_hash: String,
    settlement_input_hash: String,
    root: String,
    proofs: BTreeMap<String, Vec<String>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonSettledRow {
    claim_id: String,
    user: String,
    escrow_amount: String,
    eligible_amount: String,
    loss_usd: String,
    gross_earned_score: String,
    earned_score: String,
    score_spent: String,
    boosted_score: String,
    payout_usd: String,
    amounts: Vec<String>,
}

fn decimal(field: &str, value: &str) -> Result<BigUint, KernelError> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || value.len() > 78
    {
        return Err(KernelError::InvalidDecimal {
            field: field.to_owned(),
            value: value.to_owned(),
        });
    }
    let parsed = BigUint::from_str(value).map_err(|_| KernelError::InvalidDecimal {
        field: field.to_owned(),
        value: value.to_owned(),
    })?;
    uint256_word(&parsed)?;
    Ok(parsed)
}

fn address(field: &str, value: &str) -> Result<Address, KernelError> {
    Address::from_str(value).map_err(|_| KernelError::InvalidAddress {
        field: field.to_owned(),
        value: value.to_owned(),
    })
}

impl TryFrom<JsonKernelInput> for KernelInput {
    type Error = KernelError;

    fn try_from(value: JsonKernelInput) -> Result<Self, Self::Error> {
        let pools = value
            .pools
            .into_iter()
            .enumerate()
            .map(|(index, pool)| {
                Ok(PoolInput {
                    balance: decimal(&format!("pools[{index}].balance"), &pool.balance)?,
                    asset_usd: decimal(&format!("pools[{index}].assetUsd"), &pool.asset_usd)?,
                    asset_decimals: pool.asset_decimals,
                })
            })
            .collect::<Result<_, KernelError>>()?;
        let claims = value
            .claims
            .into_iter()
            .enumerate()
            .map(|(index, claim)| {
                let prefix = format!("claims[{index}]");
                Ok(ClaimInput {
                    claim_id: decimal(&format!("{prefix}.claimId"), &claim.claim_id)?,
                    user: address(&format!("{prefix}.user"), &claim.user)?,
                    escrow_amount: decimal(
                        &format!("{prefix}.escrowAmount"),
                        &claim.escrow_amount,
                    )?,
                    min_held: decimal(&format!("{prefix}.minHeld"), &claim.min_held)?,
                    gross_earned_score: decimal(
                        &format!("{prefix}.grossEarnedScore"),
                        &claim.gross_earned_score,
                    )?,
                    spent_score: decimal(&format!("{prefix}.spentScore"), &claim.spent_score)?,
                    score_to_spend: decimal(
                        &format!("{prefix}.scoreToSpend"),
                        &claim.score_to_spend,
                    )?,
                    booster_amount: decimal(
                        &format!("{prefix}.boosterAmount"),
                        &claim.booster_amount,
                    )?,
                })
            })
            .collect::<Result<_, KernelError>>()?;
        Ok(Self {
            incident_id: decimal("incidentId", &value.incident_id)?,
            coverage_bps: decimal("coverageBps", &value.coverage_bps)?,
            insured_decimals: value.insured_decimals,
            twap_ratio: decimal("twapRatio", &value.twap_ratio)?,
            underlying_usd: decimal("underlyingUsd", &value.underlying_usd)?,
            max_cover_pool_payout_bps: decimal(
                "maxCoverPoolPayoutBps",
                &value.max_cover_pool_payout_bps,
            )?,
            pools,
            claims,
        })
    }
}

impl From<KernelOutput> for JsonKernelOutput {
    fn from(value: KernelOutput) -> Self {
        let rows = value
            .rows
            .into_iter()
            .map(|row| JsonSettledRow {
                claim_id: row.claim_id.to_string(),
                user: row.user.to_string(),
                escrow_amount: row.escrow_amount.to_string(),
                eligible_amount: row.eligible_amount.to_string(),
                loss_usd: row.loss_usd.to_string(),
                gross_earned_score: row.gross_earned_score.to_string(),
                earned_score: row.earned_score.to_string(),
                score_spent: row.score_spent.to_string(),
                boosted_score: row.boosted_score.to_string(),
                payout_usd: row.payout_usd.to_string(),
                amounts: row
                    .amounts
                    .into_iter()
                    .map(|amount| amount.to_string())
                    .collect(),
            })
            .collect();
        let proofs = value
            .proofs
            .into_iter()
            .map(|(claim_id, proof)| (claim_id.to_string(), proof))
            .collect();
        Self {
            rows,
            pool_payouts: value
                .pool_payouts
                .into_iter()
                .map(|amount| amount.to_string())
                .collect(),
            claim_set_hash: value.claim_set_hash,
            settlement_input_hash: value.settlement_input_hash,
            root: value.root,
            proofs,
        }
    }
}

pub fn parse_json(input: &str) -> Result<KernelInput, KernelError> {
    let dto: JsonKernelInput = serde_json::from_str(input)?;
    dto.try_into()
}

pub fn serialize_output(output: KernelOutput) -> Result<String, KernelError> {
    Ok(serde_json::to_string(&JsonKernelOutput::from(output))?)
}

pub fn compute_json(input: &str) -> Result<String, KernelError> {
    serialize_output(allocate(&parse_json(input)?)?)
}
