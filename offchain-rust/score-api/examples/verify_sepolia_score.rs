use std::env;
use std::str::FromStr;
use usd8_score_api::compute_incremental_score;
use usd8_settlement::Address;
use usd8_settlement::rpc::HttpRpc;
use usd8_settlement::score::insurance_score_at;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = env::args().skip(1);
    let registry = Address::from_str(&arguments.next().ok_or("missing registry")?)
        .map_err(|()| "invalid registry")?;
    let account = Address::from_str(&arguments.next().ok_or("missing account")?)
        .map_err(|()| "invalid account")?;
    if arguments.next().is_some() {
        return Err("unexpected extra argument".into());
    }
    let rpc_url =
        env::var("USD8_SCORE_RPC_URL").unwrap_or_else(|_| "https://sepolia.drpc.org".to_owned());
    let rpc = HttpRpc::new(&rpc_url, None, 10_000)?;

    let full = insurance_score_at(&rpc, registry, account).await?;
    let (first, checkpoint) = compute_incremental_score(&rpc, registry, account, None).await?;
    let (second, _) = compute_incremental_score(&rpc, registry, account, Some(checkpoint)).await?;

    if first.gross_earned_score != full.gross_earned_score
        || first.score_spent != full.score_spent
        || first.available_score != full.available_score
    {
        return Err("incremental result differs from full replay".into());
    }
    if second.gross_earned_score != first.gross_earned_score
        || second.score_spent != first.score_spent
        || second.available_score != first.available_score
    {
        return Err("checkpoint hit differs from initial replay".into());
    }
    println!(
        "SCORE_CACHE_PARITY account={} referenceBlock={} cutoff={} gross={} spent={} available={} first={} second={} firstLogRequests={} secondLogRequests={}",
        account,
        second.reference_block,
        second.score_cutoff_block,
        second.gross_earned_score,
        second.score_spent,
        second.available_score,
        first.cache_status,
        second.cache_status,
        first.log_requests,
        second.log_requests,
    );
    Ok(())
}
