use crate::config::BootstrapConfig;
use crate::engine::SettlementRun;
use crate::typed_data::{SettlementDigestInput, settlement_digest};
use crate::{MerkleRow, SettlementTree, claim_set_hash, settlement_input_hash};
use num_bigint::BigUint;
use num_traits::Zero;
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

#[derive(Debug, Error)]
pub enum ArtifactError {
    #[error("artifact invariant failed: {0}")]
    Invariant(String),
    #[error("artifact I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("artifact JSON failed: {0}")]
    Json(#[from] serde_json::Error),
    #[error("artifact computation failed: {0}")]
    Compute(String),
}

pub fn verify_run(run: &SettlementRun, config: &BootstrapConfig) -> Result<(), ArtifactError> {
    let config_hash = config
        .hash()
        .map_err(|error| ArtifactError::Compute(error.to_string()))?;
    if !config_hash.eq_ignore_ascii_case(&run.config_hash) {
        return Err(ArtifactError::Invariant(
            "config hash does not reproduce".to_owned(),
        ));
    }

    let replayed_claim_set =
        claim_set_hash(&run.events).map_err(|error| ArtifactError::Compute(error.to_string()))?;
    if !replayed_claim_set.eq_ignore_ascii_case(&run.output.claim_set_hash) {
        return Err(ArtifactError::Invariant(
            "claim-set hash does not reproduce".to_owned(),
        ));
    }

    let input_rows = run
        .output
        .rows
        .iter()
        .map(|row| (row.user, row.gross_earned_score.clone()))
        .collect::<Vec<_>>();
    let input_hash = settlement_input_hash(&input_rows)
        .map_err(|error| ArtifactError::Compute(error.to_string()))?;
    if !input_hash.eq_ignore_ascii_case(&run.output.settlement_input_hash) {
        return Err(ArtifactError::Invariant(
            "settlement input hash does not reproduce".to_owned(),
        ));
    }

    let merkle_rows = run
        .output
        .rows
        .iter()
        .map(|row| MerkleRow {
            claim_id: row.claim_id.clone(),
            user: row.user,
            amounts: row.amounts.clone(),
            score_spent: row.score_spent.clone(),
            boosted_score: row.boosted_score.clone(),
            eligible_amount: row.eligible_amount.clone(),
        })
        .collect::<Vec<_>>();
    if merkle_rows.is_empty() {
        if run.output.root != format!("0x{}", "0".repeat(64)) || !run.output.proofs.is_empty() {
            return Err(ArtifactError::Invariant(
                "empty settlement root/proofs are noncanonical".to_owned(),
            ));
        }
    } else {
        let tree = SettlementTree::new(&run.incident_id, &merkle_rows)
            .map_err(|error| ArtifactError::Compute(error.to_string()))?;
        if !tree.root_hex().eq_ignore_ascii_case(&run.output.root) {
            return Err(ArtifactError::Invariant(
                "Merkle root does not reproduce".to_owned(),
            ));
        }
        if tree.all_proofs_hex() != run.output.proofs {
            return Err(ArtifactError::Invariant(
                "Merkle proofs do not reproduce".to_owned(),
            ));
        }
    }

    if run.pool_addrs.len() != run.output.pool_payouts.len() {
        return Err(ArtifactError::Invariant(
            "pool address/payout arrays have different lengths".to_owned(),
        ));
    }
    let mut totals = vec![BigUint::zero(); run.pool_addrs.len()];
    for row in &run.output.rows {
        if row.amounts.len() != totals.len() {
            return Err(ArtifactError::Invariant(format!(
                "claim {} payout row length differs from pool count",
                row.claim_id
            )));
        }
        for (total, amount) in totals.iter_mut().zip(&row.amounts) {
            *total += amount;
        }
    }
    if totals != run.output.pool_payouts {
        return Err(ArtifactError::Invariant(
            "pool payout totals do not equal row sums".to_owned(),
        ));
    }

    let digest = settlement_digest(&SettlementDigestInput {
        chain_id: config.chain_id,
        verifying_contract: config.defi_insurance,
        incident_id: run.incident_id.clone(),
        root: run.output.root.clone(),
        unresolved: run.window_incident.unresolved.clone(),
        pool_payouts: run.output.pool_payouts.clone(),
        pool_addrs: run.pool_addrs.clone(),
        claim_set: run.output.claim_set_hash.clone(),
        tee_pcr_hash: run.tee_pcr_hash.clone(),
    })
    .map_err(|error| ArtifactError::Compute(error.to_string()))?;
    if !digest.eq_ignore_ascii_case(&run.digest) {
        return Err(ArtifactError::Invariant(
            "settlement digest does not reproduce".to_owned(),
        ));
    }
    Ok(())
}

fn temp_path(path: &Path) -> Result<PathBuf, ArtifactError> {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| ArtifactError::Invariant("output path has no file name".to_owned()))?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| ArtifactError::Invariant("system clock is before epoch".to_owned()))?
        .as_nanos();
    Ok(path.with_file_name(format!(".{file_name}.{}.{}.tmp", std::process::id(), nonce)))
}

pub fn write_atomic_json(path: &Path, value: &Value) -> Result<(), ArtifactError> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    if !parent.is_dir() {
        return Err(ArtifactError::Invariant(format!(
            "output directory does not exist: {}",
            parent.display()
        )));
    }
    let mut bytes = serde_json::to_vec_pretty(value)?;
    bytes.push(b'\n');
    let temporary = temp_path(path)?;
    let result = (|| -> Result<(), ArtifactError> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o644);
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        OpenOptions::new().read(true).open(parent)?.sync_all()?;
        let persisted = fs::read(path)?;
        if persisted != bytes {
            return Err(ArtifactError::Invariant(
                "atomic artifact read-back differs from serialized bytes".to_owned(),
            ));
        }
        let parsed: Value = serde_json::from_slice(&persisted)?;
        if parsed != *value {
            return Err(ArtifactError::Invariant(
                "atomic artifact JSON read-back differs from source value".to_owned(),
            ));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
