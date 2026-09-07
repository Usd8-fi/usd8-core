use crate::Address;
use crate::artifact::verify_run;
use crate::chain::ChainError;
use crate::checkpoint::CheckpointError;
use crate::config::BootstrapConfig;
use crate::engine::{ScoreMode, SettlementRun, build_settlement, settlement_config_from_registry};
use crate::incident_open::build_incident_open;
use crate::rpc::{HttpRpc, RpcError};
use crate::tee::fresh_nitro_attestation;
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::str::FromStr;
use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error)]
#[error("attested runtime failed [{code}]: {detail}")]
pub struct AttestedRuntimeError {
    code: &'static str,
    detail: String,
}

impl AttestedRuntimeError {
    pub const fn code(&self) -> &'static str {
        self.code
    }
}

#[derive(Clone, Copy)]
enum SettlementStage {
    Config,
    Build,
}

#[derive(Clone, Copy)]
pub struct AttestedRuntimeOptions<'a> {
    pub proxy_url: Option<&'a str>,
    pub maximum_artifact_bytes: usize,
}

fn fail(error: impl ToString) -> AttestedRuntimeError {
    failure("ATTESTED_RUNTIME_FAILED", error)
}

fn failure(code: &'static str, error: impl ToString) -> AttestedRuntimeError {
    AttestedRuntimeError {
        code,
        detail: error.to_string(),
    }
}

fn state_is_pruned(error: &RpcError) -> bool {
    let RpcError::JsonRpc { message, .. } = error else {
        return false;
    };
    let message = message.to_ascii_lowercase();
    (message.contains("state at block #") && message.contains(" is pruned"))
        || message.contains("state unavailable: pruned")
}

fn score_failure_code(error: &CheckpointError) -> &'static str {
    match error {
        CheckpointError::Chain(ChainError::Rpc(rpc)) if state_is_pruned(rpc) => {
            "SETTLEMENT_SCORE_STATE_PRUNED"
        }
        CheckpointError::Chain(ChainError::Rpc(RpcError::HttpStatus { method, .. }))
            if method == "eth_getLogs" =>
        {
            "SETTLEMENT_SCORE_GET_LOGS_HTTP_FAILED"
        }
        CheckpointError::Chain(ChainError::Rpc(_)) => "SETTLEMENT_SCORE_RPC_FAILED",
        CheckpointError::Chain(_) => "SETTLEMENT_SCORE_CHAIN_FAILED",
        _ => "SETTLEMENT_SCORE_FAILED",
    }
}

fn chain_failure_code(stage: SettlementStage, error: &ChainError) -> &'static str {
    if let ChainError::Rpc(rpc) = error {
        return match (stage, state_is_pruned(rpc)) {
            (SettlementStage::Config, true) => "SETTLEMENT_CONFIG_STATE_PRUNED",
            (SettlementStage::Config, false) => "SETTLEMENT_CONFIG_RPC_FAILED",
            (SettlementStage::Build, true) => "SETTLEMENT_CHAIN_STATE_PRUNED",
            (SettlementStage::Build, false) => "SETTLEMENT_CHAIN_RPC_FAILED",
        };
    }
    match error {
        ChainError::WindowNotFinalized { .. } | ChainError::AnchorNotFinalized { .. } => {
            "SETTLEMENT_FINALITY_FAILED"
        }
        ChainError::AnchorChanged { .. } => "SETTLEMENT_ANCHOR_CHANGED",
        ChainError::InvalidOracle { .. } => "SETTLEMENT_ORACLE_FAILED",
        ChainError::InvalidConversion { .. } => "SETTLEMENT_CONVERSION_FAILED",
        ChainError::InvalidPoolTopology(_) | ChainError::PoolAssetMismatch { .. } => {
            "SETTLEMENT_POOL_TOPOLOGY_FAILED"
        }
        ChainError::EventDecode { .. }
        | ChainError::ReplayUnderflow { .. }
        | ChainError::BalanceReplayMismatch { .. }
        | ChainError::BatchLengthMismatch => "SETTLEMENT_REPLAY_FAILED",
        _ => match stage {
            SettlementStage::Config => "SETTLEMENT_CONFIG_CHAIN_FAILED",
            SettlementStage::Build => "SETTLEMENT_CHAIN_FAILED",
        },
    }
}

fn settlement_engine_failure(
    stage: SettlementStage,
    error: crate::engine::EngineError,
) -> AttestedRuntimeError {
    let code = match &error {
        crate::engine::EngineError::Chain(error) => chain_failure_code(stage, error),
        crate::engine::EngineError::Checkpoint(error) => score_failure_code(error),
        crate::engine::EngineError::Config(_) => "SETTLEMENT_CONFIG_FAILED",
        crate::engine::EngineError::Kernel(_) => "SETTLEMENT_ALLOCATION_FAILED",
        crate::engine::EngineError::TypedData(_) => "SETTLEMENT_DIGEST_FAILED",
        crate::engine::EngineError::Invariant(_) => "SETTLEMENT_INVARIANT_FAILED",
    };
    failure(code, error)
}

fn address(value: &str) -> Result<Address, AttestedRuntimeError> {
    Address::from_str(value).map_err(|_| fail("invalid address"))
}

fn rpc(
    rpc_url: &str,
    drpc_key: Option<&str>,
    proxy_url: Option<&str>,
) -> Result<HttpRpc, RpcError> {
    match proxy_url {
        Some(proxy) => HttpRpc::new_with_https_proxy(rpc_url, drpc_key, 30_000, proxy),
        None => HttpRpc::new(rpc_url, drpc_key, 30_000),
    }
}

fn attach_attestation(
    mut artifact: Value,
    digest: &str,
    expected_pcr_hash: &str,
) -> Result<Value, AttestedRuntimeError> {
    let bytes = hex::decode(
        digest
            .strip_prefix("0x")
            .ok_or_else(|| fail("invalid digest"))?,
    )
    .map_err(fail)?;
    if bytes.len() != 32 {
        return Err(fail("invalid digest"));
    }
    let attestation = fresh_nitro_attestation(&bytes).map_err(fail)?;
    if !attestation.pcr_hash.eq_ignore_ascii_case(expected_pcr_hash) {
        return Err(fail("PCR commitment mismatch"));
    }
    let object = artifact
        .as_object_mut()
        .ok_or_else(|| fail("artifact is not an object"))?;
    object.insert(
        "nitroAttestationDocument".into(),
        json!(format!("0x{}", hex::encode(attestation.document))),
    );
    object.insert("measuredTeePcrHash".into(), json!(attestation.pcr_hash));
    object.insert("nitroAttestedDigest".into(), json!(digest));
    Ok(artifact)
}

fn bounded_artifact(artifact: Value, maximum: usize) -> Result<Value, AttestedRuntimeError> {
    let size = serde_json::to_vec(&artifact).map_err(fail)?.len();
    if size == 0 || size > maximum {
        return Err(fail("artifact exceeds size limit"));
    }
    Ok(artifact)
}

pub fn artifact_for_attestation(run: &SettlementRun, config: &BootstrapConfig) -> Value {
    run.artifact(config, false)
}

fn settlement_artifact_available(is_unsettled: bool, root_matches: bool) -> bool {
    is_unsettled || root_matches
}

pub async fn settlement_artifact(
    rpc_url: &str,
    drpc_key: Option<&str>,
    registry: &str,
    incident_id: &str,
    score_mode: ScoreMode,
    options: AttestedRuntimeOptions<'_>,
) -> Result<Value, AttestedRuntimeError> {
    let rpc = Arc::new(
        rpc(rpc_url, drpc_key, options.proxy_url)
            .map_err(|error| failure("SETTLEMENT_RPC_INIT_FAILED", error))?,
    );
    let incident_id = BigUint::from_str(incident_id)
        .map_err(|_| failure("SETTLEMENT_INPUT_INVALID", "invalid incident ID"))?;
    let registry = Address::from_str(registry)
        .map_err(|_| failure("SETTLEMENT_INPUT_INVALID", "invalid Registry address"))?;
    let config = settlement_config_from_registry(rpc.as_ref(), registry, &incident_id)
        .await
        .map_err(|error| settlement_engine_failure(SettlementStage::Config, error))?;
    let run = build_settlement(rpc, &config, incident_id, score_mode)
        .await
        .map_err(|error| settlement_engine_failure(SettlementStage::Build, error))?;
    if !settlement_artifact_available(run.is_unsettled(), run.root_matches()) {
        return Err(failure(
            "SETTLEMENT_ROOT_MISMATCH",
            "incident standing root does not match the recomputed settlement root",
        ));
    }
    verify_run(&run, &config).map_err(|error| failure("SETTLEMENT_VERIFY_FAILED", error))?;
    let artifact = artifact_for_attestation(&run, &config);
    let artifact = attach_attestation(artifact, &run.digest, &run.tee_pcr_hash)
        .map_err(|error| failure("SETTLEMENT_ATTESTATION_FAILED", error))?;
    bounded_artifact(artifact, options.maximum_artifact_bytes)
        .map_err(|error| failure("SETTLEMENT_ARTIFACT_SIZE_FAILED", error))
}

pub async fn incident_open_artifact(
    rpc_url: &str,
    drpc_key: Option<&str>,
    registry: &str,
    insured_token: &str,
    expected_signer: &str,
    options: AttestedRuntimeOptions<'_>,
) -> Result<Value, AttestedRuntimeError> {
    let rpc = rpc(rpc_url, drpc_key, options.proxy_url).map_err(fail)?;
    let authorization = build_incident_open(
        &rpc,
        address(registry)?,
        address(insured_token)?,
        address(expected_signer)?,
    )
    .await
    .map_err(fail)?;
    let digest = authorization.digest().to_owned();
    let expected_pcr_hash = authorization.tee_pcr_hash.clone();
    let artifact = serde_json::to_value(authorization).map_err(fail)?;
    bounded_artifact(
        attach_attestation(artifact, &digest, &expected_pcr_hash)?,
        options.maximum_artifact_bytes,
    )
}

#[cfg(test)]
mod tests {
    use super::{SettlementStage, settlement_artifact_available, settlement_engine_failure};
    use crate::chain::ChainError;
    use crate::checkpoint::CheckpointError;
    use crate::engine::EngineError;
    use crate::rpc::RpcError;

    #[test]
    fn standing_root_replay_is_available_only_when_the_recomputed_root_matches() {
        assert!(settlement_artifact_available(true, false));
        assert!(settlement_artifact_available(false, true));
        assert!(!settlement_artifact_available(false, false));
    }

    #[test]
    fn settlement_score_state_pruning_has_a_precise_terminal_code() {
        let error =
            EngineError::Checkpoint(CheckpointError::Chain(ChainError::Rpc(RpcError::JsonRpc {
                code: -32603,
                message: "state at block #11538415 is pruned".to_owned(),
            })));

        assert_eq!(
            settlement_engine_failure(SettlementStage::Build, error).code(),
            "SETTLEMENT_SCORE_STATE_PRUNED"
        );
    }

    #[test]
    fn settlement_score_log_http_failure_has_a_precise_terminal_code() {
        let error = EngineError::Checkpoint(CheckpointError::Chain(ChainError::Rpc(
            RpcError::HttpStatus {
                method: "eth_getLogs".to_owned(),
                status: 400,
            },
        )));

        assert_eq!(
            settlement_engine_failure(SettlementStage::Build, error).code(),
            "SETTLEMENT_SCORE_GET_LOGS_HTTP_FAILED"
        );
    }

    #[test]
    fn settlement_invariant_has_a_precise_terminal_code() {
        let error = EngineError::Invariant("settlement phase expired".to_owned());

        assert_eq!(
            settlement_engine_failure(SettlementStage::Build, error).code(),
            "SETTLEMENT_INVARIANT_FAILED"
        );
    }

    #[test]
    fn settlement_config_state_pruning_has_a_precise_terminal_code() {
        let error = EngineError::Chain(ChainError::Rpc(RpcError::JsonRpc {
            code: -32603,
            message: "state unavailable: pruned".to_owned(),
        }));

        assert_eq!(
            settlement_engine_failure(SettlementStage::Config, error).code(),
            "SETTLEMENT_CONFIG_STATE_PRUNED"
        );
    }

    #[test]
    fn unrelated_pruned_text_stays_generic() {
        let error = EngineError::Chain(ChainError::Rpc(RpcError::JsonRpc {
            code: -32603,
            message: "state is not pruned".to_owned(),
        }));

        assert_eq!(
            settlement_engine_failure(SettlementStage::Config, error).code(),
            "SETTLEMENT_CONFIG_RPC_FAILED"
        );
    }
}
