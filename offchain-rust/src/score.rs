use crate::Address;
use crate::chain::{
    ChainError, block_by_number, chain_id, defi_insurance_at, earned_score_of, finalized_block,
    score_config_at, spent_score_at,
};
use crate::config::{CHAIN_ID, LOG_RESULT_CAP, MAX_LOG_RANGE};
use crate::rpc::{LogMetrics, Rpc};
use num_bigint::BigUint;
use num_traits::Zero;
use serde::Serialize;
use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InsuranceScoreSnapshot {
    pub network: &'static str,
    pub chain_id: String,
    pub registry: String,
    pub account: String,
    pub reference_block: String,
    pub reference_block_hash: String,
    pub score_cutoff_block: String,
    pub score_cutoff_block_hash: String,
    pub min_holding_required: String,
    pub gross_earned_score: String,
    pub score_spent: String,
    pub available_score: String,
    pub scored_tokens: Vec<String>,
    pub log_requests: String,
}

#[derive(Debug, Error)]
pub enum ScoreError {
    #[error(transparent)]
    Chain(#[from] ChainError),
    #[error("wrong chain: RPC reports {actual}, expected {expected}")]
    WrongChain { actual: u64, expected: u64 },
    #[error("Registry defiInsurance is zero")]
    ZeroDefiInsurance,
}

pub const fn score_cutoff_block(reference_block: u64, min_holding_required: u64) -> u64 {
    if reference_block > min_holding_required {
        reference_block - min_holding_required
    } else {
        1
    }
}

fn available_score(gross: &BigUint, spent: &BigUint) -> BigUint {
    if gross > spent {
        gross - spent
    } else {
        BigUint::zero()
    }
}

pub async fn insurance_score_at<R: Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    account: Address,
) -> Result<InsuranceScoreSnapshot, ScoreError> {
    let actual_chain = chain_id(rpc).await?;
    if actual_chain != CHAIN_ID {
        return Err(ScoreError::WrongChain {
            actual: actual_chain,
            expected: CHAIN_ID,
        });
    }
    let finalized = finalized_block(rpc).await?;
    let defi_insurance = defi_insurance_at(rpc, registry, Some(finalized.number)).await?;
    if defi_insurance.is_zero() {
        return Err(ScoreError::ZeroDefiInsurance);
    }
    let config = score_config_at(rpc, registry, defi_insurance, finalized.number).await?;
    let cutoff = score_cutoff_block(finalized.number, config.params.holding_margin_blocks);
    let cutoff_anchor = block_by_number(rpc, cutoff).await?;
    let (gross, LogMetrics { requests, .. }) = earned_score_of(
        rpc,
        &config.scored_tokens,
        account,
        cutoff,
        MAX_LOG_RANGE,
        LOG_RESULT_CAP,
    )
    .await?;
    let spent = spent_score_at(rpc, registry, account, finalized.number).await?;
    let available = available_score(&gross, &spent);
    let final_cutoff = block_by_number(rpc, cutoff).await?;
    if final_cutoff.hash != cutoff_anchor.hash {
        return Err(ChainError::AnchorChanged {
            name: "score cutoff",
            block: cutoff,
            before: cutoff_anchor.hash,
            after: final_cutoff.hash,
        }
        .into());
    }
    let final_reference = block_by_number(rpc, finalized.number).await?;
    if final_reference.hash != finalized.hash {
        return Err(ChainError::AnchorChanged {
            name: "score reference",
            block: finalized.number,
            before: finalized.hash,
            after: final_reference.hash,
        }
        .into());
    }

    Ok(InsuranceScoreSnapshot {
        network: if CHAIN_ID == 11_155_111 {
            "sepolia"
        } else {
            "mainnet"
        },
        chain_id: CHAIN_ID.to_string(),
        registry: registry.to_string(),
        account: account.to_string(),
        reference_block: finalized.number.to_string(),
        reference_block_hash: finalized.hash,
        score_cutoff_block: cutoff.to_string(),
        score_cutoff_block_hash: cutoff_anchor.hash,
        min_holding_required: config.params.holding_margin_blocks.to_string(),
        gross_earned_score: gross.to_string(),
        score_spent: spent.to_string(),
        available_score: available.to_string(),
        scored_tokens: config
            .scored_tokens
            .iter()
            .map(|token| token.token.to_string())
            .collect(),
        log_requests: requests.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::{available_score, score_cutoff_block};
    use num_bigint::BigUint;

    #[test]
    fn score_cutoff_uses_the_holding_maturation_window() {
        assert_eq!(score_cutoff_block(100, 7), 93);
        assert_eq!(score_cutoff_block(7, 7), 1);
        assert_eq!(score_cutoff_block(0, 7), 1);
    }

    #[test]
    fn available_score_never_underflows() {
        assert_eq!(
            available_score(&BigUint::from(10u8), &BigUint::from(3u8)),
            BigUint::from(7u8)
        );
        assert_eq!(
            available_score(&BigUint::from(3u8), &BigUint::from(10u8)),
            BigUint::from(0u8)
        );
    }
}
