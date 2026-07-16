use serde_json::Value;
use std::process::Command;
use usd8_settlement::compute_json;

#[test]
fn shared_fixture_matches_typescript_authority() {
    let actual: Value =
        serde_json::from_str(&compute_json(include_str!("../fixtures/small.json")).unwrap())
            .unwrap();
    let expected: Value = serde_json::from_str(
        r#"{
          "rows":[
            {"claimId":"1","user":"0x000000000000000000000000000000000000b0b0","escrowAmount":"100000000000000000000","eligibleAmount":"100000000000000000000","lossUsd":"100000000000000000000","grossEarnedScore":"60","earnedScore":"60","scoreSpent":"60","payoutUsd":"55051025721816600736","amounts":["55051025721816600736"]},
            {"claimId":"2","user":"0x000000000000000000000000000000000000ca50","escrowAmount":"100000000000000000000","eligibleAmount":"100000000000000000000","lossUsd":"100000000000000000000","grossEarnedScore":"40","earnedScore":"40","scoreSpent":"40","payoutUsd":"44948974278183399263","amounts":["44948974278183399263"]}
          ],
          "poolPayouts":["99999999999999999999"],
          "claimSetHash":"0x3a845fd00f6b76821faf799229f6bbc7533ded1399c08d33261e87a96326ae37",
          "settlementInputHash":"0x6fdf7088dad356db1a44c02996b33691d1ead1c10b008cf67abc2d456ba4eca0",
          "root":"0xd0fe6133bddec8bbf138286152b065bd734bc58185e3f4029bf86c94ca1ba160",
          "proofs":{
            "1":["0x76c7a3e332020a2e5a324202e6c735cb7cfb57d619aec446e46ff32d5c41e420"],
            "2":["0x5639317554493d37e5c76552f7fee9e07c02ae8d3f873badb6d6ca7e4a1a26e3"]
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
    let output = Command::new(env!("CARGO_BIN_EXE_usd8-settlement"))
        .arg(concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/small.json"))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        value["root"],
        "0xd0fe6133bddec8bbf138286152b065bd734bc58185e3f4029bf86c94ca1ba160"
    );
}
