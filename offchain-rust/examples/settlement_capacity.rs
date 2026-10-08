//! Offline capacity probe using the real allocator, digest and artifact verifier.
//! One pool and distinct claimants; minimal or funded (18-decimal) records. No RPC
//! fetching, NSM attestation, KMS signing or live enclave execution is measured.
//! The prefix crossing uses a fixed header; rebuild at a candidate count to
//! measure a complete verified artifact. Leave additional room for attestation.
//!
//! cargo run --locked --example settlement_capacity -- 170000 67043328

use num_bigint::BigUint;
use std::collections::BTreeMap;
use std::str::FromStr;
use usd8_settlement::chain::{BlockAnchor, Incident, SettlementAnchors};
use usd8_settlement::config::BootstrapConfig;
use usd8_settlement::engine::{ScoreSourceMetadata, SettlementRun};
use usd8_settlement::rpc::{LogMetrics, RpcMetrics};
use usd8_settlement::typed_data::{SettlementDigestInput, settlement_digest};
use usd8_settlement::{
    Address, ClaimEvent, ClaimInput, EventKind, KernelInput, PoolInput, allocate_with_events,
};

fn address(n: u64) -> Address {
    Address::from_str(&format!("0x{n:040x}")).unwrap()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert!(
        (3..=4).contains(&args.len()),
        "usage: settlement_capacity CLAIMANTS ARTIFACT_BYTE_CAP [minimal|funded]"
    );
    let count: u64 = args[1].parse().expect("claimant count");
    let maximum: usize = args[2].parse().expect("artifact byte cap");
    assert!(count > 0 && maximum > 0);
    let profile = args.get(3).map(String::as_str).unwrap_or("minimal");
    assert!(["minimal", "funded"].contains(&profile));
    let funded = profile == "funded";
    let started = std::time::Instant::now();
    let zero = BigUint::from(0u8);
    let wad = BigUint::from(1_000_000_000_000_000_000u64);
    let amount = if funded { wad.clone() } else { 1u8.into() };
    let score = if funded { wad.clone() } else { zero.clone() };
    let held = if funded { wad.clone() } else { zero.clone() };
    let mut claims = Vec::with_capacity(count as usize);
    let mut events = Vec::with_capacity(count as usize);
    for id in 1..=count {
        claims.push(ClaimInput {
            claim_id: id.into(),
            user: address(id + 100),
            escrow_amount: amount.clone(),
            min_held: held.clone(),
            gross_earned_score: score.clone(),
            spent_score: zero.clone(),
            score_to_spend: score.clone(),
            booster_amount: zero.clone(),
            booster_held: zero.clone(),
        });
        events.push(ClaimEvent {
            kind: EventKind::Register,
            claim_id: id.into(),
            user: address(id + 100),
            amount: amount.clone(),
            score_to_spend: score.clone(),
            booster_amount: zero.clone(),
            block_number: 100 + id / 100,
            log_index: id % 100,
        });
    }
    let output = allocate_with_events(
        &KernelInput {
            incident_id: BigUint::from(1u8),
            coverage_bps: BigUint::from(8000u16),
            booster_boost_bps: BigUint::from(500u16),
            insured_decimals: 18,
            twap_ratio: wad.clone(),
            underlying_usd: wad.clone(),
            max_cover_pool_payout_bps: BigUint::from(3000u16),
            protocol_fee_share_bps: BigUint::from(2000u16),
            pools: vec![PoolInput {
                balance: wad.clone(),
                asset_usd: wad,
                asset_decimals: 18,
            }],
            claims,
        },
        &events,
    )
    .unwrap();
    let hash = format!("0x{:064x}", 1);
    let zero_hash = format!("0x{:064x}", 0);
    let incident = Incident {
        insured_token: address(3),
        resolved_at: 0,
        reference_block: 90,
        open_block: 100,
        phase_deadline: 100_000,
        root: zero_hash,
        unresolved_claims: count.into(),
        claim_set_hash: output.claim_set_hash.clone(),
        tee_pcr_hash: hash.clone(),
        protocol_fee_share_bps: BigUint::from(2000u16),
    };
    let anchor = |n: u64| BlockAnchor {
        number: n,
        timestamp: n * 12,
        hash: format!("0x{n:064x}"),
    };
    let config = BootstrapConfig::derived(
        address(1),
        address(2),
        1,
        500,
        BTreeMap::from([(address(4), address(5))]),
        86400,
    )
    .unwrap();
    let digest = settlement_digest(&SettlementDigestInput {
        chain_id: config.chain_id,
        verifying_contract: config.defi_insurance,
        incident_id: BigUint::from(1u8),
        root: output.root.clone(),
        unresolved_claims: count.into(),
        pool_payouts: output.pool_payouts.clone(),
        pool_addrs: vec![address(6)],
        claim_set: output.claim_set_hash.clone(),
        tee_pcr_hash: hash.clone(),
    })
    .unwrap();
    let run = SettlementRun {
        incident_id: BigUint::from(1u8),
        incident: incident.clone(),
        window_incident: incident.clone(),
        latest_incident: incident,
        anchors: SettlementAnchors {
            reference: anchor(90),
            open: anchor(100),
            window_end: anchor(100_000 / 12),
            finalized_head: anchor(100_000 / 12 + 1),
        },
        config_hash: config.hash().unwrap(),
        tee_pcr_hash: hash,
        pool_order: vec![address(4)],
        pool_addrs: vec![address(6)],
        twap_ratio: BigUint::from(1_000_000_000_000_000_000u64),
        underlying_usd: BigUint::from(1_000_000_000_000_000_000u64),
        events,
        output,
        digest,
        score_source: ScoreSourceMetadata::Bulk {
            as_of_block: 80,
            as_of_block_hash: format!("0x{:064x}", 80),
            indexed_transfers: 0,
            indexed_tokens: 2,
            tracked_accounts: count as usize,
        },
        rpc_metrics: RpcMetrics::default(),
        log_metrics: LogMetrics::default(),
    };
    usd8_settlement::artifact::verify_run(&run, &config).unwrap();
    let artifact = usd8_settlement::attested_runtime::artifact_for_attestation(&run, &config);
    assert!(artifact["rows"][0].get("proof").is_none());
    let size = serde_json::to_vec(&artifact).unwrap().len();
    println!(
        "verified {count}-row {profile} production artifact without proofs or attestation: {size} bytes; configured artifact maximum: {maximum} bytes"
    );
    println!(
        "fits byte cap before attestation: {}; remaining bytes: {}; elapsed: {:?}",
        size <= maximum,
        maximum as i64 - size as i64,
        started.elapsed()
    );

    // Measure representation capacity for this fixed workload; this does not
    // measure chain execution costs, historical RPC throughput, or deadlines.
    let rows = artifact["rows"].as_array().unwrap();
    let input_rows = artifact["settlementInputRows"].as_array().unwrap();
    let rows_size: usize = rows
        .iter()
        .map(|row| serde_json::to_vec(row).unwrap().len())
        .sum();
    let inputs_size: usize = input_rows
        .iter()
        .map(|row| serde_json::to_vec(row).unwrap().len())
        .sum();
    let mut running_size = size - rows_size - inputs_size - 2 * (rows.len() - 1);
    for index in 0..rows.len() {
        running_size += serde_json::to_vec(&rows[index]).unwrap().len()
            + serde_json::to_vec(&input_rows[index]).unwrap().len()
            + if index == 0 { 0 } else { 2 };
        if running_size > maximum {
            println!(
                "fixed-header JSON representation first exceeds artifact cap at {} rows: {} bytes (attestation absent)",
                index + 1,
                running_size
            );
            break;
        }
    }
}
