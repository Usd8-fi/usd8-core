use num_bigint::BigUint;
use num_traits::Zero;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::str::FromStr;
use thiserror::Error;
use usd8_score_core::{
    AccountScoreState, RatePoint, ScoreCoreError, advance_account, apply_transfer, gross_score,
    projected_numerator, validate_rates,
};
use usd8_settlement::Address;
use usd8_settlement::chain::{
    ChainError, ScoredToken, TokenTransfer, balance_of_at, block_by_number, chain_id,
    defi_insurance_at, erc20_transfers_for_accounts, finalized_block, score_config_at,
    spent_score_at,
};
use usd8_settlement::config::{CHAIN_ID, LOG_RESULT_CAP, MAX_LOG_RANGE};
use usd8_settlement::rpc::{LogMetrics, Rpc};
use usd8_settlement::score::score_cutoff_block;

const CHECKPOINT_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PersistedAccountState {
    pub balance: String,
    pub last_block: String,
    pub completed_numerator: String,
    pub active_segment_from: Option<String>,
    pub active_integral: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PersistedRatePoint {
    pub from_block: String,
    pub rate: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TokenCheckpoint {
    pub token: String,
    pub decimals: u8,
    pub cursor_block: String,
    pub cursor_block_hash: String,
    pub rates: Vec<PersistedRatePoint>,
    pub account: PersistedAccountState,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UserCheckpoint {
    pub schema_version: u32,
    pub chain_id: String,
    pub registry: String,
    pub account: String,
    pub tokens: Vec<TokenCheckpoint>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedInsuranceScoreSnapshot {
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
    pub cache_status: &'static str,
}

#[derive(Debug, Error)]
pub enum IncrementalScoreError {
    #[error("malformed checkpoint field {0}")]
    Malformed(&'static str),
    #[error("checkpoint token does not match current token")]
    TokenMismatch,
    #[error("checkpoint token decimals do not match current token")]
    DecimalsMismatch,
    #[error("checkpoint rate history is not an exact prefix of current history")]
    RateHistoryMismatch,
    #[error("new score rate begins at or before checkpoint cursor")]
    RetroactiveRate,
    #[error("checkpoint cursor cannot move backward")]
    CursorRollback,
    #[error("transfer stream is outside the checkpoint interval or not ordered")]
    InvalidTransferOrder,
    #[error(transparent)]
    Core(#[from] ScoreCoreError),
    #[error(transparent)]
    Chain(#[from] ChainError),
    #[error("wrong chain: RPC reports {actual}, expected {expected}")]
    WrongChain { actual: u64, expected: u64 },
    #[error("Registry defiInsurance is zero")]
    ZeroDefiInsurance,
    #[error("checkpoint identity does not match this request")]
    CheckpointIdentity,
    #[error("checkpoint block hash does not match finalized chain history")]
    CheckpointBlockHash,
}

fn valid_hash(value: &str) -> bool {
    value.len() == 66
        && value.starts_with("0x")
        && value[2..].bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn decimal(value: &str, field: &'static str) -> Result<BigUint, IncrementalScoreError> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(IncrementalScoreError::Malformed(field));
    }
    BigUint::from_str(value).map_err(|_| IncrementalScoreError::Malformed(field))
}

fn decimal_u64(value: &str, field: &'static str) -> Result<u64, IncrementalScoreError> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(IncrementalScoreError::Malformed(field));
    }
    value
        .parse()
        .map_err(|_| IncrementalScoreError::Malformed(field))
}

fn persisted_rates(rates: &[RatePoint]) -> Vec<PersistedRatePoint> {
    rates
        .iter()
        .map(|point| PersistedRatePoint {
            from_block: point.from_block.to_string(),
            rate: point.rate.to_string(),
        })
        .collect()
}

fn parse_rates(rates: &[PersistedRatePoint]) -> Result<Vec<RatePoint>, IncrementalScoreError> {
    let parsed = rates
        .iter()
        .map(|point| {
            Ok(RatePoint {
                from_block: decimal_u64(&point.from_block, "rates.fromBlock")?,
                rate: decimal(&point.rate, "rates.rate")?,
            })
        })
        .collect::<Result<Vec<_>, IncrementalScoreError>>()?;
    validate_rates(&parsed)?;
    Ok(parsed)
}

fn persisted_account(state: &AccountScoreState) -> PersistedAccountState {
    PersistedAccountState {
        balance: state.balance.to_string(),
        last_block: state.last_block.to_string(),
        completed_numerator: state.completed_numerator.to_string(),
        active_segment_from: state.active_segment_from.map(|value| value.to_string()),
        active_integral: state.active_integral.to_string(),
    }
}

fn parse_account(
    state: &PersistedAccountState,
) -> Result<AccountScoreState, IncrementalScoreError> {
    Ok(AccountScoreState {
        balance: decimal(&state.balance, "account.balance")?,
        last_block: decimal_u64(&state.last_block, "account.lastBlock")?,
        completed_numerator: decimal(&state.completed_numerator, "account.completedNumerator")?,
        active_segment_from: state
            .active_segment_from
            .as_deref()
            .map(|value| decimal_u64(value, "account.activeSegmentFrom"))
            .transpose()?,
        active_integral: decimal(&state.active_integral, "account.activeIntegral")?,
    })
}

fn validate_checkpoint(
    checkpoint: &TokenCheckpoint,
    scored: &ScoredToken,
) -> Result<(u64, AccountScoreState), IncrementalScoreError> {
    if checkpoint.token != scored.token.to_string() {
        return Err(IncrementalScoreError::TokenMismatch);
    }
    if checkpoint.decimals != scored.decimals {
        return Err(IncrementalScoreError::DecimalsMismatch);
    }
    if !valid_hash(&checkpoint.cursor_block_hash) {
        return Err(IncrementalScoreError::Malformed("cursorBlockHash"));
    }
    let cursor = decimal_u64(&checkpoint.cursor_block, "cursorBlock")?;
    let old_rates = parse_rates(&checkpoint.rates)?;
    if scored.rates.len() < old_rates.len()
        || old_rates
            .iter()
            .zip(&scored.rates)
            .any(|(old, current)| old != current)
    {
        return Err(IncrementalScoreError::RateHistoryMismatch);
    }
    if scored.rates[old_rates.len()..]
        .iter()
        .any(|rate| rate.from_block <= cursor)
    {
        return Err(IncrementalScoreError::RetroactiveRate);
    }
    let state = parse_account(&checkpoint.account)?;
    if state.last_block != cursor {
        return Err(IncrementalScoreError::Malformed("account.lastBlock"));
    }
    Ok((cursor, state))
}

pub fn new_token_checkpoint(
    scored: &ScoredToken,
    starting_block: u64,
    starting_balance: BigUint,
    starting_block_hash: String,
) -> TokenCheckpoint {
    let state = AccountScoreState {
        balance: starting_balance,
        last_block: starting_block,
        ..AccountScoreState::default()
    };
    TokenCheckpoint {
        token: scored.token.to_string(),
        decimals: scored.decimals,
        cursor_block: starting_block.to_string(),
        cursor_block_hash: starting_block_hash.to_ascii_lowercase(),
        rates: persisted_rates(&scored.rates),
        account: persisted_account(&state),
    }
}

pub fn advance_token_checkpoint(
    checkpoint: &mut TokenCheckpoint,
    scored: &ScoredToken,
    account: Address,
    transfers: &[TokenTransfer],
    target_block: u64,
    target_block_hash: String,
) -> Result<(), IncrementalScoreError> {
    if !valid_hash(&target_block_hash) {
        return Err(IncrementalScoreError::Malformed("targetBlockHash"));
    }
    validate_rates(&scored.rates)?;
    let (cursor, mut state) = validate_checkpoint(checkpoint, scored)?;
    if target_block < cursor {
        return Err(IncrementalScoreError::CursorRollback);
    }
    let mut previous = None;
    for transfer in transfers {
        let order = (transfer.block_number, transfer.log_index);
        if transfer.block_number <= cursor
            || transfer.block_number > target_block
            || previous.is_some_and(|previous| order <= previous)
        {
            return Err(IncrementalScoreError::InvalidTransferOrder);
        }
        previous = Some(order);
        let inflow = if transfer.to == account {
            transfer.value.clone()
        } else {
            BigUint::from(0u8)
        };
        let outflow = if transfer.from == account {
            transfer.value.clone()
        } else {
            BigUint::from(0u8)
        };
        if inflow != BigUint::from(0u8) || outflow != BigUint::from(0u8) {
            apply_transfer(
                &mut state,
                transfer.block_number,
                &inflow,
                &outflow,
                &scored.rates,
                scored.decimals,
            )?;
        }
    }
    advance_account(&mut state, target_block, &scored.rates, scored.decimals)?;
    checkpoint.cursor_block = target_block.to_string();
    checkpoint.cursor_block_hash = target_block_hash.to_ascii_lowercase();
    checkpoint.rates = persisted_rates(&scored.rates);
    checkpoint.account = persisted_account(&state);
    Ok(())
}

pub fn token_numerator(
    checkpoint: &TokenCheckpoint,
    scored: &ScoredToken,
    target_block: u64,
) -> Result<BigUint, IncrementalScoreError> {
    let (cursor, state) = validate_checkpoint(checkpoint, scored)?;
    if target_block < cursor {
        return Err(IncrementalScoreError::CursorRollback);
    }
    Ok(projected_numerator(
        &state,
        target_block,
        &scored.rates,
        scored.decimals,
    )?)
}

fn merge_metrics(left: LogMetrics, right: LogMetrics) -> LogMetrics {
    LogMetrics {
        requests: left.requests.saturating_add(right.requests),
        bisections: left.bisections.saturating_add(right.bisections),
        errors: left.errors.saturating_add(right.errors),
        elapsed_ms: left.elapsed_ms.saturating_add(right.elapsed_ms),
    }
}

fn first_contributing_block(scored: &ScoredToken, target: u64) -> Option<u64> {
    scored
        .rates
        .iter()
        .find(|point| !point.rate.is_zero() && point.from_block < target)
        .map(|point| point.from_block)
}

fn checkpoint_cursor(checkpoint: &TokenCheckpoint) -> Result<u64, IncrementalScoreError> {
    decimal_u64(&checkpoint.cursor_block, "cursorBlock")
}

fn checkpoint_balance(checkpoint: &TokenCheckpoint) -> Result<BigUint, IncrementalScoreError> {
    decimal(&checkpoint.account.balance, "account.balance")
}

fn validate_user_checkpoint(
    checkpoint: &UserCheckpoint,
    registry: Address,
    account: Address,
) -> Result<(), IncrementalScoreError> {
    if checkpoint.schema_version != CHECKPOINT_SCHEMA_VERSION
        || checkpoint.chain_id != CHAIN_ID.to_string()
        || checkpoint.registry != registry.to_string()
        || checkpoint.account != account.to_string()
    {
        return Err(IncrementalScoreError::CheckpointIdentity);
    }
    Ok(())
}

pub async fn compute_incremental_score<R: Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    account: Address,
    previous: Option<UserCheckpoint>,
) -> Result<(CachedInsuranceScoreSnapshot, UserCheckpoint), IncrementalScoreError> {
    let actual_chain = chain_id(rpc).await?;
    if actual_chain != CHAIN_ID {
        return Err(IncrementalScoreError::WrongChain {
            actual: actual_chain,
            expected: CHAIN_ID,
        });
    }
    if let Some(checkpoint) = &previous {
        validate_user_checkpoint(checkpoint, registry, account)?;
    }
    let finalized = finalized_block(rpc).await?;
    let defi_insurance = defi_insurance_at(rpc, registry, Some(finalized.number)).await?;
    if defi_insurance.is_zero() {
        return Err(IncrementalScoreError::ZeroDefiInsurance);
    }
    let config = score_config_at(rpc, registry, defi_insurance, finalized.number).await?;
    let cutoff = score_cutoff_block(finalized.number, config.params.holding_margin_blocks);
    let cutoff_anchor = block_by_number(rpc, cutoff).await?;
    let mut next_tokens = Vec::new();
    let mut numerator = BigUint::zero();
    let mut metrics = LogMetrics::default();
    let mut advanced = false;
    let mut missed = previous.is_none();
    let tracked = BTreeSet::from([account]);

    for scored in &config.scored_tokens {
        let Some(starting_block) = first_contributing_block(scored, cutoff) else {
            continue;
        };
        let stored = previous.as_ref().and_then(|checkpoint| {
            checkpoint
                .tokens
                .iter()
                .find(|item| item.token == scored.token.to_string())
        });
        let mut checkpoint = if let Some(stored) = stored {
            let cursor = checkpoint_cursor(stored)?;
            let current_hash = block_by_number(rpc, cursor).await?.hash;
            if !current_hash.eq_ignore_ascii_case(&stored.cursor_block_hash) {
                return Err(IncrementalScoreError::CheckpointBlockHash);
            }
            stored.clone()
        } else {
            missed = true;
            let balance = balance_of_at(rpc, scored.token, account, starting_block).await?;
            let hash = block_by_number(rpc, starting_block).await?.hash;
            new_token_checkpoint(scored, starting_block, balance, hash)
        };
        let cursor = checkpoint_cursor(&checkpoint)?;
        if cursor < cutoff {
            let (transfers, transfer_metrics) = erc20_transfers_for_accounts(
                rpc,
                scored.token,
                &tracked,
                cursor + 1,
                cutoff,
                MAX_LOG_RANGE,
                LOG_RESULT_CAP,
            )
            .await?;
            metrics = merge_metrics(metrics, transfer_metrics);
            advance_token_checkpoint(
                &mut checkpoint,
                scored,
                account,
                &transfers,
                cutoff,
                cutoff_anchor.hash.clone(),
            )?;
            advanced = true;
        } else if cursor > cutoff {
            return Err(IncrementalScoreError::CursorRollback);
        }
        let actual_balance = balance_of_at(rpc, scored.token, account, cutoff).await?;
        if checkpoint_balance(&checkpoint)? != actual_balance {
            return Err(IncrementalScoreError::Malformed("replayedBalance"));
        }
        numerator += token_numerator(&checkpoint, scored, cutoff)?;
        next_tokens.push(checkpoint);
    }

    let gross = gross_score(numerator);
    let spent = spent_score_at(rpc, registry, account, finalized.number).await?;
    let available = if gross > spent {
        &gross - &spent
    } else {
        BigUint::zero()
    };
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
    let cache_status = if missed {
        "miss"
    } else if advanced {
        "advanced"
    } else {
        "hit"
    };
    let checkpoint = UserCheckpoint {
        schema_version: CHECKPOINT_SCHEMA_VERSION,
        chain_id: CHAIN_ID.to_string(),
        registry: registry.to_string(),
        account: account.to_string(),
        tokens: next_tokens,
    };
    let snapshot = CachedInsuranceScoreSnapshot {
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
        log_requests: metrics.requests.to_string(),
        cache_status,
    };
    Ok((snapshot, checkpoint))
}
