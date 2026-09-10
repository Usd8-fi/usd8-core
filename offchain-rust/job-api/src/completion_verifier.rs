//! Control-plane adapter: trusted deployment policy, exact payload, one deadline.
use crate::settlement_verifier::{PromotionPolicy, VerificationError, verify_result_for_promotion};
use crate::{CanonicalRequest, CompletionVerifier, ServiceError, TerminalEnvelope};
use async_trait::async_trait;
use std::time::Duration;
use usd8_settlement::rpc::Rpc;

pub struct RpcCompletionVerifier<R: Rpc> {
    rpc: R,
    policy: PromotionPolicy,
    timeout: Duration,
}

impl<R: Rpc> RpcCompletionVerifier<R> {
    /// Policy must come from trusted deployment configuration, never terminal data.
    pub fn new(rpc: R, policy: PromotionPolicy, timeout: Duration) -> Result<Self, ServiceError> {
        if timeout.is_zero()
            || timeout > Duration::from_secs(30)
            || policy.chain_id == 0
            || policy.registry.is_zero()
            || policy.defi_insurance.is_zero()
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(Self {
            rpc,
            policy,
            timeout,
        })
    }
}

#[async_trait]
impl<R: Rpc> CompletionVerifier for RpcCompletionVerifier<R> {
    async fn verify(
        &self,
        request: &CanonicalRequest,
        terminal: &TerminalEnvelope,
    ) -> Result<(), ServiceError> {
        if terminal.schema_version != 1 || terminal.status != crate::TerminalStatus::Completed {
            return Err(ServiceError::InvalidStoredResult);
        }
        let CanonicalRequest::Settlement(request) = request else {
            return Err(ServiceError::InvalidStoredResult);
        };
        if request.registry.parse::<usd8_settlement::Address>().ok() != Some(self.policy.registry) {
            return Err(ServiceError::InvalidStoredResult);
        }
        match tokio::time::timeout(
            self.timeout,
            verify_result_for_promotion(
                &self.rpc,
                &self.policy,
                &request.incident_id,
                &terminal.payload,
            ),
        )
        .await
        {
            Ok(Ok(_)) => Ok(()),
            Ok(Err(VerificationError::Invalid(_))) => Err(ServiceError::InvalidStoredResult),
            _ => Err(ServiceError::Unavailable),
        }
    }
}
