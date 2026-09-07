// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {SepoliaTestToken} from "./SepoliaDependencies.sol";

interface IUSD8BoosterSupply is IERC1155 {
    function totalSupply(uint256 id) external view returns (uint256);
}

/// @notice Restores the Sepolia loss fixture and tops up the second ten E2E actors to exact msLOSS targets.
/// @dev Testnet-only preparation. It is bound to the post-Incident-8 state and leaves a healthy 1:1 vault.
contract RestoreAndProvisionSepoliaTwentyClaimLossShares is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 internal constant CLAIMANT_COUNT = 10;
    uint256 internal constant FRESH_COUNT = 10;
    uint256 internal constant BOOSTER_ID = 1;

    uint256 internal constant EXPECTED_TOTAL_ASSETS = 1_845_951_534_683_544_303_797_468;
    uint256 internal constant EXPECTED_TOTAL_SUPPLY = 2_366_604_531_645_569_620_253_164;

    struct Context {
        address admin;
        Registry registry;
        DefiInsurance insurance;
        IERC20 usd8;
        IERC4626 savings;
        IERC4626 lossVault;
        SepoliaTestToken underlying;
        IUSD8BoosterSupply booster;
    }

    struct Snapshot {
        bytes32 protectedState;
        bytes32 freshActorState;
        bytes32 claimantProtectedState;
        uint256 underlyingSupply;
        uint256 adminUnderlying;
        uint256[] freshLossBalances;
        uint256[] claimantSavingsBalances;
        uint256[] claimantBoosterBalances;
    }

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");

        Context memory ctx = _loadContext();
        address[] memory claimants = _claimants();
        address[] memory fresh = _freshClaimants();

        _validateEnvironment(ctx);
        Snapshot memory beforeState = _snapshot(ctx, claimants, fresh);
        uint256 missingShares = _validateClaimants(ctx, claimants);
        uint256 restoration = EXPECTED_TOTAL_SUPPLY - EXPECTED_TOTAL_ASSETS;
        uint256 underlyingRequired = restoration + missingShares;

        vm.startBroadcast();

        ctx.underlying.mint(ctx.admin, underlyingRequired);
        IERC20(address(ctx.underlying)).safeTransfer(address(ctx.lossVault), restoration);
        require(ctx.lossVault.totalAssets() == ctx.lossVault.totalSupply(), "restore failed");

        IERC20(address(ctx.underlying)).forceApprove(address(ctx.lossVault), missingShares);
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            uint256 missing = _targetLossShares(i) - ctx.lossVault.balanceOf(claimants[i]);
            require(ctx.lossVault.previewDeposit(missing) == missing, "non-unit preview");
            uint256 minted = ctx.lossVault.deposit(missing, claimants[i]);
            require(minted == missing, "unexpected minted shares");
        }

        vm.stopBroadcast();

        _assertPostState(ctx, claimants, fresh, beforeState, missingShares, underlyingRequired);
        console2.log("healthyBaselineAnchorBlock", block.number);
    }

    function _loadContext() internal view returns (Context memory ctx) {
        ctx.admin = vm.envAddress("SEPOLIA_ADMIN");
        ctx.registry = Registry(vm.envAddress("SEPOLIA_REGISTRY"));
        ctx.insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        ctx.usd8 = IERC20(vm.envAddress("SEPOLIA_USD8"));
        ctx.savings = IERC4626(vm.envAddress("SEPOLIA_SAVINGS_VAULT"));
        ctx.lossVault = IERC4626(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        ctx.underlying = SepoliaTestToken(address(ctx.lossVault.asset()));
        ctx.booster = IUSD8BoosterSupply(vm.envAddress("SEPOLIA_BOOSTER"));
    }

    function _validateEnvironment(Context memory ctx) internal view {
        require(msg.sender == ctx.admin, "unexpected broadcaster");
        require(ctx.registry.isAdmin(ctx.admin), "admin mismatch");
        require(ctx.registry.defiInsurance() == address(ctx.insurance), "insurance mismatch");
        require(ctx.insurance.activeIncidentId() == 0, "incident active");
        // Post-lifecycle cleanup must restore the synthetic vault even when the
        // insured token has already been delisted after the incident resolved.
        require(ctx.underlying.admin() == ctx.admin, "underlying admin mismatch");
        require(ctx.lossVault.totalAssets() == EXPECTED_TOTAL_ASSETS, "unexpected total assets");
        require(ctx.lossVault.totalSupply() == EXPECTED_TOTAL_SUPPLY, "unexpected total supply");
        require(EXPECTED_TOTAL_ASSETS < EXPECTED_TOTAL_SUPPLY, "fixture is not impaired");
    }

    function _snapshot(Context memory ctx, address[] memory claimants, address[] memory fresh)
        internal
        view
        returns (Snapshot memory state)
    {
        state.protectedState = _protectedStateHash(ctx);
        state.freshActorState = _freshActorStateHash(ctx, fresh);
        state.claimantProtectedState = _claimantProtectedStateHash(ctx, claimants);
        state.underlyingSupply = ctx.underlying.totalSupply();
        state.adminUnderlying = ctx.underlying.balanceOf(ctx.admin);
        state.freshLossBalances = new uint256[](FRESH_COUNT);
        state.claimantSavingsBalances = new uint256[](CLAIMANT_COUNT);
        state.claimantBoosterBalances = new uint256[](CLAIMANT_COUNT);

        for (uint256 i = 0; i < FRESH_COUNT; i++) {
            state.freshLossBalances[i] = ctx.lossVault.balanceOf(fresh[i]);
        }
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            state.claimantSavingsBalances[i] = ctx.savings.balanceOf(claimants[i]);
            state.claimantBoosterBalances[i] = ctx.booster.balanceOf(claimants[i], BOOSTER_ID);
        }
    }

    function _validateClaimants(Context memory ctx, address[] memory claimants)
        internal
        view
        returns (uint256 missingShares)
    {
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            uint256 current = ctx.lossVault.balanceOf(claimants[i]);
            require(current == (i + 1) * 100e18, "unexpected current loss shares");
            require(current < _targetLossShares(i), "loss-share target not above current");
            missingShares += _targetLossShares(i) - current;
        }
    }

    function _assertPostState(
        Context memory ctx,
        address[] memory claimants,
        address[] memory fresh,
        Snapshot memory beforeState,
        uint256 missingShares,
        uint256 underlyingRequired
    ) internal view {
        require(ctx.lossVault.totalAssets() == EXPECTED_TOTAL_SUPPLY + missingShares, "post total assets mismatch");
        require(ctx.lossVault.totalSupply() == EXPECTED_TOTAL_SUPPLY + missingShares, "post total supply mismatch");
        require(
            ctx.underlying.totalSupply() == beforeState.underlyingSupply + underlyingRequired,
            "underlying supply mismatch"
        );
        require(ctx.underlying.balanceOf(ctx.admin) == beforeState.adminUnderlying, "admin underlying residue");
        require(_protectedStateHash(ctx) == beforeState.protectedState, "protected state changed");
        require(_freshActorStateHash(ctx, fresh) == beforeState.freshActorState, "fresh actor state changed");
        require(
            _claimantProtectedStateHash(ctx, claimants) == beforeState.claimantProtectedState,
            "claimant protected state changed"
        );

        for (uint256 i = 0; i < FRESH_COUNT; i++) {
            require(ctx.lossVault.balanceOf(fresh[i]) == beforeState.freshLossBalances[i], "fresh loss balance changed");
        }
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            require(ctx.lossVault.balanceOf(claimants[i]) == _targetLossShares(i), "loss-share target mismatch");
            require(ctx.savings.balanceOf(claimants[i]) == beforeState.claimantSavingsBalances[i], "savings changed");
            require(
                ctx.booster.balanceOf(claimants[i], BOOSTER_ID) == beforeState.claimantBoosterBalances[i],
                "booster changed"
            );
            console2.log("claimant", i + 1, claimants[i]);
            console2.log("msLOSS", ctx.lossVault.balanceOf(claimants[i]));
        }
    }

    function _protectedStateHash(Context memory ctx) internal view returns (bytes32) {
        (IERC20[] memory poolAssets, address[] memory pools) = ctx.registry.coverPools();
        require(poolAssets.length != 0 && poolAssets.length == pools.length, "invalid pool topology");

        bytes32 poolsHash;
        for (uint256 i = 0; i < pools.length; i++) {
            poolsHash = keccak256(
                abi.encode(
                    poolsHash,
                    address(poolAssets[i]),
                    pools[i],
                    IERC4626(pools[i]).totalAssets(),
                    poolAssets[i].balanceOf(pools[i])
                )
            );
        }

        return keccak256(
            abi.encode(
                ctx.insurance.activeIncidentId(),
                ctx.insurance.nextClaimId(),
                ctx.insurance.escrowedInsuredTokens(IERC20(address(ctx.lossVault))),
                ctx.usd8.balanceOf(address(ctx.insurance)),
                ctx.booster.totalSupply(BOOSTER_ID),
                ctx.booster.balanceOf(address(ctx.insurance), BOOSTER_ID),
                poolsHash
            )
        );
    }

    function _freshActorStateHash(Context memory ctx, address[] memory fresh) internal view returns (bytes32 state) {
        for (uint256 i = 0; i < FRESH_COUNT; i++) {
            state = keccak256(
                abi.encode(
                    state,
                    fresh[i],
                    ctx.usd8.balanceOf(fresh[i]),
                    ctx.savings.balanceOf(fresh[i]),
                    ctx.lossVault.balanceOf(fresh[i]),
                    ctx.booster.balanceOf(fresh[i], BOOSTER_ID),
                    ctx.registry.scoreSpent(fresh[i])
                )
            );
        }
    }

    function _claimantProtectedStateHash(Context memory ctx, address[] memory claimants)
        internal
        view
        returns (bytes32 state)
    {
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            state = keccak256(
                abi.encode(
                    state,
                    claimants[i],
                    ctx.usd8.balanceOf(claimants[i]),
                    ctx.savings.balanceOf(claimants[i]),
                    ctx.booster.balanceOf(claimants[i], BOOSTER_ID),
                    ctx.registry.scoreSpent(claimants[i])
                )
            );
        }
    }

    function _targetLossShares(uint256 index) internal pure returns (uint256) {
        uint256[10] memory amounts =
            [uint256(15_000), 30_000, 55_000, 75_000, 110_000, 160_000, 220_000, 300_000, 420_000, 600_000];
        return amounts[index] * 1e18;
    }

    function _claimants() internal pure returns (address[] memory claimants) {
        claimants = new address[](CLAIMANT_COUNT);
        claimants[0] = 0x8Fa49d582B9bB8e4613D4e05c642D3eB2C539Dcd;
        claimants[1] = 0xaf90430e677A926B6814095A5685cF8bF425B5e3;
        claimants[2] = 0x890b76bF56B65568e724bD8317d57F166C03f898;
        claimants[3] = 0x1d5A8126662308e96168F64ABaAf070Bb99aBD5a;
        claimants[4] = 0x49dC35C96966028064D789Eb57FAa7213f1aB5C2;
        claimants[5] = 0xcEACe0Be8f2cC8aC04330bc8F89f9cf5Ef53b744;
        claimants[6] = 0x3Ed161Ceef7900B7130B9ae97F3f400A71B741C6;
        claimants[7] = 0xF92E102e0f5FB4DbDDCe982B8bb2808b8a136f9c;
        claimants[8] = 0x77D25F099cac66c6eEd6D6de9bEcb4515Ae9Bb3d;
        claimants[9] = 0xeAD1462372ff1dC7A184dAA8a7c4D9542582f10e;
    }

    function _freshClaimants() internal pure returns (address[] memory claimants) {
        claimants = new address[](FRESH_COUNT);
        claimants[0] = 0xeb5eAd9c9b0E8BFa3f8959D602A32FC0c548c267;
        claimants[1] = 0x9c5d50400df8Bd397E7D7aed23bc55B5c4d0eb66;
        claimants[2] = 0x247fdb90237758B931db2e7f32A801117aCB8bA2;
        claimants[3] = 0x58cE869611C6BDe45AB627a98EaD449b89D09CA4;
        claimants[4] = 0x5F30FA9a5b2161DaA10519B7Ac16D4086a0c83d1;
        claimants[5] = 0x454265761D465CaCdEa56fE63446c6cE1486c568;
        claimants[6] = 0x8Dde6E408B844f7fB533c7a50c594ac3AAd36a84;
        claimants[7] = 0x096b098c0fC8F4b7b300467E3EFAC5efa8bd3166;
        claimants[8] = 0xFE63ab790b6D76BB7B3f4827F4F98EE44e436ccE;
        claimants[9] = 0x7f47Dbd58566B66edAc22bB4fB63DA650dDcfd7B;
    }
}
