// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";

interface IUSD8BoosterGasPrep is IERC1155 {
    function totalSupply(uint256 id) external view returns (uint256);
}

/// @notice Tops all twenty Sepolia E2E actors up to the exact native-gas target.
/// @dev Testnet-only preparation. No protocol token, score, claim, escrow, or pool state may change.
contract ProvisionSepoliaTwentyClaimNativeGas is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 internal constant ACTOR_COUNT = 20;
    uint256 internal constant NATIVE_TARGET = 0.02 ether;
    uint256 internal constant BOOSTER_ID = 1;

    struct Context {
        address admin;
        Registry registry;
        DefiInsurance insurance;
        IERC20 usd8;
        IERC4626 savings;
        IERC4626 lossVault;
        IUSD8BoosterGasPrep booster;
    }

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        Context memory ctx = _loadContext();
        address[] memory actors = _actors();

        require(msg.sender == ctx.admin, "unexpected broadcaster");
        require(ctx.registry.isAdmin(ctx.admin), "admin mismatch");
        require(ctx.registry.defiInsurance() == address(ctx.insurance), "insurance mismatch");
        require(ctx.insurance.activeIncidentId() == 0, "incident active");

        bytes32 protectedBefore = _protectedStateHash(ctx);
        bytes32 actorsBefore = _actorTokenStateHash(ctx, actors);
        uint256 totalNative;
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            if (actors[i].balance < NATIVE_TARGET) totalNative += NATIVE_TARGET - actors[i].balance;
        }
        require(ctx.admin.balance >= totalNative, "insufficient admin ETH");

        vm.startBroadcast();
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            if (actors[i].balance < NATIVE_TARGET) {
                (bool sent,) = payable(actors[i]).call{value: NATIVE_TARGET - actors[i].balance}("");
                require(sent, "native funding failed");
            }
        }
        vm.stopBroadcast();

        require(_protectedStateHash(ctx) == protectedBefore, "protected state changed");
        require(_actorTokenStateHash(ctx, actors) == actorsBefore, "actor token state changed");
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            require(actors[i].balance >= NATIVE_TARGET, "native target missed");
            console2.log("actor", i + 1, actors[i]);
            console2.log("native", actors[i].balance);
        }
    }

    function _loadContext() internal view returns (Context memory ctx) {
        ctx.admin = vm.envAddress("SEPOLIA_ADMIN");
        ctx.registry = Registry(vm.envAddress("SEPOLIA_REGISTRY"));
        ctx.insurance = DefiInsurance(vm.envAddress("SEPOLIA_DEFI_INSURANCE"));
        ctx.usd8 = IERC20(vm.envAddress("SEPOLIA_USD8"));
        ctx.savings = IERC4626(vm.envAddress("SEPOLIA_SAVINGS_VAULT"));
        ctx.lossVault = IERC4626(vm.envAddress("SEPOLIA_LOSS_TOKEN"));
        ctx.booster = IUSD8BoosterGasPrep(vm.envAddress("SEPOLIA_BOOSTER"));
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
                ctx.booster.totalSupply(BOOSTER_ID),
                ctx.booster.balanceOf(address(ctx.insurance), BOOSTER_ID),
                poolsHash
            )
        );
    }

    function _actorTokenStateHash(Context memory ctx, address[] memory actors)
        internal
        view
        returns (bytes32 state)
    {
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            state = keccak256(
                abi.encode(
                    state,
                    actors[i],
                    ctx.usd8.balanceOf(actors[i]),
                    ctx.savings.balanceOf(actors[i]),
                    ctx.lossVault.balanceOf(actors[i]),
                    ctx.booster.balanceOf(actors[i], BOOSTER_ID),
                    ctx.registry.scoreSpent(actors[i])
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
