use crate::Address;
use crate::artifact::verify_run;
use crate::engine::{ScoreMode, build_settlement, settlement_config_from_registry};
use crate::incident_open::build_incident_open;
use crate::rpc::HttpRpc;
use crate::tee::fresh_nitro_attestation;
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::str::FromStr;
use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error)]
#[error("attested runtime failed: {0}")]
pub struct AttestedRuntimeError(String);

#[derive(Clone, Copy)]
pub struct AttestedRuntimeOptions<'a> {
    pub proxy_url: Option<&'a str>,
    pub maximum_artifact_bytes: usize,
}

fn fail(error: impl ToString) -> AttestedRuntimeError {
    AttestedRuntimeError(error.to_string())
}

fn address(value: &str) -> Result<Address, AttestedRuntimeError> {
    Address::from_str(value).map_err(|_| fail("invalid address"))
}

fn rpc(
    rpc_url: &str,
    drpc_key: &str,
    proxy_url: Option<&str>,
) -> Result<HttpRpc, AttestedRuntimeError> {
    match proxy_url {
        Some(proxy) => HttpRpc::new_with_https_proxy(rpc_url, Some(drpc_key), 30_000, proxy),
        None => HttpRpc::new(rpc_url, Some(drpc_key), 30_000),
    }
    .map_err(fail)
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

pub async fn settlement_artifact(
    rpc_url: &str,
    drpc_key: &str,
    registry: &str,
    incident_id: &str,
    score_mode: ScoreMode,
    options: AttestedRuntimeOptions<'_>,
) -> Result<Value, AttestedRuntimeError> {
    let rpc = Arc::new(rpc(rpc_url, drpc_key, options.proxy_url)?);
    let incident_id = BigUint::from_str(incident_id).map_err(|_| fail("invalid incident ID"))?;
    let config = settlement_config_from_registry(rpc.as_ref(), address(registry)?, &incident_id)
        .await
        .map_err(fail)?;
    let run = build_settlement(rpc, &config, incident_id, score_mode)
        .await
        .map_err(fail)?;
    verify_run(&run, &config).map_err(fail)?;
    let artifact = run.artifact(&config, false);
    bounded_artifact(
        attach_attestation(artifact, &run.digest, &run.tee_pcr_hash)?,
        options.maximum_artifact_bytes,
    )
}

pub async fn incident_open_artifact(
    rpc_url: &str,
    drpc_key: &str,
    registry: &str,
    insured_token: &str,
    reference_block: &str,
    expected_signer: &str,
    options: AttestedRuntimeOptions<'_>,
) -> Result<Value, AttestedRuntimeError> {
    let rpc = rpc(rpc_url, drpc_key, options.proxy_url)?;
    let reference_block = reference_block
        .parse::<u64>()
        .map_err(|_| fail("invalid reference block"))?;
    let authorization = build_incident_open(
        &rpc,
        address(registry)?,
        address(insured_token)?,
        reference_block,
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
