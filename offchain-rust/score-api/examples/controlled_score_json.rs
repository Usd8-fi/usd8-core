use std::env;
use std::str::FromStr;
use usd8_score_api::{ScoreNetwork, compute_incremental_score, compute_incremental_score_at};
use usd8_settlement::Address;
use usd8_settlement::chain::block_by_number;
use usd8_settlement::rpc::HttpRpc;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = env::args().skip(1);
    let registry = Address::from_str(&arguments.next().ok_or("missing registry")?)
        .map_err(|()| "invalid registry")?;
    let account = Address::from_str(&arguments.next().ok_or("missing account")?)
        .map_err(|()| "invalid account")?;
    let reference_block = arguments
        .next()
        .map(|value| value.parse::<u64>())
        .transpose()
        .map_err(|_| "invalid reference block")?;
    if arguments.next().is_some() {
        return Err("unexpected extra argument".into());
    }
    let rpc_url = env::var("USD8_SCORE_RPC_URL")?;
    let rpc = HttpRpc::new(&rpc_url, None, 30_000)?;
    let network = ScoreNetwork {
        chain_id: 11_155_111,
        name: "sepolia".to_owned(),
    };
    let (score, _) = if let Some(reference_block) = reference_block {
        let reference = block_by_number(&rpc, reference_block).await?;
        compute_incremental_score_at(&rpc, &network, registry, account, reference, None).await?
    } else {
        compute_incremental_score(&rpc, &network, registry, account, None).await?
    };
    println!("{}", serde_json::to_string(&score)?);
    Ok(())
}
