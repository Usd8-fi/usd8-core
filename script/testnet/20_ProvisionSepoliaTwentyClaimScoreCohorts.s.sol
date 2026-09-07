// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";

interface IUSD8Booster is IERC1155 {
    function signer() external view returns (address);
    function totalSupply(uint256 id) external view returns (uint256);
}

/// @notice Adds heterogeneous sUSD8 score holdings and gas to the second ten E2E actors.
/// @dev Testnet-only preparation. It cannot run while an incident is active and does not touch msLOSS,
///      boosters, cover pools, insurance claims, or the ten actors used by the just-closed Incident 8 recovery.
contract ProvisionSepoliaTwentyClaimScoreCohorts is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 internal constant CLAIMANT_COUNT = 10;
    uint256 internal constant NATIVE_TARGET = 0.02 ether;
    uint256 internal constant BOOSTER_ID = 1;

    struct Context {
        address admin;
        Registry registry;
        DefiInsurance insurance;
        Treasury treasury;
        IERC20 usd8;
        IERC20 usdc;
        IERC4626 savings;
        IERC4626 lossVault;
        IUSD8Booster booster;
    }

    struct Totals {
        uint256 usd8;
        uint256 usdc;
        uint256 nativeAmount;
    }

    struct BeforeState {
        bytes32 protectedState;
        uint256 boosterSupply;
        uint256 usd8Supply;
        uint256 treasuryUsdc;
        uint256 adminUsd8;
    }

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        Context memory ctx = _loadContext();
        address[] memory claimants = _claimants();

        require(msg.sender == ctx.admin, "unexpected broadcaster");
        require(ctx.registry.isAdmin(ctx.admin), "admin mismatch");
        require(ctx.registry.defiInsurance() == address(ctx.insurance), "insurance mismatch");
        require(address(ctx.treasury) == ctx.registry.treasury(), "treasury mismatch");
        require(ctx.insurance.activeIncidentId() == 0, "incident active");
        require(address(ctx.savings.asset()) == address(ctx.usd8), "savings asset mismatch");
        require(ctx.booster.signer() == ctx.admin, "booster signer mismatch");

        {
            IERC20[] memory scoredTokens = ctx.registry.getScoredTokens();
            require(scoredTokens.length == 2, "unexpected scored-token count");
            require(address(scoredTokens[0]) == address(ctx.usd8), "S1 mismatch");
            require(address(scoredTokens[1]) == address(ctx.savings), "S2 mismatch");
        }

        BeforeState memory beforeState = _snapshot(ctx);
        Totals memory totals = _validateClaimants(ctx, claimants);
        uint256[] memory expectedSavingsBalances = _execute(ctx, claimants, totals);
        _assertPostState(ctx, claimants, totals, beforeState, expectedSavingsBalances);
        console2.log("scoreMaturityAnchorBlock", block.number);
    }

    function _loadContext() internal view returns (Context memory ctx) {
        ctx.admin = vm.envAddress("SEPOLIA_ADMIN");
        ctx.registry = Registry(vm.envAddress("SEPOLIA_REGISTRY"));
        ctx.insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        ctx.treasury = Treasury(payable(vm.envAddress("SEPOLIA_TREASURY")));
        ctx.usd8 = IERC20(vm.envAddress("SEPOLIA_USD8"));
        ctx.usdc = IERC20(vm.envAddress("SEPOLIA_USDC"));
        ctx.savings = IERC4626(vm.envAddress("SEPOLIA_SAVINGS_VAULT"));
        ctx.lossVault = IERC4626(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        ctx.booster = IUSD8Booster(vm.envAddress("SEPOLIA_BOOSTER"));
    }

    function _snapshot(Context memory ctx) internal view returns (BeforeState memory state) {
        state.protectedState = _protectedStateHash(ctx);
        state.boosterSupply = ctx.booster.totalSupply(BOOSTER_ID);
        state.usd8Supply = ctx.usd8.totalSupply();
        state.treasuryUsdc = ctx.usdc.balanceOf(address(ctx.treasury));
        state.adminUsd8 = ctx.usd8.balanceOf(ctx.admin);
    }

    function _validateClaimants(Context memory ctx, address[] memory claimants)
        internal
        view
        returns (Totals memory totals)
    {
        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            require(ctx.insurance.claimIdByIncidentAndUser(8, claimants[i]) == 0, "actor used in Incident 8");
            require(ctx.usd8.balanceOf(claimants[i]) >= _minimumUsd8(i), "insufficient existing USD8");
            require(ctx.savings.balanceOf(claimants[i]) == 0, "claimant already has sUSD8");
            require(ctx.booster.balanceOf(claimants[i], BOOSTER_ID) == 0, "claimant already has boosters");
            totals.usd8 += _savingsAmount(i);
            if (claimants[i].balance < NATIVE_TARGET) {
                totals.nativeAmount += NATIVE_TARGET - claimants[i].balance;
            }
        }

        require(totals.usd8 % 1e12 == 0, "USD8/USDC precision mismatch");
        totals.usdc = totals.usd8 / 1e12;
        require(ctx.usdc.balanceOf(ctx.admin) >= totals.usdc, "insufficient admin USDC");
        require(ctx.admin.balance >= totals.nativeAmount, "insufficient admin ETH");
    }

    function _execute(Context memory ctx, address[] memory claimants, Totals memory totals)
        internal
        returns (uint256[] memory expectedSavingsBalances)
    {
        expectedSavingsBalances = new uint256[](CLAIMANT_COUNT);
        vm.startBroadcast();

        ctx.usdc.forceApprove(address(ctx.treasury), totals.usdc);
        ctx.treasury.mintUSD8(totals.usdc);
        ctx.usd8.forceApprove(address(ctx.savings), totals.usd8);

        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            uint256 assets = _savingsAmount(i);
            if (assets != 0) {
                uint256 beforeBalance = ctx.savings.balanceOf(claimants[i]);
                uint256 shares = ctx.savings.deposit(assets, claimants[i]);
                require(shares != 0, "zero savings shares");
                expectedSavingsBalances[i] = beforeBalance + shares;
            }
        }

        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            if (claimants[i].balance < NATIVE_TARGET) {
                (bool sent,) = payable(claimants[i]).call{value: NATIVE_TARGET - claimants[i].balance}("");
                require(sent, "native funding failed");
            }
        }

        vm.stopBroadcast();
    }

    function _assertPostState(
        Context memory ctx,
        address[] memory claimants,
        Totals memory totals,
        BeforeState memory beforeState,
        uint256[] memory expectedSavingsBalances
    ) internal view {
        require(_protectedStateHash(ctx) == beforeState.protectedState, "protected state changed");
        require(ctx.booster.totalSupply(BOOSTER_ID) == beforeState.boosterSupply, "booster supply changed");
        require(ctx.usd8.totalSupply() == beforeState.usd8Supply + totals.usd8, "USD8 supply mismatch");
        require(
            ctx.usdc.balanceOf(address(ctx.treasury)) == beforeState.treasuryUsdc + totals.usdc,
            "treasury USDC mismatch"
        );
        require(ctx.usd8.balanceOf(ctx.admin) == beforeState.adminUsd8, "admin USD8 residue");

        for (uint256 i = 0; i < CLAIMANT_COUNT; i++) {
            require(claimants[i].balance >= NATIVE_TARGET, "native funding mismatch");
            require(ctx.savings.balanceOf(claimants[i]) == expectedSavingsBalances[i], "sUSD8 mismatch");
            require(ctx.booster.balanceOf(claimants[i], BOOSTER_ID) == 0, "booster balance changed");
            console2.log("claimant", i + 1, claimants[i]);
            console2.log("sUSD8", ctx.savings.balanceOf(claimants[i]));
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
                ctx.lossVault.totalAssets(),
                ctx.lossVault.totalSupply(),
                ctx.insurance.escrowedInsuredTokens(IERC20(address(ctx.lossVault))),
                ctx.usd8.balanceOf(address(ctx.insurance)),
                ctx.booster.balanceOf(address(ctx.insurance), BOOSTER_ID),
                poolsHash
            )
        );
    }

    function _minimumUsd8(uint256 index) internal pure returns (uint256) {
        return (index + 1) * 100e18;
    }

    function _savingsAmount(uint256 index) internal pure returns (uint256) {
        uint256[10] memory amounts = [uint256(0), 100, 250, 500, 750, 1_000, 1_500, 2_000, 3_000, 4_000];
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
}
