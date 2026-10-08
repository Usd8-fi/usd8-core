use super::open_advisory_cache::{AdvisorySource, Binding, CheckError, Semantic};
use async_trait::async_trait;
use usd8_settlement::{Address, rpc::Rpc};
pub struct Source<'a, R: Rpc + ?Sized> {
    pub rpc: &'a R,
    pub registry: Address,
    pub module: Address,
    pub token: Address,
}
impl<R: Rpc + ?Sized> Source<'_, R> {
    async fn read_binding(&self) -> Result<Binding, CheckError> {
        use sha3::{Digest, Keccak256};
        use usd8_settlement::abi::{IDefiInsurance as D, IMulticall3, IRegistry as Rg};
        use usd8_settlement::chain::{
            aggregate_reads, block_by_number, chain_id, decode_read, defi_insurance_at,
            finalized_block, latest_block, read_call,
        };
        let unavailable = |_| CheckError::Unavailable;
        if self.registry.is_zero()
            || self.module.is_zero()
            || self.token.is_zero()
            || chain_id(self.rpc).await.map_err(unavailable)?
                != usd8_tee_job_api::configured_chain_id()
        {
            return Err(CheckError::Unavailable);
        }
        let head = latest_block(self.rpc).await.map_err(unavailable)?;
        let finalized = finalized_block(self.rpc).await.map_err(unavailable)?;
        if head.number == 0
            || finalized.number == 0
            || finalized.number > head.number
            || defi_insurance_at(self.rpc, self.registry, Some(head.number))
                .await
                .map_err(unavailable)?
                != self.module
        {
            return Err(CheckError::Unavailable);
        }
        let token = self
            .token
            .to_string()
            .parse()
            .map_err(|_| CheckError::Unavailable)?;
        let reads = aggregate_reads(
            self.rpc,
            vec![
                read_call(self.module, D::registryCall {}),
                read_call(self.module, D::nextIncidentIdCall {}),
                read_call(self.registry, Rg::incidentTimingConfigCall {}),
                read_call(self.registry, Rg::incidentOpenPriceConfigCall {}),
                read_call(self.module, D::getInsuredTokenCall { token }),
                read_call(
                    self.module,
                    D::incidentOpenEligibilityHashCall {
                        insuredToken: token,
                    },
                ),
                read_call(self.registry, Rg::teePcrHashCall {}),
                IMulticall3::Call3 {
                    target: self
                        .module
                        .to_string()
                        .parse()
                        .map_err(|_| CheckError::Unavailable)?,
                    allowFailure: false,
                    callData: Keccak256::digest(b"activeIncidentId()")[..4]
                        .to_vec()
                        .into(),
                },
            ],
            head.number,
        )
        .await
        .map_err(unavailable)?;
        if decode_read::<D::registryCall>(&reads[0])
            .map_err(unavailable)?
            .as_slice()
            != self.registry.into_bytes()
            || decode_read::<D::nextIncidentIdCall>(&reads[1]).map_err(unavailable)? == 0
        {
            return Err(CheckError::Unavailable);
        }
        let timing = decode_read::<Rg::incidentTimingConfigCall>(&reads[2]).map_err(unavailable)?;
        let price =
            decode_read::<Rg::incidentOpenPriceConfigCall>(&reads[3]).map_err(unavailable)?;
        let insured = decode_read::<D::getInsuredTokenCall>(&reads[4]).map_err(unavailable)?;
        let eligibility =
            decode_read::<D::incidentOpenEligibilityHashCall>(&reads[5]).map_err(unavailable)?;
        let pcr = decode_read::<Rg::teePcrHashCall>(&reads[6]).map_err(unavailable)?;
        if timing.maxReferenceBlockAge == 0
            || price.twapBlocks == 0
            || price.sampleStepBlocks == 0
            || price.minimumDropBps == 0
            || price.minimumDropBps >= 10_000
            || eligibility.is_zero()
            || pcr.is_zero()
            || reads[7].len() != 32
        {
            return Err(CheckError::Unavailable);
        }
        if insured.maxCoverageBps == 0 {
            return Err(CheckError::Unapproved);
        }
        if reads[7].iter().any(|byte| *byte != 0) {
            return Err(CheckError::Active);
        }
        if block_by_number(self.rpc, head.number)
            .await
            .map_err(unavailable)?
            != head
        {
            return Err(CheckError::Unavailable);
        }
        let mut hash = Keccak256::new();
        hash.update(b"usd8-open-advisory-config-v1");
        for read in &reads {
            hash.update((read.len() as u64).to_be_bytes());
            hash.update(read);
        }
        Ok(Binding {
            commitment: hex::encode(hash.finalize()),
            head: head.number,
            finalized: finalized.number,
            max_age: timing.maxReferenceBlockAge,
        })
    }
}

#[async_trait]
impl<R: Rpc + ?Sized> AdvisorySource for Source<'_, R> {
    async fn binding(&self) -> Result<Binding, CheckError> {
        tokio::time::timeout(std::time::Duration::from_secs(12), self.read_binding())
            .await
            .map_err(|_| CheckError::Unavailable)?
    }
    async fn refresh(&self) -> Result<Semantic, CheckError> {
        use usd8_settlement::incident_open::{IncidentOpenError, precheck_incident_open};
        match precheck_incident_open(self.rpc, self.registry, self.token).await {
            Ok(result) if result.defi_insurance == self.module.to_string() => {
                Ok(Semantic::Qualifying {
                    reference_block: result.reference_block,
                    observation_block: result.observation_block,
                })
            }
            Err(IncidentOpenError::InsufficientPriceDrop { .. }) => Ok(Semantic::NoDrop),
            Err(IncidentOpenError::ActiveIncident) => Err(CheckError::Active),
            Err(IncidentOpenError::UnapprovedToken) => Err(CheckError::Unapproved),
            _ => Err(CheckError::Unavailable),
        }
    }
}
