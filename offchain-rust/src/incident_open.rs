use crate::Address;
use crate::abi::{IDefiInsurance, IRegistry};
use crate::chain::{
    aggregate_reads, block_by_number, chain_id, decode_read, defi_insurance_at, finalized_block,
    latest_block, ratios_at, read_call,
};
use crate::config::CHAIN_ID;
use crate::rpc::Rpc;
use crate::typed_data::{IncidentOpenDigestInput, incident_open_digest};
use alloy_primitives::{Address as AlloyAddress, U256};
use num_bigint::BigUint;
use serde::Serialize;
use thiserror::Error;

const MAX_INCIDENT_OPEN_SAMPLES: u64 = 256;
const MAX_INCIDENT_OPEN_DISCOVERY_POINTS: u64 = 256;

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
        "insured-token/immediate-underlying price drop is below the required {minimum_drop_bps} bps"
    )]
    InsufficientPriceDrop { minimum_drop_bps: u16 },
    #[error("incident-open discovery has no finalized candidate window")]
    NoFinalizedCandidateWindow,
    #[error("incident-open discovery requires {points} price points; maximum is {maximum}")]
    DiscoveryTooLarge { points: u64, maximum: u64 },

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

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IncidentOpenPrecheck {
    pub chain_id: u64,
    pub registry: String,
    pub defi_insurance: String,
    pub insured_token: String,
    pub reference_block: u64,
    pub observation_block: u64,
    pub baseline_twap: String,
    pub distress_twap: String,
    pub sample_count: u64,
    pub twap_blocks: u64,
    pub sample_step_blocks: u64,
    pub minimum_drop_bps: u16,
}

struct TwapSelection {
    reference_block: u64,
    baseline_sum: BigUint,
    distress_sum: BigUint,
    sample_count: u64,
}

struct DiscoveryPolicy {
    latest_block: u64,
    finalized_block: u64,
    max_age: u64,
    twap_blocks: u64,
    sample_step_blocks: u64,
    minimum_drop_bps: u16,
}

//we sample every 300 blocks, check its twap price upto before and after 300 blocks, then check if price drop met the minimum drop bps requirement.
async fn discover_incident_open_twap<R: Rpc + ?Sized>(
    rpc: &R,
    conversion_address: Address,
    conversion_call_data: &[u8],
    policy: DiscoveryPolicy,
) -> Result<TwapSelection, IncidentOpenError> {
    let DiscoveryPolicy {
        latest_block,
        finalized_block,
        max_age,            //max look back age for incident, set at 43200 blocks as 6 days
        twap_blocks, //the twap block window we use to calculate price drops, set at 7200 blocks as 24 hours window
        sample_step_blocks, //the step size for sampling the twap, set at 300 blocks as 1 hour
        minimum_drop_bps,
    } = policy;
    let earliest = latest_block.saturating_sub(max_age).max(twap_blocks).max(1); //get the earliest allowed block from max age. max it with twap_blocks to ensure edge case of earliest block number less than twap.
    let Some(latest) = finalized_block.checked_sub(twap_blocks) else {
        return Err(IncidentOpenError::NoFinalizedCandidateWindow);
    };
    let first_candidate = earliest
        .div_ceil(sample_step_blocks)
        .checked_mul(sample_step_blocks)
        .ok_or(IncidentOpenError::InvalidPriceConfig)?;
    let last_candidate = (latest / sample_step_blocks) * sample_step_blocks;
    if first_candidate > last_candidate || first_candidate >= latest_block {
        return Err(IncidentOpenError::NoFinalizedCandidateWindow);
    }

    let candidate_count = (last_candidate - first_candidate) / sample_step_blocks + 1; //candidate is how many blocks we are looking at. we dont look at every block due to sample step size.
    let sample_count = twap_blocks / sample_step_blocks; // sample_count is how many samples we take for each candidate
    let point_count = candidate_count //point count is total sample count we need for all candidates.
        .checked_add(sample_count.saturating_mul(2))
        .ok_or(IncidentOpenError::InvalidPriceConfig)?;
    if point_count > MAX_INCIDENT_OPEN_DISCOVERY_POINTS {
        return Err(IncidentOpenError::DiscoveryTooLarge {
            points: point_count,
            maximum: MAX_INCIDENT_OPEN_DISCOVERY_POINTS,
        });
    }

    let first_point = first_candidate - twap_blocks;
    let last_point = last_candidate
        .checked_add(twap_blocks)
        .ok_or(IncidentOpenError::InvalidPriceConfig)?;
    let mut blocks = Vec::with_capacity(point_count as usize);
    let mut block = first_point;
    while block <= last_point {
        blocks.push(block);
        let Some(next) = block.checked_add(sample_step_blocks) else {
            //we take blocks with gap of sample_step_blocks.
            break;
        };
        block = next;
    }

    let ratios = ratios_at(rpc, conversion_address, conversion_call_data, &blocks).await?; //ratios are just price against underlying, get prices for each block we are looking at.

    let sample_count_usize = sample_count as usize;
    let mut baseline_sum = ratios[..sample_count_usize]
        .iter()
        .cloned()
        .sum::<BigUint>();
    let mut distress_sum = ratios[sample_count_usize + 1..=sample_count_usize * 2]
        .iter()
        .cloned()
        .sum::<BigUint>();
    let bps = BigUint::from(10_000u16);
    let remaining_bps = BigUint::from(10_000u16 - minimum_drop_bps);
    let mut selected = None;
    let mut previous_qualified = false;
    for candidate_index in 0..candidate_count as usize {
        let qualified = &distress_sum * &bps < &baseline_sum * &remaining_bps;
        if qualified && !previous_qualified {
            selected = Some(TwapSelection {
                reference_block: first_candidate + candidate_index as u64 * sample_step_blocks,
                baseline_sum: baseline_sum.clone(),
                distress_sum: distress_sum.clone(),
                sample_count,
            });
        }
        previous_qualified = qualified;
        if candidate_index + 1 < candidate_count as usize {
            baseline_sum -= &ratios[candidate_index];
            baseline_sum += &ratios[candidate_index + sample_count_usize];
            distress_sum -= &ratios[candidate_index + sample_count_usize + 1];
            distress_sum += &ratios[candidate_index + sample_count_usize * 2 + 1];
        }
    }
    selected.ok_or(IncidentOpenError::InsufficientPriceDrop { minimum_drop_bps })
}

/// Runs the same bounded price-drop discovery used by incident authorization without
/// producing a digest or signature. This is only a cost-saving admission check; callers
/// must rerun authoritative verification inside the measured enclave before signing.
pub async fn precheck_incident_open<R: Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    insured_token: Address,
) -> Result<IncidentOpenPrecheck, IncidentOpenError> {
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
    let reads = aggregate_reads(
        rpc,
        vec![
            read_call(defi_insurance, IDefiInsurance::registryCall {}),
            read_call(defi_insurance, IDefiInsurance::nextIncidentIdCall {}),
            read_call(registry, IRegistry::incidentTimingConfigCall {}),
            read_call(registry, IRegistry::incidentOpenPriceConfigCall {}),
            read_call(
                defi_insurance,
                IDefiInsurance::getInsuredTokenCall {
                    token: AlloyAddress::from(insured_token.into_bytes()),
                },
            ),
        ],
        head.number,
    )
    .await?;
    let reverse_registry = local_address(decode_read::<IDefiInsurance::registryCall>(&reads[0])?);
    if reverse_registry != registry {
        return Err(IncidentOpenError::RegistryMismatch);
    }

    let next_incident = decode_read::<IDefiInsurance::nextIncidentIdCall>(&reads[1])?;
    if next_incident == 0 {
        return Err(IncidentOpenError::ZeroIncidentId);
    }
    if next_incident > 1 {
        let previous_id = U256::from(next_incident - 1);
        let previous_reads = aggregate_reads(
            rpc,
            vec![
                read_call(
                    defi_insurance,
                    IDefiInsurance::incidentsCall {
                        incidentId: previous_id,
                    },
                ),
                read_call(
                    defi_insurance,
                    IDefiInsurance::incidentPhaseWindowCall {
                        incidentId: previous_id,
                    },
                ),
            ],
            head.number,
        )
        .await?;
        let previous = decode_read::<IDefiInsurance::incidentsCall>(&previous_reads[0])?;
        let phase_window =
            decode_read::<IDefiInsurance::incidentPhaseWindowCall>(&previous_reads[1])?;
        let head_timestamp = U256::from(head.timestamp);
        let phase_deadline = U256::from(previous.phaseDeadline);
        let active = if head_timestamp <= phase_deadline {
            true
        } else if previous.unresolvedClaims.is_zero() {
            false
        } else {
            head_timestamp <= phase_deadline + U256::from(phase_window)
        };
        if active {
            return Err(IncidentOpenError::ActiveIncident);
        }
    }

    let timing = decode_read::<IRegistry::incidentTimingConfigCall>(&reads[2])?;
    let max_age = timing.maxReferenceBlockAge;
    let price_config = decode_read::<IRegistry::incidentOpenPriceConfigCall>(&reads[3])?;
    if price_config.twapBlocks == 0
        || price_config.sampleStepBlocks == 0
        || price_config.sampleStepBlocks > price_config.twapBlocks
        || price_config.twapBlocks % price_config.sampleStepBlocks != 0
        || price_config.twapBlocks / price_config.sampleStepBlocks < 2
        || price_config.twapBlocks / price_config.sampleStepBlocks > MAX_INCIDENT_OPEN_SAMPLES
        || price_config.minimumDropBps == 0
        || price_config.minimumDropBps >= 10_000
        || price_config.twapBlocks >= max_age
    {
        return Err(IncidentOpenError::InvalidPriceConfig);
    }
    let token = decode_read::<IDefiInsurance::getInsuredTokenCall>(&reads[4])?;
    if token.maxCoverageBps == 0 {
        return Err(IncidentOpenError::UnapprovedToken);
    }

    let selection = discover_incident_open_twap(
        rpc,
        local_address(token.underlyingConversionAddress),
        token.underlyingConversionCallData.as_ref(),
        DiscoveryPolicy {
            latest_block: head.number,
            finalized_block: finalized.number,
            max_age,
            twap_blocks: price_config.twapBlocks,
            sample_step_blocks: price_config.sampleStepBlocks,
            minimum_drop_bps: price_config.minimumDropBps,
        },
    )
    .await?;
    if block_by_number(rpc, finalized.number).await?.hash != finalized.hash {
        return Err(IncidentOpenError::FinalizedHeadChanged);
    }
    if block_by_number(rpc, head.number).await?.hash != head.hash {
        return Err(IncidentOpenError::HeadChanged);
    }
    let observation_block = selection
        .reference_block
        .checked_add(price_config.twapBlocks)
        .ok_or(IncidentOpenError::InvalidPriceConfig)?;
    let sample_count_big = BigUint::from(selection.sample_count);
    let baseline_twap = &selection.baseline_sum / &sample_count_big;
    let distress_twap = &selection.distress_sum / sample_count_big;
    Ok(IncidentOpenPrecheck {
        chain_id: actual_chain_id,
        registry: registry.to_string(),
        defi_insurance: defi_insurance.to_string(),
        insured_token: insured_token.to_string(),
        reference_block: selection.reference_block,
        observation_block,
        baseline_twap: baseline_twap.to_string(),
        distress_twap: distress_twap.to_string(),
        sample_count: selection.sample_count,
        twap_blocks: price_config.twapBlocks,
        sample_step_blocks: price_config.sampleStepBlocks,
        minimum_drop_bps: price_config.minimumDropBps,
    })
}

pub async fn build_incident_open<R: Rpc + ?Sized>(
    rpc: &R,
    registry: Address,
    insured_token: Address,
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
    let reads = aggregate_reads(
        rpc,
        vec![
            read_call(defi_insurance, IDefiInsurance::registryCall {}),
            read_call(defi_insurance, IDefiInsurance::nextIncidentIdCall {}),
            read_call(registry, IRegistry::incidentTimingConfigCall {}),
            read_call(registry, IRegistry::incidentOpenPriceConfigCall {}),
            read_call(
                defi_insurance,
                IDefiInsurance::getInsuredTokenCall {
                    token: AlloyAddress::from(insured_token.into_bytes()),
                },
            ),
            read_call(
                defi_insurance,
                IDefiInsurance::incidentOpenEligibilityHashCall {
                    insuredToken: AlloyAddress::from(insured_token.into_bytes()),
                },
            ),
            read_call(
                defi_insurance,
                IDefiInsurance::isTeeSignerCall {
                    signer: AlloyAddress::from(expected_signer.into_bytes()),
                },
            ),
            read_call(registry, IRegistry::teePcrHashCall {}),
        ],
        head.number,
    )
    .await?;
    let reverse_registry = local_address(decode_read::<IDefiInsurance::registryCall>(&reads[0])?);
    if reverse_registry != registry {
        return Err(IncidentOpenError::RegistryMismatch);
    }

    let next_incident = decode_read::<IDefiInsurance::nextIncidentIdCall>(&reads[1])?;
    if next_incident == 0 {
        return Err(IncidentOpenError::ZeroIncidentId);
    }
    let timing = decode_read::<IRegistry::incidentTimingConfigCall>(&reads[2])?;
    let max_age = timing.maxReferenceBlockAge;
    let price_config = decode_read::<IRegistry::incidentOpenPriceConfigCall>(&reads[3])?;
    if price_config.twapBlocks == 0 //we get twapBlocks and sampleStepBlocks from the contract and verify their values.
        || price_config.sampleStepBlocks == 0
        || price_config.sampleStepBlocks > price_config.twapBlocks
        || price_config.twapBlocks % price_config.sampleStepBlocks != 0
        || price_config.twapBlocks / price_config.sampleStepBlocks < 2
        || price_config.twapBlocks / price_config.sampleStepBlocks > MAX_INCIDENT_OPEN_SAMPLES
        || price_config.minimumDropBps == 0
        || price_config.minimumDropBps >= 10_000 //mindrop cant be >= 100%
        || price_config.twapBlocks >= max_age
    {
        return Err(IncidentOpenError::InvalidPriceConfig);
    }

    let token = decode_read::<IDefiInsurance::getInsuredTokenCall>(&reads[4])?;
    if token.maxCoverageBps == 0 {
        return Err(IncidentOpenError::UnapprovedToken);
    }
    //this is the hash of the current defiInsurance storage state.
    let eligibility_hash =
        decode_read::<IDefiInsurance::incidentOpenEligibilityHashCall>(&reads[5])?;
    let eligibility_hash = format!("{eligibility_hash:#x}");
    let signer_authorized = decode_read::<IDefiInsurance::isTeeSignerCall>(&reads[6])?;
    if !signer_authorized {
        return Err(IncidentOpenError::UnauthorizedSigner);
    }
    let tee_pcr_hash = decode_read::<IRegistry::teePcrHashCall>(&reads[7])?;
    if tee_pcr_hash.is_zero() {
        return Err(IncidentOpenError::ZeroPcrCommitment);
    }

    if next_incident > 1 {
        let previous_id = U256::from(next_incident - 1);
        let previous_reads = aggregate_reads(
            rpc,
            vec![
                read_call(
                    defi_insurance,
                    IDefiInsurance::incidentsCall {
                        incidentId: previous_id,
                    },
                ),
                read_call(
                    defi_insurance,
                    IDefiInsurance::incidentPhaseWindowCall {
                        incidentId: previous_id,
                    },
                ),
            ],
            head.number,
        )
        .await?;
        let previous = decode_read::<IDefiInsurance::incidentsCall>(&previous_reads[0])?;
        let phase_window =
            decode_read::<IDefiInsurance::incidentPhaseWindowCall>(&previous_reads[1])?;
        let head_timestamp = U256::from(head.timestamp);
        let phase_deadline = U256::from(previous.phaseDeadline);
        let active = if head_timestamp <= phase_deadline {
            true
        } else if previous.unresolvedClaims.is_zero() {
            false
        } else {
            head_timestamp <= phase_deadline + U256::from(phase_window)
        };
        if active {
            return Err(IncidentOpenError::ActiveIncident);
        }
    }

    let TwapSelection {
        reference_block,
        baseline_sum,
        distress_sum,
        sample_count,
    } = discover_incident_open_twap(
        rpc,
        local_address(token.underlyingConversionAddress),
        token.underlyingConversionCallData.as_ref(),
        DiscoveryPolicy {
            latest_block: head.number,
            finalized_block: finalized.number,
            max_age,
            twap_blocks: price_config.twapBlocks,
            sample_step_blocks: price_config.sampleStepBlocks,
            minimum_drop_bps: price_config.minimumDropBps,
        },
    )
    .await?;
    let observation_block = reference_block
        .checked_add(price_config.twapBlocks)
        .ok_or(IncidentOpenError::InvalidPriceConfig)?;
    let sample_count_big = BigUint::from(sample_count);
    let baseline_twap = &baseline_sum / &sample_count_big;
    let distress_twap = &distress_sum / sample_count_big;

    let digest = incident_open_digest(&IncidentOpenDigestInput {
        chain_id: actual_chain_id,
        verifying_contract: defi_insurance,
        insured_token,
        reference_block,
        incident_id: BigUint::from(next_incident),
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
        incident_id: next_incident.to_string(),
        tee_pcr_hash: format!("{tee_pcr_hash:#x}"),
        open_digest: digest,
    })
}
