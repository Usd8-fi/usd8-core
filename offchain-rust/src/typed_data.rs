use crate::{Address, Hash, hash_hex, keccak256, uint256_word};
use num_bigint::BigUint;
use thiserror::Error;

const DOMAIN_TYPE: &[u8] =
    b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
const SETTLEMENT_TYPE: &[u8] = b"Settlement(uint256 incidentId,bytes32 root,uint256 unresolved,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)";
const INCIDENT_OPEN_TYPE: &[u8] =
    b"IncidentOpen(address insuredToken,uint64 referenceBlock,uint256 incidentId,bytes32 teePcrHash)";

#[derive(Clone, Debug)]
pub struct SettlementDigestInput {
    pub chain_id: u64,
    pub verifying_contract: Address,
    pub incident_id: BigUint,
    pub root: String,
    pub unresolved: BigUint,
    pub pool_payouts: Vec<BigUint>,
    pub pool_addrs: Vec<Address>,
    pub claim_set: String,
    pub tee_pcr_hash: String,
}

#[derive(Clone, Debug)]
pub struct IncidentOpenDigestInput {
    pub chain_id: u64,
    pub verifying_contract: Address,
    pub insured_token: Address,
    pub reference_block: u64,
    pub incident_id: BigUint,
    pub tee_pcr_hash: String,
}

#[derive(Debug, Error)]
pub enum TypedDataError {
    #[error("invalid {field}: expected 32-byte 0x-prefixed hex, got {value}")]
    InvalidHash { field: &'static str, value: String },
    #[error("value exceeds uint256")]
    Uint256Overflow,
}

fn hash32(field: &'static str, value: &str) -> Result<Hash, TypedDataError> {
    let raw = value
        .strip_prefix("0x")
        .filter(|raw| raw.len() == 64)
        .ok_or_else(|| TypedDataError::InvalidHash {
            field,
            value: value.to_owned(),
        })?;
    let mut result = [0u8; 32];
    hex::decode_to_slice(raw, &mut result).map_err(|_| TypedDataError::InvalidHash {
        field,
        value: value.to_owned(),
    })?;
    Ok(result)
}

fn word(value: &BigUint) -> Result<Hash, TypedDataError> {
    uint256_word(value).map_err(|_| TypedDataError::Uint256Overflow)
}

fn packed_uint256_hash(values: &[BigUint]) -> Result<Hash, TypedDataError> {
    let mut packed = Vec::with_capacity(values.len().saturating_mul(32));
    for value in values {
        packed.extend_from_slice(&word(value)?);
    }
    Ok(keccak256(packed))
}

fn packed_address_hash(values: &[Address]) -> Hash {
    let mut packed = Vec::with_capacity(values.len().saturating_mul(32));
    for value in values {
        packed.extend_from_slice(&value.abi_word());
    }
    keccak256(packed)
}

fn domain_hash(chain_id: u64, verifying_contract: Address) -> Result<Hash, TypedDataError> {
    let mut domain = Vec::with_capacity(160);
    domain.extend_from_slice(&keccak256(DOMAIN_TYPE));
    domain.extend_from_slice(&keccak256(b"DefiInsurance"));
    domain.extend_from_slice(&keccak256(b"1"));
    domain.extend_from_slice(&word(&BigUint::from(chain_id))?);
    domain.extend_from_slice(&verifying_contract.abi_word());
    Ok(keccak256(domain))
}

fn typed_digest(domain_hash: Hash, struct_hash: Hash) -> String {
    let mut digest = Vec::with_capacity(66);
    digest.extend_from_slice(&[0x19, 0x01]);
    digest.extend_from_slice(&domain_hash);
    digest.extend_from_slice(&struct_hash);
    hash_hex(keccak256(digest))
}

pub fn pools_hash(values: &[Address]) -> String {
    hash_hex(packed_address_hash(values))
}

pub fn settlement_digest(input: &SettlementDigestInput) -> Result<String, TypedDataError> {
    let root = hash32("root", &input.root)?;
    let claim_set = hash32("claimSet", &input.claim_set)?;
    let tee_pcr_hash = hash32("teePcrHash", &input.tee_pcr_hash)?;
    let domain_hash = domain_hash(input.chain_id, input.verifying_contract)?;

    let mut structure = Vec::with_capacity(256);
    structure.extend_from_slice(&keccak256(SETTLEMENT_TYPE));
    structure.extend_from_slice(&word(&input.incident_id)?);
    structure.extend_from_slice(&root);
    structure.extend_from_slice(&word(&input.unresolved)?);
    structure.extend_from_slice(&packed_uint256_hash(&input.pool_payouts)?);
    structure.extend_from_slice(&packed_address_hash(&input.pool_addrs));
    structure.extend_from_slice(&claim_set);
    structure.extend_from_slice(&tee_pcr_hash);
    Ok(typed_digest(domain_hash, keccak256(structure)))
}

pub fn incident_open_digest(input: &IncidentOpenDigestInput) -> Result<String, TypedDataError> {
    let tee_pcr_hash = hash32("teePcrHash", &input.tee_pcr_hash)?;
    let mut structure = Vec::with_capacity(160);
    structure.extend_from_slice(&keccak256(INCIDENT_OPEN_TYPE));
    structure.extend_from_slice(&input.insured_token.abi_word());
    structure.extend_from_slice(&word(&BigUint::from(input.reference_block))?);
    structure.extend_from_slice(&word(&input.incident_id)?);
    structure.extend_from_slice(&tee_pcr_hash);
    Ok(typed_digest(
        domain_hash(input.chain_id, input.verifying_contract)?,
        keccak256(structure),
    ))
}
