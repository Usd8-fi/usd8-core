#![cfg(feature = "sepolia")]

use usd8_settlement::config::CHAIN_ID;

#[test]
fn sepolia_feature_pins_chain_id() {
    assert_eq!(CHAIN_ID, 11_155_111);
}
