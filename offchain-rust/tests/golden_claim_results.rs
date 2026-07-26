use serde_json::{Value, json};
use usd8_settlement::compute_json;

#[test]
fn pre_crafted_claim_results_match_golden_vectors() {
    let vectors: Value =
        serde_json::from_str(include_str!("../../test-vectors/golden-claim-results.json")).unwrap();

    for vector in vectors.as_array().unwrap() {
        let name = vector["name"].as_str().unwrap();
        assert!(
            !vector["derivation"].as_array().unwrap().is_empty(),
            "{name}: missing independent derivation"
        );
        let actual: Value = serde_json::from_str(
            &compute_json(&serde_json::to_string(&vector["input"]).unwrap()).unwrap(),
        )
        .unwrap();
        let projected_rows = actual["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                json!({
                    "claimId": row["claimId"],
                    "eligibleAmount": row["eligibleAmount"],
                    "lossUsd": row["lossUsd"],
                    "earnedScore": row["earnedScore"],
                    "scoreSpent": row["scoreSpent"],
                    "boostedScore": row["boostedScore"],
                    "payoutUsd": row["payoutUsd"],
                    "amounts": row["amounts"],
                })
            })
            .collect::<Vec<_>>();
        let projected = json!({
            "rows": projected_rows,
            "poolPayouts": actual["poolPayouts"],
        });
        assert_eq!(projected, vector["expected"], "{name}");
    }
}
