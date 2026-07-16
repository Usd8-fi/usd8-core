use usd8_settlement::config::BootstrapConfig;

const VALID: &str = r#"{
  "version": "4.5.0",
  "chainId": 1,
  "registry": "0x0000000000000000000000000000000000001000",
  "defiInsurance": "0x0000000000000000000000000000000000002000",
  "boosterId": "1",
  "boosterBoostBps": "100",
  "assetUsdFeed": {
    "0x0000000000000000000000000000000000005000": "0x0000000000000000000000000000000000006000",
    "0x0000000000000000000000000000000000003000": "0x0000000000000000000000000000000000004000"
  },
  "maxOracleStaleness": "86400",
  "maxLogRange": "1000",
  "logResultCap": 1000
}"#;

#[test]
fn config_hash_matches_typescript_and_sorts_feed_keys() {
    let config = BootstrapConfig::from_json(VALID).unwrap();
    assert_eq!(
        config.commitment_json().unwrap(),
        r#"{"version":"4.5.0","chainId":1,"registry":"0x0000000000000000000000000000000000001000","defiInsurance":"0x0000000000000000000000000000000000002000","boosterId":"1","boosterBoostBps":"100","assetUsdFeed":[["0x0000000000000000000000000000000000003000","0x0000000000000000000000000000000000004000"],["0x0000000000000000000000000000000000005000","0x0000000000000000000000000000000000006000"]],"maxOracleStaleness":"86400","maxLogRange":"1000","logResultCap":"1000"}"#
    );
    assert_eq!(
        config.hash().unwrap(),
        "0x4978fad16bc932217dc50f7083fc74b516ae710276ba04b04d0f36803965eac0"
    );
}

#[test]
fn bootstrap_validation_rejects_placeholders_and_noncanonical_maps() {
    let zero = VALID.replacen(
        "0x0000000000000000000000000000000000001000",
        "0x0000000000000000000000000000000000000000",
        1,
    );
    assert!(
        BootstrapConfig::from_json(&zero)
            .unwrap_err()
            .to_string()
            .contains("registry address is zero")
    );

    let same = VALID.replacen(
        "0x0000000000000000000000000000000000002000",
        "0x0000000000000000000000000000000000001000",
        1,
    );
    assert!(
        BootstrapConfig::from_json(&same)
            .unwrap_err()
            .to_string()
            .contains("must differ")
    );

    let uppercase_key = VALID.replacen(
        "0x0000000000000000000000000000000000005000",
        "0X0000000000000000000000000000000000005000",
        1,
    );
    assert!(
        BootstrapConfig::from_json(&uppercase_key)
            .unwrap_err()
            .to_string()
            .contains("key must be lowercase")
    );
}

#[test]
fn bootstrap_validation_rejects_unknown_or_unsupported_policy() {
    let unknown = VALID.replacen("\"chainId\": 1,", "\"chainId\": 1, \"extra\": true,", 1);
    assert!(BootstrapConfig::from_json(&unknown).is_err());

    let version = VALID.replacen("4.5.0", "5.0.0", 1);
    assert!(
        BootstrapConfig::from_json(&version)
            .unwrap_err()
            .to_string()
            .contains("unsupported config version")
    );

    let zero_range = VALID.replacen("\"maxLogRange\": \"1000\"", "\"maxLogRange\": \"0\"", 1);
    assert!(
        BootstrapConfig::from_json(&zero_range)
            .unwrap_err()
            .to_string()
            .contains("maxLogRange must be positive")
    );

    let excessive_range =
        VALID.replacen("\"maxLogRange\": \"1000\"", "\"maxLogRange\": \"2049\"", 1);
    assert!(
        BootstrapConfig::from_json(&excessive_range)
            .unwrap_err()
            .to_string()
            .contains("maxLogRange exceeds maximum 2048")
    );

    let excessive_cap = VALID.replacen("\"logResultCap\": 1000", "\"logResultCap\": 10001", 1);
    assert!(
        BootstrapConfig::from_json(&excessive_cap)
            .unwrap_err()
            .to_string()
            .contains("logResultCap exceeds maximum 10000")
    );
}

#[test]
fn feed_lookup_is_case_insensitive_but_requires_complete_mapping() {
    let config = BootstrapConfig::from_json(VALID).unwrap();
    assert_eq!(
        config
            .asset_feed("0x0000000000000000000000000000000000003000")
            .unwrap()
            .to_string(),
        "0x0000000000000000000000000000000000004000"
    );
    assert!(
        config
            .asset_feed("0x0000000000000000000000000000000000009999")
            .unwrap_err()
            .to_string()
            .contains("no assetUsdFeed")
    );
}
