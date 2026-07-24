use crate::Address;
use serde::Serialize;
use sha3::{Digest, Keccak256};
use std::collections::BTreeMap;
use thiserror::Error;

pub const CONFIG_VERSION: &str = "5.0.0";
#[cfg(not(feature = "sepolia"))]
pub const CHAIN_ID: u64 = 1;
#[cfg(feature = "sepolia")]
pub const CHAIN_ID: u64 = 11_155_111;
pub const MAX_LOG_RANGE: u64 = 1_000;
pub const LOG_RESULT_CAP: usize = 1_000;
pub const MAX_LOG_RESULT_CAP: u64 = LOG_RESULT_CAP as u64;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("registry address is zero")]
    ZeroRegistry,
    #[error("defiInsurance address is zero")]
    ZeroDefiInsurance,
    #[error("unsupported booster policy: id={id}, boostBps={boost_bps}")]
    UnsupportedBoosterPolicy { id: u64, boost_bps: u64 },
    #[error("maxOracleStaleness must be positive")]
    InvalidOracleStaleness,
    #[error("no on-chain USD feed configured for pool asset {0}")]
    MissingAssetFeed(Address),
    #[error("derived configuration JSON failed: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Debug)]
pub struct BootstrapConfig {
    pub version: &'static str,
    pub chain_id: u64,
    pub registry: Address,
    pub defi_insurance: Address,
    pub booster_id: u64,
    pub booster_boost_bps: u64,
    pub asset_usd_feed: BTreeMap<Address, Address>,
    pub max_oracle_staleness: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Commitment<'a> {
    version: &'a str,
    chain_id: String,
    registry: String,
    defi_insurance: String,
    booster_id: String,
    booster_boost_bps: String,
    asset_usd_feed: Vec<(String, String)>,
    max_oracle_staleness: String,
    max_log_range: String,
    log_result_cap: String,
}

impl BootstrapConfig {
    pub fn derived(
        registry: Address,
        defi_insurance: Address,
        booster_id: u64,
        booster_boost_bps: u64,
        asset_usd_feed: BTreeMap<Address, Address>,
        max_oracle_staleness: u64,
    ) -> Result<Self, ConfigError> {
        if registry.is_zero() {
            return Err(ConfigError::ZeroRegistry);
        }
        if defi_insurance.is_zero() {
            return Err(ConfigError::ZeroDefiInsurance);
        }
        if booster_id != 1 || booster_boost_bps != 100 {
            return Err(ConfigError::UnsupportedBoosterPolicy {
                id: booster_id,
                boost_bps: booster_boost_bps,
            });
        }
        if max_oracle_staleness == 0 {
            return Err(ConfigError::InvalidOracleStaleness);
        }
        if let Some(asset) = asset_usd_feed
            .iter()
            .find_map(|(asset, feed)| feed.is_zero().then_some(*asset))
        {
            return Err(ConfigError::MissingAssetFeed(asset));
        }
        Ok(Self {
            version: CONFIG_VERSION,
            chain_id: CHAIN_ID,
            registry,
            defi_insurance,
            booster_id,
            booster_boost_bps,
            asset_usd_feed,
            max_oracle_staleness,
        })
    }

    fn commitment(&self) -> Commitment<'_> {
        Commitment {
            version: self.version,
            chain_id: self.chain_id.to_string(),
            registry: self.registry.to_string(),
            defi_insurance: self.defi_insurance.to_string(),
            booster_id: self.booster_id.to_string(),
            booster_boost_bps: self.booster_boost_bps.to_string(),
            asset_usd_feed: self
                .asset_usd_feed
                .iter()
                .map(|(asset, feed)| (asset.to_string(), feed.to_string()))
                .collect(),
            max_oracle_staleness: self.max_oracle_staleness.to_string(),
            max_log_range: MAX_LOG_RANGE.to_string(),
            log_result_cap: LOG_RESULT_CAP.to_string(),
        }
    }

    pub fn commitment_json(&self) -> Result<String, ConfigError> {
        Ok(serde_json::to_string(&self.commitment())?)
    }

    pub fn hash(&self) -> Result<String, ConfigError> {
        let mut hasher = Keccak256::new();
        hasher.update(self.commitment_json()?.as_bytes());
        Ok(format!("0x{}", hex::encode(hasher.finalize())))
    }

    pub fn asset_feed(&self, asset: Address) -> Result<Address, ConfigError> {
        self.asset_usd_feed
            .get(&asset)
            .copied()
            .ok_or(ConfigError::MissingAssetFeed(asset))
    }
}
