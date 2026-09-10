//! Independent discovery promotion gate. No signer key, KMS, or parent-supplied policy.
//! `verify_candidate` is NOT authorization: only `verif...ion` may gate publication.
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use serde_json::Value;
use sha3::{Digest, Keccak256};
use std::{collections::HashSet, str::FromStr};
use usd8_settlement::typed_data::{SettlementDigestInput, settlement_digest};
use usd8_settlement::{Address, MerkleRow, SettlementTree};

#[derive(Clone, Debug)]
pub struct PromotionPolicy {
    pub chain_id: u64,
    pub registry: Address,
    pub defi_insurance: Address,
}
#[derive(Debug, thiserror::Error)]
pub enum VerificationError {
    #[error("invalid settlement: {0}")]
    Invalid(&'static str),
    #[error("chain verification failed: {0}")]
    Chain(#[from] usd8_settlement::chain::ChainError),
    #[error("RPC verification failed: {0}")]
    Rpc(#[from] usd8_settlement::rpc::RpcError),
}
type Result<T> = std::result::Result<T, VerificationError>;
fn require(ok: bool, why: &'static str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(VerificationError::Invalid(why))
    }
}
// RPC evidence is not the uploaded artifact. Missing/malformed/inconsistent
// provider data and changed canonical anchors are retryable, never authority.
fn evidence<T>(result: Result<T>) -> Result<T> {
    result.map_err(|e| match e {
        VerificationError::Invalid(why) => usd8_settlement::rpc::RpcError::InvalidResponse {
            method: "settlement evidence".into(),
            message: why.into(),
        }
        .into(),
        other => other,
    })
}
fn evidence_require(ok: bool, why: &'static str) -> Result<()> {
    evidence(require(ok, why))
}
fn evidence_input(v: &Value) -> Result<&str> {
    let s = evidence(text(v))?;
    evidence_require(
        s.strip_prefix("0x")
            .is_some_and(|raw| raw.len() % 2 == 0 && raw.bytes().all(|b| b.is_ascii_hexdigit())),
        "malformed RPC calldata",
    )?;
    Ok(s)
}

fn text(v: &Value) -> Result<&str> {
    v.as_str()
        .ok_or(VerificationError::Invalid("expected string"))
}
fn decimal<T: FromStr>(v: &Value) -> Result<T> {
    let s = text(v)?;
    const MAX: &str =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    require(
        !s.is_empty()
            && s.bytes().all(|b| b.is_ascii_digit())
            && (s == "0" || !s.starts_with('0'))
            && (s.len() < MAX.len() || (s.len() == MAX.len() && s <= MAX)),
        "noncanonical uint256",
    )?;
    s.parse()
        .map_err(|_| VerificationError::Invalid("integer overflow"))
}
fn address(v: &Value) -> Result<Address> {
    text(v)?
        .parse()
        .map_err(|_| VerificationError::Invalid("address"))
}
fn bytes(v: &Value, size: usize) -> Result<Vec<u8>> {
    let raw = text(v)?
        .strip_prefix("0x")
        .ok_or(VerificationError::Invalid("hex prefix"))?;
    require(raw.len() == size * 2, "hex width")?;
    hex::decode(raw).map_err(|_| VerificationError::Invalid("hex encoding"))
}
fn hash(v: &Value) -> Result<String> {
    Ok(format!("0x{}", hex::encode(bytes(v, 32)?)))
}
fn array(v: &Value) -> Result<&Vec<Value>> {
    v.as_array().ok_or(VerificationError::Invalid("array"))
}

/// Cryptographically self-consistent, but not yet an authorized publication.
#[derive(Debug)]
pub struct Candidate {
    input: SettlementDigestInput,
    digest: String,
    signer: Address,
    signature: Vec<u8>,
    fee_bps: u64,
    reference_block: u64,
}
impl Candidate {
    pub fn digest(&self) -> &str {
        &self.digest
    }
    pub fn signer(&self) -> Address {
        self.signer
    }
}

pub fn verify_candidate(
    policy: &PromotionPolicy,
    incident_id: &str,
    artifact: &Value,
) -> Result<Candidate> {
    require(
        policy.chain_id != 0 && !policy.registry.is_zero() && !policy.defi_insurance.is_zero(),
        "invalid trusted policy",
    )?;
    require(
        artifact["schemaVersion"] == 2 && artifact["chainId"].as_u64() == Some(policy.chain_id),
        "schema/network",
    )?;
    require(
        address(&artifact["registry"])? == policy.registry
            && address(&artifact["defiInsurance"])? == policy.defi_insurance,
        "protocol binding",
    )?;
    require(
        text(&artifact["incidentId"])? == incident_id,
        "incident locator",
    )?;
    let input = SettlementDigestInput {
        chain_id: policy.chain_id,
        verifying_contract: policy.defi_insurance,
        incident_id: decimal(&artifact["incidentId"])?,
        root: hash(&artifact["root"])?,
        unresolved_claims: decimal(&artifact["unresolvedClaims"])?,
        pool_payouts: array(&artifact["poolPayouts"])?
            .iter()
            .map(decimal)
            .collect::<Result<_>>()?,
        pool_addrs: array(&artifact["poolAddrs"])?
            .iter()
            .map(address)
            .collect::<Result<_>>()?,
        claim_set: hash(&artifact["claimSetHash"])?,
        tee_pcr_hash: hash(&artifact["teePcrHash"])?,
    };
    require(
        input.incident_id != 0u8.into() && input.root != format!("0x{}", "00".repeat(32)),
        "zero incident/root",
    )?;
    require(
        input.pool_addrs.len() == input.pool_payouts.len()
            && input.pool_addrs.iter().all(|a| !a.is_zero())
            && input.pool_addrs.iter().collect::<HashSet<_>>().len() == input.pool_addrs.len(),
        "pool shape",
    )?;
    let fee_bps: u64 = decimal(&artifact["protocolFeeShareBps"])?;
    require(fee_bps <= 2000, "fee cap")?;
    let rows = array(&artifact["rows"])?
        .iter()
        .map(|r| {
            Ok(MerkleRow {
                claim_id: decimal(&r["claimId"])?,
                user: address(&r["user"])?,
                amounts: array(&r["amounts"])?
                    .iter()
                    .map(decimal)
                    .collect::<Result<_>>()?,
                score_spent: decimal(&r["scoreSpent"])?,
                boosted_score: decimal(&r["boostedScore"])?,
                eligible_amount: decimal(&r["eligibleAmount"])?,
                eligible_booster_amount: decimal(&r["eligibleBoosterAmount"])?,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    require(input.unresolved_claims == rows.len().into(), "row count")?;
    let tree = SettlementTree::new(&input.incident_id, &rows)
        .map_err(|_| VerificationError::Invalid("Merkle rows"))?;
    require(tree.root_hex() == input.root, "Merkle root")?;
    let mut totals = input.pool_payouts.clone();
    totals.fill(Default::default());
    for (r, json_row) in rows.iter().zip(array(&artifact["rows"])?) {
        require(r.amounts.len() == totals.len(), "row pool width")?;
        for (total, amount) in totals.iter_mut().zip(&r.amounts) {
            *total += (amount * 10000u64) / (10000 - fee_bps);
        }
        if let Some(proof) = json_row.get("proof") {
            let actual = array(proof)?.iter().map(hash).collect::<Result<Vec<_>>>()?;
            require(
                actual
                    == tree
                        .proof_hex(&r.claim_id)
                        .map_err(|_| VerificationError::Invalid("proof"))?,
                "proof mismatch",
            )?;
        }
    }
    require(totals == input.pool_payouts, "gross pool totals")?;
    let digest = settlement_digest(&input).map_err(|_| VerificationError::Invalid("typed data"))?;
    require(
        hash(&artifact["settlementDigest"])? == digest,
        "digest mismatch",
    )?;
    let signature = bytes(&artifact["signature"], 65)?;
    require(matches!(signature[64], 27 | 28), "signature v")?;
    let sig = Signature::from_slice(&signature[..64])
        .map_err(|_| VerificationError::Invalid("signature scalars"))?;
    require(sig.normalize_s().is_none(), "high-s signature")?;
    let key = VerifyingKey::recover_from_prehash(
        &bytes(&Value::String(digest.clone()), 32)?,
        &sig,
        RecoveryId::from_byte(signature[64] - 27)
            .ok_or(VerificationError::Invalid("recovery id"))?,
    )
    .map_err(|_| VerificationError::Invalid("signature recovery"))?;
    let public = key.to_encoded_point(false);
    let recovered = Keccak256::digest(&public.as_bytes()[1..]);
    let signer = Address::from_bytes(recovered[12..].try_into().expect("20 bytes"));
    // Metadata can detect corruption; it never grants authority.
    require(
        address(&artifact["signer"])? == signer,
        "declared signer mismatch",
    )?;
    Ok(Candidate {
        input,
        digest,
        signer,
        signature,
        fee_bps,
        reference_block: decimal(&artifact["referenceBlock"])?,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Authorization {
    CurrentSigner,
    AcceptedOnchain,
}
#[derive(Debug)]
pub struct VerifiedSettlement {
    block: usd8_settlement::chain::BlockAnchor,
    authorization: Authorization,
}
impl VerifiedSettlement {
    pub fn block(&self) -> &usd8_settlement::chain::BlockAnchor {
        &self.block
    }
    pub fn authorization(&self) -> Authorization {
        self.authorization
    }
}
use usd8_settlement::chain;
use usd8_settlement::rpc::Rpc;

// One budget per verification, shared by all chain reads, log subdivisions,
// receipt fallbacks and traces. HttpRpc separately bounds pre-JSON wire bytes
// and transport retries; this cap counts logical requests and conservative
// decoded JSON bytes (including escaping), not unobservable wire whitespace.
const VERIFICATION_RPC_CAP: usize = 256;
const VERIFICATION_BYTE_CAP: usize = 8 * 1024 * 1024;
struct BudgetRpc<'a, R: ?Sized> {
    inner: &'a R,
    remaining: std::sync::Mutex<(usize, usize)>,
}
#[async_trait::async_trait]
impl<R: Rpc + ?Sized> Rpc for BudgetRpc<'_, R> {
    fn metrics(&self) -> usd8_settlement::rpc::RpcMetrics {
        self.inner.metrics()
    }
    async fn request(
        &self,
        method: &str,
        params: Value,
    ) -> std::result::Result<Value, usd8_settlement::rpc::RpcError> {
        use usd8_settlement::rpc::RpcError;
        {
            let mut budget = self.remaining.lock().expect("verification budget");
            budget.0 = budget
                .0
                .checked_sub(1)
                .ok_or(RpcError::LogBudgetExceeded("verification requests"))?;
        }
        let value = self.inner.request(method, params).await?;
        let mut budget = self.remaining.lock().expect("verification budget");
        bounded_evidence(&value, &mut budget.1)
            .map_err(|_| RpcError::LogBudgetExceeded("verification bytes/depth/nodes"))?;
        Ok(value)
    }
}

fn abi_word(bytes: &[u8]) -> Vec<u8> {
    let mut word = vec![0; 32 - bytes.len()];
    word.extend_from_slice(bytes);
    word
}
fn selector(signature: &str) -> Vec<u8> {
    Keccak256::digest(signature.as_bytes())[..4].to_vec()
}
async fn call<R: Rpc + ?Sized>(
    rpc: &R,
    to: Address,
    signature: &str,
    args: &[u8],
    block: u64,
) -> Result<Vec<u8>> {
    let mut data = selector(signature);
    data.extend_from_slice(args);
    Ok(chain::raw_call(rpc, to, &data, Some(block)).await?)
}
async fn bindings<R: Rpc + ?Sized>(rpc: &R, policy: &PromotionPolicy, block: u64) -> Result<()> {
    for a in [policy.registry, policy.defi_insurance] {
        chain::assert_contract_code_at(rpc, &a.to_string(), "canonical contract", block).await?;
    }
    require(
        chain::defi_insurance_at(rpc, policy.registry, Some(block)).await? == policy.defi_insurance,
        "Registry module",
    )?;
    require(
        call(rpc, policy.defi_insurance, "registry()", &[], block).await?
            == abi_word(policy.registry.as_slice()),
        "module Registry",
    )
}

/// Match the actual successfully executed settlement call, not a contemporary
/// allowlist nor a caller-selected historical block. The EVM checked isTeeSigner
/// at execution (including same-block rotations). The standing root must still
/// match. Remaining poolBudget/unresolvedClaims are deliberately not used here.
/// Wrappers use bounded trusted-RPC callTracer evidence; no trace means unavailable.
async fn accepted_onchain<R: Rpc + ?Sized>(
    rpc: &R,
    policy: &PromotionPolicy,
    candidate: &Candidate,
    from: u64,
    to: u64,
) -> Result<()> {
    use serde_json::json;
    use usd8_settlement::rpc::{LogFilter, get_logs_chunked};
    let input = &candidate.input;
    let topic = format!(
        "0x{}",
        hex::encode(Keccak256::digest(
            b"IncidentSettled(uint256,bytes32,bytes32)"
        ))
    );
    let incident_topic = format!(
        "0x{}",
        hex::encode(abi_word(&input.incident_id.to_bytes_be()))
    );
    let filter = LogFilter {
        address: policy.defi_insurance.to_string(),
        topics: vec![json!(topic), json!(incident_topic)],
    };
    let expected_data = format!("{}{}", input.root, &input.tee_pcr_hash[2..]);
    let mut start = from;
    while start <= to {
        let end = start
            .saturating_add(usd8_settlement::config::MAX_LOG_RANGE - 1)
            .min(to);
        let (logs, _) = get_logs_chunked(
            rpc,
            &filter,
            start,
            end,
            usd8_settlement::config::MAX_LOG_RANGE,
            usd8_settlement::config::LOG_RESULT_CAP,
        )
        .await?;
        for log in logs {
            if log.data != expected_data || log.topics.len() != 2 {
                continue;
            }
            let anchor = chain::block_by_number(rpc, log.block_number).await?;
            let tx = rpc
                .request("eth_getTransactionByHash", json!([log.transaction_hash]))
                .await?;
            let receipt = rpc
                .request("eth_getTransactionReceipt", json!([log.transaction_hash]))
                .await?;
            // Any malformed evidence fails closed rather than falling through to a
            // current/historical signer shortcut.
            evidence_require(
                evidence(hash(&tx["hash"]))? == log.transaction_hash
                    && evidence(hash(&receipt["transactionHash"]))? == log.transaction_hash,
                "acceptance transaction identity",
            )?;
            evidence_require(
                chain::quantity(&tx["blockNumber"], "tx block")? == log.block_number
                    && chain::quantity(&receipt["blockNumber"], "receipt block")?
                        == log.block_number
                    && evidence(hash(&tx["blockHash"]))? == anchor.hash
                    && evidence(hash(&receipt["blockHash"]))? == anchor.hash,
                "acceptance block binding",
            )?;
            evidence_require(
                chain::quantity(&receipt["status"], "receipt status")? == 1,
                "reverted acceptance",
            )?;
            let matching_log = evidence(array(&receipt["logs"]))?.iter().any(|entry| {
                entry["address"]
                    .as_str()
                    .is_some_and(|a| a.eq_ignore_ascii_case(&log.address))
                    && entry["topics"] == json!(log.topics)
                    && entry["data"].as_str() == Some(log.data.as_str())
                    && entry["transactionHash"].as_str() == Some(log.transaction_hash.as_str())
                    && entry["blockHash"].as_str() == Some(anchor.hash.as_str())
                    && entry["blockNumber"].as_str()
                        == Some(format!("0x{:x}", log.block_number).as_str())
                    && entry["logIndex"].as_str() == Some(format!("0x{:x}", log.log_index).as_str())
                    && entry["removed"] == false
            });
            evidence_require(matching_log, "acceptance receipt event")?;
            let direct = !tx["to"].is_null()
                && evidence(address(&tx["to"]))? == policy.defi_insurance
                && settlement_call_matches(candidate, evidence_input(&tx["input"])?);
            if !direct && !traced_settlement(rpc, policy, candidate, &tx, &receipt).await? {
                continue;
            }
            bindings(rpc, policy, log.block_number).await?;
            evidence_require(
                chain::block_by_number(rpc, anchor.number).await?.hash == anchor.hash,
                "acceptance reorg",
            )?;
            return Ok(());
        }
        if end == to {
            break;
        }
        start = end + 1;
    }
    Err(VerificationError::Invalid(
        "no exact accepted settlement call",
    ))
}
const TRACE_METHOD: &str = "debug_traceTransaction";
const TRACE_BYTE_CAP: usize = 2 * 1024 * 1024;
fn trace_unavailable(message: &str) -> VerificationError {
    usd8_settlement::rpc::RpcError::InvalidResponse {
        method: TRACE_METHOD.into(),
        message: message.into(),
    }
    .into()
}

// HttpRpc enforces its transport byte cap before JSON parsing. Also cap the
// parsed evidence here for every Rpc implementation; iteration avoids recursive
// descent on an adversarial trace. Conservative JSON-escaped byte accounting is
// deliberate: resource-limit errors are retryable unavailable, never authority.
fn bounded_trace(value: &Value) -> Result<()> {
    let mut budget = TRACE_BYTE_CAP;
    bounded_evidence(value, &mut budget)
}
fn bounded_evidence(value: &Value, budget: &mut usize) -> Result<()> {
    let mut stack = vec![(value, 0usize)];
    let mut nodes = 0;
    while let Some((value, depth)) = stack.pop() {
        nodes += 1;
        if depth > 96 || nodes > 65536 {
            return Err(trace_unavailable("trace depth/node limit"));
        }
        let mut charge = 32usize;
        match value {
            Value::String(s) => charge = charge.saturating_add(s.len().saturating_mul(6)),
            Value::Array(a) => {
                if a.len() > 65536 {
                    return Err(trace_unavailable("trace array limit"));
                }
                stack.extend(a.iter().map(|v| (v, depth + 1)));
            }
            Value::Object(o) => {
                if o.len() > 65536 {
                    return Err(trace_unavailable("trace object limit"));
                }
                for (key, v) in o {
                    charge = charge.saturating_add(key.len().saturating_mul(6).saturating_add(4));
                    stack.push((v, depth + 1));
                }
            }
            _ => (),
        }
        *budget = budget.checked_sub(charge).ok_or_else(|| {
            VerificationError::Rpc(usd8_settlement::rpc::RpcError::ResponseTooLarge {
                method: TRACE_METHOD.into(),
                limit: TRACE_BYTE_CAP,
            })
        })?;
    }
    Ok(())
}

async fn traced_settlement<R: Rpc + ?Sized>(
    rpc: &R,
    policy: &PromotionPolicy,
    candidate: &Candidate,
    tx: &Value,
    receipt: &Value,
) -> Result<bool> {
    let trace = rpc.request(TRACE_METHOD, serde_json::json!([
        tx["hash"], {"tracer":"callTracer", "timeout":"5s", "tracerConfig":{"onlyTopCall":false}}
    ])).await?;
    bounded_trace(&trace)?;
    if !trace.is_object() || trace["type"].as_str().is_none() {
        return Err(trace_unavailable("callTracer result unavailable"));
    }
    // Trace by the hash already bound to a successful receipt and canonical
    // block. Bind its outer frame to the mined transaction too (not trace JSON
    // supplied by the candidate). Recheck that block after examining execution.
    let (outer_type, outer_to) = if tx["to"].is_null() {
        ("CREATE", &receipt["contractAddress"])
    } else {
        ("CALL", &tx["to"])
    };
    evidence_require(
        trace["type"] == outer_type
            && evidence(address(&trace["from"]))? == evidence(address(&tx["from"]))?
            && evidence(address(&trace["to"]))? == evidence(address(outer_to))?
            && evidence_input(&trace["input"])?.eq_ignore_ascii_case(evidence_input(&tx["input"])?)
            && trace["value"] == tx["value"],
        "trace transaction binding",
    )?;
    let mut stack = vec![&trace];
    while let Some(frame) = stack.pop() {
        if !matches!(
            frame["type"].as_str(),
            Some(
                "CALL"
                    | "STATICCALL"
                    | "DELEGATECALL"
                    | "CALLCODE"
                    | "CREATE"
                    | "CREATE2"
                    | "SELFDESTRUCT"
            )
        ) {
            return Err(trace_unavailable("malformed callTracer frame"));
        }
        // A successful child below a reverted ancestor never committed state.
        // Prune the entire subtree; independently successful siblings remain.
        if !frame["error"].is_null() || !frame["revertReason"].is_null() {
            continue;
        }
        // DELEGATECALL/CALLCODE to the module is not execution in its storage
        // context. Such frames may be wrapper ancestors, but never evidence.
        if frame["type"] == "CALL"
            && evidence(address(&frame["to"]))? == policy.defi_insurance
            && settlement_call_matches(candidate, evidence_input(&frame["input"])?)
        {
            return Ok(true);
        }
        if let Some(children) = frame.get("calls") {
            let children = children
                .as_array()
                .ok_or_else(|| trace_unavailable("malformed callTracer children"))?;
            stack.extend(children.iter());
        }
    }
    Ok(false)
}

// Decode Solidity's accepted dynamic-argument layout, not canonical encoding.
// Offsets are relative to the arguments (after selector). Do not require aligned
// or ordered tails, zero padding, or absence of trailing data. Every slice and
// machine-sized offset/length conversion is checked before indexing/allocation.
fn settlement_call_matches(candidate: &Candidate, input: &str) -> bool {
    fn range(data: &[u8], start: usize, len: usize) -> Option<&[u8]> {
        data.get(start..start.checked_add(len)?)
    }
    fn size(data: &[u8], start: usize) -> Option<usize> {
        range(data, start, 32)?.iter().try_fold(0usize, |n, b| {
            n.checked_mul(256)?.checked_add(usize::from(*b))
        })
    }
    fn matches(candidate: &Candidate, input: &str) -> Option<bool> {
        let data = hex::decode(input.strip_prefix("0x")?).ok()?;
        if range(&data, 0, 4)? != selector("settleIncident(bytes32,uint256[],bytes)") {
            return Some(false);
        }
        let args = data.get(4..)?;
        range(args, 0, 96)?;
        if range(args, 0, 32)? != hex::decode(&candidate.input.root[2..]).ok()? {
            return Some(false);
        }
        let payouts = size(args, 32)?;
        let signature = size(args, 64)?;
        let count = size(args, payouts)?;
        if count != candidate.input.pool_payouts.len() || size(args, signature)? != 65 {
            return Some(false);
        }
        let words = range(args, payouts.checked_add(32)?, count.checked_mul(32)?)?;
        if !words
            .chunks_exact(32)
            .zip(&candidate.input.pool_payouts)
            .all(|(word, payout)| word == abi_word(&payout.to_bytes_be()))
        {
            return Some(false);
        }
        Some(range(args, signature.checked_add(32)?, 65)? == candidate.signature)
    }
    matches(candidate, input).unwrap_or(false)
}

/// Accepts the exact `TerminalEnvelope.payload` shape emitted by enclave.rs.
/// Envelope job/request validation remains the service's responsibility.
/// See `verify_for_promotion` for the authenticated subset and unverified metadata.
pub async fn verify_result_for_promotion<R: Rpc + ?Sized>(
    rpc: &R,
    policy: &PromotionPolicy,
    incident_id: &str,
    result: &Value,
) -> Result<VerifiedSettlement> {
    require(
        hash(&result["digest"])? == hash(&result["artifact"]["settlementDigest"])?,
        "outer digest",
    )?;
    let mut artifact = result["artifact"].clone();
    let object = artifact
        .as_object_mut()
        .ok_or(VerificationError::Invalid("artifact object"))?;
    require(
        !object.contains_key("signature")
            && !object.contains_key("signer")
            && !object.contains_key("digest"),
        "ambiguous signature metadata",
    )?;
    object.insert("signature".into(), result["signature"].clone());
    object.insert("signer".into(), result["signer"].clone());
    verify_for_promotion(rpc, policy, incident_id, &artifact).await
}

/// Authenticates the EIP-712 domain and settlement payload, recovered signer,
/// canonical incident/window/pool/PCR/fee bindings, Merkle rows/proofs and gross
/// row totals, with current authorization or exact historical execution evidence.
/// It does NOT validate attached Nitro/KMS attestation documents or their metadata,
/// independently recompute economic eligibility/prices/score derivation, or sign
/// unsigned diagnostics (e.g. settlementInputHash, payoutUsd, RPC metrics). Merkle
/// row values are commitment-checked, not independently economically recomputed.
/// Downstream callers must not call the entire envelope independently attested.
/// Production async interface. Pass a bounded, trusted-config `HttpRpc`, never an
/// RPC endpoint, network, Registry, or module taken from the uploaded JSON.
/// Reads one finalized state, then rechecks its hash. No S3 write is performed.
/// A caller must await this result BEFORE any conditional shared-index creation.
pub async fn verify_for_promotion<R: Rpc + ?Sized>(
    rpc: &R,
    policy: &PromotionPolicy,
    incident_id: &str,
    artifact: &Value,
) -> Result<VerifiedSettlement> {
    let candidate = verify_candidate(policy, incident_id, artifact)?;
    let budgeted = BudgetRpc {
        inner: rpc,
        remaining: std::sync::Mutex::new((VERIFICATION_RPC_CAP, VERIFICATION_BYTE_CAP)),
    };
    let rpc = &budgeted;
    require(
        chain::chain_id(rpc).await? == policy.chain_id,
        "RPC network",
    )?;
    let head = chain::finalized_block(rpc).await?;
    let latest = chain::latest_block(rpc).await?;
    evidence_require(
        head.number <= latest.number && head.timestamp <= latest.timestamp,
        "impossible finalized head",
    )?;
    bindings(rpc, policy, head.number).await?;
    let input = &candidate.input;
    let inc = chain::incident_at(
        rpc,
        policy.defi_insurance,
        input.incident_id.clone(),
        Some(head.number),
    )
    .await?;
    require(
        inc.open_block > 0
            && inc.open_block <= head.number
            && inc.reference_block == candidate.reference_block
            && inc.reference_block <= inc.open_block
            && !inc.insured_token.is_zero(),
        "incident anchors",
    )?;
    require(
        inc.tee_pcr_hash == input.tee_pcr_hash
            && inc.tee_pcr_hash != format!("0x{}", "00".repeat(32))
            && inc.protocol_fee_share_bps == candidate.fee_bps.into(),
        "incident PCR/fee snapshot",
    )?;
    let id_word = abi_word(&input.incident_id.to_bytes_be());
    let mut expected_pools = abi_word(&[32]);
    expected_pools.extend(abi_word(&input.pool_addrs.len().to_be_bytes()));
    for pool in &input.pool_addrs {
        expected_pools.extend(abi_word(pool.as_slice()));
    }
    require(
        call(
            rpc,
            policy.defi_insurance,
            "incidentPools(uint256)",
            &id_word,
            head.number,
        )
        .await?
            == expected_pools,
        "incident pool order",
    )?;
    let deadline = chain::incident_claim_deadline_at(
        rpc,
        policy.defi_insurance,
        &input.incident_id,
        inc.open_block,
    )
    .await?;
    require(head.timestamp > deadline, "claim window not finalized")?;
    let window_number = chain::block_at_or_before_timestamp(rpc, deadline, head.number).await?;
    let window = chain::block_by_number(rpc, window_number).await?;
    let snapshot = chain::incident_at(
        rpc,
        policy.defi_insurance,
        input.incident_id.clone(),
        Some(window_number),
    )
    .await?;
    require(
        snapshot.unresolved_claims == input.unresolved_claims
            && snapshot.claim_set_hash == input.claim_set
            && snapshot.tee_pcr_hash == input.tee_pcr_hash,
        "claim-window snapshot",
    )?;
    let auth = call(
        rpc,
        policy.defi_insurance,
        "isTeeSigner(address)",
        &abi_word(candidate.signer.as_slice()),
        head.number,
    )
    .await?;
    require(
        auth == abi_word(&[0]) || auth == abi_word(&[1]),
        "signer ABI bool",
    )?;
    let authorization = if inc.root == format!("0x{}", "00".repeat(32)) {
        require(auth == abi_word(&[1]), "unauthorized signer")?;
        require(
            inc.resolved_at == 0
                && inc.unresolved_claims == input.unresolved_claims
                && inc.claim_set_hash == input.claim_set
                && inc.phase_deadline == deadline,
            "unsettled incident state",
        )?;
        Authorization::CurrentSigner
    } else {
        require(inc.root == input.root, "standing root mismatch")?;
        if auth == abi_word(&[1]) {
            // Recovery (including beta-corrected roots) is authenticated by the
            // current signer; it need not reuse the original signature bytes.
            Authorization::CurrentSigner
        } else {
            // phaseDeadline is at/after the last root commit, including beta
            // corrections that restart its window. Do NOT subtract today's
            // phase window or beta mode: neither identifies original acceptance.
            // Invalid/legacy bounds fall back to the head (still budgeted).
            let to = if inc.phase_deadline > deadline && inc.phase_deadline < head.timestamp {
                chain::block_at_or_before_timestamp(rpc, inc.phase_deadline, head.number).await?
            } else {
                head.number
            };
            accepted_onchain(rpc, policy, &candidate, window_number, to).await?;
            Authorization::AcceptedOnchain
        }
    };
    for anchor in [&head, &window] {
        evidence_require(
            chain::block_by_number(rpc, anchor.number).await?.hash == anchor.hash,
            "anchor changed",
        )?;
    }
    Ok(VerifiedSettlement {
        block: head,
        authorization,
    })
}
