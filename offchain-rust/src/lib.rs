use num_bigint::BigUint;
use num_traits::{One, Zero};
use sha3::{Digest, Keccak256};
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::str::FromStr;
use thiserror::Error;

pub mod abi;
pub mod artifact;
pub mod chain;
pub mod checkpoint;
pub mod config;
pub mod engine;
pub mod ffi;
mod json;
pub mod rpc;
pub mod tee;
pub mod typed_data;
pub use json::{compute_json, parse_json, serialize_output};

const BPS: u64 = 10_000;
const BOOSTER_BOOST_BPS: u64 = 100;
pub(crate) type Hash = [u8; 32];
const ZERO_HASH: Hash = [0; 32];

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct Address([u8; 20]);

impl Address {
    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub fn from_bytes(bytes: [u8; 20]) -> Self {
        Self(bytes)
    }

    pub fn into_bytes(self) -> [u8; 20] {
        self.0
    }

    pub fn is_zero(&self) -> bool {
        self.0 == [0; 20]
    }

    pub(crate) fn abi_word(self) -> Hash {
        let mut word = ZERO_HASH;
        word[12..].copy_from_slice(&self.0);
        word
    }
}

impl FromStr for Address {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let value = value.strip_prefix("0x").ok_or(())?;
        if value.len() != 40 {
            return Err(());
        }
        let mut bytes = [0u8; 20];
        hex::decode_to_slice(value, &mut bytes).map_err(|_| ())?;
        Ok(Self(bytes))
    }
}

impl fmt::Display for Address {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "0x{}", hex::encode(self.0))
    }
}

#[derive(Debug, Error)]
pub enum KernelError {
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid decimal string for {field}: {value}")]
    InvalidDecimal { field: String, value: String },
    #[error("invalid address for {field}: {value}")]
    InvalidAddress { field: String, value: String },
    #[error("value exceeds uint256")]
    Uint256Overflow,
    #[error("duplicate settlement input user: {0}")]
    DuplicateInputUser(Address),
    #[error("duplicate claim {0} in settlement")]
    DuplicateClaim(BigUint),
    #[error("claim {0} not in settlement")]
    MissingClaim(BigUint),
    #[error("merkle tree requires at least one row")]
    EmptyMerkleTree,
    #[error("duplicate registration for claim {0}")]
    DuplicateRegistration(BigUint),
    #[error("cancellation references unknown claim {0}")]
    UnknownCancellation(BigUint),
    #[error("duplicate cancellation for claim {0}")]
    DuplicateCancellation(BigUint),
    #[error("duplicate resolved claim {0}")]
    DuplicateResolvedClaim(BigUint),
    #[error("missing resolved claim {0}")]
    MissingResolvedClaim(BigUint),
    #[error("resolved claim {0} is not live in replayed events")]
    UnexpectedResolvedClaim(BigUint),
    #[error("resolved claim does not match replayed registration for claim {0}")]
    ResolvedClaimMismatch(BigUint),
    #[error(
        "claim event position is not strictly increasing: ({previous_block},{previous_index}) then ({block},{index})"
    )]
    EventOrder {
        previous_block: u64,
        previous_index: u64,
        block: u64,
        index: u64,
    },
    #[error("invalid settlement policy: {0}")]
    InvalidPolicy(String),
}

#[derive(Clone, Debug)]
pub struct PoolInput {
    pub balance: BigUint,
    pub asset_usd: BigUint,
    pub asset_decimals: u32,
}

#[derive(Clone, Debug)]
pub struct ClaimInput {
    pub claim_id: BigUint,
    pub user: Address,
    pub escrow_amount: BigUint,
    pub min_held: BigUint,
    pub gross_earned_score: BigUint,
    pub spent_score: BigUint,
    pub score_to_spend: BigUint,
    pub booster_amount: BigUint,
    pub booster_held: BigUint,
}

#[derive(Clone, Debug)]
pub struct KernelInput {
    pub incident_id: BigUint,
    pub coverage_bps: BigUint,
    pub insured_decimals: u32,
    pub twap_ratio: BigUint,
    pub underlying_usd: BigUint,
    pub max_cover_pool_payout_bps: BigUint,
    pub pools: Vec<PoolInput>,
    pub claims: Vec<ClaimInput>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettledRow {
    pub claim_id: BigUint,
    pub user: Address,
    pub escrow_amount: BigUint,
    pub eligible_amount: BigUint,
    pub loss_usd: BigUint,
    pub gross_earned_score: BigUint,
    pub earned_score: BigUint,
    pub score_spent: BigUint,
    pub booster_amount_used: BigUint,
    pub boosted_score: BigUint,
    pub payout_usd: BigUint,
    pub amounts: Vec<BigUint>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MerkleRow {
    pub claim_id: BigUint,
    pub user: Address,
    pub amounts: Vec<BigUint>,
    pub score_spent: BigUint,
    pub booster_amount_used: BigUint,
    pub boosted_score: BigUint,
    pub eligible_amount: BigUint,
}

#[derive(Clone, Debug)]
pub struct KernelOutput {
    pub rows: Vec<SettledRow>,
    pub pool_payouts: Vec<BigUint>,
    pub claim_set_hash: String,
    pub settlement_input_hash: String,
    pub root: String,
    pub proofs: HashMap<BigUint, Vec<String>>,
}

#[derive(Clone, Copy, Debug)]
pub enum EventKind {
    Register,
    Cancel,
}

#[derive(Clone, Debug)]
pub struct ClaimEvent {
    pub kind: EventKind,
    pub claim_id: BigUint,
    pub user: Address,
    pub amount: BigUint,
    pub score_to_spend: BigUint,
    pub booster_amount: BigUint,
    pub block_number: u64,
    pub log_index: u64,
}

fn pow10(decimals: u32) -> BigUint {
    BigUint::from(10u8).pow(decimals)
}

pub(crate) fn uint256_word(value: &BigUint) -> Result<Hash, KernelError> {
    let bytes = value.to_bytes_be();
    if bytes.len() > 32 {
        return Err(KernelError::Uint256Overflow);
    }
    let mut word = ZERO_HASH;
    word[32 - bytes.len()..].copy_from_slice(&bytes);
    Ok(word)
}

fn usize_word(value: usize) -> Hash {
    let mut word = ZERO_HASH;
    let bytes = value.to_be_bytes();
    word[32 - bytes.len()..].copy_from_slice(&bytes);
    word
}

pub(crate) fn keccak256(bytes: impl AsRef<[u8]>) -> Hash {
    let mut hasher = Keccak256::new();
    hasher.update(bytes.as_ref());
    hasher.finalize().into()
}

pub(crate) fn hash_hex(hash: Hash) -> String {
    format!("0x{}", hex::encode(hash))
}

fn sqrt_floor(value: &BigUint) -> BigUint {
    if value < &BigUint::from(2u8) {
        return value.clone();
    }
    let mut previous = BigUint::one() << value.bits().div_ceil(2);
    loop {
        let next = (&previous + value / &previous) >> 1usize;
        if next >= previous {
            return previous;
        }
        previous = next;
    }
}

pub fn settlement_input_hash(rows: &[(Address, BigUint)]) -> Result<String, KernelError> {
    let mut canonical = rows.to_vec();
    canonical.sort_by(|a, b| a.0.as_slice().cmp(b.0.as_slice()));
    for pair in canonical.windows(2) {
        if pair[0].0 == pair[1].0 {
            return Err(KernelError::DuplicateInputUser(pair[1].0));
        }
    }
    let array_bytes = canonical
        .len()
        .checked_mul(32)
        .ok_or(KernelError::Uint256Overflow)?;
    let second_offset = 96usize
        .checked_add(array_bytes)
        .ok_or(KernelError::Uint256Overflow)?;
    let mut encoded = Vec::with_capacity(128 + 2 * array_bytes);
    encoded.extend_from_slice(&usize_word(64));
    encoded.extend_from_slice(&usize_word(second_offset));
    encoded.extend_from_slice(&usize_word(canonical.len()));
    for (user, _) in &canonical {
        encoded.extend_from_slice(&user.abi_word());
    }
    encoded.extend_from_slice(&usize_word(canonical.len()));
    for (_, score) in &canonical {
        encoded.extend_from_slice(&uint256_word(score)?);
    }
    Ok(hash_hex(keccak256(encoded)))
}

pub fn claim_set_hash(events: &[ClaimEvent]) -> Result<String, KernelError> {
    let mut accumulator = ZERO_HASH;
    for event in events {
        let mut encoded = Vec::with_capacity(match event.kind {
            EventKind::Register => 192,
            EventKind::Cancel => 64,
        });
        encoded.extend_from_slice(&accumulator);
        encoded.extend_from_slice(&uint256_word(&event.claim_id)?);
        if matches!(event.kind, EventKind::Register) {
            encoded.extend_from_slice(&event.user.abi_word());
            encoded.extend_from_slice(&uint256_word(&event.amount)?);
            encoded.extend_from_slice(&uint256_word(&event.score_to_spend)?);
            encoded.extend_from_slice(&uint256_word(&event.booster_amount)?);
        }
        accumulator = keccak256(encoded);
    }
    Ok(hash_hex(accumulator))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClaimSetReplay {
    pub hash: String,
    pub unresolved: usize,
    pub live_claim_ids: Vec<BigUint>,
}

pub fn replay_claim_set(events: &[ClaimEvent]) -> Result<ClaimSetReplay, KernelError> {
    let mut registrations = HashSet::new();
    let mut order = Vec::new();
    let mut cancelled = HashSet::new();
    let mut previous = None;
    for event in events {
        if let Some((previous_block, previous_index)) = previous
            && (event.block_number, event.log_index) <= (previous_block, previous_index)
        {
            return Err(KernelError::EventOrder {
                previous_block,
                previous_index,
                block: event.block_number,
                index: event.log_index,
            });
        }
        previous = Some((event.block_number, event.log_index));
        match event.kind {
            EventKind::Register => {
                if !registrations.insert(event.claim_id.clone()) {
                    return Err(KernelError::DuplicateRegistration(event.claim_id.clone()));
                }
                order.push(event.claim_id.clone());
            }
            EventKind::Cancel => {
                if !registrations.contains(&event.claim_id) {
                    return Err(KernelError::UnknownCancellation(event.claim_id.clone()));
                }
                if !cancelled.insert(event.claim_id.clone()) {
                    return Err(KernelError::DuplicateCancellation(event.claim_id.clone()));
                }
            }
        }
    }
    let live_claim_ids = order
        .into_iter()
        .filter(|claim_id| !cancelled.contains(claim_id))
        .collect::<Vec<_>>();
    Ok(ClaimSetReplay {
        hash: claim_set_hash(events)?,
        unresolved: live_claim_ids.len(),
        live_claim_ids,
    })
}

fn standard_leaf_hash(incident_id: &BigUint, row: &MerkleRow) -> Result<Hash, KernelError> {
    let amount_bytes = row
        .amounts
        .len()
        .checked_mul(32)
        .ok_or(KernelError::Uint256Overflow)?;
    let mut encoded = Vec::with_capacity(256 + amount_bytes);
    encoded.extend_from_slice(&uint256_word(incident_id)?);
    encoded.extend_from_slice(&uint256_word(&row.claim_id)?);
    encoded.extend_from_slice(&row.user.abi_word());
    encoded.extend_from_slice(&usize_word(256));
    encoded.extend_from_slice(&uint256_word(&row.score_spent)?);
    encoded.extend_from_slice(&uint256_word(&row.booster_amount_used)?);
    encoded.extend_from_slice(&uint256_word(&row.boosted_score)?);
    encoded.extend_from_slice(&uint256_word(&row.eligible_amount)?);
    encoded.extend_from_slice(&usize_word(row.amounts.len()));
    for amount in &row.amounts {
        encoded.extend_from_slice(&uint256_word(amount)?);
    }
    Ok(keccak256(keccak256(encoded)))
}

fn standard_node_hash(a: Hash, b: Hash) -> Hash {
    let (left, right) = if a <= b { (a, b) } else { (b, a) };
    let mut encoded = [0u8; 64];
    encoded[..32].copy_from_slice(&left);
    encoded[32..].copy_from_slice(&right);
    keccak256(encoded)
}

fn sibling_index(index: usize) -> usize {
    if index.is_multiple_of(2) {
        index - 1
    } else {
        index + 1
    }
}

#[derive(Clone, Debug)]
pub struct SettlementTree {
    root: Hash,
    proofs: HashMap<BigUint, Vec<Hash>>,
}

impl SettlementTree {
    pub fn new(incident_id: &BigUint, rows: &[MerkleRow]) -> Result<Self, KernelError> {
        if rows.is_empty() {
            return Err(KernelError::EmptyMerkleTree);
        }
        let mut claims = HashSet::new();
        let mut leaves = Vec::with_capacity(rows.len());
        for row in rows {
            if !claims.insert(row.claim_id.clone()) {
                return Err(KernelError::DuplicateClaim(row.claim_id.clone()));
            }
            leaves.push((standard_leaf_hash(incident_id, row)?, row.claim_id.clone()));
        }
        leaves.sort_by(|a, b| a.0.cmp(&b.0));

        let mut tree = vec![ZERO_HASH; 2 * leaves.len() - 1];
        let mut tree_index_by_claim = HashMap::with_capacity(leaves.len());
        for (leaf_index, (hash, claim_id)) in leaves.iter().enumerate() {
            let tree_index = tree.len() - 1 - leaf_index;
            tree[tree_index] = *hash;
            tree_index_by_claim.insert(claim_id.clone(), tree_index);
        }
        for index in (0..tree.len() - leaves.len()).rev() {
            tree[index] = standard_node_hash(tree[2 * index + 1], tree[2 * index + 2]);
        }

        let mut proofs = HashMap::with_capacity(rows.len());
        for (claim_id, mut index) in tree_index_by_claim {
            let mut proof = Vec::new();
            while index > 0 {
                proof.push(tree[sibling_index(index)]);
                index = (index - 1) / 2;
            }
            proofs.insert(claim_id, proof);
        }
        Ok(Self {
            root: tree[0],
            proofs,
        })
    }

    pub fn root_hex(&self) -> String {
        hash_hex(self.root)
    }

    pub fn proof_hex(&self, claim_id: &BigUint) -> Result<Vec<String>, KernelError> {
        self.proofs
            .get(claim_id)
            .map(|proof| proof.iter().copied().map(hash_hex).collect())
            .ok_or_else(|| KernelError::MissingClaim(claim_id.clone()))
    }

    pub fn all_proofs_hex(&self) -> HashMap<BigUint, Vec<String>> {
        self.proofs
            .iter()
            .map(|(claim, proof)| {
                (
                    claim.clone(),
                    proof.iter().copied().map(hash_hex).collect::<Vec<_>>(),
                )
            })
            .collect()
    }
}

pub fn allocate(input: &KernelInput) -> Result<KernelOutput, KernelError> {
    let bps = BigUint::from(BPS);
    let boost_bps = BigUint::from(BOOSTER_BOOST_BPS);
    if input.coverage_bps > bps {
        return Err(KernelError::InvalidPolicy(format!(
            "coverageBps exceeds {BPS}: {}",
            input.coverage_bps
        )));
    }
    if input.max_cover_pool_payout_bps > bps {
        return Err(KernelError::InvalidPolicy(format!(
            "maxCoverPoolPayoutBps exceeds {BPS}: {}",
            input.max_cover_pool_payout_bps
        )));
    }
    if input.insured_decimals > 255 {
        return Err(KernelError::InvalidPolicy(format!(
            "insuredDecimals exceeds uint8: {}",
            input.insured_decimals
        )));
    }
    if let Some(pool) = input.pools.iter().find(|pool| pool.asset_decimals > 255) {
        return Err(KernelError::InvalidPolicy(format!(
            "pool assetDecimals exceeds uint8: {}",
            pool.asset_decimals
        )));
    }
    let wad = pow10(18);

    let mut rows = Vec::with_capacity(input.claims.len());
    for claim in &input.claims {
        let eligible = claim.min_held.clone().min(claim.escrow_amount.clone());
        let loss_usd = (((&eligible * &input.twap_ratio) / &wad) * &input.underlying_usd)
            / pow10(input.insured_decimals);
        let unspent = if claim.gross_earned_score > claim.spent_score {
            &claim.gross_earned_score - &claim.spent_score
        } else {
            BigUint::zero()
        };
        let boost = claim.booster_amount.clone().min(claim.booster_held.clone());
        let score_spent = claim.score_to_spend.clone().min(unspent.clone());
        let boosted_score = (&score_spent * (&bps + &boost * &boost_bps)) / &bps;
        rows.push(SettledRow {
            claim_id: claim.claim_id.clone(),
            user: claim.user,
            escrow_amount: claim.escrow_amount.clone(),
            eligible_amount: eligible,
            loss_usd,
            gross_earned_score: claim.gross_earned_score.clone(),
            earned_score: unspent,
            score_spent,
            booster_amount_used: boost,
            boosted_score,
            payout_usd: BigUint::zero(),
            amounts: Vec::new(),
        });
    }

    let pool_usd = input.pools.iter().fold(BigUint::zero(), |sum, pool| {
        sum + (&pool.balance * &pool.asset_usd) / pow10(pool.asset_decimals)
    });
    let max_total_usd = (&pool_usd * &input.max_cover_pool_payout_bps) / &bps;

    struct Weighted {
        row_index: usize,
        cap: BigUint,
        weight: BigUint,
    }
    let mut active = Vec::new();
    for (row_index, row) in rows.iter().enumerate() {
        let cap = (&row.loss_usd * &input.coverage_bps) / &bps;
        let weight = sqrt_floor(&(&cap * &row.boosted_score));
        if !cap.is_zero() && !weight.is_zero() {
            active.push(Weighted {
                row_index,
                cap,
                weight,
            });
        }
    }
    active.sort_by(|a, b| {
        let left = &a.cap * &b.weight;
        let right = &b.cap * &a.weight;
        match left.cmp(&right) {
            Ordering::Equal => rows[a.row_index].claim_id.cmp(&rows[b.row_index].claim_id),
            ordering => ordering,
        }
    });

    let mut remaining_budget = max_total_usd;
    let mut remaining_weight = active
        .iter()
        .fold(BigUint::zero(), |sum, claim| sum + &claim.weight);
    let mut first_unsaturated = 0usize;
    while first_unsaturated < active.len() && !remaining_weight.is_zero() {
        let claim = &active[first_unsaturated];
        if &remaining_budget * &claim.weight < &claim.cap * &remaining_weight {
            break;
        }
        rows[claim.row_index].payout_usd = claim.cap.clone();
        remaining_budget -= &claim.cap;
        remaining_weight -= &claim.weight;
        first_unsaturated += 1;
    }
    if !remaining_budget.is_zero() && !remaining_weight.is_zero() {
        for claim in &active[first_unsaturated..] {
            rows[claim.row_index].payout_usd =
                (&remaining_budget * &claim.weight) / &remaining_weight;
        }
    }

    let mut pool_payouts = vec![BigUint::zero(); input.pools.len()];
    for row in &mut rows {
        row.amounts = input
            .pools
            .iter()
            .map(|pool| {
                if pool_usd.is_zero() {
                    BigUint::zero()
                } else {
                    (&row.payout_usd * &pool.balance) / &pool_usd
                }
            })
            .collect();
        for (total, amount) in pool_payouts.iter_mut().zip(&row.amounts) {
            *total += amount;
        }
    }

    let claim_events = input
        .claims
        .iter()
        .enumerate()
        .map(|(index, claim)| ClaimEvent {
            kind: EventKind::Register,
            claim_id: claim.claim_id.clone(),
            user: claim.user,
            amount: claim.escrow_amount.clone(),
            score_to_spend: claim.score_to_spend.clone(),
            booster_amount: claim.booster_amount.clone(),
            block_number: 0,
            log_index: index as u64,
        })
        .collect::<Vec<_>>();
    let claim_set_hash = claim_set_hash(&claim_events)?;
    let input_hash_rows = rows
        .iter()
        .map(|row| (row.user, row.gross_earned_score.clone()))
        .collect::<Vec<_>>();
    let settlement_input_hash = settlement_input_hash(&input_hash_rows)?;
    let (root, proofs) = if rows.is_empty() {
        (format!("0x{}", "0".repeat(64)), HashMap::new())
    } else {
        let merkle_rows = rows
            .iter()
            .map(|row| MerkleRow {
                claim_id: row.claim_id.clone(),
                user: row.user,
                amounts: row.amounts.clone(),
                score_spent: row.score_spent.clone(),
                booster_amount_used: row.booster_amount_used.clone(),
                boosted_score: row.boosted_score.clone(),
                eligible_amount: row.eligible_amount.clone(),
            })
            .collect::<Vec<_>>();
        let tree = SettlementTree::new(&input.incident_id, &merkle_rows)?;
        (tree.root_hex(), tree.all_proofs_hex())
    };

    Ok(KernelOutput {
        rows,
        pool_payouts,
        claim_set_hash,
        settlement_input_hash,
        root,
        proofs,
    })
}

/// Production settlement entry point. `input.claims` contains the expensive
/// resolved values for live claims only, while `events` is the complete ordered
/// register/cancel stream. The event stream controls row order and the rolling
/// claim-set commitment; cancelled registrations therefore remain committed but
/// can never produce payout rows.
pub fn allocate_with_events(
    input: &KernelInput,
    events: &[ClaimEvent],
) -> Result<KernelOutput, KernelError> {
    replay_claim_set(events)?;
    let mut registrations = HashMap::<BigUint, &ClaimEvent>::new();
    let mut registration_order = Vec::new();
    let mut cancelled = HashSet::<BigUint>::new();

    for event in events {
        match event.kind {
            EventKind::Register => {
                if registrations
                    .insert(event.claim_id.clone(), event)
                    .is_some()
                {
                    return Err(KernelError::DuplicateRegistration(event.claim_id.clone()));
                }
                registration_order.push(event.claim_id.clone());
            }
            EventKind::Cancel => {
                if !registrations.contains_key(&event.claim_id) {
                    return Err(KernelError::UnknownCancellation(event.claim_id.clone()));
                }
                if !cancelled.insert(event.claim_id.clone()) {
                    return Err(KernelError::DuplicateCancellation(event.claim_id.clone()));
                }
            }
        }
    }

    let mut resolved = HashMap::<BigUint, &ClaimInput>::new();
    for claim in &input.claims {
        if resolved.insert(claim.claim_id.clone(), claim).is_some() {
            return Err(KernelError::DuplicateResolvedClaim(claim.claim_id.clone()));
        }
        if !registrations.contains_key(&claim.claim_id) || cancelled.contains(&claim.claim_id) {
            return Err(KernelError::UnexpectedResolvedClaim(claim.claim_id.clone()));
        }
    }

    let mut ordered_claims = Vec::with_capacity(resolved.len());
    for claim_id in registration_order {
        if cancelled.contains(&claim_id) {
            continue;
        }
        let registration = registrations.get(&claim_id).ok_or_else(|| {
            KernelError::InvalidPolicy(format!(
                "registration order references missing claim {claim_id}"
            ))
        })?;
        let claim = resolved
            .get(&claim_id)
            .ok_or_else(|| KernelError::MissingResolvedClaim(claim_id.clone()))?;
        if registration.user != claim.user
            || registration.amount != claim.escrow_amount
            || registration.score_to_spend != claim.score_to_spend
            || registration.booster_amount != claim.booster_amount
        {
            return Err(KernelError::ResolvedClaimMismatch(claim_id));
        }
        ordered_claims.push((*claim).clone());
    }

    let mut ordered_input = input.clone();
    ordered_input.claims = ordered_claims;
    let mut output = allocate(&ordered_input)?;
    output.claim_set_hash = claim_set_hash(events)?;
    Ok(output)
}
