use crate::Address;
use crate::chain::{
    ChainError, IncidentConfig, RatePoint, ScoredToken, balance_of_at, block_by_number, chain_id,
    erc20_transfers,
};
use crate::rpc::{LogMetrics, Rpc};
use hmac::{Hmac, Mac};
use num_bigint::BigUint;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

const SCHEMA_VERSION: u32 = 1;
const ZERO_HASH: &str = "0x0000000000000000000000000000000000000000000000000000000000000000";
const WAD: u64 = 1_000_000_000_000_000_000;
const MAX_CHECKPOINT_BYTES: u64 = 128 * 1024 * 1024;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Error)]
pub enum CheckpointError {
    #[error(transparent)]
    Chain(#[from] ChainError),
    #[error("score checkpoint I/O error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("score checkpoint JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("checkpoint authentication failed: {0}")]
    Authentication(String),
    #[error("invalid score checkpoint: {0}")]
    Invalid(String),
    #[error("score checkpoint is locked by another process: {0}")]
    Locked(PathBuf),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CheckpointMetadata {
    pub path: PathBuf,
    pub as_of_block: u64,
    pub as_of_block_hash: String,
    pub indexed_transfers: usize,
    pub indexed_tokens: usize,
    pub log_metrics: LogMetrics,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BulkMetadata {
    pub as_of_block: u64,
    pub as_of_block_hash: String,
    pub indexed_transfers: usize,
    pub indexed_tokens: usize,
    pub tracked_accounts: usize,
    pub log_metrics: LogMetrics,
}

#[derive(Clone, Debug, Default)]
struct AccountState {
    balance: BigUint,
    last_block: u64,
    completed_numerator: BigUint,
    active_segment_from: Option<u64>,
    active_integral: BigUint,
}

#[derive(Clone, Debug)]
struct TokenState {
    decimals: u8,
    cursor_block: u64,
    cursor_block_hash: String,
    rates: Vec<RatePoint>,
    accounts: BTreeMap<Address, AccountState>,
}

#[derive(Clone, Debug)]
struct CheckpointState {
    chain_id: u64,
    tokens: BTreeMap<Address, TokenState>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedAccount {
    balance: String,
    last_block: String,
    completed_numerator: String,
    active_segment_from: Option<String>,
    active_integral: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedRate {
    from_block: String,
    rate: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedToken {
    decimals: u8,
    cursor_block: String,
    cursor_block_hash: String,
    rates: Vec<PersistedRate>,
    accounts: BTreeMap<String, PersistedAccount>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedCheckpoint {
    schema_version: u32,
    chain_id: u64,
    tokens: BTreeMap<String, PersistedToken>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AuthenticatedCheckpoint {
    schema_version: u32,
    chain_id: u64,
    tokens: BTreeMap<String, PersistedToken>,
    authentication: String,
}

impl AuthenticatedCheckpoint {
    fn checkpoint(&self) -> PersistedCheckpoint {
        PersistedCheckpoint {
            schema_version: self.schema_version,
            chain_id: self.chain_id,
            tokens: self.tokens.clone(),
        }
    }
}

fn io(path: &Path, source: std::io::Error) -> CheckpointError {
    CheckpointError::Io {
        path: path.to_owned(),
        source,
    }
}

fn lock_path_for_checkpoint(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".lock");
    PathBuf::from(value)
}

fn ensure_checkpoint_size(length: u64, limit: u64) -> Result<(), CheckpointError> {
    if length > limit {
        return Err(CheckpointError::Invalid(format!(
            "checkpoint file exceeds {limit}-byte limit"
        )));
    }
    Ok(())
}

fn read_checkpoint_bytes_with_limit(
    path: &Path,
    limit: u64,
) -> Result<Option<Vec<u8>>, CheckpointError> {
    let file = match OpenOptions::new().read(true).open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(io(path, error)),
    };
    let length = file.metadata().map_err(|error| io(path, error))?.len();
    ensure_checkpoint_size(length, limit)?;
    let mut bytes = Vec::with_capacity(length.try_into().unwrap_or(usize::MAX));
    file.take(limit.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| io(path, error))?;
    ensure_checkpoint_size(bytes.len() as u64, limit)?;
    Ok(Some(bytes))
}

fn verify_checkpoint_bytes(path: &Path, expected: &[u8]) -> Result<(), CheckpointError> {
    let persisted = read_checkpoint_bytes_with_limit(path, MAX_CHECKPOINT_BYTES)?
        .ok_or_else(|| CheckpointError::Invalid("checkpoint read-back is missing".to_owned()))?;
    if persisted != expected {
        return Err(CheckpointError::Invalid(
            "checkpoint read-back differs from serialized bytes".to_owned(),
        ));
    }
    Ok(())
}

fn decimal(value: &str, field: &str) -> Result<BigUint, CheckpointError> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(CheckpointError::Invalid(format!(
            "non-canonical bigint {field}"
        )));
    }
    BigUint::from_str(value)
        .map_err(|_| CheckpointError::Invalid(format!("invalid bigint {field}")))
}

fn decimal_u64(value: &str, field: &str) -> Result<u64, CheckpointError> {
    decimal(value, field)?
        .try_into()
        .map_err(|_| CheckpointError::Invalid(format!("checkpoint integer {field} exceeds u64")))
}

fn valid_hash(hash: &str) -> bool {
    hash.len() == 66
        && hash.starts_with("0x")
        && hash[2..].bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn assert_rates(rates: &[RatePoint]) -> Result<(), CheckpointError> {
    if rates
        .windows(2)
        .any(|pair| pair[0].from_block >= pair[1].from_block)
    {
        return Err(CheckpointError::Invalid(
            "scored-token rate history must be strictly ascending".to_owned(),
        ));
    }
    Ok(())
}

fn contributes_at(scored: &ScoredToken, as_of_block: u64) -> bool {
    scored.rates.iter().enumerate().any(|(index, point)| {
        let next = scored
            .rates
            .get(index + 1)
            .map_or(as_of_block, |next| next.from_block);
        point.rate != BigUint::from(0u8) && point.from_block < next.min(as_of_block)
    })
}

fn scale_integral(integral: BigUint, decimals: u8) -> BigUint {
    if decimals <= 18 {
        integral * BigUint::from(10u8).pow(u32::from(18 - decimals))
    } else {
        integral / BigUint::from(10u8).pow(u32::from(decimals - 18))
    }
}

fn rate_for(rates: &[RatePoint], from_block: u64) -> Result<&BigUint, CheckpointError> {
    rates
        .iter()
        .find(|point| point.from_block == from_block)
        .map(|point| &point.rate)
        .ok_or_else(|| {
            CheckpointError::Invalid(format!(
                "active rate segment {from_block} is absent from current history"
            ))
        })
}

fn finalize_active(
    account: &mut AccountState,
    rates: &[RatePoint],
    decimals: u8,
) -> Result<(), CheckpointError> {
    let Some(from_block) = account.active_segment_from else {
        return Ok(());
    };
    account.completed_numerator +=
        scale_integral(account.active_integral.clone(), decimals) * rate_for(rates, from_block)?;
    account.active_segment_from = None;
    account.active_integral = BigUint::from(0u8);
    Ok(())
}

fn accrue_to(
    account: &mut AccountState,
    to_block: u64,
    rates: &[RatePoint],
    decimals: u8,
) -> Result<(), CheckpointError> {
    if to_block < account.last_block {
        return Err(CheckpointError::Invalid(format!(
            "cannot move score account backward from {} to {to_block}",
            account.last_block
        )));
    }
    if to_block == account.last_block {
        return Ok(());
    }
    for (index, point) in rates.iter().enumerate() {
        let next = rates.get(index + 1).map(|next| next.from_block);
        let overlap_from = account.last_block.max(point.from_block);
        let overlap_to = next.map_or(to_block, |next| next.min(to_block));
        if overlap_from >= overlap_to {
            continue;
        }
        if account.active_segment_from != Some(point.from_block) {
            finalize_active(account, rates, decimals)?;
            account.active_segment_from = Some(point.from_block);
            account.active_integral = BigUint::from(0u8);
        }
        account.active_integral += &account.balance * BigUint::from(overlap_to - overlap_from);
        if next.is_some_and(|next| overlap_to == next && next <= to_block) {
            finalize_active(account, rates, decimals)?;
        }
    }
    account.last_block = to_block;
    Ok(())
}

fn projected_numerator(
    account: &AccountState,
    to_block: u64,
    rates: &[RatePoint],
    decimals: u8,
) -> Result<BigUint, CheckpointError> {
    let mut projected = account.clone();
    accrue_to(&mut projected, to_block, rates, decimals)?;
    let mut numerator = projected.completed_numerator;
    if let Some(from_block) = projected.active_segment_from {
        numerator +=
            scale_integral(projected.active_integral, decimals) * rate_for(rates, from_block)?;
    }
    Ok(numerator)
}

fn serialize_state(state: &CheckpointState) -> PersistedCheckpoint {
    let mut tokens = BTreeMap::new();
    for (address, token) in &state.tokens {
        let mut accounts = BTreeMap::new();
        for (account, value) in &token.accounts {
            accounts.insert(
                account.to_string(),
                PersistedAccount {
                    balance: value.balance.to_string(),
                    last_block: value.last_block.to_string(),
                    completed_numerator: value.completed_numerator.to_string(),
                    active_segment_from: value.active_segment_from.map(|value| value.to_string()),
                    active_integral: value.active_integral.to_string(),
                },
            );
        }
        tokens.insert(
            address.to_string(),
            PersistedToken {
                decimals: token.decimals,
                cursor_block: token.cursor_block.to_string(),
                cursor_block_hash: token.cursor_block_hash.clone(),
                rates: token
                    .rates
                    .iter()
                    .map(|rate| PersistedRate {
                        from_block: rate.from_block.to_string(),
                        rate: rate.rate.to_string(),
                    })
                    .collect(),
                accounts,
            },
        );
    }
    PersistedCheckpoint {
        schema_version: SCHEMA_VERSION,
        chain_id: state.chain_id,
        tokens,
    }
}

fn parse_state(persisted: PersistedCheckpoint) -> Result<CheckpointState, CheckpointError> {
    if persisted.schema_version != SCHEMA_VERSION {
        return Err(CheckpointError::Invalid(format!(
            "unsupported schema version {}",
            persisted.schema_version
        )));
    }
    let mut tokens = BTreeMap::new();
    for (token_text, raw) in persisted.tokens {
        let token = Address::from_str(&token_text)
            .map_err(|_| CheckpointError::Invalid(format!("invalid token address {token_text}")))?;
        if token.to_string() != token_text.to_ascii_lowercase() {
            return Err(CheckpointError::Invalid(format!(
                "non-canonical token address {token_text}"
            )));
        }
        if !valid_hash(&raw.cursor_block_hash) {
            return Err(CheckpointError::Invalid(format!(
                "invalid cursor block hash for {token}"
            )));
        }
        let cursor_block = decimal_u64(&raw.cursor_block, &format!("{token}.cursorBlock"))?;
        if cursor_block == 0 && !raw.cursor_block_hash.eq_ignore_ascii_case(ZERO_HASH) {
            return Err(CheckpointError::Invalid(format!(
                "nonzero genesis cursor hash for {token}"
            )));
        }
        let rates = raw
            .rates
            .into_iter()
            .enumerate()
            .map(|(index, rate)| {
                Ok(RatePoint {
                    from_block: decimal_u64(
                        &rate.from_block,
                        &format!("{token}.rates[{index}].fromBlock"),
                    )?,
                    rate: decimal(&rate.rate, &format!("{token}.rates[{index}].rate"))?,
                })
            })
            .collect::<Result<Vec<_>, CheckpointError>>()?;
        assert_rates(&rates)?;
        let mut accounts = BTreeMap::new();
        for (account_text, value) in raw.accounts {
            let account = Address::from_str(&account_text).map_err(|_| {
                CheckpointError::Invalid(format!("invalid account address {account_text}"))
            })?;
            if account.to_string() != account_text.to_ascii_lowercase() {
                return Err(CheckpointError::Invalid(format!(
                    "non-canonical account address {account_text}"
                )));
            }
            let last_block =
                decimal_u64(&value.last_block, &format!("{token}.{account}.lastBlock"))?;
            if last_block > cursor_block {
                return Err(CheckpointError::Invalid(format!(
                    "account {account} is ahead of token cursor {cursor_block}"
                )));
            }
            let active_segment_from = value
                .active_segment_from
                .as_deref()
                .map(|raw| decimal_u64(raw, &format!("{token}.{account}.activeSegmentFrom")))
                .transpose()?;
            if let Some(from_block) = active_segment_from {
                if !rates.iter().any(|rate| rate.from_block == from_block) {
                    return Err(CheckpointError::Invalid(format!(
                        "account {account} references absent rate segment {from_block}"
                    )));
                }
            } else if value.active_integral != "0" {
                return Err(CheckpointError::Invalid(format!(
                    "account {account} has inactive nonzero integral"
                )));
            }
            accounts.insert(
                account,
                AccountState {
                    balance: decimal(&value.balance, &format!("{token}.{account}.balance"))?,
                    last_block,
                    completed_numerator: decimal(
                        &value.completed_numerator,
                        &format!("{token}.{account}.completedNumerator"),
                    )?,
                    active_segment_from,
                    active_integral: decimal(
                        &value.active_integral,
                        &format!("{token}.{account}.activeIntegral"),
                    )?,
                },
            );
        }
        if tokens
            .insert(
                token,
                TokenState {
                    decimals: raw.decimals,
                    cursor_block,
                    cursor_block_hash: raw.cursor_block_hash.to_ascii_lowercase(),
                    rates,
                    accounts,
                },
            )
            .is_some()
        {
            return Err(CheckpointError::Invalid(format!(
                "duplicate token address {token}"
            )));
        }
    }
    Ok(CheckpointState {
        chain_id: persisted.chain_id,
        tokens,
    })
}

fn authentication(
    checkpoint: &PersistedCheckpoint,
    integrity_key: &[u8],
) -> Result<[u8; 32], CheckpointError> {
    let mut mac = HmacSha256::new_from_slice(integrity_key)
        .map_err(|_| CheckpointError::Invalid("invalid HMAC key".to_owned()))?;
    mac.update(&serde_json::to_vec(checkpoint)?);
    Ok(mac.finalize().into_bytes().into())
}

fn load_checkpoint(
    path: &Path,
    expected_chain_id: u64,
    integrity_key: &[u8],
) -> Result<CheckpointState, CheckpointError> {
    let bytes = match read_checkpoint_bytes_with_limit(path, MAX_CHECKPOINT_BYTES)? {
        Some(bytes) => bytes,
        None => {
            return Ok(CheckpointState {
                chain_id: expected_chain_id,
                tokens: BTreeMap::new(),
            });
        }
    };
    let envelope: AuthenticatedCheckpoint = serde_json::from_slice(&bytes)?;
    let supplied = envelope
        .authentication
        .strip_prefix("0x")
        .filter(|value| value.len() == 64)
        .and_then(|value| hex::decode(value).ok())
        .ok_or_else(|| CheckpointError::Authentication("missing or malformed HMAC".to_owned()))?;
    let checkpoint = envelope.checkpoint();
    let expected = authentication(&checkpoint, integrity_key)?;
    let mut verifier = HmacSha256::new_from_slice(integrity_key)
        .map_err(|_| CheckpointError::Invalid("invalid HMAC key".to_owned()))?;
    verifier.update(&serde_json::to_vec(&checkpoint)?);
    verifier
        .verify_slice(&supplied)
        .map_err(|_| CheckpointError::Authentication("HMAC mismatch".to_owned()))?;
    debug_assert_eq!(expected.as_slice(), supplied.as_slice());
    let state = parse_state(checkpoint)?;
    if state.chain_id != expected_chain_id {
        return Err(CheckpointError::Invalid(format!(
            "checkpoint chain {} does not match RPC chain {expected_chain_id}",
            state.chain_id
        )));
    }
    Ok(state)
}

fn save_checkpoint(
    path: &Path,
    state: &CheckpointState,
    integrity_key: &[u8],
) -> Result<(), CheckpointError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|error| io(parent, error))?;
    let checkpoint = serialize_state(state);
    let envelope = AuthenticatedCheckpoint {
        schema_version: checkpoint.schema_version,
        chain_id: checkpoint.chain_id,
        tokens: checkpoint.tokens.clone(),
        authentication: format!(
            "0x{}",
            hex::encode(authentication(&checkpoint, integrity_key)?)
        ),
    };
    let mut bytes = serde_json::to_vec(&envelope)?;
    bytes.push(b'\n');
    ensure_checkpoint_size(bytes.len() as u64, MAX_CHECKPOINT_BYTES)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CheckpointError::Invalid("system clock before Unix epoch".to_owned()))?
        .as_nanos();
    let temporary = path.with_extension(format!("{}.{}.tmp", std::process::id(), nonce));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options
        .open(&temporary)
        .map_err(|error| io(&temporary, error))?;
    if let Err(error) = file.write_all(&bytes).and_then(|()| file.sync_all()) {
        let _ = fs::remove_file(&temporary);
        return Err(io(&temporary, error));
    }
    drop(file);
    if let Err(error) = verify_checkpoint_bytes(&temporary, &bytes) {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::remove_file(&temporary);
        return Err(io(path, error));
    }
    let directory = fs::File::open(parent).map_err(|error| io(parent, error))?;
    directory.sync_all().map_err(|error| io(parent, error))?;
    verify_checkpoint_bytes(path, &bytes)?;
    Ok(())
}

struct LockGuard {
    path: PathBuf,
}

impl LockGuard {
    fn acquire(path: &Path) -> Result<Self, CheckpointError> {
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent).map_err(|error| io(parent, error))?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        match options.open(path) {
            Ok(mut file) => {
                if let Err(error) =
                    writeln!(file, "{}", std::process::id()).and_then(|()| file.sync_all())
                {
                    drop(file);
                    let _ = fs::remove_file(path);
                    return Err(io(path, error));
                }
                Ok(Self {
                    path: path.to_owned(),
                })
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                Err(CheckpointError::Locked(path.to_owned()))
            }
            Err(error) => Err(io(path, error)),
        }
    }
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn validate_stored_token(
    stored: &TokenState,
    current: &ScoredToken,
) -> Result<(), CheckpointError> {
    if stored.decimals != current.decimals {
        return Err(CheckpointError::Invalid(format!(
            "decimals mismatch for {}: {} != {}",
            current.token, stored.decimals, current.decimals
        )));
    }
    if current.rates.len() < stored.rates.len() {
        return Err(CheckpointError::Invalid(format!(
            "rate history shrank for {}",
            current.token
        )));
    }
    for (index, old) in stored.rates.iter().enumerate() {
        let new = &current.rates[index];
        if old != new {
            return Err(CheckpointError::Invalid(format!(
                "rate history mismatch for {} at index {index}",
                current.token
            )));
        }
    }
    if current.rates[stored.rates.len()..]
        .iter()
        .any(|rate| rate.from_block <= stored.cursor_block)
    {
        return Err(CheckpointError::Invalid(format!(
            "new rate for {} begins at/before checkpoint block {}",
            current.token, stored.cursor_block
        )));
    }
    Ok(())
}

fn merge_metrics(left: LogMetrics, right: LogMetrics) -> LogMetrics {
    LogMetrics {
        requests: left.requests.saturating_add(right.requests),
        bisections: left.bisections.saturating_add(right.bisections),
        errors: left.errors.saturating_add(right.errors),
        elapsed_ms: left.elapsed_ms.saturating_add(right.elapsed_ms),
    }
}

fn apply_transfer_delta(
    token: &mut TokenState,
    rates: &[RatePoint],
    address: Address,
    block: u64,
    value: &BigUint,
    inflow: bool,
    tracked_accounts: Option<&BTreeSet<Address>>,
) -> Result<(), CheckpointError> {
    if address.is_zero() || tracked_accounts.is_some_and(|tracked| !tracked.contains(&address)) {
        return Ok(());
    }
    let account = token.accounts.entry(address).or_default();
    accrue_to(account, block, rates, token.decimals)?;
    if inflow {
        account.balance += value;
    } else if *value > account.balance {
        return Err(CheckpointError::Invalid(format!(
            "Transfer index produced negative balance for {address} at block {block}"
        )));
    } else {
        account.balance -= value;
    }
    Ok(())
}

async fn advance_token<R: Rpc + ?Sized>(
    rpc: &R,
    scored: &ScoredToken,
    token: &mut TokenState,
    target_block: u64,
    max_range: u64,
    result_cap: usize,
    tracked_accounts: Option<&BTreeSet<Address>>,
) -> Result<(usize, LogMetrics), CheckpointError> {
    if target_block < token.cursor_block {
        return Err(CheckpointError::Invalid(format!(
            "checkpoint for {} is ahead of requested block {target_block}",
            scored.token
        )));
    }
    if target_block == token.cursor_block {
        return Ok((0, LogMetrics::default()));
    }
    if max_range == 0 {
        return Err(CheckpointError::Invalid(
            "score replay max range must be nonzero".to_owned(),
        ));
    }
    let rates = scored.rates.clone();
    let mut indexed_transfers = 0usize;
    let mut metrics = LogMetrics::default();
    let mut slice_from = token.cursor_block + 1;
    while slice_from <= target_block {
        let slice_to = slice_from.saturating_add(max_range - 1).min(target_block);
        let (transfers, slice_metrics) = erc20_transfers(
            rpc,
            scored.token,
            slice_from,
            slice_to,
            max_range,
            result_cap,
        )
        .await?;
        indexed_transfers = indexed_transfers.saturating_add(transfers.len());
        metrics = merge_metrics(metrics, slice_metrics);
        for transfer in &transfers {
            apply_transfer_delta(
                token,
                &rates,
                transfer.from,
                transfer.block_number,
                &transfer.value,
                false,
                tracked_accounts,
            )?;
            apply_transfer_delta(
                token,
                &rates,
                transfer.to,
                transfer.block_number,
                &transfer.value,
                true,
                tracked_accounts,
            )?;
        }
        slice_from = slice_to.saturating_add(1);
    }
    token.cursor_block = target_block;
    token.cursor_block_hash = block_by_number(rpc, target_block).await?.hash;
    token.rates = rates;
    Ok((indexed_transfers, metrics))
}

pub struct CheckpointScoreSource<R: Rpc + ?Sized> {
    rpc: Arc<R>,
    config: IncidentConfig,
    as_of_block: u64,
    state: CheckpointState,
    _lock: LockGuard,
    pub metadata: CheckpointMetadata,
}

impl<R: Rpc + ?Sized> CheckpointScoreSource<R> {
    #[allow(clippy::too_many_arguments)]
    pub async fn open(
        rpc: Arc<R>,
        config: &IncidentConfig,
        as_of_block: u64,
        checkpoint_path: impl AsRef<Path>,
        expected_chain_id: u64,
        integrity_key: &[u8],
        max_range: u64,
        result_cap: usize,
    ) -> Result<Self, CheckpointError> {
        if integrity_key.len() < 32 {
            return Err(CheckpointError::Invalid(
                "integrity key must be at least 32 bytes".to_owned(),
            ));
        }
        let path = if checkpoint_path.as_ref().is_absolute() {
            checkpoint_path.as_ref().to_owned()
        } else {
            std::env::current_dir()
                .map_err(|error| io(Path::new("."), error))?
                .join(checkpoint_path)
        };
        let lock_path = lock_path_for_checkpoint(&path);
        let lock = LockGuard::acquire(&lock_path)?;
        let actual_chain_id = chain_id(rpc.as_ref()).await?;
        if actual_chain_id != expected_chain_id {
            return Err(CheckpointError::Invalid(format!(
                "RPC chain {actual_chain_id} does not match expected chain {expected_chain_id}"
            )));
        }
        let mut state = load_checkpoint(&path, expected_chain_id, integrity_key)?;
        let active = config
            .scored_tokens
            .iter()
            .filter(|scored| contributes_at(scored, as_of_block))
            .collect::<Vec<_>>();
        let mut indexed_transfers = 0usize;
        let mut log_metrics = LogMetrics::default();
        for scored in &active {
            assert_rates(&scored.rates)?;
            if let Some(stored) = state.tokens.get(&scored.token) {
                validate_stored_token(stored, scored)?;
                if stored.cursor_block != 0 {
                    let current_hash = block_by_number(rpc.as_ref(), stored.cursor_block)
                        .await?
                        .hash;
                    if !current_hash.eq_ignore_ascii_case(&stored.cursor_block_hash) {
                        return Err(CheckpointError::Invalid(format!(
                            "checkpoint block hash mismatch for {} at {}: {} != {}",
                            scored.token,
                            stored.cursor_block,
                            stored.cursor_block_hash,
                            current_hash
                        )));
                    }
                }
            } else {
                state.tokens.insert(
                    scored.token,
                    TokenState {
                        decimals: scored.decimals,
                        cursor_block: 0,
                        cursor_block_hash: ZERO_HASH.to_owned(),
                        rates: scored.rates.clone(),
                        accounts: BTreeMap::new(),
                    },
                );
            }
            let token = state.tokens.get_mut(&scored.token).ok_or_else(|| {
                CheckpointError::Invalid(format!(
                    "checkpoint token {} disappeared during initialization",
                    scored.token
                ))
            })?;
            let (count, metrics) = advance_token(
                rpc.as_ref(),
                scored,
                token,
                as_of_block,
                max_range,
                result_cap,
                None,
            )
            .await?;
            indexed_transfers = indexed_transfers.saturating_add(count);
            log_metrics = merge_metrics(log_metrics, metrics);
        }
        let as_of_block_hash = block_by_number(rpc.as_ref(), as_of_block).await?.hash;
        Ok(Self {
            rpc,
            config: config.clone(),
            as_of_block,
            state,
            _lock: lock,
            metadata: CheckpointMetadata {
                path,
                as_of_block,
                as_of_block_hash,
                indexed_transfers,
                indexed_tokens: active.len(),
                log_metrics,
            },
        })
    }

    pub fn commit(self, integrity_key: &[u8]) -> Result<(), CheckpointError> {
        if integrity_key.len() < 32 {
            return Err(CheckpointError::Invalid(
                "integrity key must be at least 32 bytes".to_owned(),
            ));
        }
        save_checkpoint(&self.metadata.path, &self.state, integrity_key)
    }

    pub async fn gross_score_of(&self, user: Address) -> Result<BigUint, CheckpointError> {
        let mut numerator = BigUint::from(0u8);
        for scored in &self.config.scored_tokens {
            if !contributes_at(scored, self.as_of_block) {
                continue;
            }
            let token = self.state.tokens.get(&scored.token).ok_or_else(|| {
                CheckpointError::Invalid(format!("missing token {}", scored.token))
            })?;
            let account = token.accounts.get(&user).cloned().unwrap_or_default();
            let actual =
                balance_of_at(self.rpc.as_ref(), scored.token, user, self.as_of_block).await?;
            if actual != account.balance {
                return Err(CheckpointError::Invalid(format!(
                    "unsupported token balance semantics for {}: indexed balance {}, balanceOf({user}) at block {} is {actual}",
                    scored.token, account.balance, self.as_of_block
                )));
            }
            numerator +=
                projected_numerator(&account, self.as_of_block, &scored.rates, scored.decimals)?;
        }
        Ok(numerator / BigUint::from(WAD))
    }
}

/// Fresh claimant-filtered replay. This type deliberately has no path, key, lock, or commit API.
pub struct BulkScoreSource<R: Rpc + ?Sized> {
    config: IncidentConfig,
    as_of_block: u64,
    state: CheckpointState,
    tracked_accounts: BTreeSet<Address>,
    _rpc: Arc<R>,
    pub metadata: BulkMetadata,
}

impl<R: Rpc + ?Sized> BulkScoreSource<R> {
    #[allow(clippy::too_many_arguments)]
    pub async fn open(
        rpc: Arc<R>,
        config: &IncidentConfig,
        as_of_block: u64,
        tracked_accounts: BTreeSet<Address>,
        expected_chain_id: u64,
        max_range: u64,
        result_cap: usize,
    ) -> Result<Self, CheckpointError> {
        if tracked_accounts.iter().any(Address::is_zero) {
            return Err(CheckpointError::Invalid(
                "bulk score claimant set contains the zero address".to_owned(),
            ));
        }
        let actual_chain_id = chain_id(rpc.as_ref()).await?;
        if actual_chain_id != expected_chain_id {
            return Err(CheckpointError::Invalid(format!(
                "RPC chain {actual_chain_id} does not match expected chain {expected_chain_id}"
            )));
        }
        let mut state = CheckpointState {
            chain_id: expected_chain_id,
            tokens: BTreeMap::new(),
        };
        let mut indexed_transfers = 0usize;
        let mut log_metrics = LogMetrics::default();
        let mut indexed_tokens = BTreeSet::new();
        for scored in config
            .scored_tokens
            .iter()
            .filter(|scored| contributes_at(scored, as_of_block))
        {
            assert_rates(&scored.rates)?;
            if !indexed_tokens.insert(scored.token) {
                let stored = state.tokens.get(&scored.token).ok_or_else(|| {
                    CheckpointError::Invalid(format!("bulk token {} disappeared", scored.token))
                })?;
                if stored.decimals != scored.decimals || stored.rates != scored.rates {
                    return Err(CheckpointError::Invalid(format!(
                        "conflicting duplicate scored-token configuration for {}",
                        scored.token
                    )));
                }
                continue;
            }
            state.tokens.insert(
                scored.token,
                TokenState {
                    decimals: scored.decimals,
                    cursor_block: 0,
                    cursor_block_hash: ZERO_HASH.to_owned(),
                    rates: scored.rates.clone(),
                    accounts: BTreeMap::new(),
                },
            );
            let token = state.tokens.get_mut(&scored.token).ok_or_else(|| {
                CheckpointError::Invalid(format!("bulk token {} disappeared", scored.token))
            })?;
            let (count, metrics) = advance_token(
                rpc.as_ref(),
                scored,
                token,
                as_of_block,
                max_range,
                result_cap,
                Some(&tracked_accounts),
            )
            .await?;
            indexed_transfers = indexed_transfers.saturating_add(count);
            log_metrics = merge_metrics(log_metrics, metrics);
        }
        for token_address in &indexed_tokens {
            let token = state.tokens.get(token_address).ok_or_else(|| {
                CheckpointError::Invalid(format!("missing token {token_address}"))
            })?;
            for user in &tracked_accounts {
                let indexed = token
                    .accounts
                    .get(user)
                    .map_or_else(|| BigUint::from(0u8), |account| account.balance.clone());
                let actual =
                    balance_of_at(rpc.as_ref(), *token_address, *user, as_of_block).await?;
                if actual != indexed {
                    return Err(CheckpointError::Invalid(format!(
                        "unsupported token balance semantics for {token_address}: indexed balance {indexed}, balanceOf({user}) at block {as_of_block} is {actual}"
                    )));
                }
            }
        }
        let as_of_block_hash = block_by_number(rpc.as_ref(), as_of_block).await?.hash;
        Ok(Self {
            config: config.clone(),
            as_of_block,
            state,
            metadata: BulkMetadata {
                as_of_block,
                as_of_block_hash,
                indexed_transfers,
                indexed_tokens: indexed_tokens.len(),
                tracked_accounts: tracked_accounts.len(),
                log_metrics,
            },
            tracked_accounts,
            _rpc: rpc,
        })
    }

    pub async fn gross_score_of(&self, user: Address) -> Result<BigUint, CheckpointError> {
        if !self.tracked_accounts.contains(&user) {
            return Err(CheckpointError::Invalid(format!(
                "bulk score requested for untracked claimant {user}"
            )));
        }
        let mut numerator = BigUint::from(0u8);
        for scored in &self.config.scored_tokens {
            if !contributes_at(scored, self.as_of_block) {
                continue;
            }
            let token = self.state.tokens.get(&scored.token).ok_or_else(|| {
                CheckpointError::Invalid(format!("missing token {}", scored.token))
            })?;
            let account = token.accounts.get(&user).cloned().unwrap_or_default();
            numerator +=
                projected_numerator(&account, self.as_of_block, &scored.rates, scored.decimals)?;
        }
        Ok(numerator / BigUint::from(WAD))
    }
}

#[cfg(test)]
mod tests {
    use super::read_checkpoint_bytes_with_limit;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static NEXT_PATH: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn checkpoint_read_is_bounded_before_json_parsing() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "usd8-checkpoint-limit-{}-{nonce}-{}",
            std::process::id(),
            NEXT_PATH.fetch_add(1, Ordering::Relaxed)
        ));
        fs::write(&path, [0u8; 17]).unwrap();
        let error = read_checkpoint_bytes_with_limit(&path, 16).unwrap_err();
        assert!(error.to_string().contains("exceeds 16-byte limit"));
        fs::remove_file(path).unwrap();
    }
}
