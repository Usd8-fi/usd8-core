use std::fs;
use std::hint::black_box;
use std::io::{self, Read};
use std::time::Instant;
use usd8_settlement::{allocate, parse_json, serialize_output};

const USAGE: &str = "usage: usd8-kernel [fixture.json] [iterations] [warmup]";

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

fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args
        .first()
        .is_some_and(|arg| matches!(arg.as_str(), "--help" | "-h" | "help"))
    {
        println!("{USAGE}");
        return;
    }
    match run_kernel(&args) {
        Ok(code) => std::process::exit(code),
        Err(CliError::Usage(message)) => {
            eprintln!("ERROR: {message}\n{USAGE}");
            std::process::exit(2);
        }
        Err(CliError::Fatal(message)) => {
            eprintln!("FATAL: {message}");
            std::process::exit(1);
        }
    }
}
