use crate::typed_data::{SettlementDigestInput, settlement_digest};
use crate::{Address, ClaimEvent, EventKind, MerkleRow, SettlementTree, claim_set_hash};
use alloy_primitives::{Address as AlloyAddress, B256, U256};
use alloy_sol_types::{SolType, sol};
use num_bigint::BigUint;
use std::str::FromStr;
use thiserror::Error;

type TreePayload = sol!((uint256,uint256[],address[],uint256[][],uint256[],uint256[],uint256[]));
type DigestPayload =
    sol!((uint256,address,uint256,bytes32,uint256,uint256[],address[],bytes32,bytes32));
type ClaimSetPayload = sol!((uint8[],uint256[],address[],uint256[],uint256[],uint256[]));
type Bytes32Type = sol!(bytes32);
type Bytes32ArrayType = sol!(bytes32[]);

#[derive(Debug, Error)]
pub enum FfiError {
    #[error("invalid hex payload")]
    InvalidHex,
    #[error("invalid ABI payload: {0}")]
    InvalidAbi(String),
    #[error("invalid FFI input: {0}")]
    InvalidInput(String),
    #[error("invalid claim id: {0}")]
    InvalidClaimId(String),
    #[error("settlement computation failed: {0}")]
    Compute(String),
}

fn payload_bytes(payload: &str) -> Result<Vec<u8>, FfiError> {
    let raw = payload.strip_prefix("0x").ok_or(FfiError::InvalidHex)?;
    if !raw.len().is_multiple_of(2) {
        return Err(FfiError::InvalidHex);
    }
    hex::decode(raw).map_err(|_| FfiError::InvalidHex)
}

fn big(value: U256) -> BigUint {
    BigUint::from_bytes_be(&value.to_be_bytes::<32>())
}

fn local_address(value: AlloyAddress) -> Address {
    Address::from_bytes(value.into_array())
}

fn b256_hex(value: B256) -> String {
    format!("0x{}", hex::encode(value.as_slice()))
}

fn parse_b256(value: &str) -> Result<B256, FfiError> {
    B256::from_str(value).map_err(|_| FfiError::Compute("invalid bytes32 output".to_owned()))
}

fn tree(payload: &str) -> Result<(SettlementTree, Vec<BigUint>), FfiError> {
    let decoded = <TreePayload as SolType>::abi_decode_params(&payload_bytes(payload)?)
        .map_err(|error| FfiError::InvalidAbi(error.to_string()))?;
    let (incident_id, ids, users, amounts, spents, boosteds, eligibles) = decoded;
    let length = ids.len();
    if users.len() != length
        || amounts.len() != length
        || spents.len() != length
        || boosteds.len() != length
        || eligibles.len() != length
    {
        return Err(FfiError::InvalidInput(
            "tree payload arrays have different lengths".to_owned(),
        ));
    }
    let claim_ids = ids.into_iter().map(big).collect::<Vec<_>>();
    let rows = claim_ids
        .iter()
        .cloned()
        .zip(users.into_iter().map(local_address))
        .zip(amounts)
        .zip(spents)
        .zip(boosteds)
        .zip(eligibles)
        .map(
            |(((((claim_id, user), amounts), score_spent), boosted_score), eligible_amount)| {
                MerkleRow {
                    claim_id,
                    user,
                    amounts: amounts.into_iter().map(big).collect(),
                    score_spent: big(score_spent),
                    boosted_score: big(boosted_score),
                    eligible_amount: big(eligible_amount),
                }
            },
        )
        .collect::<Vec<_>>();
    let tree = SettlementTree::new(&big(incident_id), &rows)
        .map_err(|error| FfiError::Compute(error.to_string()))?;
    Ok((tree, claim_ids))
}

fn encode_bytes32(value: B256) -> String {
    format!(
        "0x{}",
        hex::encode(<Bytes32Type as SolType>::abi_encode(&value))
    )
}

fn encode_bytes32_array(values: &[B256]) -> String {
    format!(
        "0x{}",
        hex::encode(<Bytes32ArrayType as SolType>::abi_encode(values))
    )
}

pub fn run(command: &str, payload: &str, argument: Option<&str>) -> Result<String, FfiError> {
    match command {
        "root" => {
            let (tree, _) = tree(payload)?;
            Ok(encode_bytes32(parse_b256(&tree.root_hex())?))
        }
        "proof" => {
            let claim_text = argument.ok_or_else(|| {
                FfiError::InvalidInput("proof command requires claim id".to_owned())
            })?;
            let claim_id = BigUint::from_str(claim_text)
                .map_err(|_| FfiError::InvalidClaimId(claim_text.to_owned()))?;
            let (tree, claim_ids) = tree(payload)?;
            let proof = if claim_ids.contains(&claim_id) {
                tree.proof_hex(&claim_id)
                    .map_err(|error| FfiError::Compute(error.to_string()))?
                    .iter()
                    .map(|value| parse_b256(value))
                    .collect::<Result<Vec<_>, _>>()?
            } else {
                Vec::new()
            };
            Ok(encode_bytes32_array(&proof))
        }
        "digest" => {
            let decoded = <DigestPayload as SolType>::abi_decode_params(&payload_bytes(payload)?)
                .map_err(|error| FfiError::InvalidAbi(error.to_string()))?;
            let (
                chain_id,
                verifying_contract,
                incident_id,
                root,
                unresolved,
                pool_payouts,
                pool_addrs,
                claim_set,
                tee_pcr_hash,
            ) = decoded;
            let chain_id = u64::try_from(chain_id)
                .map_err(|_| FfiError::InvalidInput("chain id exceeds uint64".to_owned()))?;
            let digest = settlement_digest(&SettlementDigestInput {
                chain_id,
                verifying_contract: local_address(verifying_contract),
                incident_id: big(incident_id),
                root: b256_hex(root),
                unresolved: big(unresolved),
                pool_payouts: pool_payouts.into_iter().map(big).collect(),
                pool_addrs: pool_addrs.into_iter().map(local_address).collect(),
                claim_set: b256_hex(claim_set),
                tee_pcr_hash: b256_hex(tee_pcr_hash),
            })
            .map_err(|error| FfiError::Compute(error.to_string()))?;
            Ok(encode_bytes32(parse_b256(&digest)?))
        }
        "claimset" => {
            let decoded = <ClaimSetPayload as SolType>::abi_decode_params(&payload_bytes(payload)?)
                .map_err(|error| FfiError::InvalidAbi(error.to_string()))?;
            let (kinds, ids, users, escrows, scores, boosters) = decoded;
            let length = kinds.len();
            if ids.len() != length
                || users.len() != length
                || escrows.len() != length
                || scores.len() != length
                || boosters.len() != length
            {
                return Err(FfiError::InvalidInput(
                    "claim-set payload arrays have different lengths".to_owned(),
                ));
            }
            let events = kinds
                .into_iter()
                .zip(ids)
                .zip(users)
                .zip(escrows)
                .zip(scores)
                .zip(boosters)
                .enumerate()
                .map(
                    |(
                        index,
                        (((((kind, claim_id), user), amount), score_to_spend), booster_amount),
                    )| {
                        let kind = match kind {
                            0 => Ok(EventKind::Register),
                            1 => Ok(EventKind::Cancel),
                            value => Err(FfiError::InvalidInput(format!(
                                "unsupported claim event kind: {value}"
                            ))),
                        }?;
                        Ok(ClaimEvent {
                            kind,
                            claim_id: big(claim_id),
                            user: local_address(user),
                            amount: big(amount),
                            score_to_spend: big(score_to_spend),
                            booster_amount: big(booster_amount),
                            block_number: u64::try_from(index).map_err(|_| {
                                FfiError::InvalidInput("too many claim events".to_owned())
                            })?,
                            log_index: u64::try_from(index).map_err(|_| {
                                FfiError::InvalidInput("too many claim events".to_owned())
                            })?,
                        })
                    },
                )
                .collect::<Result<Vec<_>, FfiError>>()?;
            let hash =
                claim_set_hash(&events).map_err(|error| FfiError::Compute(error.to_string()))?;
            Ok(encode_bytes32(parse_b256(&hash)?))
        }
        value => Err(FfiError::InvalidInput(format!(
            "unknown FFI command: {value}"
        ))),
    }
}
