use std::process::{Command, Output};

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_usd8-settlement")
}

fn run(args: &[&str]) -> Output {
    Command::new(binary())
        .env_remove("USD8_REGISTRY")
        .env_remove("ETH_RPC_URL")
        .env_remove("DRPC_KEY")
        .env_remove("SCORE_CHECKPOINT_PATH")
        .env_remove("SCORE_CHECKPOINT_KEY")
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn retired_compute_names_are_unknown_commands_even_when_files_exist() {
    let directory = std::env::temp_dir().join(format!("usd8-retired-cli-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let help = run(&["--help"]);
    for name in ["compute_score", "compute_local", "compute_tee"] {
        assert!(!String::from_utf8_lossy(&help.stdout).contains(name));
        std::fs::write(directory.join(name), "{}").unwrap();
        for extra in [vec![], vec!["7", "--unknown"]] {
            let output = Command::new(binary())
                .current_dir(&directory)
                .arg(name)
                .args(extra)
                .output()
                .unwrap();
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert_eq!(output.status.code(), Some(2), "{name}: {stderr}");
            assert!(
                stderr.contains(&format!("unknown command: {name}")),
                "{stderr}"
            );
            assert!(stderr.contains("usage:"), "{stderr}");
            assert!(output.stdout.is_empty());
        }
    }
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn detect_price_drop_is_advertised_instead_of_attested_open() {
    let help = run(&["--help"]);
    let text = String::from_utf8_lossy(&help.stdout);
    assert!(
        text.contains("usd8-settlement detect_price_drop "),
        "{text}"
    );
    assert!(!text.contains("attested-open"));
    assert!(!text.contains("expected-signer"));
    assert!(!text.contains("USD8_EXPECTED_SIGNER"));
}

#[test]
fn compute_insurance_score_help_dispatch_and_address_validation() {
    let help = run(&["--help"]);
    assert!(
        String::from_utf8_lossy(&help.stdout)
            .contains("usd8-settlement compute_insurance_score <userAddress>")
    );
    for (args, message) in [
        (vec!["compute_insurance_score"], "missing userAddress"),
        (
            vec!["compute_insurance_score", "broken"],
            "invalid userAddress",
        ),
        (
            vec![
                "compute_insurance_score",
                "0x0000000000000000000000000000000000000000",
            ],
            "userAddress is zero",
        ),
        (
            vec![
                "compute_insurance_score",
                "0x0000000000000000000000000000000000001000",
            ],
            "missing --registry",
        ),
    ] {
        let output = run(&args);
        assert_eq!(output.status.code(), Some(2));
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(message),
            "{message}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn local_queries_validate_arguments_and_optional_credentials_before_network() {
    const ADDRESS: &str = "0x0000000000000000000000000000000000001000";
    for mode in ["detect_price_drop", "compute_insurance_score"] {
        for (extra, message) in [
            (vec!["--raw-score"], "invalid for"),
            (vec!["--bulk-score"], "invalid for"),
            (vec!["--checkpoint", "state.json"], "invalid for"),
            (vec!["--checkpoint-key-env", "KEY"], "invalid for"),
            (vec!["--expected-signer", ADDRESS], "unknown option"),
            (vec!["--timeout-ms", "bad"], "invalid --timeout-ms"),
            (vec!["--timeout-ms"], "requires a value"),
            (
                vec!["--registry", ADDRESS, "--registry", ADDRESS],
                "duplicate option",
            ),
        ] {
            let mut args = vec![mode, ADDRESS];
            args.extend(extra);
            let output = run(&args);
            assert_eq!(output.status.code(), Some(2));
            assert!(
                String::from_utf8_lossy(&output.stderr).contains(message),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(output.stdout.is_empty());
        }
        for (endpoint, key, extra, message) in [
            ("not-a-url", None, vec![], "invalid RPC endpoint"),
            (
                "ftp://127.0.0.1",
                None,
                vec![],
                "unsupported RPC endpoint scheme",
            ),
            (
                "http://127.0.0.1:1",
                None,
                vec!["--timeout-ms", "0"],
                "RPC timeout",
            ),
            (
                "http://127.0.0.1:1",
                Some("test-key"),
                vec![],
                "untrusted RPC endpoint",
            ),
            (
                "https://lb.drpc.org/ogrpc?network=ethereum",
                Some("bad\nkey"),
                vec![],
                "invalid DRPC_KEY header",
            ),
        ] {
            let mut command = Command::new(binary());
            command
                .env_remove("DRPC_KEY")
                .env_remove("SCORE_CHECKPOINT_PATH");
            if let Some(key) = key {
                command.env("CLI_TEST_DRPC_KEY", key);
            } else {
                command.env_remove("CLI_TEST_DRPC_KEY");
            }
            let output = command
                .args([
                    mode,
                    ADDRESS,
                    "--registry",
                    ADDRESS,
                    "--rpc-url",
                    endpoint,
                    "--drpc-key-env",
                    "CLI_TEST_DRPC_KEY",
                ])
                .args(extra)
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(1));
            assert!(
                String::from_utf8_lossy(&output.stderr).contains(message),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(output.stdout.is_empty());
        }
        for address in ["broken", "0x0000000000000000000000000000000000000000"] {
            let output = run(&[mode, address]);
            assert_eq!(output.status.code(), Some(2));
            assert!(output.stdout.is_empty());
        }
    }
}

#[test]
fn help_and_usage_exit_codes_are_stable() {
    let help = run(&["--help"]);
    assert_eq!(help.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&help.stdout).starts_with("usage:"));

    for args in [
        vec!["compute_settlement"],
        vec!["compute_settlement", "01"],
        vec!["compute_settlement", "7", "--config", "removed.json"],
        vec!["detect_price_drop"],
        vec![
            "detect_price_drop",
            "0x0000000000000000000000000000000000001000",
            "01",
        ],
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
fn compute_settlement_tee_requires_the_approved_credentialed_provider() {
    let help = run(&["--help"]);
    assert!(
        String::from_utf8_lossy(&help.stdout).contains("usd8-settlement compute_settlement_tee ")
    );
    let output = run(&[
        "compute_settlement_tee",
        "7",
        "--registry",
        "0x0000000000000000000000000000000000001000",
        "--rpc-url",
        "https://lb.drpc.org/ogrpc?network=ethereum",
        "--no-drpc-key",
        "--bulk-score",
    ]);
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("requires DRPC_KEY"));
}

#[test]
fn tee_credentials_precede_rpc_and_checkpoint_setup_but_follow_argument_guards() {
    const ADDRESS: &str = "0x0000000000000000000000000000000000001000";
    for (mode, expected) in [
        ("compute_settlement_tee", "requires DRPC_KEY"),
        ("compute_settlement", "invalid RPC endpoint"),
    ] {
        let output = run(&[
            mode,
            "7",
            "--registry",
            ADDRESS,
            "--rpc-url",
            "not-a-url",
            "--no-drpc-key",
            "--checkpoint",
            "unused-checkpoint.json",
            "--checkpoint-key-env",
            "CLI_TEST_MISSING_CHECKPOINT_KEY",
        ]);
        assert_eq!(output.status.code(), Some(1));
        assert!(String::from_utf8_lossy(&output.stderr).contains(expected));
        assert!(output.stdout.is_empty());
    }
    let output = run(&[
        "compute_settlement_tee",
        "7",
        "--registry",
        ADDRESS,
        "--rpc-url",
        "not-a-url",
        "--no-drpc-key",
        "--checkpoint",
        "collision.json",
        "--output",
        "collision.json",
    ]);
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("output path collides"));
}

#[test]
fn bulk_score_is_accepted_and_score_modes_are_pairwise_exclusive() {
    let accepted = run(&["compute_settlement", "7", "--bulk-score"]);
    assert_eq!(accepted.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&accepted.stderr).contains("missing --registry"));
    assert!(!String::from_utf8_lossy(&accepted.stderr).contains("unknown option"));

    for args in [
        vec!["compute_settlement", "7", "--bulk-score", "--raw-score"],
        vec![
            "compute_settlement",
            "7",
            "--bulk-score",
            "--checkpoint",
            "state.json",
        ],
    ] {
        let output = run(&args);
        assert_eq!(output.status.code(), Some(2));
        assert!(String::from_utf8_lossy(&output.stderr).contains("mutually exclusive"));
    }

    let open = run(&[
        "detect_price_drop",
        "0x0000000000000000000000000000000000003000",
        "--bulk-score",
    ]);
    assert_eq!(open.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&open.stderr).contains("invalid for detect_price_drop"));
}

#[test]
fn detect_price_drop_rejects_a_caller_supplied_reference_block() {
    let output = run(&[
        "detect_price_drop",
        "0x0000000000000000000000000000000000003000",
        "1234567",
    ]);
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("unknown option: 1234567"));
}

#[test]
fn detect_price_drop_needs_no_provider_credential() {
    let output = run(&[
        "detect_price_drop",
        "0x0000000000000000000000000000000000003000",
        "--registry",
        "0x0000000000000000000000000000000000001000",
        "--rpc-url",
        "not-a-url",
        "--no-drpc-key",
    ]);
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("invalid RPC endpoint"));
}

#[test]
fn compute_settlement_needs_no_provider_credential() {
    let help = run(&["--help"]);
    assert!(String::from_utf8_lossy(&help.stdout).contains("usd8-settlement compute_settlement "));
    let output = run(&[
        "compute_settlement",
        "7",
        "--registry",
        "0x0000000000000000000000000000000000001000",
        "--rpc-url",
        "not-a-url",
        "--no-drpc-key",
        "--raw-score",
    ]);
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("invalid RPC endpoint"), "{stderr}");
    assert!(!stderr.contains("requires DRPC_KEY"));
}

#[test]
fn legacy_commands_are_rejected_not_interpreted_as_kernel_paths() {
    for command in [
        "compute",
        "attested-compute",
        "verify",
        "ffi",
        "attested-open",
    ] {
        for args in [vec![command], vec![command, "7"]] {
            let output = run(&args);
            assert_eq!(output.status.code(), Some(2), "{args:?}");
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert!(
                stderr.contains(&format!("unknown command: {command}")),
                "{stderr}"
            );
            assert!(output.stdout.is_empty());
        }
        let help = run(&["--help"]);
        assert!(
            !String::from_utf8_lossy(&help.stdout).contains(&format!("usd8-settlement {command} "))
        );
    }
}

#[test]
fn retired_ffi_and_kernel_are_usage_errors_without_runtime_io() {
    let malformed_ffi = run(&["ffi", "root", "0x"]);
    assert_eq!(malformed_ffi.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&malformed_ffi.stderr).contains("unknown command: ffi"));

    let missing_fixture = run(&["kernel", "/definitely/missing/usd8-fixture.json"]);
    assert_eq!(missing_fixture.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&missing_fixture.stderr).contains("unknown command: kernel"));
}

#[test]
fn production_cli_rejects_fixture_paths_and_missing_commands_without_reading_stdin() {
    assert!(!String::from_utf8_lossy(&run(&["--help"]).stdout).contains("kernel"));
    for args in [
        vec![],
        vec!["kernel"],
        vec!["fixtures/small.json"],
        vec!["/definitely/missing/input.json"],
    ] {
        let mut child = Command::new(binary())
            .args(&args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            if child.try_wait().unwrap().is_some() {
                break;
            }
            if std::time::Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("production CLI consumed stdin for {args:?}");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let output = child.wait_with_output().unwrap();
        drop(stdin);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(2), "{stderr}");
        assert!(stderr.contains("usage:"), "{stderr}");
        let expected = args.first().map_or_else(
            || "missing command".to_owned(),
            |arg| format!("unknown command: {arg}"),
        );
        assert!(stderr.contains(&expected), "{stderr}");
        assert!(output.stdout.is_empty());
    }
}
