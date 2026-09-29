use lambda_http::{Body, Error, Request, RequestExt, Response, service_fn};
use num_bigint::BigUint;
use serde_json::{Value, json};
use std::env;
use std::str::FromStr;
use usd8_settlement::Address;
use usd8_settlement::chain::{
    chain_id, earned_score_from_tokens, finalized_block, scored_tokens_at, spent_score_at,
};
use usd8_settlement::config::{CHAIN_ID, LOG_RESULT_CAP, MAX_LOG_RANGE};
use usd8_settlement::rpc::HttpRpc;

fn score_body(
    account: &str,
    as_of_block: u64,
    as_of_block_hash: &str,
    gross_earned_score: &BigUint,
    spent_score: &BigUint,
) -> Value {
    let available_score = if gross_earned_score > spent_score {
        gross_earned_score - spent_score
    } else {
        BigUint::from(0u8)
    };
    json!({
        "estimated": true,
        "account": account,
        "chainId": CHAIN_ID.to_string(),
        "asOfBlock": as_of_block.to_string(),
        "asOfBlockHash": as_of_block_hash,
        "grossEarnedScore": gross_earned_score.to_string(),
        "spentScore": spent_score.to_string(),
        "availableScore": available_score.to_string(),
    })
}

fn json_response(status: u16, body: Value) -> Result<Response<Body>, Error> {
    Ok(Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("access-control-allow-origin", "*")
        .header("access-control-allow-methods", "GET,OPTIONS")
        .header("access-control-allow-headers", "content-type")
        .body(Body::Text(body.to_string()))?)
}

async fn handler(request: Request) -> Result<Response<Body>, Error> {
    if request.method().as_str() == "OPTIONS" {
        return json_response(200, json!({}));
    }
    if request.method().as_str() != "GET" {
        return json_response(405, json!({ "error": "method not allowed" }));
    }

    let query = request.query_string_parameters();
    let Some(account_text) = query.first("account") else {
        return json_response(400, json!({ "error": "missing account query parameter" }));
    };
    let account = match Address::from_str(account_text) {
        Ok(account) if !account.is_zero() => account,
        _ => return json_response(400, json!({ "error": "invalid account" })),
    };
    let registry = match env::var("USD8_REGISTRY")
        .ok()
        .and_then(|value| Address::from_str(&value).ok())
        .filter(|address| !address.is_zero())
    {
        Some(registry) => registry,
        None => return json_response(500, json!({ "error": "service misconfigured" })),
    };
    let Ok(rpc_url) = env::var("ETH_RPC_URL") else {
        return json_response(500, json!({ "error": "service misconfigured" }));
    };
    let drpc_key = env::var("DRPC_KEY").ok().filter(|value| !value.is_empty());
    let rpc = match HttpRpc::new(&rpc_url, drpc_key.as_deref(), 30_000) {
        Ok(rpc) => rpc,
        Err(_) => return json_response(500, json!({ "error": "service misconfigured" })),
    };

    let finalized = match finalized_block(&rpc).await {
        Ok(block) => block,
        Err(_) => return json_response(502, json!({ "error": "RPC unavailable" })),
    };
    match chain_id(&rpc).await {
        Ok(actual) if actual == CHAIN_ID => {}
        Ok(_) => return json_response(503, json!({ "error": "wrong RPC chain" })),
        Err(_) => return json_response(502, json!({ "error": "RPC unavailable" })),
    }
    let scored_tokens = match scored_tokens_at(&rpc, registry, finalized.number).await {
        Ok(tokens) => tokens,
        Err(_) => return json_response(502, json!({ "error": "score configuration unavailable" })),
    };
    let scores = tokio::try_join!(
        earned_score_from_tokens(
            &rpc,
            &scored_tokens,
            account,
            finalized.number,
            MAX_LOG_RANGE,
            LOG_RESULT_CAP,
        ),
        spent_score_at(&rpc, registry, account, finalized.number),
    );
    let (gross_earned_score, spent_score) = match scores {
        Ok(((gross, _metrics), spent)) => (gross, spent),
        Err(_) => return json_response(502, json!({ "error": "score calculation unavailable" })),
    };

    json_response(
        200,
        score_body(
            &account.to_string(),
            finalized.number,
            &finalized.hash,
            &gross_earned_score,
            &spent_score,
        ),
    )
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    lambda_http::run(service_fn(handler)).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn score_body_reports_lifetime_and_available_score() {
        let body = score_body(
            "0x0000000000000000000000000000000000000001",
            123,
            "0xabc",
            &BigUint::from(900u16),
            &BigUint::from(250u16),
        );

        assert_eq!(body["estimated"], true);
        assert_eq!(body["grossEarnedScore"], "900");
        assert_eq!(body["spentScore"], "250");
        assert_eq!(body["availableScore"], "650");
        assert_eq!(body["asOfBlock"], "123");
        assert_eq!(body["asOfBlockHash"], "0xabc");
    }

    #[test]
    fn score_body_saturates_available_score_at_zero() {
        let body = score_body(
            "0x0000000000000000000000000000000000000001",
            123,
            "0xabc",
            &BigUint::from(10u8),
            &BigUint::from(11u8),
        );

        assert_eq!(body["availableScore"], "0");
    }
}
