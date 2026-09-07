use alloy_primitives::aliases::U80;
use alloy_primitives::{Address as AlloyAddress, Bytes, I256, U256};
use alloy_sol_types::SolCall;
use async_trait::async_trait;
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;
use usd8_settlement::Address;
use usd8_settlement::abi::{
    IAggregatorV3, IDefiInsurance, IERC20, IRegistry, ISingleAssetCoverPool,
};
use usd8_settlement::chain::{
    ChainError, derive_bootstrap_config_at, incident_at, incident_config_at, pool_state_at,
    pools_at, price_usd_1e18, ratio_at, twap_ratio_before,
};
use usd8_settlement::config::BootstrapConfig;
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};

const DEFI: &str = "0x0000000000000000000000000000000000002000";
const REGISTRY: &str = "0x0000000000000000000000000000000000001000";
const INSURED: &str = "0x0000000000000000000000000000000000003000";
const ORACLE: &str = "0x0000000000000000000000000000000000004000";
const SCORED: &str = "0x0000000000000000000000000000000000005000";
const POOL: &str = "0x0000000000000000000000000000000000006000";
const ASSET: &str = "0x0000000000000000000000000000000000007000";
const FEED: &str = "0x0000000000000000000000000000000000008000";

fn a(value: &str) -> AlloyAddress {
    AlloyAddress::from_str(value).unwrap()
}

fn encoded<C: SolCall>(value: &C::Return) -> Value {
    json!(format!("0x{}", hex::encode(C::abi_encode_returns(value))))
}

#[derive(Clone)]
struct CallRpc {
    responses: Arc<HashMap<(String, String), Value>>,
}

#[async_trait]
impl Rpc for CallRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match method {
            "eth_call" => {
                let to = params[0]["to"].as_str().unwrap().to_ascii_lowercase();
                let data = params[0]["data"].as_str().unwrap();
                let selector = data[..10].to_owned();
                self.responses
                    .get(&(to, selector))
                    .cloned()
                    .ok_or_else(|| RpcError::JsonRpc {
                        code: -32000,
                        message: "missing canned call".to_owned(),
                    })
            }
            "eth_getBlockByNumber" => {
                let number = params[0].as_str().unwrap();
                Ok(json!({
                    "number": number,
                    "timestamp": "0x3e8",
                    "hash": format!("0x{}", "11".repeat(32))
                }))
            }
            _ => panic!("unexpected RPC method {method}"),
        }
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

fn fixture(answer: I256) -> CallRpc {
    fixture_with_feed_decimals(answer, 8)
}

fn fixture_with_feed_decimals(answer: I256, feed_decimals: u8) -> CallRpc {
    let mut responses = HashMap::new();
    let mut insert = |to: &str, selector: [u8; 4], value: Value| {
        responses.insert(
            (
                to.to_ascii_lowercase(),
                format!("0x{}", hex::encode(selector)),
            ),
            value,
        );
    };
    insert(
        DEFI,
        IDefiInsurance::incidentsCall::SELECTOR,
        encoded::<IDefiInsurance::incidentsCall>(&IDefiInsurance::incidentsReturn {
            insuredToken: a(INSURED),
            resolvedAt: 0,
            referenceBlock: 80,
            openBlock: 90,
            phaseDeadline: 900,
            root: [0x22; 32].into(),
            unresolvedClaims: U256::from(2),
            claimSetHash: [0x33; 32].into(),
            teePcrHash: [0x44; 32].into(),
            protocolFeeShareBps: 2_000,
        }),
    );
    insert(
        REGISTRY,
        IRegistry::defiInsuranceCall::SELECTOR,
        encoded::<IRegistry::defiInsuranceCall>(&a(DEFI)),
    );
    insert(
        DEFI,
        IDefiInsurance::registryCall::SELECTOR,
        encoded::<IDefiInsurance::registryCall>(&a(REGISTRY)),
    );
    insert(
        REGISTRY,
        IRegistry::boosterConfigCall::SELECTOR,
        encoded::<IRegistry::boosterConfigCall>(&IRegistry::boosterConfigReturn {
            collection: AlloyAddress::ZERO,
            tokenId: 1,
            boostBps: 100,
        }),
    );
    insert(
        REGISTRY,
        IRegistry::assetUsdFeedCall::SELECTOR,
        encoded::<IRegistry::assetUsdFeedCall>(&a(FEED)),
    );
    insert(
        REGISTRY,
        IRegistry::maxOracleStalenessCall::SELECTOR,
        encoded::<IRegistry::maxOracleStalenessCall>(&129_600),
    );
    insert(
        DEFI,
        IDefiInsurance::getInsuredTokenCall::SELECTOR,
        encoded::<IDefiInsurance::getInsuredTokenCall>(&IDefiInsurance::InsuredToken {
            maxCoverageBps: 8_000,
            underlyingPriceOracle: a(ORACLE),
            underlyingConversionAddress: AlloyAddress::ZERO,
            underlyingConversionCallData: Bytes::new(),
        }),
    );
    insert(
        DEFI,
        IDefiInsurance::settlementParamsCall::SELECTOR,
        encoded::<IDefiInsurance::settlementParamsCall>(&IDefiInsurance::settlementParamsReturn {
            twapLookbackBlocks: 10,
            minHoldingRequired: 5,
            sampleStepBlocks: 2,
        }),
    );
    insert(
        REGISTRY,
        IRegistry::getScoredTokensCall::SELECTOR,
        encoded::<IRegistry::getScoredTokensCall>(&vec![a(SCORED)]),
    );
    insert(
        REGISTRY,
        IRegistry::getScoredRateHistoryCall::SELECTOR,
        encoded::<IRegistry::getScoredRateHistoryCall>(&vec![
            IRegistry::RatePoint {
                fromBlock: 5,
                rate: 1_000_000_000_000_000_000,
            },
            IRegistry::RatePoint {
                fromBlock: 50,
                rate: 2_000_000_000_000_000_000,
            },
        ]),
    );
    insert(
        REGISTRY,
        IRegistry::coverPoolsCall::SELECTOR,
        encoded::<IRegistry::coverPoolsCall>(&IRegistry::coverPoolsReturn {
            assets: vec![a(ASSET)],
            poolAddrs: vec![a(POOL)],
        }),
    );
    insert(
        SCORED,
        IERC20::decimalsCall::SELECTOR,
        encoded::<IERC20::decimalsCall>(&6),
    );
    insert(
        ASSET,
        IERC20::decimalsCall::SELECTOR,
        encoded::<IERC20::decimalsCall>(&6),
    );
    insert(
        POOL,
        ISingleAssetCoverPool::assetCall::SELECTOR,
        encoded::<ISingleAssetCoverPool::assetCall>(&a(ASSET)),
    );
    insert(
        POOL,
        ISingleAssetCoverPool::totalAssetsCall::SELECTOR,
        encoded::<ISingleAssetCoverPool::totalAssetsCall>(&U256::from(1_000_000_000u64)),
    );
    insert(
        FEED,
        IAggregatorV3::latestRoundDataCall::SELECTOR,
        encoded::<IAggregatorV3::latestRoundDataCall>(&IAggregatorV3::latestRoundDataReturn {
            roundId: U80::from(7),
            answer,
            startedAt: U256::from(900),
            updatedAt: U256::from(950),
            answeredInRound: U80::from(7),
        }),
    );
    insert(
        FEED,
        IAggregatorV3::decimalsCall::SELECTOR,
        encoded::<IAggregatorV3::decimalsCall>(&feed_decimals),
    );
    CallRpc {
        responses: Arc::new(responses),
    }
}

fn config() -> BootstrapConfig {
    BootstrapConfig::derived(
        Address::from_str(REGISTRY).unwrap(),
        Address::from_str(DEFI).unwrap(),
        1,
        100,
        [(
            Address::from_str(ASSET).unwrap(),
            Address::from_str(FEED).unwrap(),
        )]
        .into_iter()
        .collect(),
        129_600,
    )
    .unwrap()
}

#[tokio::test]
async fn registry_root_derives_historical_runtime_configuration() {
    let rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let registry = Address::from_str(REGISTRY).unwrap();
    let defi = Address::from_str(DEFI).unwrap();
    let config = derive_bootstrap_config_at(&rpc, registry, defi, 90)
        .await
        .unwrap();

    assert_eq!(config.registry, registry);
    assert_eq!(config.defi_insurance, defi);
    assert_eq!(config.booster_id, 1);
    assert_eq!(config.booster_boost_bps, 100);
    assert_eq!(config.max_oracle_staleness, 129_600);
    assert_eq!(
        config
            .asset_feed(Address::from_str(ASSET).unwrap())
            .unwrap(),
        Address::from_str(FEED).unwrap()
    );
}

#[tokio::test]
async fn historical_abi_reads_reconstruct_incident_config_and_pool_state() {
    let rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    let cfg = config();
    let incident = incident_at(&rpc, cfg.defi_insurance, 7u8.into(), Some(100))
        .await
        .unwrap();
    assert_eq!(incident.reference_block, 80);
    assert_eq!(incident.open_block, 90);
    assert_eq!(incident.unresolved_claims.to_string(), "2");

    let incident_cfg = incident_config_at(&rpc, &cfg, incident.insured_token, 90)
        .await
        .unwrap();
    assert_eq!(incident_cfg.coverage_bps.to_string(), "8000");
    assert_eq!(incident_cfg.params.sample_step_blocks, 2);
    assert_eq!(incident_cfg.scored_tokens.len(), 1);
    assert_eq!(incident_cfg.scored_tokens[0].decimals, 6);
    assert_eq!(incident_cfg.scored_tokens[0].rates.len(), 2);
    assert_eq!(incident_cfg.scored_tokens[0].rates[0].from_block, 5);
    assert_eq!(
        incident_cfg.scored_tokens[0].rates[0].rate,
        BigUint::from(1_000_000_000_000_000_000u64)
    );
    assert_eq!(incident_cfg.scored_tokens[0].rates[1].from_block, 50);
    assert_eq!(
        incident_cfg.scored_tokens[0].rates[1].rate,
        BigUint::from(2_000_000_000_000_000_000u64)
    );
    assert_eq!(
        twap_ratio_before(&rpc, &incident_cfg, 80)
            .await
            .unwrap()
            .to_string(),
        "1000000000000000000"
    );

    let topology = pools_at(&rpc, &cfg, 90).await.unwrap();
    assert_eq!(topology.assets.len(), 1);
    let pool = pool_state_at(&rpc, &cfg, topology.assets[0], topology.pool_addrs[0], 100)
        .await
        .unwrap();
    assert_eq!(pool.balance.to_string(), "1000000000");
    assert_eq!(pool.asset_decimals, 6);
    assert_eq!(pool.asset_usd.to_string(), "1000000000000000000");
}

#[tokio::test]
async fn oracle_price_that_normalizes_to_zero_is_rejected() {
    let cfg = config();
    let rpc = fixture_with_feed_decimals(I256::try_from(100_000_000i64).unwrap(), 30);

    let error = price_usd_1e18(
        &rpc,
        cfg.asset_feed(Address::from_str(ASSET).unwrap()).unwrap(),
        100,
        cfg.max_oracle_staleness,
    )
    .await
    .unwrap_err();
    assert!(matches!(
        error,
        ChainError::InvalidOracle { message, .. } if message == "normalized price rounds to zero"
    ));
}

#[tokio::test]
async fn oracle_and_conversion_reads_fail_closed_on_invalid_values() {
    let cfg = config();
    let negative = fixture(I256::try_from(-1i64).unwrap());
    assert!(
        price_usd_1e18(
            &negative,
            cfg.asset_feed(Address::from_str(ASSET).unwrap()).unwrap(),
            100,
            cfg.max_oracle_staleness
        )
        .await
        .is_err()
    );

    let rpc = fixture(I256::try_from(100_000_000i64).unwrap());
    assert_eq!(
        ratio_at(
            &rpc,
            Address::from_str("0x0000000000000000000000000000000000000000").unwrap(),
            &[],
            100,
        )
        .await
        .unwrap()
        .to_string(),
        "1000000000000000000"
    );
}
