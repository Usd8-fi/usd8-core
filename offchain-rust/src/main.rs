use num_bigint::BigUint;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::hint::black_box;
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::time::Instant;
use usd8_settlement::Address;
use usd8_settlement::artifact::{verify_run, write_atomic_json};
use usd8_settlement::engine::{ScoreMode, build_settlement, settlement_config_from_registry};
use usd8_settlement::rpc::HttpRpc;
use usd8_settlement::{allocate, parse_json, serialize_output};

const USAGE: &str = "usage:\n  usd8-settlement compute <incidentId> --registry <address> --rpc-url <url> [--checkpoint <file>] [--output <file>]\n  usd8-settlement attested-compute <incidentId> --registry <address> --rpc-url <url> [--checkpoint <file>] [--output <file>]\n  usd8-settlement verify  <incidentId> --registry <address> --rpc-url <url> [--checkpoint <file>] [--output <file>]\n  usd8-settlement ffi <root|proof|digest|claimset> <abiHexPayload> [claimId]\n  usd8-settlement kernel [fixture.json] [iterations] [warmup]\n\nEnvironment fallbacks: USD8_REGISTRY, ETH_RPC_URL, DRPC_KEY, SCORE_CHECKPOINT_PATH, SCORE_CHECKPOINT_KEY.";

#[derive(Debug)]
enum CliError {
    Usage(String),
    Fatal(String),
}

fn usage(error: impl Into<String>) -> CliError {
    CliError::Usage(error.into())
}

fn fatal(error: impl Into<String>) -> CliError {
    CliError::Fatal(error.into())
}

fn parse_count(value: Option<&String>, default: usize, label: &str) -> Result<usize, String> {
    let parsed = match value {
        Some(value) => value
            .parse::<usize>()
            .map_err(|_| format!("invalid {label}: {value}"))?,
        None => default,
    };
    if parsed == 0 && label == "iterations" {
        return Err("iterations must be greater than zero".to_owned());
    }
    Ok(parsed)
}

fn read_input(path: Option<&String>) -> Result<String, String> {
    match path {
        Some(path) => {
            fs::read_to_string(path).map_err(|error| format!("failed to read input: {error}"))
        }
        None => {
            let mut input = String::new();
            io::stdin()
                .read_to_string(&mut input)
                .map_err(|error| format!("failed to read stdin: {error}"))?;
            Ok(input)
        }
    }
}

fn run_kernel(args: &[String]) -> Result<i32, CliError> {
    if args.len() > 3 {
        return Err(usage("too many kernel arguments"));
    }
    let iterations = parse_count(args.get(1), 1, "iterations").map_err(usage)?;
    let warmup = parse_count(args.get(2), 0, "warmup").map_err(usage)?;
    let input = read_input(args.first()).map_err(fatal)?;
    let parsed = parse_json(&input).map_err(|error| fatal(error.to_string()))?;
    for _ in 0..warmup {
        black_box(allocate(&parsed).map_err(|error| fatal(error.to_string()))?);
    }
    let started = Instant::now();
    let mut output = None;
    for _ in 0..iterations {
        output = Some(black_box(
            allocate(&parsed).map_err(|error| fatal(error.to_string()))?,
        ));
    }
    let elapsed_ns = started.elapsed().as_nanos();
    let output = output.ok_or_else(|| fatal("kernel produced no output"))?;
    let output = serialize_output(output).map_err(|error| fatal(error.to_string()))?;
    println!("{output}");
    eprintln!(
        "{}",
        serde_json::json!({
            "engine": "rust",
            "iterations": iterations,
            "elapsedNs": elapsed_ns.to_string(),
            "averageNs": (elapsed_ns / iterations as u128).to_string(),
        })
    );
    Ok(0)
}

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
}

fn set_once<T>(slot: &mut Option<T>, value: T, name: &str) -> Result<(), String> {
    if slot.replace(value).is_some() {
        return Err(format!("duplicate option: {name}"));
    }
    Ok(())
}

fn option_value(args: &[String], index: &mut usize, name: &str) -> Result<String, String> {
    *index += 1;
    args.get(*index)
        .cloned()
        .ok_or_else(|| format!("{name} requires a value"))
}

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
            value => return Err(format!("unknown option: {value}")),
        }
        index += 1;
    }
    if parsed.raw_score && parsed.checkpoint.is_some() {
        return Err("--raw-score and --checkpoint are mutually exclusive".to_owned());
    }
    Ok(parsed)
}

fn environment_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

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

fn lock_path(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".lock");
    PathBuf::from(value)
}

fn aliases(left: &[PathBuf], right: &[PathBuf]) -> bool {
    left.iter().any(|left| right.contains(left))
}

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

fn required_environment(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("missing required environment variable: {name}"))
}

fn verification_exit_code(root_matches: bool) -> i32 {
    if root_matches { 0 } else { 1 }
}

async fn run_production(mode: &str, args: &[String]) -> Result<i32, CliError> {
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
    let checkpoint_path = if options.raw_score {
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
    if mode == "attested-compute" && drpc_key.is_none() {
        return Err(fatal(
            "attested-compute requires DRPC_KEY for the approved dRPC endpoint",
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
    let score_mode = if let Some(path) = checkpoint_path {
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
    let mut artifact = run.artifact(&config, mode != "verify");
    if mode == "attested-compute" {
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
    }
    if let Some(path) = output_path {
        write_atomic_json(&path, &artifact).map_err(|error| fatal(error.to_string()))?;
        eprintln!("wrote verified artifact: {}", path.display());
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(&artifact).map_err(|error| fatal(error.to_string()))?
        );
    }
    if mode == "verify" {
        eprintln!("computed root: {}", run.output.root);
        eprintln!("on-chain root: {}", run.latest_incident.root);
        if !run.root_matches() {
            eprintln!("MISMATCH — submitted root does not reproduce from finalized chain history.");
            return Ok(verification_exit_code(false));
        }
        eprintln!("MATCH — submitted root reproduces exactly from finalized chain history.");
        return Ok(verification_exit_code(true));
    }
    Ok(0)
}

async fn run() -> Result<i32, CliError> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    match args.first().map(String::as_str) {
        Some("compute") | Some("attested-compute") | Some("verify") => {
            let mode = args.remove(0);
            run_production(&mode, &args).await
        }
        Some("ffi") => {
            args.remove(0);
            let command = args.first().ok_or_else(|| usage("missing FFI command"))?;
            let expected = match command.as_str() {
                "root" | "digest" | "claimset" => 2,
                "proof" => 3,
                value => return Err(usage(format!("unknown FFI command: {value}"))),
            };
            if args.len() != expected {
                return Err(usage(format!(
                    "FFI {command} expects {} argument(s) after the command",
                    expected - 1
                )));
            }
            let payload = &args[1];
            let output =
                usd8_settlement::ffi::run(command, payload, args.get(2).map(String::as_str))
                    .map_err(|error| fatal(error.to_string()))?;
            print!("{output}");
            Ok(0)
        }
        Some("kernel") => {
            args.remove(0);
            run_kernel(&args)
        }
        Some("--help" | "-h" | "help") => {
            println!("{USAGE}");
            Ok(0)
        }
        Some(_) => run_kernel(&args),
        None => run_kernel(&args),
    }
}

#[tokio::main(flavor = "multi_thread")]
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
    use super::{validate_production_paths, verification_exit_code};
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static NEXT_PATH: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn verification_exit_codes_are_stable() {
        assert_eq!(verification_exit_code(true), 0);
        assert_eq!(verification_exit_code(false), 1);
    }

    #[test]
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
