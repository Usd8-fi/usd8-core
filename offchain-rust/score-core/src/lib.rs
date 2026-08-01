use num_bigint::BigUint;
use thiserror::Error;

pub const SCORE_SCALE: u64 = 1_000_000_000_000_000_000;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RatePoint {
    pub from_block: u64,
    pub rate: BigUint,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AccountScoreState {
    pub balance: BigUint,
    pub last_block: u64,
    pub completed_numerator: BigUint,
    pub active_segment_from: Option<u64>,
    pub active_integral: BigUint,
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ScoreCoreError {
    #[error("score rate history must be strictly ascending")]
    RatesNotAscending,
    #[error("cannot move score account backward from {from_block} to {to_block}")]
    Backward { from_block: u64, to_block: u64 },
    #[error("active score rate segment {0} is absent from rate history")]
    MissingRate(u64),
    #[error("score transfer produces a negative balance at block {block}")]
    BalanceUnderflow { block: u64 },
}

pub fn validate_rates(rates: &[RatePoint]) -> Result<(), ScoreCoreError> {
    if rates
        .windows(2)
        .any(|pair| pair[0].from_block >= pair[1].from_block)
    {
        return Err(ScoreCoreError::RatesNotAscending);
    }
    Ok(())
}

fn scaled_integral(integral: BigUint, decimals: u8) -> BigUint {
    if decimals <= 18 {
        integral * BigUint::from(10u8).pow(u32::from(18 - decimals))
    } else {
        integral / BigUint::from(10u8).pow(u32::from(decimals - 18))
    }
}

fn rate_for(rates: &[RatePoint], from_block: u64) -> Result<&BigUint, ScoreCoreError> {
    rates
        .iter()
        .find(|point| point.from_block == from_block)
        .map(|point| &point.rate)
        .ok_or(ScoreCoreError::MissingRate(from_block))
}

fn finalize_active(
    state: &mut AccountScoreState,
    rates: &[RatePoint],
    decimals: u8,
) -> Result<(), ScoreCoreError> {
    let Some(from_block) = state.active_segment_from else {
        return Ok(());
    };
    state.completed_numerator +=
        scaled_integral(state.active_integral.clone(), decimals) * rate_for(rates, from_block)?;
    state.active_segment_from = None;
    state.active_integral = BigUint::from(0u8);
    Ok(())
}

pub fn advance_account(
    state: &mut AccountScoreState,
    to_block: u64,
    rates: &[RatePoint],
    decimals: u8,
) -> Result<(), ScoreCoreError> {
    validate_rates(rates)?;
    if to_block < state.last_block {
        return Err(ScoreCoreError::Backward {
            from_block: state.last_block,
            to_block,
        });
    }
    if to_block == state.last_block {
        return Ok(());
    }
    for (index, point) in rates.iter().enumerate() {
        let next = rates.get(index + 1).map(|next| next.from_block);
        let overlap_from = state.last_block.max(point.from_block);
        let overlap_to = next.map_or(to_block, |next| next.min(to_block));
        if overlap_from >= overlap_to {
            continue;
        }
        if state.active_segment_from != Some(point.from_block) {
            finalize_active(state, rates, decimals)?;
            state.active_segment_from = Some(point.from_block);
            state.active_integral = BigUint::from(0u8);
        }
        state.active_integral += &state.balance * BigUint::from(overlap_to - overlap_from);
        if next.is_some_and(|next| overlap_to == next && next <= to_block) {
            finalize_active(state, rates, decimals)?;
        }
    }
    state.last_block = to_block;
    Ok(())
}

pub fn apply_transfer(
    state: &mut AccountScoreState,
    block: u64,
    inflow: &BigUint,
    outflow: &BigUint,
    rates: &[RatePoint],
    decimals: u8,
) -> Result<(), ScoreCoreError> {
    advance_account(state, block, rates, decimals)?;
    if inflow >= outflow {
        state.balance += inflow - outflow;
    } else {
        let decrease = outflow - inflow;
        if decrease > state.balance {
            return Err(ScoreCoreError::BalanceUnderflow { block });
        }
        state.balance -= decrease;
    }
    Ok(())
}

pub fn projected_numerator(
    state: &AccountScoreState,
    to_block: u64,
    rates: &[RatePoint],
    decimals: u8,
) -> Result<BigUint, ScoreCoreError> {
    let mut projected = state.clone();
    advance_account(&mut projected, to_block, rates, decimals)?;
    let mut numerator = projected.completed_numerator;
    if let Some(from_block) = projected.active_segment_from {
        numerator +=
            scaled_integral(projected.active_integral, decimals) * rate_for(rates, from_block)?;
    }
    Ok(numerator)
}

pub fn gross_score(numerator: BigUint) -> BigUint {
    numerator / BigUint::from(SCORE_SCALE)
}
