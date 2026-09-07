use std::{env, str::FromStr};

use usd8_settlement::Address;
use usd8_settlement::incident_open::{IncidentOpenError, precheck_incident_open};
use usd8_settlement::rpc::HttpRpc;

#[tokio::main]
async fn main() {
    let arguments = env::args().collect::<Vec<_>>();
    if arguments.len() != 4 {
        eprintln!("usage: open_precheck_json <rpc-url> <registry> <insured-token>");
        std::process::exit(2);
    }
    let registry = Address::from_str(&arguments[2]).expect("invalid Registry address");
    let insured_token = Address::from_str(&arguments[3]).expect("invalid insured-token address");
    let rpc = HttpRpc::new(&arguments[1], None, 120_000).expect("invalid RPC configuration");

    match precheck_incident_open(&rpc, registry, insured_token).await {
        Ok(precheck) => println!(
            "{}",
            serde_json::json!({
                "complete": true,
                "qualifiedLoss": true,
                "healthyBaseline": false,
                "precheck": precheck,
            })
        ),
        Err(IncidentOpenError::InsufficientPriceDrop { minimum_drop_bps }) => println!(
            "{}",
            serde_json::json!({
                "complete": true,
                "qualifiedLoss": false,
                "healthyBaseline": true,
                "minimumDropBps": minimum_drop_bps,
                "reason": "InsufficientPriceDrop",
            })
        ),
        Err(error) => {
            println!(
                "{}",
                serde_json::json!({
                    "complete": false,
                    "qualifiedLoss": false,
                    "healthyBaseline": false,
                    "error": error.to_string(),
                })
            );
            std::process::exit(1);
        }
    }
}
