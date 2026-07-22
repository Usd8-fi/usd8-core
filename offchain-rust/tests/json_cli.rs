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
            {"claimId":"1","user":"0x000000000000000000000000000000000000b0b0","escrowAmount":"100000000000000000000","eligibleAmount":"100000000000000000000","lossUsd":"100000000000000000000","grossEarnedScore":"60","earnedScore":"60","scoreSpent":"60","boostedScore":"60","payoutUsd":"55051025721816600736","amounts":["55051025721816600736"]},
            {"claimId":"2","user":"0x000000000000000000000000000000000000ca50","escrowAmount":"100000000000000000000","eligibleAmount":"100000000000000000000","lossUsd":"100000000000000000000","grossEarnedScore":"40","earnedScore":"40","scoreSpent":"40","boostedScore":"40","payoutUsd":"44948974278183399263","amounts":["44948974278183399263"]}
          ],
          "poolPayouts":["99999999999999999999"],
          "claimSetHash":"0x3a845fd00f6b76821faf799229f6bbc7533ded1399c08d33261e87a96326ae37",
          "settlementInputHash":"0x6fdf7088dad356db1a44c02996b33691d1ead1c10b008cf67abc2d456ba4eca0",
          "root":"0xc49d55c3cf8eb13b6610f2ea535f30915e824a498ed05b2f6d0ca1d94ba15e66",
          "proofs":{
            "1":["0xa7a37192744b909ef7188777172160185ef8dc048d61f0f91206917600d48f7c"],
            "2":["0x1dfaa622c93c2219664c5338dc00b9a88ec7564fd55613e97126c5d3c4584ed7"]
          }
        }"#,
    )
    .unwrap();
    assert_eq!(actual, expected);
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
        "0xc49d55c3cf8eb13b6610f2ea535f30915e824a498ed05b2f6d0ca1d94ba15e66"
    );
}
