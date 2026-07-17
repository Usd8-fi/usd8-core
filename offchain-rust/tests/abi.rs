use alloy_sol_types::{SolCall, SolEvent};
use usd8_settlement::abi::{
    IAggregatorV3, IDefiInsurance, IERC20, IERC1155, IRegistry, ISingleAssetCoverPool,
};

#[test]
fn generated_function_selectors_match_solidity_authority() {
    assert_eq!(
        hex::encode(IDefiInsurance::incidentsCall::SELECTOR),
        "a6c6a8f3"
    );
    assert_eq!(
        hex::encode(IDefiInsurance::incidentTeePcrHashCall::SELECTOR),
        "03d88b70"
    );
    assert_eq!(
        hex::encode(IDefiInsurance::getInsuredTokenCall::SELECTOR),
        "3f962199"
    );
    assert_eq!(
        hex::encode(IDefiInsurance::settlementParamsCall::SELECTOR),
        "cbeee318"
    );
    assert_eq!(hex::encode(IRegistry::coverPoolsCall::SELECTOR), "87549445");
    assert_eq!(
        hex::encode(IRegistry::coverPoolsLengthCall::SELECTOR),
        "28efbe47"
    );
    assert_eq!(
        hex::encode(IRegistry::getScoredTokensCall::SELECTOR),
        "3aaa0b0c"
    );
    assert_eq!(
        hex::encode(IRegistry::getScoredRateHistoryCall::SELECTOR),
        "99e54713"
    );
    assert_eq!(hex::encode(IRegistry::boosterNFTCall::SELECTOR), "821c4043");
    assert_eq!(
        hex::encode(IRegistry::maxCoverPoolPayoutBpsCall::SELECTOR),
        "6d4dffcb"
    );
    assert_eq!(hex::encode(IRegistry::scoreSpentCall::SELECTOR), "f7e2a75c");
    assert_eq!(
        hex::encode(ISingleAssetCoverPool::assetCall::SELECTOR),
        "38d52e0f"
    );
    assert_eq!(
        hex::encode(ISingleAssetCoverPool::totalAssetsCall::SELECTOR),
        "01e1d114"
    );
    assert_eq!(
        hex::encode(IAggregatorV3::latestRoundDataCall::SELECTOR),
        "feaf968c"
    );
    assert_eq!(
        hex::encode(IAggregatorV3::decimalsCall::SELECTOR),
        "313ce567"
    );
    assert_eq!(hex::encode(IERC20::balanceOfCall::SELECTOR), "70a08231");
    assert_eq!(hex::encode(IERC1155::balanceOfCall::SELECTOR), "00fdd58e");
}

#[test]
fn generated_event_topics_match_solidity_authority() {
    assert_eq!(
        IDefiInsurance::ClaimRegistered::SIGNATURE_HASH.to_string(),
        "0x3ffe4fc1b5027f1d2081361769c1da9915da24ce8e1232deed128277b8f7c79e"
    );
    assert_eq!(
        IDefiInsurance::ClaimCancelled::SIGNATURE_HASH.to_string(),
        "0xb07c35948b3aa55af6baed77379d187e78a6e78bbe61fc2fe299f400607c441f"
    );
    assert_eq!(
        IERC20::Transfer::SIGNATURE_HASH.to_string(),
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    );
    assert_eq!(
        IERC1155::TransferSingle::SIGNATURE_HASH.to_string(),
        "0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62"
    );
    assert_eq!(
        IERC1155::TransferBatch::SIGNATURE_HASH.to_string(),
        "0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb"
    );
}
