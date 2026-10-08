/*
This is the CLI entry point for the USD8 Settlement Engine.
It provides commands for computing, verifying, and attesting settlement artifacts,
as well as interacting with the underlying FFI and kernel components.

There are 2 main entrypoints of using USD8 Settlement Engine:

1. via this CLI command, anyone can run it locally and verify the results.
2. front end use the engine via a cloud function to
    1. compute users' insurance scores
    2. initialize and managing settlement, including spin off a TEE to compute the settlement results

*/

use num_bigint::BigUint;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use usd8_settlement::Address;
use usd8_settlement::artifact::{verify_run, write_atomic_json};
use usd8_settlement::config::BootstrapConfig;
use usd8_settlement::engine::{
    ScoreMode, SettlementRun, build_settlement, settlement_config_from_registry,
};
use usd8_settlement::incident_open::precheck_incident_open;
use usd8_settlement::rpc::HttpRpc;

const USAGE: &str = "usage:\n  usd8-settlement compute_settlement <incidentId> --registry <address> --rpc-url <url> [--raw-score|--bulk-score|--checkpoint <file>] [--output <file>]\n  usd8-settlement compute_settlement_tee <incidentId> --registry <address> --rpc-url <url> [--raw-score|--bulk-score|--checkpoint <file>] [--output <file>]\n  usd8-settlement detect_price_drop <insuredToken> --registry <address> --rpc-url <url> [--no-drpc-key|--drpc-key-env <name>] [--timeout-ms <ms>] [--output <file>]\n  usd8-settlement compute_insurance_score <userAddress> --registry <address> --rpc-url <url> [--no-drpc-key|--drpc-key-env <name>] [--timeout-ms <ms>] [--output <file>]\n  usd8-settlement pcr-hash <PCR0> <PCR1> <PCR2>\n\nEnvironment fallbacks: USD8_REGISTRY, ETH_RPC_URL, DRPC_KEY, SCORE_CHECKPOINT_PATH, SCORE_CHECKPOINT_KEY.";

#[derive(Debug)]
enum CliError {
    Usage(String),
    Fatal(String),
}

/// Classify invalid command-line input as a usage error.
fn usage(error: impl Into<String>) -> CliError {
    CliError::Usage(error.into())
}

/// Classify runtime failures without changing their diagnostic text.
fn fatal(error: impl Into<String>) -> CliError {
    CliError::Fatal(error.into())
}

/// Parse a canonical decimal incident ID within the uint256 range.
fn parse_incident(value: &str) -> Result<BigUint, String> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || value.len() > 78
    {
        return Err(format!("invalid incidentId: {value}"));
    }
    let parsed = BigUint::from_str(value).map_err(|_| format!("invalid incidentId: {value}"))?;
    if parsed.to_bytes_be().len() > 32 {
        return Err("incidentId exceeds uint256".to_owned());
    }
    Ok(parsed)
}

#[derive(Default)]
struct ProductionArgs {
    registry: Option<String>,
    rpc_url: Option<String>,
    checkpoint: Option<PathBuf>,
    output: Option<PathBuf>,
    timeout_ms: Option<u64>,
    drpc_key_env: Option<String>,
    checkpoint_key_env: Option<String>,
    no_drpc_key: bool,
    raw_score: bool,
    bulk_score: bool,
}

/// Reject repeated value-bearing options while recording their values.
fn set_once<T>(slot: &mut Option<T>, value: T, name: &str) -> Result<(), String> {
    if slot.replace(value).is_some() {
        return Err(format!("duplicate option: {name}"));
    }
    Ok(())
}

/// Consume the required value following a command-line option.
fn option_value(args: &[String], index: &mut usize, name: &str) -> Result<String, String> {
    *index += 1;
    args.get(*index)
        .cloned()
        .ok_or_else(|| format!("{name} requires a value"))
}

/// Parse shared options and enforce mutually exclusive score modes.
fn parse_production_args(args: &[String]) -> Result<ProductionArgs, String> {
    let mut parsed = ProductionArgs::default();
    let mut index = 0usize;
    while index < args.len() {
        match args[index].as_str() {
            "--registry" => {
                let value = option_value(args, &mut index, "--registry")?;
                set_once(&mut parsed.registry, value, "--registry")?;
            }
            "--rpc-url" => {
                let value = option_value(args, &mut index, "--rpc-url")?;
                set_once(&mut parsed.rpc_url, value, "--rpc-url")?;
            }
            "--checkpoint" => {
                let value = PathBuf::from(option_value(args, &mut index, "--checkpoint")?);
                set_once(&mut parsed.checkpoint, value, "--checkpoint")?;
            }
            "--output" => {
                let value = PathBuf::from(option_value(args, &mut index, "--output")?);
                set_once(&mut parsed.output, value, "--output")?;
            }
            "--timeout-ms" => {
                let text = option_value(args, &mut index, "--timeout-ms")?;
                let value = text
                    .parse::<u64>()
                    .map_err(|_| format!("invalid --timeout-ms: {text}"))?;
                set_once(&mut parsed.timeout_ms, value, "--timeout-ms")?;
            }
            "--drpc-key-env" => {
                let value = option_value(args, &mut index, "--drpc-key-env")?;
                set_once(&mut parsed.drpc_key_env, value, "--drpc-key-env")?;
            }
            "--checkpoint-key-env" => {
                let value = option_value(args, &mut index, "--checkpoint-key-env")?;
                set_once(
                    &mut parsed.checkpoint_key_env,
                    value,
                    "--checkpoint-key-env",
                )?;
            }
            "--no-drpc-key" => parsed.no_drpc_key = true,
            "--raw-score" => parsed.raw_score = true,
            "--bulk-score" => parsed.bulk_score = true,
            value => return Err(format!("unknown option: {value}")),
        }
        index += 1;
    }
    let explicit_modes = usize::from(parsed.raw_score)
        + usize::from(parsed.bulk_score)
        + usize::from(parsed.checkpoint.is_some());
    if explicit_modes > 1 {
        return Err(
            "--raw-score, --bulk-score, and --checkpoint are mutually exclusive".to_owned(),
        );
    }
    Ok(parsed)
}

/// Read a nonempty environment path without requiring Unicode.
fn environment_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// Normalize an absolute path and reject traversal beyond its root.
fn lexical_absolute(path: &Path) -> Result<PathBuf, String> {
    let absolute = if path.is_absolute() {
        path.to_owned()
    } else {
        env::current_dir()
            .map_err(|error| format!("failed to resolve current directory: {error}"))?
            .join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => {
                normalized.push(component.as_os_str());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return Err(format!("path escapes filesystem root: {}", path.display()));
                }
            }
        }
    }
    Ok(normalized)
}

/// Resolve existing path ancestors while preserving missing suffixes.
fn resolve_allow_missing(path: &Path) -> Result<PathBuf, String> {
    let mut ancestor = lexical_absolute(path)?;
    let mut suffix = Vec::<OsString>::new();
    loop {
        match fs::canonicalize(&ancestor) {
            Ok(mut resolved) => {
                for component in suffix.into_iter().rev() {
                    resolved.push(component);
                }
                return Ok(resolved);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let component = ancestor
                    .file_name()
                    .ok_or_else(|| format!("cannot resolve path identity: {}", path.display()))?;
                suffix.push(component.to_os_string());
                if !ancestor.pop() {
                    return Err(format!("cannot resolve path identity: {}", path.display()));
                }
            }
            Err(error) => {
                return Err(format!(
                    "failed to resolve path identity {}: {error}",
                    path.display()
                ));
            }
        }
    }
}

/// Resolve a destination parent without following its final filename.
fn write_path_identity(path: &Path) -> Result<PathBuf, String> {
    let absolute = lexical_absolute(path)?;
    let file_name = absolute
        .file_name()
        .ok_or_else(|| format!("path has no file name: {}", path.display()))?
        .to_os_string();
    let parent = absolute
        .parent()
        .ok_or_else(|| format!("path has no parent: {}", path.display()))?;
    Ok(resolve_allow_missing(parent)?.join(file_name))
}

/// Collect write and existing-target identities for alias checks.
fn path_identities(path: &Path) -> Result<Vec<PathBuf>, String> {
    let mut identities = vec![write_path_identity(path)?];
    match fs::canonicalize(path) {
        Ok(canonical) if !identities.contains(&canonical) => identities.push(canonical),
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "failed to resolve existing path {}: {error}",
                path.display()
            ));
        }
    }
    Ok(identities)
}

/// Derive the checkpoint lock filename without lossy path conversion.
fn lock_path(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".lock");
    PathBuf::from(value)
}

/// Check whether two sets of resolved path identities overlap.
fn aliases(left: &[PathBuf], right: &[PathBuf]) -> bool {
    left.iter().any(|left| right.contains(left))
}

/// Reject output aliases of the checkpoint or its lock before RPC work.
fn validate_production_paths(
    checkpoint: Option<&Path>,
    output: Option<&Path>,
) -> Result<(), String> {
    let checkpoint_ids = checkpoint.map(path_identities).transpose()?;
    let lock_ids = checkpoint
        .map(lock_path)
        .as_deref()
        .map(path_identities)
        .transpose()?;
    let output_ids = output.map(path_identities).transpose()?;

    if output_ids.as_deref().is_some_and(|output_ids| {
        checkpoint_ids
            .as_deref()
            .is_some_and(|checkpoint_ids| aliases(output_ids, checkpoint_ids))
    }) {
        return Err("output path collides with checkpoint path".to_owned());
    }
    if output_ids.as_deref().is_some_and(|output_ids| {
        lock_ids
            .as_deref()
            .is_some_and(|lock_ids| aliases(output_ids, lock_ids))
    }) {
        return Err("output path collides with checkpoint lock path".to_owned());
    }
    Ok(())
}

/// Require a nonempty Unicode environment value for protected state.
fn required_environment(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing required environment variable: {name}"))
}

/// Validate three 48-byte PCR values and print their shared commitment.
fn run_pcr_hash(args: &[String]) -> Result<i32, CliError> {
    if args.len() != 3 {
        return Err(usage("pcr-hash requires PCR0 PCR1 PCR2"));
    }
    let mut pcrs = Vec::with_capacity(3);
    for value in args {
        let value = value.strip_prefix("0x").unwrap_or(value);
        let bytes = hex::decode(value).map_err(|_| usage("invalid PCR hex"))?;
        if bytes.len() != usd8_settlement::tee::PCR_BYTE_LENGTH {
            return Err(usage("each PCR must be 48 bytes"));
        }
        pcrs.push(bytes);
    }
    println!(
        "{}",
        usd8_settlement::tee::pcr0_2_hash(&pcrs[0], &pcrs[1], &pcrs[2]) //pcr0_2_hash this is a keccak256 hash fn
            .map_err(|error| fatal(error.to_string()))?
    );
    Ok(0)
}

//runs a local query to detect price drop or compute score, without touching TEE or checkpointing
/// Validate read-only query options and construct the credential-safe RPC client.
fn prepare_local_query(
    args: &[String],
    label: &str,
    command: &str,
) -> Result<(HttpRpc, Address, Address, Option<PathBuf>), CliError> {
    let address_text = args
        .first()
        .ok_or_else(|| usage(format!("missing {label}")))?;
    let address = Address::from_str(address_text)
        .map_err(|_| usage(format!("invalid {label}: {address_text}")))?;
    if address.is_zero() {
        return Err(usage(format!("{label} is zero")));
    }
    let options = parse_production_args(&args[1..]).map_err(usage)?;
    if options.checkpoint.is_some()
        || options.checkpoint_key_env.is_some()
        || options.raw_score
        || options.bulk_score
    {
        return Err(usage(format!(
            "checkpoint and score options are invalid for {command}"
        )));
    }
    validate_production_paths(None, options.output.as_deref()).map_err(usage)?;
    let registry_text = options
        .registry
        .or_else(|| {
            env::var("USD8_REGISTRY")
                .ok()
                .filter(|value| !value.is_empty())
        })
        .ok_or_else(|| usage("missing --registry or USD8_REGISTRY"))?;
    let registry = Address::from_str(&registry_text)
        .map_err(|_| usage(format!("invalid Registry address: {registry_text}")))?;
    if registry.is_zero() {
        return Err(usage("Registry address is zero"));
    }
    let rpc_url = options
        .rpc_url
        .or_else(|| {
            env::var("ETH_RPC_URL")
                .ok()
                .filter(|value| !value.is_empty())
        })
        .ok_or_else(|| usage("missing --rpc-url or ETH_RPC_URL"))?;
    let drpc_key_name = options
        .drpc_key_env
        .unwrap_or_else(|| "DRPC_KEY".to_owned());
    let drpc_key = if options.no_drpc_key {
        None
    } else {
        env::var(&drpc_key_name)
            .ok()
            .filter(|value| !value.is_empty())
    };
    let rpc = HttpRpc::new(
        &rpc_url,
        drpc_key.as_deref(),
        options.timeout_ms.unwrap_or(30_000),
    )
    .map_err(|error| fatal(error.to_string()))?;
    Ok((rpc, registry, address, options.output))
}

/// Replay the finalized insurance score and publish its existing JSON schema.
async fn compute_insurance_score(args: &[String]) -> Result<i32, CliError> {
    let (rpc, registry, user, output) =
        prepare_local_query(args, "userAddress", "compute_insurance_score")?;
    let snapshot = usd8_settlement::score::insurance_score_at(&rpc, registry, user)
        .await
        .map_err(|error| fatal(error.to_string()))?;
    let artifact = serde_json::to_value(snapshot).map_err(|error| fatal(error.to_string()))?;
    output_json(&artifact, output.as_deref())?;
    Ok(0)
}

/// Publish the shared read-only price-drop precheck without opening or attesting.
async fn detect_price_drop(args: &[String]) -> Result<i32, CliError> {
    let (rpc, registry, insured_token, output) =
        prepare_local_query(args, "insuredToken", "detect_price_drop")?;
    // Historical CLI notes retained verbatim; detection below does not open or attest.
    //verify and open an incident.
    //build a nitro TEE with attestation.
    let precheck = precheck_incident_open(&rpc, registry, insured_token)
        .await
        .map_err(|error| fatal(error.to_string()))?;
    let artifact = serde_json::to_value(precheck).map_err(|error| fatal(error.to_string()))?;
    output_json(&artifact, output.as_deref())?;
    Ok(0)
}

/// Write JSON atomically to a file or pretty-print it to stdout.
fn output_json(artifact: &serde_json::Value, output: Option<&Path>) -> Result<(), CliError> {
    if let Some(path) = output {
        write_atomic_json(path, artifact).map_err(|error| fatal(error.to_string()))?;
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(artifact).map_err(|error| fatal(error.to_string()))?
        );
    }
    Ok(())
}

// This function handles the main production modes: compute, attested-compute
// compute_local -  reads on-chain inputs and computes the settlement result. Used for local computes not via TEE.
// compute_tee — performs the same computation, then asks the existing Nitro Security Module for an attestation
//                    binding the result’s digest. It checks the enclave measurements against the incident’s stored PCR hash.
//                    This is the cononical way to compute settlement results in a TEE.
/// Validate paths and credentials, build settlement, and verify it before output.
async fn prepare_settlement(
    args: &[String],
    require_drpc_key: bool,
) -> Result<(SettlementRun, BootstrapConfig, Option<PathBuf>), CliError> {
    let incident_text = args.first().ok_or_else(|| usage("missing incidentId"))?;
    let incident_id = parse_incident(incident_text).map_err(usage)?;
    let options = parse_production_args(&args[1..]).map_err(usage)?;
    let registry_text = options
        .registry
        .or_else(|| {
            env::var("USD8_REGISTRY")
                .ok()
                .filter(|value| !value.is_empty())
        })
        .ok_or_else(|| usage("missing --registry or USD8_REGISTRY"))?;
    let registry = Address::from_str(&registry_text)
        .map_err(|_| usage(format!("invalid Registry address: {registry_text}")))?;
    if registry.is_zero() {
        return Err(usage("Registry address is zero"));
    }
    let output_path = options.output.clone();
    let checkpoint_path = if options.raw_score || options.bulk_score {
        None
    } else {
        options
            .checkpoint
            .clone()
            .or_else(|| environment_path("SCORE_CHECKPOINT_PATH"))
    };
    validate_production_paths(checkpoint_path.as_deref(), output_path.as_deref()).map_err(usage)?;
    let rpc_url = options
        .rpc_url
        .or_else(|| {
            env::var("ETH_RPC_URL")
                .ok()
                .filter(|value| !value.is_empty())
        })
        .ok_or_else(|| usage("missing --rpc-url or ETH_RPC_URL"))?;
    let drpc_key_name = options
        .drpc_key_env
        .unwrap_or_else(|| "DRPC_KEY".to_owned());
    let drpc_key = if options.no_drpc_key {
        None
    } else {
        env::var(&drpc_key_name)
            .ok()
            .filter(|value| !value.is_empty())
    };
    if require_drpc_key && drpc_key.is_none() {
        return Err(fatal(
            "compute_settlement_tee requires DRPC_KEY for the approved dRPC endpoint",
        ));
    }
    let rpc = Arc::new(
        HttpRpc::new(
            &rpc_url,
            drpc_key.as_deref(),
            options.timeout_ms.unwrap_or(30_000),
        )
        .map_err(|error| fatal(error.to_string()))?,
    );
    let score_mode = if options.bulk_score {
        ScoreMode::Bulk
    } else if let Some(path) = checkpoint_path {
        let key_name = options
            .checkpoint_key_env
            .unwrap_or_else(|| "SCORE_CHECKPOINT_KEY".to_owned());
        let integrity_key = required_environment(&key_name).map_err(fatal)?.into_bytes();
        if integrity_key.len() < 32 {
            return Err(fatal(format!("{key_name} must contain at least 32 bytes")));
        }
        ScoreMode::Checkpoint {
            path,
            integrity_key,
        }
    } else {
        ScoreMode::Raw
    };
    let config = settlement_config_from_registry(rpc.as_ref(), registry, &incident_id)
        .await
        .map_err(|error| fatal(error.to_string()))?;
    let run = build_settlement(rpc, &config, incident_id, score_mode)
        .await
        .map_err(|error| fatal(error.to_string()))?;
    verify_run(&run, &config).map_err(|error| fatal(error.to_string()))?;
    Ok((run, config, output_path))
}

/// Publish a verified settlement with per-claim proofs and no attestation.
async fn compute_settlement(args: &[String]) -> Result<i32, CliError> {
    let (run, config, output_path) = prepare_settlement(args, false).await?;
    let artifact = run.artifact(&config, true);
    output_settlement(&artifact, output_path.as_deref())?;
    Ok(0)
}

/// Bind a verified settlement to fresh Nitro evidence and matching incident PCRs.
async fn compute_settlement_tee(args: &[String]) -> Result<i32, CliError> {
    let (run, config, output_path) = prepare_settlement(args, true).await?;
    let mut artifact = run.artifact(&config, false);
    let digest_bytes = hex::decode(
        run.digest
            .strip_prefix("0x")
            .ok_or_else(|| fatal("settlement digest is missing 0x prefix"))?,
    )
    .map_err(|error| fatal(format!("invalid settlement digest: {error}")))?;
    if digest_bytes.len() != 32 {
        return Err(fatal(format!(
            "settlement digest must be 32 bytes, got {}",
            digest_bytes.len()
        )));
    }
    let attestation = usd8_settlement::tee::fresh_nitro_attestation(&digest_bytes)
        .map_err(|error| fatal(error.to_string()))?;
    if !attestation.pcr_hash.eq_ignore_ascii_case(&run.tee_pcr_hash) {
        return Err(fatal(format!(
            "local Nitro PCR hash {} does not match incident snapshot {}",
            attestation.pcr_hash, run.tee_pcr_hash
        )));
    }
    let object = artifact
        .as_object_mut()
        .ok_or_else(|| fatal("settlement artifact is not a JSON object"))?;
    object.insert(
        "nitroAttestationDocument".to_owned(),
        serde_json::json!(format!("0x{}", hex::encode(attestation.document))),
    );
    object.insert(
        "measuredTeePcrHash".to_owned(),
        serde_json::json!(attestation.pcr_hash),
    );
    object.insert(
        "nitroAttestedDigest".to_owned(),
        serde_json::json!(run.digest),
    );
    output_settlement(&artifact, output_path.as_deref())?;
    Ok(0)
}

/// Publish settlement JSON and report a successfully written artifact path.
fn output_settlement(artifact: &serde_json::Value, output: Option<&Path>) -> Result<(), CliError> {
    output_json(artifact, output)?;
    if let Some(path) = output {
        eprintln!("wrote verified artifact: {}", path.display());
    }
    Ok(())
}

/// Dispatch supported public commands and reject unknown or missing commands.
async fn run() -> Result<i32, CliError> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    match args.first().map(String::as_str) {
        Some("pcr-hash") => {
            // hash given 3 PCR values to produce a root hash for attestation verification
            args.remove(0);
            run_pcr_hash(&args)
        }
        Some("detect_price_drop") => {
            args.remove(0);
            detect_price_drop(&args).await
        }
        Some("compute_insurance_score") => {
            args.remove(0);
            compute_insurance_score(&args).await
        }
        Some("compute_settlement") => {
            //compute settlement results either locally or via TEE
            args.remove(0);
            compute_settlement(&args).await
        }
        Some("compute_settlement_tee") => {
            args.remove(0);
            compute_settlement_tee(&args).await
        }
        Some("--help" | "-h" | "help") => {
            println!("{USAGE}");
            Ok(0)
        }
        Some(
            command @ ("compute" | "attested-compute" | "verify" | "ffi" | "attested-open"
            | "compute_score" | "compute_local" | "compute_tee"),
        ) => Err(usage(format!("unknown command: {command}"))),
        Some(command) => Err(usage(format!("unknown command: {command}"))),
        None => Err(usage("missing command")),
    }
}

#[tokio::main(flavor = "multi_thread")]
/// Run the CLI and map usage versus runtime failures to stable exit codes.
async fn main() {
    match run().await {
        Ok(0) => {}
        Ok(code) => std::process::exit(code),
        Err(error) => match error {
            CliError::Usage(message) => {
                eprintln!("ERROR: {message}");
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
            CliError::Fatal(message) => {
                eprintln!("FATAL: {message}");
                std::process::exit(1);
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::validate_production_paths;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static NEXT_PATH: AtomicUsize = AtomicUsize::new(0);

    #[test]
    /// Check that checkpoint and lock aliases cannot be used as output paths.
    fn production_state_paths_must_not_collide() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "usd8-production-paths-{}-{nonce}-{}",
            std::process::id(),
            NEXT_PATH.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(directory.join("sub")).unwrap();
        let checkpoint = directory.join("score.json");

        assert!(validate_production_paths(Some(&checkpoint), Some(&checkpoint)).is_err());
        assert!(
            validate_production_paths(Some(&checkpoint), Some(&directory.join("score.json.lock")),)
                .is_err()
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
