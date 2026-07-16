use crate::abi::{
    IAggregatorV3, IDefiInsurance, IERC20, IERC1155, IRegistry, ISingleAssetCoverPool,
};
use crate::config::BootstrapConfig;
use crate::rpc::{LogFilter, LogMetrics, Rpc, RpcError, RpcLog, get_logs_chunked};
use crate::{Address, ClaimEvent, EventKind};
use alloy_primitives::{Address as AlloyAddress, B256, U256};
use alloy_sol_types::{SolCall, SolEvent};
use num_bigint::BigUint;
use num_traits::ToPrimitive;
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
use std::str::FromStr;
use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BlockAnchor {
    pub number: u64,
    pub timestamp: u64,
    pub hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SettlementAnchors {
    pub reference: BlockAnchor,
    pub open: BlockAnchor,
    pub window_end: BlockAnchor,
    pub finalized_head: BlockAnchor,
}

#[derive(Debug, Error)]
pub enum ChainError {
    #[error(transparent)]
    Rpc(#[from] RpcError),
    #[error("invalid RPC quantity for {0}")]
    InvalidQuantity(&'static str),
    #[error("invalid block response: {0}")]
    InvalidBlock(String),
    #[error(
        "claim window is not finalized: deadline {deadline}, finalized head {head} timestamp {timestamp}"
    )]
    WindowNotFinalized {
        deadline: u64,
        head: u64,
        timestamp: u64,
    },
    #[error(
        "settlement anchor is not finalized: reference {reference}, open {open}, finalized head {head}"
    )]
    AnchorNotFinalized {
        reference: u64,
        open: u64,
        head: u64,
    },
    #[error("anchor hash changed for {name} block {block}: {before} -> {after}")]
    AnchorChanged {
        name: &'static str,
        block: u64,
        before: String,
        after: String,
    },
    #[error("{label} {address} has no bytecode at block {block}")]
    MissingCode {
        label: String,
        address: String,
        block: u64,
    },
    #[error("invalid ABI response for {function}: {message}")]
    Abi {
        function: &'static str,
        message: String,
    },
    #[error("invalid eth_call result: {0}")]
    InvalidCallResult(String),
    #[error("uint256 overflow for {0}")]
    Uint256Overflow(&'static str),
    #[error("invalid incident configuration: {0}")]
    InvalidConfiguration(String),
    #[error("invalid pool topology: {0}")]
    InvalidPoolTopology(String),
    #[error("pool {pool} reports asset {actual}, expected {expected}")]
    PoolAssetMismatch {
        pool: Address,
        actual: Address,
        expected: Address,
    },
    #[error("invalid oracle {oracle}: {message}")]
    InvalidOracle { oracle: Address, message: String },
    #[error("invalid conversion {address}: {message}")]
    InvalidConversion { address: Address, message: String },
    #[error("cannot decode {event} at block {block} log {index}: {message}")]
    EventDecode {
        event: &'static str,
        block: u64,
        index: u64,
        message: String,
    },
    #[error("history replay underflow for {asset} at block {block} log {index}")]
    ReplayUnderflow {
        asset: Address,
        block: u64,
        index: u64,
    },
    #[error(
        "unsupported token balance semantics for {asset}: replay ended at {replayed}, balanceOf at block {block} is {actual}"
    )]
    BalanceReplayMismatch {
        asset: Address,
        replayed: BigUint,
        actual: BigUint,
        block: u64,
    },
    #[error("ERC1155 TransferBatch ids/values length mismatch")]
    BatchLengthMismatch,
}

pub fn quantity(value: &Value, field: &'static str) -> Result<u64, ChainError> {
    let raw = value
        .as_str()
        .and_then(|value| value.strip_prefix("0x"))
        .filter(|value| !value.is_empty())
        .ok_or(ChainError::InvalidQuantity(field))?;
    u64::from_str_radix(raw, 16).map_err(|_| ChainError::InvalidQuantity(field))
}

fn block_hash(value: &Value) -> Result<String, ChainError> {
    let hash = value
        .as_str()
        .and_then(|value| value.strip_prefix("0x"))
        .filter(|value| value.len() == 64 && hex::decode(value).is_ok())
        .ok_or_else(|| ChainError::InvalidBlock("missing or malformed hash".to_owned()))?;
    Ok(format!("0x{}", hash.to_ascii_lowercase()))
}

async fn block<R: Rpc + ?Sized>(
    rpc: &R,
    tag: &str,
    expected_number: Option<u64>,
) -> Result<BlockAnchor, ChainError> {
    let value = rpc
        .request("eth_getBlockByNumber", json!([tag, false]))
        .await?;
    if value.is_null() {
        return Err(ChainError::InvalidBlock(format!("block {tag} not found")));
    }
    let number = quantity(&value["number"], "block.number")?;
    if let Some(expected) = expected_number
        && expected != number
    {
        return Err(ChainError::InvalidBlock(format!(
            "requested block {expected} but provider returned {number}"
        )));
    }
    Ok(BlockAnchor {
        number,
        timestamp: quantity(&value["timestamp"], "block.timestamp")?,
        hash: block_hash(&value["hash"])?,
    })
}

pub async fn block_by_number<R: Rpc + ?Sized>(
    rpc: &R,
    number: u64,
) -> Result<BlockAnchor, ChainError> {
    block(rpc, &format!("0x{number:x}"), Some(number)).await
}

pub async fn finalized_block<R: Rpc + ?Sized>(rpc: &R) -> Result<BlockAnchor, ChainError> {
    block(rpc, "finalized", None).await
}

pub async fn chain_id<R: Rpc + ?Sized>(rpc: &R) -> Result<u64, ChainError> {
    let value = rpc.request("eth_chainId", json!([])).await?;
    quantity(&value, "chainId")
}

pub async fn block_at_or_before_timestamp<R: Rpc + ?Sized>(
    rpc: &R,
    timestamp: u64,
    upper_bound: u64,
) -> Result<u64, ChainError> {
    let head = block_by_number(rpc, upper_bound).await?;
    if head.timestamp < timestamp {
        return Err(ChainError::WindowNotFinalized {
            deadline: timestamp,
            head: head.number,
            timestamp: head.timestamp,
        });
    }
    let mut low = 1u64;
    let mut high = upper_bound;
    while low < high {
        let middle = low + (high - low).div_ceil(2);
        let candidate = block_by_number(rpc, middle).await?;
        if candidate.timestamp <= timestamp {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    Ok(low)
}

pub async fn finalized_settlement_anchors<R: Rpc + ?Sized>(
    rpc: &R,
    reference_block: u64,
    open_block: u64,
    window_end_timestamp: u64,
) -> Result<SettlementAnchors, ChainError> {
    let finalized = finalized_block(rpc).await?;
    if finalized.timestamp < window_end_timestamp {
        return Err(ChainError::WindowNotFinalized {
            deadline: window_end_timestamp,
            head: finalized.number,
            timestamp: finalized.timestamp,
        });
    }
    if reference_block > finalized.number || open_block > finalized.number {
        return Err(ChainError::AnchorNotFinalized {
            reference: reference_block,
            open: open_block,
            head: finalized.number,
        });
    }
    let window_end_block =
        block_at_or_before_timestamp(rpc, window_end_timestamp, finalized.number).await?;
    Ok(SettlementAnchors {
        reference: block_by_number(rpc, reference_block).await?,
        open: block_by_number(rpc, open_block).await?,
        window_end: block_by_number(rpc, window_end_block).await?,
        finalized_head: finalized,
    })
}

pub async fn assert_anchors_unchanged<R: Rpc + ?Sized>(
    rpc: &R,
    anchors: &SettlementAnchors,
) -> Result<(), ChainError> {
    for (name, expected) in [
        ("reference", &anchors.reference),
        ("open", &anchors.open),
        ("windowEnd", &anchors.window_end),
        ("finalizedHead", &anchors.finalized_head),
    ] {
        let actual = block_by_number(rpc, expected.number).await?;
        if actual.hash != expected.hash {
            return Err(ChainError::AnchorChanged {
                name,
                block: expected.number,
                before: expected.hash.clone(),
                after: actual.hash,
            });
        }
    }
    Ok(())
}

pub async fn assert_contract_code_at<R: Rpc + ?Sized>(
    rpc: &R,
    address: &str,
    label: &str,
    block_number: u64,
) -> Result<(), ChainError> {
    let code = rpc
        .request(
            "eth_getCode",
            json!([address, format!("0x{block_number:x}")]),
        )
        .await?;
    if code
        .as_str()
        .is_none_or(|code| code == "0x" || code.is_empty())
    {
        return Err(ChainError::MissingCode {
            label: label.to_owned(),
            address: address.to_owned(),
            block: block_number,
        });
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Incident {
    pub insured_token: Address,
    pub claim_window_end_time: u64,
    pub root: String,
    pub unresolved: BigUint,
    pub root_submitted_at: u64,
    pub reference_block: u64,
    pub open_block: u64,
    pub status: u8,
    pub disputed_at: u64,
    pub claim_set_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SettlementParams {
    pub twap_lookback_blocks: u64,
    pub holding_margin_blocks: u64,
    pub sample_step_blocks: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RatePoint {
    pub from_block: u64,
    pub rate: BigUint,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ScoredToken {
    pub token: Address,
    pub decimals: u8,
    pub rates: Vec<RatePoint>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IncidentConfig {
    pub coverage_bps: BigUint,
    pub underlying_price_oracle: Address,
    pub conversion_address: Address,
    pub conversion_call_data: Vec<u8>,
    pub params: SettlementParams,
    pub scored_tokens: Vec<ScoredToken>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PoolTopology {
    pub assets: Vec<Address>,
    pub pool_addrs: Vec<Address>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PoolState {
    pub asset: Address,
    pub pool: Address,
    pub balance: BigUint,
    pub asset_usd: BigUint,
    pub asset_decimals: u8,
}

fn from_alloy(value: AlloyAddress) -> Address {
    Address::from_bytes(value.into_array())
}

fn to_alloy(value: Address) -> AlloyAddress {
    AlloyAddress::from_slice(value.as_slice())
}

fn u256_to_big(value: U256) -> BigUint {
    BigUint::from_bytes_be(&value.to_be_bytes::<32>())
}

fn u256_to_u64(value: U256, field: &'static str) -> Result<u64, ChainError> {
    u256_to_big(value)
        .to_u64()
        .ok_or(ChainError::Uint256Overflow(field))
}

fn big_to_u256(value: &BigUint, field: &'static str) -> Result<U256, ChainError> {
    let bytes = value.to_bytes_be();
    if bytes.len() > 32 {
        return Err(ChainError::Uint256Overflow(field));
    }
    Ok(U256::from_be_slice(&bytes))
}

fn decode_call_result(value: Value) -> Result<Vec<u8>, ChainError> {
    let encoded = value
        .as_str()
        .and_then(|value| value.strip_prefix("0x"))
        .filter(|value| value.len().is_multiple_of(2))
        .ok_or_else(|| {
            ChainError::InvalidCallResult("result is not 0x-prefixed even-length hex".to_owned())
        })?;
    hex::decode(encoded)
        .map_err(|_| ChainError::InvalidCallResult("result is not valid hex".to_owned()))
}

pub async fn raw_call<R: Rpc + ?Sized>(
    rpc: &R,
    to: Address,
    data: &[u8],
    block_number: Option<u64>,
) -> Result<Vec<u8>, ChainError> {
    let tag = block_number
        .map(|number| format!("0x{number:x}"))
        .unwrap_or_else(|| "latest".to_owned());
    let result = rpc
        .request(
            "eth_call",
            json!([{
                "to": to.to_string(),
                "data": format!("0x{}", hex::encode(data))
            }, tag]),
        )
        .await?;
    decode_call_result(result)
}

pub async fn contract_call<R, C>(
    rpc: &R,
    to: Address,
    call: &C,
    block_number: Option<u64>,
) -> Result<C::Return, ChainError>
where
    R: Rpc + ?Sized,
    C: SolCall,
{
    let data = raw_call(rpc, to, &call.abi_encode(), block_number).await?;
    C::abi_decode_returns_validate(&data).map_err(|error| ChainError::Abi {
        function: C::SIGNATURE,
        message: error.to_string(),
    })
}

pub async fn incident_at<R: Rpc + ?Sized>(
    rpc: &R,
    defi_insurance: Address,
    incident_id: BigUint,
    block_number: Option<u64>,
) -> Result<Incident, ChainError> {
    let result = contract_call(
        rpc,
        defi_insurance,
        &IDefiInsurance::incidentsCall {
            incidentId: big_to_u256(&incident_id, "incidentId")?,
        },
        block_number,
    )
    .await?;
    Ok(Incident {
        insured_token: from_alloy(result.insuredToken),
        claim_window_end_time: result.claimWindowEndTime,
        root: format!("{:#x}", result.root),
        unresolved: u256_to_big(result.unresolved),
        root_submitted_at: result.rootSubmittedAt,
        reference_block: result.referenceBlock,
        open_block: result.openBlock,
        status: result.status,
        disputed_at: result.disputedAt,
        claim_set_hash: format!("{:#x}", result.claimSetHash),
    })
}

pub async fn decimals_at<R: Rpc + ?Sized>(
    rpc: &R,
    token: Address,
    block_number: u64,
) -> Result<u8, ChainError> {
    contract_call(rpc, token, &IERC20::decimalsCall {}, Some(block_number)).await
}

pub async fn balance_of_at<R: Rpc + ?Sized>(
    rpc: &R,
    token: Address,
    account: Address,
    block_number: u64,
) -> Result<BigUint, ChainError> {
    let value = contract_call(
        rpc,
        token,
        &IERC20::balanceOfCall {
            account: to_alloy(account),
        },
        Some(block_number),
    )
    .await?;
    Ok(u256_to_big(value))
}

pub async fn erc1155_balance_of_at<R: Rpc + ?Sized>(
    rpc: &R,
    collection: Address,
    account: Address,
    id: &BigUint,
    block_number: u64,
) -> Result<BigUint, ChainError> {
    let value = contract_call(
        rpc,
        collection,
        &IERC1155::balanceOfCall {
            account: to_alloy(account),
            id: big_to_u256(id, "ERC1155 id")?,
        },
        Some(block_number),
    )
    .await?;
    Ok(u256_to_big(value))
}

pub async fn spent_score_at<R: Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    account: Address,
    block_number: u64,
) -> Result<BigUint, ChainError> {
    let value = contract_call(
        rpc,
        registry,
        &IRegistry::scoreSpentCall {
            account: to_alloy(account),
        },
        Some(block_number),
    )
    .await?;
    Ok(u256_to_big(value))
}

pub async fn booster_nft_at<R: Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    block_number: u64,
) -> Result<Address, ChainError> {
    let value = contract_call(
        rpc,
        registry,
        &IRegistry::boosterNFTCall {},
        Some(block_number),
    )
    .await?;
    Ok(from_alloy(value))
}

pub async fn max_cover_pool_payout_bps_at<R: Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    block_number: u64,
) -> Result<BigUint, ChainError> {
    let value = contract_call(
        rpc,
        registry,
        &IRegistry::maxCoverPoolPayoutBpsCall {},
        Some(block_number),
    )
    .await?;
    Ok(u256_to_big(value))
}

pub async fn incident_config_at<R: Rpc + ?Sized>(
    rpc: &R,
    config: &BootstrapConfig,
    insured_token: Address,
    open_block: u64,
) -> Result<IncidentConfig, ChainError> {
    let insured = contract_call(
        rpc,
        config.defi_insurance,
        &IDefiInsurance::getInsuredTokenCall {
            token: to_alloy(insured_token),
        },
        Some(open_block),
    )
    .await?;
    if insured.maxCoverageBps.is_zero() || insured.maxCoverageBps > U256::from(10_000u64) {
        return Err(ChainError::InvalidConfiguration(
            "maxCoverageBps must be in 1..=10000 at open block".to_owned(),
        ));
    }
    if insured.underlyingPriceOracle.is_zero() {
        return Err(ChainError::InvalidConfiguration(
            "underlyingPriceOracle is zero".to_owned(),
        ));
    }
    let params = contract_call(
        rpc,
        config.defi_insurance,
        &IDefiInsurance::settlementParamsCall {},
        Some(open_block),
    )
    .await?;
    if params.sampleStepBlocks == 0 {
        return Err(ChainError::InvalidConfiguration(
            "sampleStepBlocks is zero".to_owned(),
        ));
    }

    let token_addresses = contract_call(
        rpc,
        config.registry,
        &IRegistry::getScoredTokensCall {},
        Some(open_block),
    )
    .await?;
    let mut seen = HashSet::new();
    let mut scored_tokens = Vec::with_capacity(token_addresses.len());
    for token in token_addresses {
        let token = from_alloy(token);
        if !seen.insert(token) {
            return Err(ChainError::InvalidConfiguration(format!(
                "duplicate scored token {token}"
            )));
        }
        let rates = contract_call(
            rpc,
            config.registry,
            &IRegistry::getScoredRateHistoryCall {
                token: to_alloy(token),
            },
            Some(open_block),
        )
        .await?;
        if rates.is_empty() {
            return Err(ChainError::InvalidConfiguration(format!(
                "scored token {token} has no rate history"
            )));
        }
        let mut previous = None;
        let rates = rates
            .into_iter()
            .map(|point| {
                if previous.is_some_and(|block| point.fromBlock <= block) {
                    return Err(ChainError::InvalidConfiguration(format!(
                        "rate history for {token} is not strictly ascending"
                    )));
                }
                previous = Some(point.fromBlock);
                Ok(RatePoint {
                    from_block: point.fromBlock,
                    rate: BigUint::from(point.rate),
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        scored_tokens.push(ScoredToken {
            token,
            decimals: decimals_at(rpc, token, open_block).await?,
            rates,
        });
    }

    Ok(IncidentConfig {
        coverage_bps: u256_to_big(insured.maxCoverageBps),
        underlying_price_oracle: from_alloy(insured.underlyingPriceOracle),
        conversion_address: from_alloy(insured.underlyingConversionAddress),
        conversion_call_data: insured.underlyingConversionCallData.to_vec(),
        params: SettlementParams {
            twap_lookback_blocks: params.twapLookbackBlocks,
            holding_margin_blocks: params.holdingMarginBlocks,
            sample_step_blocks: params.sampleStepBlocks,
        },
        scored_tokens,
    })
}

pub async fn pools_at<R: Rpc + ?Sized>(
    rpc: &R,
    config: &BootstrapConfig,
    block_number: u64,
) -> Result<PoolTopology, ChainError> {
    let result = contract_call(
        rpc,
        config.registry,
        &IRegistry::coverPoolsCall {},
        Some(block_number),
    )
    .await?;
    if result.assets.len() != result.poolAddrs.len() {
        return Err(ChainError::InvalidPoolTopology(format!(
            "{} assets but {} pools",
            result.assets.len(),
            result.poolAddrs.len()
        )));
    }
    let assets = result
        .assets
        .into_iter()
        .map(from_alloy)
        .collect::<Vec<_>>();
    let pool_addrs = result
        .poolAddrs
        .into_iter()
        .map(from_alloy)
        .collect::<Vec<_>>();
    let unique_assets = assets.iter().copied().collect::<HashSet<_>>();
    let unique_pools = pool_addrs.iter().copied().collect::<HashSet<_>>();
    if unique_assets.len() != assets.len() || unique_pools.len() != pool_addrs.len() {
        return Err(ChainError::InvalidPoolTopology(
            "duplicate asset or pool".to_owned(),
        ));
    }
    Ok(PoolTopology { assets, pool_addrs })
}

pub async fn ratio_at<R: Rpc + ?Sized>(
    rpc: &R,
    conversion_address: Address,
    conversion_call_data: &[u8],
    block_number: u64,
) -> Result<BigUint, ChainError> {
    if conversion_address.is_zero() {
        return Ok(BigUint::from(1_000_000_000_000_000_000u64));
    }
    let result = raw_call(
        rpc,
        conversion_address,
        conversion_call_data,
        Some(block_number),
    )
    .await?;
    if result.len() != 32 {
        return Err(ChainError::InvalidConversion {
            address: conversion_address,
            message: "returned malformed uint256 data".to_owned(),
        });
    }
    let ratio = BigUint::from_bytes_be(&result);
    if ratio == BigUint::from(0u8) {
        return Err(ChainError::InvalidConversion {
            address: conversion_address,
            message: "returned non-positive ratio".to_owned(),
        });
    }
    Ok(ratio)
}

pub async fn price_usd_1e18<R: Rpc + ?Sized>(
    rpc: &R,
    oracle: Address,
    block_number: u64,
    max_staleness: u64,
) -> Result<BigUint, ChainError> {
    let round = contract_call(
        rpc,
        oracle,
        &IAggregatorV3::latestRoundDataCall {},
        Some(block_number),
    )
    .await?;
    if round.answer.is_negative() || round.answer.is_zero() {
        return Err(ChainError::InvalidOracle {
            oracle,
            message: "returned non-positive price".to_owned(),
        });
    }
    let started_at = u256_to_u64(round.startedAt, "oracle.startedAt")?;
    let updated_at = u256_to_u64(round.updatedAt, "oracle.updatedAt")?;
    if started_at == 0 || updated_at == 0 {
        return Err(ChainError::InvalidOracle {
            oracle,
            message: "round incomplete".to_owned(),
        });
    }
    if started_at > updated_at {
        return Err(ChainError::InvalidOracle {
            oracle,
            message: format!("startedAt {started_at} is after updatedAt {updated_at}"),
        });
    }
    if round.answeredInRound < round.roundId {
        return Err(ChainError::InvalidOracle {
            oracle,
            message: "answeredInRound is older than roundId".to_owned(),
        });
    }
    let block_timestamp = block_by_number(rpc, block_number).await?.timestamp;
    if updated_at > block_timestamp {
        return Err(ChainError::InvalidOracle {
            oracle,
            message: format!(
                "updatedAt {updated_at} is later than pinned block ts {block_timestamp}"
            ),
        });
    }
    if block_timestamp - updated_at > max_staleness {
        return Err(ChainError::InvalidOracle {
            oracle,
            message: format!("stale at pinned block timestamp {block_timestamp}"),
        });
    }
    let decimals = contract_call(
        rpc,
        oracle,
        &IAggregatorV3::decimalsCall {},
        Some(block_number),
    )
    .await?;
    let answer = u256_to_big(round.answer.unsigned_abs());
    Ok(if decimals <= 18 {
        answer * BigUint::from(10u8).pow(u32::from(18 - decimals))
    } else {
        answer / BigUint::from(10u8).pow(u32::from(decimals - 18))
    })
}

pub async fn pool_state_at<R: Rpc + ?Sized>(
    rpc: &R,
    config: &BootstrapConfig,
    asset: Address,
    pool: Address,
    block_number: u64,
) -> Result<PoolState, ChainError> {
    let actual_asset = from_alloy(
        contract_call(
            rpc,
            pool,
            &ISingleAssetCoverPool::assetCall {},
            Some(block_number),
        )
        .await?,
    );
    if actual_asset != asset {
        return Err(ChainError::PoolAssetMismatch {
            pool,
            actual: actual_asset,
            expected: asset,
        });
    }
    let balance = u256_to_big(
        contract_call(
            rpc,
            pool,
            &ISingleAssetCoverPool::totalAssetsCall {},
            Some(block_number),
        )
        .await?,
    );
    let feed = config
        .asset_feed(&asset.to_string())
        .map_err(|_| ChainError::InvalidPoolTopology(format!("missing USD feed for {asset}")))?;
    Ok(PoolState {
        asset,
        pool,
        balance,
        asset_usd: price_usd_1e18(rpc, feed, block_number, config.max_oracle_staleness).await?,
        asset_decimals: decimals_at(rpc, asset, block_number).await?,
    })
}

fn topic_hash(value: B256) -> Value {
    Value::String(format!("{value:#x}"))
}

fn uint_topic(value: &BigUint, field: &'static str) -> Result<Value, ChainError> {
    let word = big_to_u256(value, field)?.to_be_bytes::<32>();
    Ok(Value::String(format!("0x{}", hex::encode(word))))
}

fn address_topic(value: Address) -> Value {
    let mut word = [0u8; 32];
    word[12..].copy_from_slice(value.as_slice());
    Value::String(format!("0x{}", hex::encode(word)))
}

fn decode_event<E: SolEvent>(log: &RpcLog) -> Result<E, ChainError> {
    let topics = log
        .topics
        .iter()
        .map(|topic| B256::from_str(topic))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| ChainError::EventDecode {
            event: E::SIGNATURE,
            block: log.block_number,
            index: log.log_index,
            message: error.to_string(),
        })?;
    let data = hex::decode(log.data.trim_start_matches("0x")).map_err(|error| {
        ChainError::EventDecode {
            event: E::SIGNATURE,
            block: log.block_number,
            index: log.log_index,
            message: error.to_string(),
        }
    })?;
    E::decode_raw_log_validate(topics, &data).map_err(|error| ChainError::EventDecode {
        event: E::SIGNATURE,
        block: log.block_number,
        index: log.log_index,
        message: error.to_string(),
    })
}

fn merge_log_metrics(left: LogMetrics, right: LogMetrics) -> LogMetrics {
    LogMetrics {
        requests: left.requests.saturating_add(right.requests),
        bisections: left.bisections.saturating_add(right.bisections),
        errors: left.errors.saturating_add(right.errors),
        elapsed_ms: left.elapsed_ms.saturating_add(right.elapsed_ms),
    }
}

pub async fn read_input_events<R: Rpc + ?Sized>(
    rpc: &R,
    defi_insurance: Address,
    incident_id: &BigUint,
    from_block: u64,
    to_block: u64,
    max_range: u64,
    result_cap: usize,
) -> Result<(Vec<ClaimEvent>, LogMetrics), ChainError> {
    let registration_filter = LogFilter {
        address: defi_insurance.to_string(),
        topics: vec![
            topic_hash(IDefiInsurance::ClaimRegistered::SIGNATURE_HASH),
            Value::Null,
            uint_topic(incident_id, "incidentId")?,
        ],
    };
    let (registration_logs, registration_metrics) = get_logs_chunked(
        rpc,
        &registration_filter,
        from_block,
        to_block,
        max_range,
        result_cap,
    )
    .await?;
    let mut claim_ids = HashSet::with_capacity(registration_logs.len());
    let mut events = Vec::with_capacity(registration_logs.len());
    for log in registration_logs {
        let decoded = decode_event::<IDefiInsurance::ClaimRegistered>(&log)?;
        let claim_id = u256_to_big(decoded.claimId);
        claim_ids.insert(claim_id.clone());
        events.push(ClaimEvent {
            kind: EventKind::Register,
            claim_id,
            user: from_alloy(decoded.user),
            amount: BigUint::from(decoded.insuredTokenAmount),
            score_to_spend: u256_to_big(decoded.scoreToSpend),
            booster_amount: u256_to_big(decoded.boosterAmount),
            block_number: log.block_number,
            log_index: log.log_index,
        });
    }

    // ClaimCancelled has no incidentId topic; read all and retain registered IDs.
    let cancellation_filter = LogFilter {
        address: defi_insurance.to_string(),
        topics: vec![topic_hash(IDefiInsurance::ClaimCancelled::SIGNATURE_HASH)],
    };
    let (cancellation_logs, cancellation_metrics) = get_logs_chunked(
        rpc,
        &cancellation_filter,
        from_block,
        to_block,
        max_range,
        result_cap,
    )
    .await?;
    for log in cancellation_logs {
        let decoded = decode_event::<IDefiInsurance::ClaimCancelled>(&log)?;
        let claim_id = u256_to_big(decoded.claimId);
        if claim_ids.contains(&claim_id) {
            events.push(ClaimEvent {
                kind: EventKind::Cancel,
                claim_id,
                user: from_alloy(decoded.user),
                amount: BigUint::from(0u8),
                score_to_spend: BigUint::from(0u8),
                booster_amount: BigUint::from(0u8),
                block_number: log.block_number,
                log_index: log.log_index,
            });
        }
    }
    events.sort_by_key(|event| (event.block_number, event.log_index));
    Ok((
        events,
        merge_log_metrics(registration_metrics, cancellation_metrics),
    ))
}

#[derive(Default)]
struct NetDelta {
    inflow: BigUint,
    outflow: BigUint,
}

fn add_delta(
    deltas: &mut BTreeMap<(u64, u64), NetDelta>,
    log: &RpcLog,
    value: BigUint,
    inflow: bool,
) {
    let delta = deltas.entry((log.block_number, log.log_index)).or_default();
    if inflow {
        delta.inflow += value;
    } else {
        delta.outflow += value;
    }
}

fn apply_deltas(
    asset: Address,
    mut balance: BigUint,
    deltas: BTreeMap<(u64, u64), NetDelta>,
) -> Result<(BigUint, BigUint), ChainError> {
    let mut minimum = balance.clone();
    for ((block, index), delta) in deltas {
        if delta.inflow >= delta.outflow {
            balance += delta.inflow - delta.outflow;
        } else {
            let decrease = delta.outflow - delta.inflow;
            if decrease > balance {
                return Err(ChainError::ReplayUnderflow {
                    asset,
                    block,
                    index,
                });
            }
            balance -= decrease;
            if balance < minimum {
                minimum = balance.clone();
            }
        }
    }
    Ok((minimum, balance))
}

pub async fn min_balance_over<R: Rpc + ?Sized>(
    rpc: &R,
    token: Address,
    account: Address,
    from_block: u64,
    to_block: u64,
    max_range: u64,
    result_cap: usize,
) -> Result<(BigUint, LogMetrics), ChainError> {
    let starting_balance = balance_of_at(rpc, token, account, from_block).await?;
    if to_block <= from_block {
        return Ok((starting_balance, LogMetrics::default()));
    }
    let from_filter = LogFilter {
        address: token.to_string(),
        topics: vec![
            topic_hash(IERC20::Transfer::SIGNATURE_HASH),
            address_topic(account),
        ],
    };
    let to_filter = LogFilter {
        address: token.to_string(),
        topics: vec![
            topic_hash(IERC20::Transfer::SIGNATURE_HASH),
            Value::Null,
            address_topic(account),
        ],
    };
    let (outgoing, outgoing_metrics) = get_logs_chunked(
        rpc,
        &from_filter,
        from_block + 1,
        to_block,
        max_range,
        result_cap,
    )
    .await?;
    let (incoming, incoming_metrics) = get_logs_chunked(
        rpc,
        &to_filter,
        from_block + 1,
        to_block,
        max_range,
        result_cap,
    )
    .await?;
    let mut deltas = BTreeMap::new();
    for log in outgoing {
        let event = decode_event::<IERC20::Transfer>(&log)?;
        add_delta(&mut deltas, &log, u256_to_big(event.value), false);
    }
    for log in incoming {
        let event = decode_event::<IERC20::Transfer>(&log)?;
        add_delta(&mut deltas, &log, u256_to_big(event.value), true);
    }
    let (minimum, replayed) = apply_deltas(token, starting_balance, deltas)?;
    let actual = balance_of_at(rpc, token, account, to_block).await?;
    if actual != replayed {
        return Err(ChainError::BalanceReplayMismatch {
            asset: token,
            replayed,
            actual,
            block: to_block,
        });
    }
    Ok((
        minimum,
        merge_log_metrics(outgoing_metrics, incoming_metrics),
    ))
}

fn values_for_id(ids: &[U256], values: &[U256], wanted: U256) -> Result<BigUint, ChainError> {
    if ids.len() != values.len() {
        return Err(ChainError::BatchLengthMismatch);
    }
    Ok(ids
        .iter()
        .zip(values)
        .filter(|(id, _)| **id == wanted)
        .fold(BigUint::from(0u8), |sum, (_, value)| {
            sum + u256_to_big(*value)
        }))
}

#[allow(clippy::too_many_arguments)] // Historical range and provider completeness policy are independent inputs.
pub async fn min_erc1155_balance_over<R: Rpc + ?Sized>(
    rpc: &R,
    collection: Address,
    account: Address,
    id: &BigUint,
    from_block: u64,
    to_block: u64,
    max_range: u64,
    result_cap: usize,
) -> Result<(BigUint, LogMetrics), ChainError> {
    let starting_balance = erc1155_balance_of_at(rpc, collection, account, id, from_block).await?;
    if to_block <= from_block {
        return Ok((starting_balance, LogMetrics::default()));
    }
    let from_topic = address_topic(account);
    let to_topic = address_topic(account);
    let queries = [
        (
            LogFilter {
                address: collection.to_string(),
                topics: vec![
                    topic_hash(IERC1155::TransferSingle::SIGNATURE_HASH),
                    Value::Null,
                    from_topic.clone(),
                ],
            },
            false,
            false,
        ),
        (
            LogFilter {
                address: collection.to_string(),
                topics: vec![
                    topic_hash(IERC1155::TransferSingle::SIGNATURE_HASH),
                    Value::Null,
                    Value::Null,
                    to_topic.clone(),
                ],
            },
            true,
            false,
        ),
        (
            LogFilter {
                address: collection.to_string(),
                topics: vec![
                    topic_hash(IERC1155::TransferBatch::SIGNATURE_HASH),
                    Value::Null,
                    from_topic,
                ],
            },
            false,
            true,
        ),
        (
            LogFilter {
                address: collection.to_string(),
                topics: vec![
                    topic_hash(IERC1155::TransferBatch::SIGNATURE_HASH),
                    Value::Null,
                    Value::Null,
                    to_topic,
                ],
            },
            true,
            true,
        ),
    ];
    let wanted = big_to_u256(id, "ERC1155 id")?;
    let mut deltas = BTreeMap::new();
    let mut metrics = LogMetrics::default();
    for (filter, inflow, batch) in queries {
        let (logs, query_metrics) = get_logs_chunked(
            rpc,
            &filter,
            from_block + 1,
            to_block,
            max_range,
            result_cap,
        )
        .await?;
        metrics = merge_log_metrics(metrics, query_metrics);
        for log in logs {
            let value = if batch {
                let event = decode_event::<IERC1155::TransferBatch>(&log)?;
                values_for_id(&event.ids, &event.values, wanted)?
            } else {
                let event = decode_event::<IERC1155::TransferSingle>(&log)?;
                if event.id == wanted {
                    u256_to_big(event.value)
                } else {
                    BigUint::from(0u8)
                }
            };
            if value != BigUint::from(0u8) {
                add_delta(&mut deltas, &log, value, inflow);
            }
        }
    }
    let (minimum, replayed) = apply_deltas(collection, starting_balance, deltas)?;
    let actual = erc1155_balance_of_at(rpc, collection, account, id, to_block).await?;
    if actual != replayed {
        return Err(ChainError::BalanceReplayMismatch {
            asset: collection,
            replayed,
            actual,
            block: to_block,
        });
    }
    Ok((minimum, metrics))
}

pub async fn token_block_integral<R: Rpc + ?Sized>(
    rpc: &R,
    token: Address,
    account: Address,
    from_block: u64,
    to_block: u64,
    max_range: u64,
    result_cap: usize,
) -> Result<(BigUint, LogMetrics), ChainError> {
    if to_block <= from_block {
        return Ok((BigUint::from(0u8), LogMetrics::default()));
    }
    let mut balance = balance_of_at(rpc, token, account, from_block).await?;
    let from_filter = LogFilter {
        address: token.to_string(),
        topics: vec![
            topic_hash(IERC20::Transfer::SIGNATURE_HASH),
            address_topic(account),
        ],
    };
    let to_filter = LogFilter {
        address: token.to_string(),
        topics: vec![
            topic_hash(IERC20::Transfer::SIGNATURE_HASH),
            Value::Null,
            address_topic(account),
        ],
    };
    let (outgoing, outgoing_metrics) = get_logs_chunked(
        rpc,
        &from_filter,
        from_block + 1,
        to_block,
        max_range,
        result_cap,
    )
    .await?;
    let (incoming, incoming_metrics) = get_logs_chunked(
        rpc,
        &to_filter,
        from_block + 1,
        to_block,
        max_range,
        result_cap,
    )
    .await?;
    let mut deltas = BTreeMap::new();
    for log in outgoing {
        let event = decode_event::<IERC20::Transfer>(&log)?;
        add_delta(&mut deltas, &log, u256_to_big(event.value), false);
    }
    for log in incoming {
        let event = decode_event::<IERC20::Transfer>(&log)?;
        add_delta(&mut deltas, &log, u256_to_big(event.value), true);
    }

    let mut accumulator = BigUint::from(0u8);
    let mut cursor = from_block;
    for ((block, index), delta) in deltas {
        accumulator += &balance * BigUint::from(block - cursor);
        cursor = block;
        if delta.inflow >= delta.outflow {
            balance += delta.inflow - delta.outflow;
        } else {
            let decrease = delta.outflow - delta.inflow;
            if decrease > balance {
                return Err(ChainError::ReplayUnderflow {
                    asset: token,
                    block,
                    index,
                });
            }
            balance -= decrease;
        }
    }
    accumulator += &balance * BigUint::from(to_block - cursor);
    let actual = balance_of_at(rpc, token, account, to_block).await?;
    if actual != balance {
        return Err(ChainError::BalanceReplayMismatch {
            asset: token,
            replayed: balance,
            actual,
            block: to_block,
        });
    }
    Ok((
        accumulator,
        merge_log_metrics(outgoing_metrics, incoming_metrics),
    ))
}

pub async fn earned_score_of<R: Rpc + ?Sized>(
    rpc: &R,
    config: &IncidentConfig,
    account: Address,
    as_of_block: u64,
    max_range: u64,
    result_cap: usize,
) -> Result<(BigUint, LogMetrics), ChainError> {
    let mut numerator = BigUint::from(0u8);
    let mut metrics = LogMetrics::default();
    for scored in &config.scored_tokens {
        for (index, point) in scored.rates.iter().enumerate() {
            let next_from = scored
                .rates
                .get(index + 1)
                .map_or(as_of_block, |next| next.from_block);
            let to_block = next_from.min(as_of_block);
            if point.rate == BigUint::from(0u8) || point.from_block >= to_block {
                continue;
            }
            let (integral, segment_metrics) = token_block_integral(
                rpc,
                scored.token,
                account,
                point.from_block,
                to_block,
                max_range,
                result_cap,
            )
            .await?;
            metrics = merge_log_metrics(metrics, segment_metrics);
            let normalized = if scored.decimals <= 18 {
                integral * BigUint::from(10u8).pow(u32::from(18 - scored.decimals))
            } else {
                integral / BigUint::from(10u8).pow(u32::from(scored.decimals - 18))
            };
            numerator += normalized * &point.rate;
        }
    }
    Ok((
        numerator / BigUint::from(1_000_000_000_000_000_000u64),
        metrics,
    ))
}

pub async fn twap_ratio_before<R: Rpc + ?Sized>(
    rpc: &R,
    config: &IncidentConfig,
    reference_block: u64,
) -> Result<BigUint, ChainError> {
    let step = config.params.sample_step_blocks;
    if step == 0 {
        return Err(ChainError::InvalidConfiguration(
            "sampleStepBlocks is zero".to_owned(),
        ));
    }
    let start = if reference_block > config.params.twap_lookback_blocks {
        reference_block - config.params.twap_lookback_blocks
    } else {
        1
    };
    let mut sum = BigUint::from(0u8);
    let mut samples = 0u64;
    let mut block = start;
    while block <= reference_block {
        sum += ratio_at(
            rpc,
            config.conversion_address,
            &config.conversion_call_data,
            block,
        )
        .await?;
        samples = samples.checked_add(1).ok_or_else(|| {
            ChainError::InvalidConfiguration("TWAP sample count overflow".to_owned())
        })?;
        let Some(next) = block.checked_add(step) else {
            break;
        };
        block = next;
    }
    if samples == 0 {
        Ok(BigUint::from(0u8))
    } else {
        Ok(sum / BigUint::from(samples))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TokenTransfer {
    pub from: Address,
    pub to: Address,
    pub value: BigUint,
    pub block_number: u64,
    pub log_index: u64,
}

pub async fn erc20_transfers<R: Rpc + ?Sized>(
    rpc: &R,
    token: Address,
    from_block: u64,
    to_block: u64,
    max_range: u64,
    result_cap: usize,
) -> Result<(Vec<TokenTransfer>, LogMetrics), ChainError> {
    if to_block < from_block {
        return Ok((Vec::new(), LogMetrics::default()));
    }
    let filter = LogFilter {
        address: token.to_string(),
        topics: vec![topic_hash(IERC20::Transfer::SIGNATURE_HASH)],
    };
    let (logs, metrics) =
        get_logs_chunked(rpc, &filter, from_block, to_block, max_range, result_cap).await?;
    let mut transfers = Vec::with_capacity(logs.len());
    for log in logs {
        let event = decode_event::<IERC20::Transfer>(&log)?;
        transfers.push(TokenTransfer {
            from: from_alloy(event.from),
            to: from_alloy(event.to),
            value: u256_to_big(event.value),
            block_number: log.block_number,
            log_index: log.log_index,
        });
    }
    transfers.sort_by_key(|transfer| (transfer.block_number, transfer.log_index));
    Ok((transfers, metrics))
}
