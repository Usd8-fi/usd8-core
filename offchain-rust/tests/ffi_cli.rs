#![cfg(feature = "ffi-tools")]

use alloy_primitives::{Address, U256};
use alloy_sol_types::SolValue;
use std::process::{Command, Output};

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_usd8-ffi"))
        .args(args)
        .output()
        .unwrap()
}

fn tree_payload() -> String {
    format!(
        "0x{}",
        hex::encode(
            (
                U256::from(7),
                vec![U256::from(1), U256::from(2)],
                vec![Address::from([0x11; 20]), Address::from([0x22; 20])],
                vec![vec![U256::from(90)], vec![U256::from(60)]],
                vec![U256::from(60), U256::from(40)],
                vec![U256::from(61), U256::from(40)],
                vec![U256::from(100), U256::from(100)],
                vec![U256::ZERO, U256::ZERO],
            )
                .abi_encode_params()
        )
    )
}

fn assert_output(command: &str, payload: &str, argument: Option<&str>) {
    let expected = usd8_settlement::ffi::run(command, payload, argument).unwrap();
    let mut args = vec![command, payload];
    if let Some(argument) = argument {
        args.push(argument);
    }
    let result = run(&args);
    assert_eq!(result.status.code(), Some(0), "{:?}", result);
    assert!(result.stderr.is_empty());
    assert_eq!(result.stdout, expected.as_bytes());
}

#[test]
fn root_outputs_exact_abi_without_wrapper_or_newline() {
    assert_output("root", &tree_payload(), None);
}

#[test]
fn proof_outputs_exact_abi() {
    assert_output("proof", &tree_payload(), Some("1"));
}

#[test]
fn digest_outputs_exact_abi() {
    let payload = format!(
        "0x{}",
        hex::encode(
            (
                U256::from(1),
                Address::from([0x11; 20]),
                U256::from(7),
                alloy_primitives::B256::from([0x22; 32]),
                U256::from(2),
                vec![U256::from(150)],
                vec![Address::from([0x33; 20])],
                alloy_primitives::B256::from([0x44; 32]),
                alloy_primitives::B256::from([0x55; 32]),
            )
                .abi_encode_params()
        )
    );
    assert_output("digest", &payload, None);
}

#[test]
fn claimset_outputs_exact_abi() {
    use alloy_sol_types::{SolType, sol};
    type Payload = sol!((uint8[],uint256[],address[],uint256[],uint256[],uint256[]));
    let payload = format!(
        "0x{}",
        hex::encode(<Payload as SolType>::abi_encode_params(&(
            vec![0u8, 1u8],
            vec![U256::from(1), U256::from(1)],
            vec![Address::from([0x11; 20]); 2],
            vec![U256::from(100), U256::ZERO],
            vec![U256::from(60), U256::ZERO],
            vec![U256::ZERO; 2],
        )))
    );
    assert_output("claimset", &payload, None);
}

#[test]
fn usage_rejects_missing_extra_arguments_and_aliases() {
    let payload = tree_payload();
    for args in [
        vec![],
        vec!["root"],
        vec!["proof", &payload],
        vec!["root", &payload, "1"],
        vec!["proof", &payload, "1", "extra"],
        vec!["digest", "0x", "extra"],
        vec!["claimset", "0x", "extra"],
        vec!["ffi", "root", &payload],
        vec!["ROOT", &payload],
        vec!["claim-set", &payload],
        vec!["merkle-root", &payload],
    ] {
        let output = run(&args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.starts_with("ERROR:"), "{stderr}");
        assert!(stderr.contains("usage:"), "{stderr}");
    }
    for command in ["--help", "-h", "help"] {
        let output = run(&[command]);
        assert_eq!(output.status.code(), Some(0));
        assert!(output.stderr.is_empty());
        assert!(
            String::from_utf8_lossy(&output.stdout)
                .contains("usd8-ffi <root|proof|digest|claimset>")
        );
    }
}

#[test]
fn malformed_payloads_are_fatal_not_panics() {
    for command in ["root", "proof", "digest", "claimset"] {
        for payload in ["0x", "0xgg", "0x1", "00"] {
            let mut args = vec![command, payload];
            if command == "proof" {
                args.push("1");
            }
            let output = run(&args);
            assert_eq!(output.status.code(), Some(1), "{args:?}");
            assert!(output.stdout.is_empty());
            assert!(String::from_utf8_lossy(&output.stderr).starts_with("FATAL:"));
        }
    }
}
