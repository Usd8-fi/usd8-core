use crate::Address;
use crate::abi::{IDefiInsurance, IRegistry};
use crate::chain::{
    block_by_number, chain_id, contract_call, defi_insurance_at, finalized_block, incident_at,
    latest_block, ratio_at,
};
use crate::config::CHAIN_ID;
use crate::rpc::Rpc;
use crate::typed_data::{IncidentOpenDigestInput, incident_open_digest};
use alloy_primitives::{Address as AlloyAddress, U256};
use num_bigint::BigUint;
use num_traits::Zero;
use serde::Serialize;
use thiserror::Error;

const CLOSED_STATUS: u8 = 2;
const MAX_INCIDENT_OPEN_SAMPLES: u64 = 256;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IncidentOpenAuthorization {
    pub schema_version: u32,
    pub artifact_type: &'static str,
    pub chain_id: u64,
    pub registry: String,
    pub defi_insurance: String,
    pub insured_token: String,
    pub reference_block: u64,
    pub observation_block: u64,
    pub baseline_twap: String,
    pub distress_twap: String,
    pub baseline_ratio_sum: String,
    pub distress_ratio_sum: String,
    pub sample_count: u64,
    pub twap_blocks: u64,
    pub sample_step_blocks: u64,
    pub minimum_drop_bps: u16,
    pub eligibility_hash: String,
    pub incident_id: String,
    pub tee_pcr_hash: String,
    pub open_digest: String,
}

impl IncidentOpenAuthorization {
    pub fn digest(&self) -> &str {
        &self.open_digest
    }
}

#[derive(Debug, Error)]
pub enum IncidentOpenError {
    #[error(transparent)]
    Chain(#[from] crate::chain::ChainError),
    #[error("RPC chain id {actual} does not match compiled chain id {expected}")]
    ChainId { actual: u64, expected: u64 },
    #[error("DefiInsurance reverse Registry binding mismatch")]
    RegistryMismatch,
    #[error("nextIncidentId is zero")]
    ZeroIncidentId,
    #[error("reference block {reference} is invalid at head {head} with max age {max_age}")]
    InvalidReferenceBlock {
        reference: u64,
        head: u64,
        max_age: u64,
    },
    #[error("reference block {reference} is not finalized; finalized head is {finalized}")]
    ReferenceNotFinalized { reference: u64, finalized: u64 },
    #[error("finalized head {finalized} is ahead of latest head {latest}")]
    FinalizedAheadOfLatest { finalized: u64, latest: u64 },
    #[error("insured token is not approved")]
    UnapprovedToken,
    #[error("TEE signer is not authorized")]
    UnauthorizedSigner,
    #[error("Registry TEE PCR commitment is zero")]
    ZeroPcrCommitment,
    #[error("an active incident already exists")]
    ActiveIncident,
    #[error("incident-open price configuration is invalid")]
    InvalidPriceConfig,
    #[error(
        "post-reference TWAP ending at block {required} is not finalized; finalized head is {finalized}"
    )]
    InsufficientPostReferenceWindow { required: u64, finalized: u64 },
    #[error(
        "insured-token/immediate-underlying price drop is below the required {minimum_drop_bps} bps"
    )]
    InsufficientPriceDrop { minimum_drop_bps: u16 },

    #[error("latest block changed during authorization")]
    HeadChanged,
    #[error("finalized block changed during authorization")]
    FinalizedHeadChanged,
    #[error("typed-data digest failed: {0}")]
    TypedData(String),
}

fn local_address(value: AlloyAddress) -> Address {
    Address::from_bytes(value.into_array())
}

fn big(value: U256) -> BigUint {
    BigUint::from_bytes_be(&value.to_be_bytes::<32>())
}

async fn incident_open_twap_sums<R: Rpc + ?Sized>(
    rpc: &R,
    conversion_address: Address,
    conversion_call_data: &[u8],
    reference_block: u64,
    twap_blocks: u64,
    sample_step_blocks: u64,
) -> Result<(BigUint, BigUint, u64), IncidentOpenError> {
    let mut baseline_sum = BigUint::zero();
    let mut distress_sum = BigUint::zero();
    let mut samples = 0u64;
    let mut offset = sample_step_blocks;
    while offset <= twap_blocks {
        baseline_sum += ratio_at(
            rpc,
            conversion_address,
            conversion_call_data,
            reference_block - offset,
        )
        .await?;
        distress_sum += ratio_at(
            rpc,
            conversion_address,
            conversion_call_data,
            reference_block + offset,
        )
        .await?;
        samples += 1;
        offset += sample_step_blocks;
    }
    Ok((baseline_sum, distress_sum, samples))
}

pub async fn build_incident_open<R: Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    insured_token: Address,
    reference_block: u64,
    expected_signer: Address,
) -> Result<IncidentOpenAuthorization, IncidentOpenError> {
    let actual_chain_id = chain_id(rpc).await?;
    if actual_chain_id != CHAIN_ID {
        return Err(IncidentOpenError::ChainId {
            actual: actual_chain_id,
            expected: CHAIN_ID,
        });
    }
    let finalized = finalized_block(rpc).await?;
    let head = latest_block(rpc).await?;
    if finalized.number > head.number {
        return Err(IncidentOpenError::FinalizedAheadOfLatest {
            finalized: finalized.number,
            latest: head.number,
        });
    }
    let at = Some(head.number);
    let defi_insurance = defi_insurance_at(rpc, registry, at).await?;
    let reverse_registry = local_address(
        contract_call(rpc, defi_insurance, &IDefiInsurance::registryCall {}, at).await?,
    );
    if reverse_registry != registry {
        return Err(IncidentOpenError::RegistryMismatch);
    }

    let next_incident = contract_call(
        rpc,
        defi_insurance,
        &IDefiInsurance::nextIncidentIdCall {},
        at,
    )
    .await?;
    if next_incident.is_zero() {
        return Err(IncidentOpenError::ZeroIncidentId);
    }
    let timing = contract_call(rpc, registry, &IRegistry::incidentTimingConfigCall {}, at).await?;
    let max_age = timing.maxReferenceBlockAge;
    if reference_block == 0
        || reference_block >= head.number
        || head.number - reference_block > max_age
    {
        return Err(IncidentOpenError::InvalidReferenceBlock {
            reference: reference_block,
            head: head.number,
            max_age,
        });
    }
    if reference_block > finalized.number {
        return Err(IncidentOpenError::ReferenceNotFinalized {
            reference: reference_block,
            finalized: finalized.number,
        });
    }
    let price_config = contract_call(
        rpc,
        registry,
        &IRegistry::incidentOpenPriceConfigCall {},
        at,
    )
    .await?;
    if price_config.twapBlocks == 0
        || price_config.sampleStepBlocks == 0
        || price_config.sampleStepBlocks > price_config.twapBlocks
        || price_config.twapBlocks % price_config.sampleStepBlocks != 0
        || price_config.twapBlocks / price_config.sampleStepBlocks < 2
        || price_config.twapBlocks / price_config.sampleStepBlocks > MAX_INCIDENT_OPEN_SAMPLES
        || price_config.minimumDropBps == 0
        || price_config.minimumDropBps >= 10_000
        || price_config.twapBlocks >= max_age
        || reference_block < price_config.twapBlocks
    {
        return Err(IncidentOpenError::InvalidPriceConfig);
    }
    let observation_block = reference_block
        .checked_add(price_config.twapBlocks)
        .ok_or(IncidentOpenError::InvalidPriceConfig)?;
    if observation_block > finalized.number {
        return Err(IncidentOpenError::InsufficientPostReferenceWindow {
            required: observation_block,
            finalized: finalized.number,
        });
    }

    let token = contract_call(
        rpc,
        defi_insurance,
        &IDefiInsurance::getInsuredTokenCall {
            token: AlloyAddress::from(insured_token.into_bytes()),
        },
        at,
    )
    .await?;
    if token.maxCoverageBps.is_zero() {
        return Err(IncidentOpenError::UnapprovedToken);
    }
    let eligibility_hash = contract_call(
        rpc,
        defi_insurance,
        &IDefiInsurance::incidentOpenEligibilityHashCall {
            insuredToken: AlloyAddress::from(insured_token.into_bytes()),
        },
        at,
    )
    .await?;
    let eligibility_hash = format!("{eligibility_hash:#x}");
    let signer_authorized = contract_call(
        rpc,
        defi_insurance,
        &IDefiInsurance::isTeeSignerCall {
            signer: AlloyAddress::from(expected_signer.into_bytes()),
        },
        at,
    )
    .await?;
    if !signer_authorized {
        return Err(IncidentOpenError::UnauthorizedSigner);
    }
    let tee_pcr_hash = contract_call(rpc, registry, &IRegistry::teePcrHashCall {}, at).await?;
    if tee_pcr_hash.is_zero() {
        return Err(IncidentOpenError::ZeroPcrCommitment);
    }

    if next_incident > U256::from(1) {
        let previous_id = next_incident - U256::from(1);
        let previous = incident_at(rpc, defi_insurance, big(previous_id), at).await?;
        let active = if previous.status == CLOSED_STATUS {
            false
        } else if head.timestamp <= previous.claim_window_end_time {
            true
        } else if previous.unresolved.is_zero() {
            false
        } else if previous.root == format!("0x{}", "0".repeat(64)) {
            head.timestamp <= previous.disputed_at
        } else {
            let finalize_deadline = contract_call(
                rpc,
                defi_insurance,
                &IDefiInsurance::incidentFinalizeDeadlineCall {
                    incidentId: previous_id,
                },
                at,
            )
            .await?;
            head.timestamp <= finalize_deadline
        };
        if active {
            return Err(IncidentOpenError::ActiveIncident);
        }
    }

    let (baseline_sum, distress_sum, sample_count) = incident_open_twap_sums(
        rpc,
        local_address(token.underlyingConversionAddress),
        token.underlyingConversionCallData.as_ref(),
        reference_block,
        price_config.twapBlocks,
        price_config.sampleStepBlocks,
    )
    .await?;
    let bps = BigUint::from(10_000u16);
    let remaining_bps = BigUint::from(10_000u16 - price_config.minimumDropBps);
    if &distress_sum * &bps >= &baseline_sum * &remaining_bps {
        return Err(IncidentOpenError::InsufficientPriceDrop {
            minimum_drop_bps: price_config.minimumDropBps,
        });
    }
    let sample_count_big = BigUint::from(sample_count);
    let baseline_twap = &baseline_sum / &sample_count_big;
    let distress_twap = &distress_sum / sample_count_big;

    let digest = incident_open_digest(&IncidentOpenDigestInput {
        chain_id: actual_chain_id,
        verifying_contract: defi_insurance,
        insured_token,
        reference_block,
        incident_id: big(next_incident),
        tee_pcr_hash: format!("{tee_pcr_hash:#x}"),
        eligibility_hash: eligibility_hash.clone(),
    })
    .map_err(|error| IncidentOpenError::TypedData(error.to_string()))?;
    if block_by_number(rpc, finalized.number).await?.hash != finalized.hash {
        return Err(IncidentOpenError::FinalizedHeadChanged);
    }
    if block_by_number(rpc, head.number).await?.hash != head.hash {
        return Err(IncidentOpenError::HeadChanged);
    }
    Ok(IncidentOpenAuthorization {
        schema_version: 1,
        artifact_type: "incidentOpen",
        chain_id: actual_chain_id,
        registry: registry.to_string(),
        defi_insurance: defi_insurance.to_string(),
        insured_token: insured_token.to_string(),
        reference_block,
        observation_block,
        baseline_twap: baseline_twap.to_string(),
        distress_twap: distress_twap.to_string(),
        baseline_ratio_sum: baseline_sum.to_string(),
        distress_ratio_sum: distress_sum.to_string(),
        sample_count,
        twap_blocks: price_config.twapBlocks,
        sample_step_blocks: price_config.sampleStepBlocks,
        minimum_drop_bps: price_config.minimumDropBps,
        eligibility_hash,
        incident_id: big(next_incident).to_string(),
        tee_pcr_hash: format!("{tee_pcr_hash:#x}"),
        open_digest: digest,
    })
}
