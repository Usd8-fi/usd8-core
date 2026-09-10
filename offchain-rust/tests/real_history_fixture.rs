use serde_json::Value;
use sha2::{Digest, Sha256};
use usd8_settlement::compute_json;

const FIXTURE: &str = include_str!("../fixtures/real-usdc-usdt-wsteth-300-6m.json");
const HISTORICAL_REPORT: &str =
    include_str!("../fixtures/provenance/benchmark-real-history-wsteth-300-6m-2026-07-15.json");
const REPLAY_RECORD: &str = include_str!("../fixtures/provenance/wsteth-300-current-replay.json");

fn sha256(value: &[u8]) -> String {
    hex::encode(Sha256::digest(value))
}

#[test]
fn real_history_fixture_has_explicit_provenance_and_current_replay() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let historical: Value = serde_json::from_str(HISTORICAL_REPORT).unwrap();
    let record: Value = serde_json::from_str(REPLAY_RECORD).unwrap();

    assert_eq!(sha256(FIXTURE.as_bytes()), record["fixture"]["sha256"]);
    assert_eq!(
        sha256(HISTORICAL_REPORT.as_bytes()),
        record["historicalReport"]["sha256"]
    );
    assert_eq!(record["scope"], historical["scope"]);

    let inputs = fixture["claims"].as_array().unwrap();
    let archived = historical["settlement"]["claims"].as_array().unwrap();
    assert_eq!(inputs.len(), 300);
    assert_eq!(inputs.len(), archived.len());
    for (input, prior) in inputs.iter().zip(archived) {
        for (input_key, prior_key) in [
            ("claimId", "claimId"),
            ("user", "user"),
            ("escrowAmount", "eligibleInsuredAmountRaw"),
            ("grossEarnedScore", "grossScoreRaw"),
            ("scoreToSpend", "scoreSpentRaw"),
        ] {
            assert_eq!(input[input_key], prior[prior_key]);
        }
    }

    let current: Value = serde_json::from_str(&compute_json(FIXTURE).unwrap()).unwrap();
    assert_eq!(
        current["claimSetHash"],
        record["currentReplay"]["claimSetHash"]
    );
    assert_eq!(
        current["settlementInputHash"],
        record["currentReplay"]["settlementInputHash"]
    );
    assert_eq!(current["root"], record["currentReplay"]["root"]);
    assert_eq!(
        current["poolPayouts"],
        record["currentReplay"]["poolPayouts"]
    );
    assert_ne!(current["root"], record["historicalReport"]["root"]);
}
