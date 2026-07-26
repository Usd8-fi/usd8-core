use std::collections::BTreeMap;
use std::str::FromStr;
use usd8_settlement::Address;
use usd8_settlement::config::{
    BootstrapConfig, CHAIN_ID, CONFIG_VERSION, LOG_RESULT_CAP, MAX_LOG_RANGE,
};

fn address(value: &str) -> Address {
    Address::from_str(value).unwrap()
}

fn valid() -> BootstrapConfig {
    BootstrapConfig::derived(
        address("0x0000000000000000000000000000000000001000"),
        address("0x0000000000000000000000000000000000002000"),
        1,
        100,
        [
            (
                address("0x0000000000000000000000000000000000003000"),
                address("0x0000000000000000000000000000000000004000"),
            ),
            (
                address("0x0000000000000000000000000000000000005000"),
                address("0x0000000000000000000000000000000000006000"),
            ),
        ]
        .into_iter()
        .collect(),
        129_600,
    )
    .unwrap()
}

#[test]
fn derived_config_commitment_is_canonical_and_binds_baked_rpc_policy() {
    let config = valid();
    assert_eq!(CONFIG_VERSION, "5.0.0");
    assert_eq!(
        CHAIN_ID,
        if cfg!(feature = "sepolia") {
            11_155_111
        } else {
            1
        }
    );
    assert_eq!(MAX_LOG_RANGE, 1_000);
    assert_eq!(LOG_RESULT_CAP, 1_000);
    let expected_json = format!(
        r#"{{"version":"5.0.0","chainId":"{}","registry":"0x0000000000000000000000000000000000001000","defiInsurance":"0x0000000000000000000000000000000000002000","boosterId":"1","boosterBoostBps":"100","assetUsdFeed":[["0x0000000000000000000000000000000000003000","0x0000000000000000000000000000000000004000"],["0x0000000000000000000000000000000000005000","0x0000000000000000000000000000000000006000"]],"maxOracleStaleness":"129600","maxLogRange":"1000","logResultCap":"1000"}}"#,
        CHAIN_ID
    );
    assert_eq!(config.commitment_json().unwrap(), expected_json);
    let expected_hash = if cfg!(feature = "sepolia") {
        "0x521c03162afdbe5901fb7beb3573bd835ad2233cf929ee02f16e7f3e2b7e0c2b"
    } else {
        "0xf4c864ca629a28b3755712eeec7a8a3c80be0bf5f1e6d8d8abaab4eb84674449"
    };
    assert_eq!(config.hash().unwrap(), expected_hash);
}

#[test]
fn derived_config_rejects_invalid_onchain_state() {
    let registry = address("0x0000000000000000000000000000000000001000");
    let defi = address("0x0000000000000000000000000000000000002000");
    assert!(
        BootstrapConfig::derived(
            Address::from_bytes([0; 20]),
            defi,
            1,
            100,
            BTreeMap::new(),
            1
        )
        .is_err()
    );
    assert!(
        BootstrapConfig::derived(
            registry,
            Address::from_bytes([0; 20]),
            1,
            100,
            BTreeMap::new(),
            1
        )
        .is_err()
    );
    assert!(BootstrapConfig::derived(registry, defi, 2, 100, BTreeMap::new(), 1).is_err());
    assert!(BootstrapConfig::derived(registry, defi, 1, 101, BTreeMap::new(), 1).is_err());
    assert!(BootstrapConfig::derived(registry, defi, 1, 100, BTreeMap::new(), 0).is_err());

    let feeds = [(
        address("0x0000000000000000000000000000000000003000"),
        Address::from_bytes([0; 20]),
    )]
    .into_iter()
    .collect();
    assert!(BootstrapConfig::derived(registry, defi, 1, 100, feeds, 1).is_err());
}
