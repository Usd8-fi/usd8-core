use async_trait::async_trait;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use usd8_settlement::chain::{
    assert_anchors_unchanged, assert_contract_code_at, chain_id, finalized_settlement_anchors,
};
use usd8_settlement::rpc::{Rpc, RpcError, RpcMetrics};

#[derive(Clone)]
struct BlockRpc {
    finalized: u64,
    hashes: Arc<Mutex<BTreeMap<u64, String>>>,
    code: String,
}

fn block_hash(number: u64) -> String {
    format!("0x{number:064x}")
}

#[async_trait]
impl Rpc for BlockRpc {
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        match method {
            "eth_chainId" => Ok(json!("0x1")),
            "eth_getCode" => Ok(json!(self.code)),
            "eth_getBlockByNumber" => {
                let tag = params[0].as_str().unwrap();
                let number = if tag == "finalized" {
                    self.finalized
                } else {
                    u64::from_str_radix(tag.trim_start_matches("0x"), 16).unwrap()
                };
                let hash = self
                    .hashes
                    .lock()
                    .unwrap()
                    .get(&number)
                    .cloned()
                    .unwrap_or_else(|| block_hash(number));
                Ok(json!({
                    "number": format!("0x{number:x}"),
                    "timestamp": format!("0x{:x}", number * 12),
                    "hash": hash
                }))
            }
            _ => panic!("unexpected RPC method {method}"),
        }
    }

    fn metrics(&self) -> RpcMetrics {
        RpcMetrics::default()
    }
}

fn rpc() -> BlockRpc {
    BlockRpc {
        finalized: 10,
        hashes: Arc::new(Mutex::new(BTreeMap::new())),
        code: "0x6000".to_owned(),
    }
}

#[tokio::test]
async fn anchors_use_last_in_window_block_beneath_finalized_head() {
    let rpc = rpc();
    let anchors = finalized_settlement_anchors(&rpc, 3, 4, 65).await.unwrap();
    assert_eq!(anchors.reference.number, 3);
    assert_eq!(anchors.open.number, 4);
    assert_eq!(anchors.window_end.number, 5);
    assert_eq!(anchors.window_end.timestamp, 60);
    assert_eq!(anchors.finalized_head.number, 10);
    assert_eq!(anchors.finalized_head.timestamp, 120);
    assert_eq!(chain_id(&rpc).await.unwrap(), 1);
}

#[tokio::test]
async fn provisional_windows_or_unfinalized_anchors_fail_closed() {
    let rpc = rpc();
    assert!(
        finalized_settlement_anchors(&rpc, 3, 4, 121)
            .await
            .unwrap_err()
            .to_string()
            .contains("claim window is not finalized")
    );
    assert!(
        finalized_settlement_anchors(&rpc, 11, 4, 65)
            .await
            .unwrap_err()
            .to_string()
            .contains("settlement anchor is not finalized")
    );
}

#[tokio::test]
async fn changed_anchor_hash_fails_before_output() {
    let rpc = rpc();
    let anchors = finalized_settlement_anchors(&rpc, 3, 4, 65).await.unwrap();
    rpc.hashes
        .lock()
        .unwrap()
        .insert(5, format!("0x{}", "ff".repeat(32)));
    assert!(
        assert_anchors_unchanged(&rpc, &anchors)
            .await
            .unwrap_err()
            .to_string()
            .contains("anchor hash changed for windowEnd block 5")
    );
}

#[tokio::test]
async fn historical_code_check_rejects_eoa_or_missing_contract() {
    let deployed = rpc();
    assert_contract_code_at(
        &deployed,
        "0x0000000000000000000000000000000000001000",
        "Registry",
        4,
    )
    .await
    .unwrap();

    let empty = BlockRpc {
        code: "0x".to_owned(),
        ..rpc()
    };
    assert!(
        assert_contract_code_at(
            &empty,
            "0x0000000000000000000000000000000000001000",
            "Registry",
            4,
        )
        .await
        .unwrap_err()
        .to_string()
        .contains("Registry")
    );
}
