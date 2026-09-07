use serde_json::Value;
use std::io::Write;
use std::process::{Command, Stdio};
use usd8_settlement::compute_json;

#[test]
fn shared_fixture_matches_golden_output() {
    let actual: Value =
        serde_json::from_str(&compute_json(include_str!("../fixtures/small.json")).unwrap())
            .unwrap();
    let expected: Value = serde_json::from_str(
        r#"{
          "rows":[
            {"claimId":"1","user":"0x000000000000000000000000000000000000b0b0","escrowAmount":"100000000000000000000","eligibleAmount":"100000000000000000000","lossUsd":"100000000000000000000","grossEarnedScore":"60","earnedScore":"60","scoreSpent":"60","boostedScore":"60","boosterAmount":"0","eligibleBoosterAmount":"0","payoutUsd":"60000000000000000000","amounts":["60000000000000000000"]},
            {"claimId":"2","user":"0x000000000000000000000000000000000000ca50","escrowAmount":"100000000000000000000","eligibleAmount":"100000000000000000000","lossUsd":"100000000000000000000","grossEarnedScore":"40","earnedScore":"40","scoreSpent":"40","boostedScore":"40","boosterAmount":"0","eligibleBoosterAmount":"0","payoutUsd":"40000000000000000000","amounts":["40000000000000000000"]}
          ],
          "poolPayouts":["100000000000000000000"],
          "claimSetHash":"0x3a845fd00f6b76821faf799229f6bbc7533ded1399c08d33261e87a96326ae37",
          "settlementInputHash":"0x6fdf7088dad356db1a44c02996b33691d1ead1c10b008cf67abc2d456ba4eca0",
          "root":"0x4963216704d898788f548ccdaab73ba16930af05657b51eea8e8c885dcac80c1",
          "proofs":{
            "1":["0x7be61f8e01ccb59acef4f858a22b7245c586f6c212caaae91962f828c5829543"],
            "2":["0xeb87601be980c254b113991770e8f24f1d33359abeb5f0674ff7bf5f1599875f"]
          }
        }"#,
    )
    .unwrap();
    assert_eq!(actual, expected);
}

#[test]
fn missing_booster_history_is_rejected() {
    let mut input: Value = serde_json::from_str(include_str!("../fixtures/small.json")).unwrap();
    input["claims"][0]
        .as_object_mut()
        .unwrap()
        .remove("boosterHeld");
    assert!(
        compute_json(&input.to_string())
            .unwrap_err()
            .to_string()
            .contains("boosterHeld")
    );
}

#[test]
fn invalid_decimal_string_is_rejected() {
    let invalid = include_str!("../fixtures/small.json").replacen("\"8000\"", "\"8x\"", 1);
    assert!(
        compute_json(&invalid)
            .unwrap_err()
            .to_string()
            .contains("coverageBps")
    );
}

#[test]
fn cli_computes_shared_fixture() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_usd8-settlement"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(include_bytes!("../fixtures/small.json"))
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        value["root"],
        "0x4963216704d898788f548ccdaab73ba16930af05657b51eea8e8c885dcac80c1"
    );
}
