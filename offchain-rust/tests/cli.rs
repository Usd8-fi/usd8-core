use std::process::{Command, Output};

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_usd8-settlement")
}

fn run(args: &[&str]) -> Output {
    Command::new(binary())
        .env_remove("USD8_REGISTRY")
        .env_remove("ETH_RPC_URL")
        .env_remove("DRPC_KEY")
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn help_and_usage_exit_codes_are_stable() {
    let help = run(&["--help"]);
    assert_eq!(help.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&help.stdout).starts_with("usage:"));

    for args in [
        vec!["compute"],
        vec!["compute", "01"],
        vec!["compute", "7", "--config", "removed.json"],
        vec!["verify", "7", "--unknown"],
        vec!["ffi", "unknown", "0x"],
        vec!["ffi", "proof", "0x"],
        vec!["kernel", "fixture.json", "1", "0", "extra"],
    ] {
        let output = run(&args);
        assert_eq!(
            output.status.code(),
            Some(2),
            "unexpected status for {args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stderr).contains("usage:"));
    }
}

#[test]
fn attested_compute_requires_the_approved_credentialed_provider() {
    let output = run(&[
        "attested-compute",
        "7",
        "--registry",
        "0x0000000000000000000000000000000000001000",
        "--rpc-url",
        "https://lb.drpc.org/ogrpc?network=ethereum",
        "--no-drpc-key",
        "--raw-score",
    ]);
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("requires DRPC_KEY"));
}

#[test]
fn malformed_payloads_and_runtime_io_fail_with_code_one() {
    let malformed_ffi = run(&["ffi", "root", "0x"]);
    assert_eq!(malformed_ffi.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&malformed_ffi.stderr).starts_with("FATAL:"));

    let missing_fixture = run(&["kernel", "/definitely/missing/usd8-fixture.json"]);
    assert_eq!(missing_fixture.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&missing_fixture.stderr).starts_with("FATAL:"));
}
