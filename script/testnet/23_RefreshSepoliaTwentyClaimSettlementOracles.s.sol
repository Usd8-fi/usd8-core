// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {SepoliaTestOracle} from "./SepoliaDependencies.sol";

interface IUSD8BoosterOracleRefresh is IERC1155 {
    function totalSupply(uint256 id) external view returns (uint256);
}

/// @notice Refreshes exactly the live oracle union required by Sepolia settlement.
/// @dev Preserves all answers and fails closed if topology, rounds, code, or protected state drifted.
contract RefreshSepoliaTwentyClaimSettlementOracles is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 internal constant ACTOR_COUNT = 20;
    uint256 internal constant BOOSTER_ID = 1;

    address internal constant REGISTRY = 0xB34D92cd05005DF36050370433819597a9BaC693;
    address internal constant INSURANCE = 0x4E346CcD0a46D51ebaE6810d653791982968d502;
    address internal constant LOSS_TOKEN = 0xD5B2a08F474f77eF29211Ccc59cd65e5fA6734dc;
    address internal constant USD8 = 0xa5B32853235619B5e9AF364A40c0c6386Dbd6055;
    address internal constant SUSD8 = 0x7989B3EB6faD27e404b07433eBD265657359F4AB;
    address internal constant BOOSTER = 0xC0012770848FCD350AB11906e93ba9fdfDA19f4c;

    address internal constant POOL_ASSET_0 = 0xdfaf9C1CE55f18AB7850EDd84F2175ce734985fa;
    address internal constant POOL_0 = 0x55cb69271da9937d0Cb3c548409FD3f77586dF79;
    address internal constant FEED_0 = 0x00E79aFB10A84D153803F00e73900803179D594e;
    address internal constant POOL_ASSET_1 = 0xBBd327336D5135E146312dD16F2491C1E6ce8822;
    address internal constant POOL_1 = 0x8917f4C377dD0e5Bd4909D8A00B508F38C0f3f4F;
    address internal constant FEED_1 = 0xDa725125d8ff0588496382427ab65Bc8f8D639Eb;
    address internal constant INSURED_FEED = 0x9989a6bB00C1737A9A0175408053a04A6f3eD74b;

    bytes32 internal constant EXPECTED_FEED_CODEHASH =
        0x5e5702ff10ecdf75f747ebb038a9063ef57960b13192c1cc6de7509fbfd6bda9;

    struct FeedState {
        uint80 roundId;
        int256 answer;
        uint256 updatedAt;
    }

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        address admin = vm.envAddress("SEPOLIA_ADMIN");
        require(msg.sender == admin, "unexpected broadcaster");

        Registry registry = Registry(REGISTRY);
        DefiInsurance insurance = DefiInsurance(INSURANCE);
        IERC4626 lossVault = IERC4626(LOSS_TOKEN);
        IUSD8BoosterOracleRefresh booster = IUSD8BoosterOracleRefresh(BOOSTER);
        address[] memory actors = _actors();

        _validateTopology(registry, insurance, admin);
        require(insurance.activeIncidentId() == 0, "incident active");
        require(lossVault.totalAssets() == lossVault.totalSupply(), "loss vault not healthy");

        FeedState memory before0 = _requireFeed(FEED_0, admin, 7, 400_000_000_000, 1_788_227_784);
        FeedState memory before1 = _requireFeed(FEED_1, admin, 3, 100_000_000, 1_788_227_796);
        FeedState memory before2 = _requireFeed(INSURED_FEED, admin, 5, 100_000_000, 1_788_227_832);
        bytes32 protectedBefore = _protectedStateHash(registry, insurance, lossVault, booster);
        bytes32 actorsBefore = _actorStateHash(registry, lossVault, booster, actors);

        vm.startBroadcast();
        SepoliaTestOracle(FEED_0).updateAnswer(before0.answer);
        SepoliaTestOracle(FEED_1).updateAnswer(before1.answer);
        SepoliaTestOracle(INSURED_FEED).updateAnswer(before2.answer);
        vm.stopBroadcast();

        _requireRefreshed(FEED_0, before0);
        _requireRefreshed(FEED_1, before1);
        _requireRefreshed(INSURED_FEED, before2);
        require(_protectedStateHash(registry, insurance, lossVault, booster) == protectedBefore, "protected state changed");
        require(_actorStateHash(registry, lossVault, booster, actors) == actorsBefore, "actor state changed");
        _validateTopology(registry, insurance, admin);

        console2.log("refreshedAtBlock", block.number);
        console2.log("feed0", FEED_0);
        console2.log("feed1", FEED_1);
        console2.log("insuredFeed", INSURED_FEED);
    }

    function _validateTopology(Registry registry, DefiInsurance insurance, address admin) internal view {
        require(address(registry) == REGISTRY && address(insurance) == INSURANCE, "module mismatch");
        require(registry.isAdmin(admin), "admin mismatch");
        require(registry.defiInsurance() == INSURANCE, "insurance wiring mismatch");
        (IERC20[] memory assets, address[] memory pools) = registry.coverPools();
        require(assets.length == 2 && pools.length == 2, "unexpected pool count");
        require(address(assets[0]) == POOL_ASSET_0 && pools[0] == POOL_0, "pool 0 mismatch");
        require(address(assets[1]) == POOL_ASSET_1 && pools[1] == POOL_1, "pool 1 mismatch");
        require(registry.coverPool(IERC20(POOL_ASSET_0)) == POOL_0, "pool 0 reverse mismatch");
        require(registry.coverPool(IERC20(POOL_ASSET_1)) == POOL_1, "pool 1 reverse mismatch");
        require(registry.assetUsdFeed(IERC20(POOL_ASSET_0)) == FEED_0, "feed 0 mismatch");
        require(registry.assetUsdFeed(IERC20(POOL_ASSET_1)) == FEED_1, "feed 1 mismatch");
        DefiInsurance.InsuredToken memory insured = insurance.getInsuredToken(IERC20(LOSS_TOKEN));
        require(insured.maxCoverageBps == 8_000, "coverage mismatch");
        require(insured.underlyingPriceOracle == INSURED_FEED, "insured feed mismatch");
        require(insured.underlyingConversionAddress == LOSS_TOKEN, "conversion target mismatch");
        require(
            keccak256(insured.underlyingConversionCallData)
                == 0x445607c3c62812954cc9508d48672100a4ebe3d179eb6f18345b174b6357156d,
            "conversion calldata mismatch"
        );
    }

    function _requireFeed(address feed, address admin, uint80 round, int256 answer, uint256 updatedAt)
        internal
        view
        returns (FeedState memory state)
    {
        require(feed.codehash == EXPECTED_FEED_CODEHASH, "feed codehash mismatch");
        SepoliaTestOracle oracle = SepoliaTestOracle(feed);
        require(oracle.admin() == admin, "feed admin mismatch");
        require(oracle.decimals() == 8, "feed decimals mismatch");
        (state.roundId, state.answer,, state.updatedAt,) = oracle.latestRoundData();
        require(state.roundId == round, "feed round mismatch");
        require(state.answer == answer, "feed answer mismatch");
        require(state.updatedAt == updatedAt, "feed timestamp mismatch");
    }

    function _requireRefreshed(address feed, FeedState memory beforeState) internal view {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            SepoliaTestOracle(feed).latestRoundData();
        require(roundId == beforeState.roundId + 1, "round did not increment exactly once");
        require(answeredInRound == roundId, "incomplete round");
        require(answer == beforeState.answer, "answer changed");
        require(updatedAt > beforeState.updatedAt, "timestamp did not refresh");
    }

    function _protectedStateHash(
        Registry registry,
        DefiInsurance insurance,
        IERC4626 lossVault,
        IUSD8BoosterOracleRefresh booster
    ) internal view returns (bytes32) {
        (IERC20[] memory assets, address[] memory pools) = registry.coverPools();
        bytes32 poolsHash;
        for (uint256 i = 0; i < pools.length; i++) {
            poolsHash = keccak256(
                abi.encode(
                    poolsHash,
                    address(assets[i]),
                    pools[i],
                    IERC4626(pools[i]).totalAssets(),
                    assets[i].balanceOf(pools[i])
                )
            );
        }
        Registry.ProtocolFeeConfig memory fee = registry.protocolFeeConfig();
        return keccak256(
            abi.encode(
                insurance.activeIncidentId(),
                insurance.nextClaimId(),
                lossVault.totalAssets(),
                lossVault.totalSupply(),
                insurance.escrowedInsuredTokens(IERC20(LOSS_TOKEN)),
                IERC20(USD8).balanceOf(INSURANCE),
                booster.totalSupply(BOOSTER_ID),
                booster.balanceOf(INSURANCE, BOOSTER_ID),
                fee.receiver,
                fee.claimProtocolFeeShareBps,
                poolsHash
            )
        );
    }

    function _actorStateHash(
        Registry registry,
        IERC4626 lossVault,
        IUSD8BoosterOracleRefresh booster,
        address[] memory actors
    ) internal view returns (bytes32 state) {
        for (uint256 i = 0; i < actors.length; i++) {
            state = keccak256(
                abi.encode(
                    state,
                    actors[i],
                    IERC20(USD8).balanceOf(actors[i]),
                    IERC20(SUSD8).balanceOf(actors[i]),
                    lossVault.balanceOf(actors[i]),
                    booster.balanceOf(actors[i], BOOSTER_ID),
                    registry.scoreSpent(actors[i])
                )
            );
        }
    }

    function _actors() internal pure returns (address[] memory actors) {
        actors = new address[](ACTOR_COUNT);
        actors[0] = 0xeb5eAd9c9b0E8BFa3f8959D602A32FC0c548c267;
        actors[1] = 0x9c5d50400df8Bd397E7D7aed23bc55B5c4d0eb66;
        actors[2] = 0x247fdb90237758B931db2e7f32A801117aCB8bA2;
        actors[3] = 0x58cE869611C6BDe45AB627a98EaD449b89D09CA4;
        actors[4] = 0x5F30FA9a5b2161DaA10519B7Ac16D4086a0c83d1;
        actors[5] = 0x454265761D465CaCdEa56fE63446c6cE1486c568;
        actors[6] = 0x8Dde6E408B844f7fB533c7a50c594ac3AAd36a84;
        actors[7] = 0x096b098c0fC8F4b7b300467E3EFAC5efa8bd3166;
        actors[8] = 0xFE63ab790b6D76BB7B3f4827F4F98EE44e436ccE;
        actors[9] = 0x7f47Dbd58566B66edAc22bB4fB63DA650dDcfd7B;
        actors[10] = 0x8Fa49d582B9bB8e4613D4e05c642D3eB2C539Dcd;
        actors[11] = 0xaf90430e677A926B6814095A5685cF8bF425B5e3;
        actors[12] = 0x890b76bF56B65568e724bD8317d57F166C03f898;
        actors[13] = 0x1d5A8126662308e96168F64ABaAf070Bb99aBD5a;
        actors[14] = 0x49dC35C96966028064D789Eb57FAa7213f1aB5C2;
        actors[15] = 0xcEACe0Be8f2cC8aC04330bc8F89f9cf5Ef53b744;
        actors[16] = 0x3Ed161Ceef7900B7130B9ae97F3f400A71B741C6;
        actors[17] = 0xF92E102e0f5FB4DbDDCe982B8bb2808b8a136f9c;
        actors[18] = 0x77D25F099cac66c6eEd6D6de9bEcb4515Ae9Bb3d;
        actors[19] = 0xeAD1462372ff1dC7A184dAA8a7c4D9542582f10e;
    }
}
