use alloy_sol_types::SolCall;
use serde_json::{Value, json};
use usd8_settlement::abi::IMulticall3;
use usd8_settlement::rpc::RpcError;

#[allow(dead_code)]
pub struct FaultRpc<R> {
    pub inner: R,
    pub fault: &'static str,
    pub at_aggregate: usize,
    pub aggregates: std::sync::atomic::AtomicUsize,
    pub poisoned: std::sync::atomic::AtomicBool,
}
#[allow(dead_code)]
impl<R> FaultRpc<R> {
    pub fn new(inner: R, fault: &'static str, at_aggregate: usize) -> Self {
        Self {
            inner,
            fault,
            at_aggregate,
            aggregates: 0.into(),
            poisoned: false.into(),
        }
    }
}
#[async_trait::async_trait]
impl<R: usd8_settlement::rpc::Rpc> usd8_settlement::rpc::Rpc for FaultRpc<R> {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        self.inner.metrics()
    }
    async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        use std::sync::atomic::Ordering::SeqCst;
        assert!(
            !self.poisoned.load(SeqCst),
            "RPC after terminal aggregate failure (fallback)"
        );
        let aggregate = method == "eth_call"
            && params[0]["to"].as_str().is_some_and(|to| {
                to.eq_ignore_ascii_case("0xca11bde05977b3631167028862be2a173976ca11")
            });
        if !aggregate || self.aggregates.fetch_add(1, SeqCst) != self.at_aggregate {
            return self.inner.request(method, params).await;
        }
        self.poisoned.store(true, SeqCst);
        if self.fault == "revert" {
            return Err(RpcError::JsonRpc {
                code: -32000,
                message: "aggregate unavailable".into(),
            });
        }
        let value = self.inner.request(method, params).await?;
        let mut bytes = hex::decode(&value.as_str().unwrap()[2..]).unwrap();
        if self.fault == "envelope" {
            bytes = vec![0; 31];
        } else if self.fault == "trailing-envelope" {
            bytes.extend([0; 32]);
        } else {
            let mut results = IMulticall3::aggregate3Call::abi_decode_returns(&bytes).unwrap();
            match self.fault {
                "count" => {
                    results.pop();
                }
                "failed" => results[0].success = false,
                "empty" => results[0].returnData = Default::default(),
                "malformed" => results[0].returnData = vec![0; 31].into(),
                "trailing-subcall" => {
                    let mut data = results[0].returnData.to_vec();
                    data.extend([0; 32]);
                    results[0].returnData = data.into();
                }
                _ => panic!("unknown fault"),
            }
            bytes = IMulticall3::aggregate3Call::abi_encode_returns(&results);
        }
        Ok(json!(format!("0x{}", hex::encode(bytes))))
    }
}

// Wrapping adversarial mocks must still see each getter, otherwise a selector-
// based fault would silently stop being exercised after batching.
#[allow(dead_code)]
pub async fn dispatch_wrapped<R: usd8_settlement::rpc::Rpc + ?Sized>(
    rpc: &R,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !params[0]["to"]
        .as_str()?
        .eq_ignore_ascii_case("0xca11bde05977b3631167028862be2a173976ca11")
    {
        return None;
    }
    let data = hex::decode(&params[0]["data"].as_str().unwrap()[2..]).unwrap();
    let call = IMulticall3::aggregate3Call::abi_decode_validate(&data).unwrap();
    let mut results = Vec::new();
    for input in call.calls {
        assert!(!input.allowFailure);
        let params = json!([{"to":format!("{:#x}",input.target),"data":format!("0x{}",hex::encode(input.callData))},params[1]]);
        let value = match rpc.request("eth_call", params).await {
            Ok(value) => value,
            Err(error) => return Some(Err(error)),
        };
        results.push(IMulticall3::Result {
            success: true,
            returnData: hex::decode(&value.as_str().unwrap()[2..]).unwrap().into(),
        });
    }
    Some(Ok(json!(format!(
        "0x{}",
        hex::encode(IMulticall3::aggregate3Call::abi_encode_returns(&results))
    ))))
}

// Emulate the EVM boundary, not extra RPC requests. The caller records one
// transport request; subcalls dispatch to the same scalar fixture responses.
pub fn dispatch(
    params: &Value,
    scalar: impl Fn(&Value) -> Result<Value, RpcError>,
) -> Result<Value, RpcError> {
    if !params[0]["to"]
        .as_str()
        .unwrap()
        .eq_ignore_ascii_case("0xca11bde05977b3631167028862be2a173976ca11")
    {
        return scalar(params);
    }
    assert!(params[1].as_str().unwrap().starts_with("0x"));
    let data = hex::decode(&params[0]["data"].as_str().unwrap()[2..]).unwrap();
    let call = IMulticall3::aggregate3Call::abi_decode_validate(&data).unwrap();
    assert!(!call.calls.is_empty());
    let mut results = Vec::new();
    for input in call.calls {
        assert!(!input.allowFailure);
        let value = scalar(&json!([{
            "to": format!("{:#x}", input.target),
            "data": format!("0x{}", hex::encode(input.callData)),
        }, params[1]]))?;
        results.push(IMulticall3::Result {
            success: true,
            returnData: hex::decode(&value.as_str().unwrap()[2..]).unwrap().into(),
        });
    }
    Ok(json!(format!(
        "0x{}",
        hex::encode(IMulticall3::aggregate3Call::abi_encode_returns(&results))
    )))
}
