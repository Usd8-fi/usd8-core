use crate::Address;
use serde::{Deserialize, Serialize};
use sha3::{Digest, Keccak256};
use std::collections::BTreeMap;
use std::str::FromStr;
use thiserror::Error;

pub const SUPPORTED_CONFIG_VERSION: &str = "4.5.0";
pub const SUPPORTED_BOOSTER_ID: u64 = 1;
pub const SUPPORTED_BOOSTER_BOOST_BPS: u64 = 100;
pub const MAX_LOG_RANGE: u64 = 2_048;
pub const MAX_LOG_RESULT_CAP: u64 = 10_000;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("invalid config JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid {label} address: {value}")]
    InvalidAddress { label: String, value: String },
    #[error("{0} address is zero")]
    ZeroAddress(String),
    #[error("registry and defiInsurance addresses must differ")]
    DuplicateContracts,
    #[error("assetUsdFeed key must be lowercase: {0}")]
    NoncanonicalAssetKey(String),
    #[error("invalid decimal string for {field}: {value}")]
    InvalidDecimal { field: String, value: String },
    #[error("unsupported config version: {0}")]
    UnsupportedVersion(String),
    #[error("unsupported booster policy: id={id}, boostBps={boost_bps}")]
    UnsupportedBoosterPolicy { id: u64, boost_bps: u64 },
    #[error("{0} must be positive")]
    NonPositivePolicy(&'static str),
    #[error("{field} exceeds maximum {maximum}: {value}")]
    PolicyTooLarge {
        field: &'static str,
        value: u64,
        maximum: u64,
    },
    #[error("no assetUsdFeed configured for pool asset {0}")]
    MissingAssetFeed(String),
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConfigDto {
    version: String,
    chain_id: u64,
    registry: String,
    defi_insurance: String,
    booster_id: String,
    booster_boost_bps: String,
    asset_usd_feed: BTreeMap<String, String>,
    max_oracle_staleness: String,
    max_log_range: String,
    log_result_cap: u64,
}

#[derive(Clone, Debug)]
pub struct BootstrapConfig {
    pub version: String,
    pub chain_id: u64,
    pub registry: Address,
    pub defi_insurance: Address,
    pub booster_id: u64,
    pub booster_boost_bps: u64,
    pub asset_usd_feed: BTreeMap<Address, Address>,
    pub max_oracle_staleness: u64,
    pub max_log_range: u64,
    pub log_result_cap: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Commitment<'a> {
    version: &'a str,
    chain_id: u64,
    registry: String,
    defi_insurance: String,
    booster_id: String,
    booster_boost_bps: String,
    asset_usd_feed: Vec<(String, String)>,
    max_oracle_staleness: String,
    max_log_range: String,
    log_result_cap: String,
}

fn decimal(field: &str, value: &str) -> Result<u64, ConfigError> {
    let parsed = value
        .parse::<u64>()
        .map_err(|_| ConfigError::InvalidDecimal {
            field: field.to_owned(),
            value: value.to_owned(),
        })?;
    if parsed.to_string() != value {
        return Err(ConfigError::InvalidDecimal {
            field: field.to_owned(),
            value: value.to_owned(),
        });
    }
    Ok(parsed)
}

fn configured_address(value: &str, label: &str) -> Result<Address, ConfigError> {
    let address = Address::from_str(value).map_err(|_| ConfigError::InvalidAddress {
        label: label.to_owned(),
        value: value.to_owned(),
    })?;
    if address.is_zero() {
        return Err(ConfigError::ZeroAddress(label.to_owned()));
    }
    Ok(address)
}

impl BootstrapConfig {
    pub fn from_json(input: &str) -> Result<Self, ConfigError> {
        let dto: ConfigDto = serde_json::from_str(input)?;
        if dto.version != SUPPORTED_CONFIG_VERSION {
            return Err(ConfigError::UnsupportedVersion(dto.version));
        }
        let registry = configured_address(&dto.registry, "registry")?;
        let defi_insurance = configured_address(&dto.defi_insurance, "defiInsurance")?;
        if registry == defi_insurance {
            return Err(ConfigError::DuplicateContracts);
        }
        let booster_id = decimal("boosterId", &dto.booster_id)?;
        let booster_boost_bps = decimal("boosterBoostBps", &dto.booster_boost_bps)?;
        if booster_id != SUPPORTED_BOOSTER_ID || booster_boost_bps != SUPPORTED_BOOSTER_BOOST_BPS {
            return Err(ConfigError::UnsupportedBoosterPolicy {
                id: booster_id,
                boost_bps: booster_boost_bps,
            });
        }
        let max_oracle_staleness = decimal("maxOracleStaleness", &dto.max_oracle_staleness)?;
        let max_log_range = decimal("maxLogRange", &dto.max_log_range)?;
        if max_oracle_staleness == 0 {
            return Err(ConfigError::NonPositivePolicy("maxOracleStaleness"));
        }
        if max_log_range == 0 {
            return Err(ConfigError::NonPositivePolicy("maxLogRange"));
        }
        if max_log_range > MAX_LOG_RANGE {
            return Err(ConfigError::PolicyTooLarge {
                field: "maxLogRange",
                value: max_log_range,
                maximum: MAX_LOG_RANGE,
            });
        }
        if dto.log_result_cap == 0 {
            return Err(ConfigError::NonPositivePolicy("logResultCap"));
        }
        if dto.log_result_cap > MAX_LOG_RESULT_CAP {
            return Err(ConfigError::PolicyTooLarge {
                field: "logResultCap",
                value: dto.log_result_cap,
                maximum: MAX_LOG_RESULT_CAP,
            });
        }

        let mut asset_usd_feed = BTreeMap::new();
        for (asset, feed) in dto.asset_usd_feed {
            if asset != asset.to_lowercase() {
                return Err(ConfigError::NoncanonicalAssetKey(asset));
            }
            let asset_address = configured_address(&asset, "pool asset")?;
            let feed_address = configured_address(&feed, &format!("USD feed for {asset}"))?;
            asset_usd_feed.insert(asset_address, feed_address);
        }

        Ok(Self {
            version: SUPPORTED_CONFIG_VERSION.to_owned(),
            chain_id: dto.chain_id,
            registry,
            defi_insurance,
            booster_id,
            booster_boost_bps,
            asset_usd_feed,
            max_oracle_staleness,
            max_log_range,
            log_result_cap: dto.log_result_cap,
        })
    }

    fn commitment(&self) -> Commitment<'_> {
        Commitment {
            version: &self.version,
            chain_id: self.chain_id,
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
            max_log_range: self.max_log_range.to_string(),
            log_result_cap: self.log_result_cap.to_string(),
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

    pub fn asset_feed(&self, asset: &str) -> Result<Address, ConfigError> {
        let parsed = Address::from_str(asset).map_err(|_| ConfigError::InvalidAddress {
            label: "pool asset".to_owned(),
            value: asset.to_owned(),
        })?;
        self.asset_usd_feed
            .get(&parsed)
            .copied()
            .ok_or_else(|| ConfigError::MissingAssetFeed(parsed.to_string()))
    }
}
