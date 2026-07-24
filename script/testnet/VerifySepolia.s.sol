// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";
import {Treasury} from "../../src/Treasury.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";

interface IOwnableView {
    function owner() external view returns (address);
}

/// @notice Verifies the complete nonce-locked USD8 Sepolia staging deployment.
contract VerifySepolia is Script {
    uint256 private constant SEPOLIA_CHAIN_ID = 11_155_111;
    address private constant ADMIN = 0xB2E999D531D45a9115dA7706adFc651999f3c1F1;
    address private constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address private constant BOOSTER = 0xC0012770848FCD350AB11906e93ba9fdfDA19f4c;
    address private constant SEED_SINK = 0x000000000000000000000000000000000000dEaD;

    address private constant TIMELOCK = 0x8d10C99dDE0E91Dba85896ce65Daa861B972b330;
    address private constant REGISTRY = 0x3Fa82eC1842f72c36580D84E03377b10B5E2F590;
    address private constant USD8_PROXY = 0x12C7b483C164C648b4F7b72Af4b93250bED623CE;
    address private constant TREASURY = 0x5B5e52b7E603cA71C7dc37134924855cc45864c1;
    address private constant COVER_POOL = 0xd54ce4989Bf30A1d28864f0892e8211e4A28AF30;
    address private constant COVER_POOL_BEACON = 0x02051110D30CD5087a3cE0f03F2d419d0415640E;
    address private constant AAVE_STRATEGY = 0x9c8a4d149Af4AFEcAb45E82dB5265975dd12040a;
    address private constant MORPHO_STRATEGY = 0xCdb5Aa1f50F3b19C12FC1d50E482e93FBaBc39eC;
    address private constant SAVINGS_VAULT = 0x64E64eAdD9817e5F97266D34FF057ba4777c395B;
    address private constant DEFI_INSURANCE = 0x250CeBDD9d6997fFD45C60D6E713f42e44E383ec;
    address private constant USD8_PRICE_ORACLE = 0xc316AC5A8fa0D6961c2BCd26EA2d9F9e657626f5;

    function run() external view {
        require(block.chainid == SEPOLIA_CHAIN_ID, "wrong chain");

        address coverAsset = vm.envAddress("SEPOLIA_COVER_ASSET");
        address coverOracle = vm.envAddress("SEPOLIA_COVER_ASSET_USD_ORACLE");
        address aaveVault = vm.envAddress("SEPOLIA_AAVE_USDC_VAULT");
        address morphoVault = vm.envAddress("SEPOLIA_MORPHO_USDC_VAULT");
        address sgho = vm.envAddress("SEPOLIA_AAVE_SGHO");
        address ghoOracle = vm.envAddress("SEPOLIA_GHO_USD_ORACLE");
        address susds = vm.envAddress("SEPOLIA_SKY_SUSDS");
        address usdsOracle = vm.envAddress("SEPOLIA_USDS_USD_ORACLE");
        address usdcOracle = vm.envAddress("SEPOLIA_USDC_USD_ORACLE");

        _requireCode(BOOSTER);
        _requireCode(coverAsset);
        _requireCode(coverOracle);
        _requireCode(aaveVault);
        _requireCode(morphoVault);
        _requireCode(sgho);
        _requireCode(ghoOracle);
        _requireCode(susds);
        _requireCode(usdsOracle);
        _requireCode(usdcOracle);
        require(IERC4626(aaveVault).asset() == USDC, "wrong Aave mock asset");
        require(IERC4626(morphoVault).asset() == USDC, "wrong Morpho mock asset");
        require(IERC4626(sgho).convertToAssets(1e18) != 0, "bad sGHO conversion");
        require(IERC4626(susds).convertToAssets(1e18) != 0, "bad sUSDS conversion");
        _requirePositiveOracle(coverOracle);
        _requirePositiveOracle(ghoOracle);
        _requirePositiveOracle(usdsOracle);
        _requirePositiveOracle(usdcOracle);

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        require(timelock.getMinDelay() == 1 days, "wrong timelock delay");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), ADMIN), "missing proposer");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), ADMIN), "missing canceller");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "executor not open");
        require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), TIMELOCK), "timelock not self-admin");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), ADMIN), "external timelock admin");

        Registry registry = Registry(REGISTRY);
        require(registry.timelock() == TIMELOCK, "wrong Registry timelock");
        require(registry.isAdmin(ADMIN), "missing beta admin");
        require(registry.usd8() == USD8_PROXY, "wrong canonical USD8");
        require(registry.treasury() == TREASURY, "wrong canonical Treasury");
        require(registry.savingsVault() == SAVINGS_VAULT, "wrong canonical savings vault");
        require(registry.defiInsurance() == DEFI_INSURANCE, "wrong payout module");
        require(registry.boosterNFT() == BOOSTER, "wrong booster");
        require(registry.usd8PriceOracle() == USD8_PRICE_ORACLE, "wrong USD8 oracle");

        (IERC20[] memory assets, address[] memory pools) = registry.coverPools();
        require(assets.length == 1 && address(assets[0]) == coverAsset, "wrong cover asset");
        require(pools.length == 1 && pools[0] == COVER_POOL, "wrong cover pool");
        require(address(SingleAssetCoverPool(COVER_POOL).asset()) == coverAsset, "pool asset mismatch");

        USD8 usd8 = USD8(USD8_PROXY);
        Treasury treasury = Treasury(TREASURY);
        require(usd8.treasury() == TREASURY, "USD8 Treasury mismatch");
        require(address(treasury.USDC()) == USDC, "wrong reserve asset");
        require(treasury.strategies(0) == ERC4626Strategy(AAVE_STRATEGY), "wrong strategy zero");
        require(treasury.strategies(1) == ERC4626Strategy(MORPHO_STRATEGY), "wrong strategy one");
        require(address(ERC4626Strategy(AAVE_STRATEGY).vault()) == aaveVault, "wrong Aave strategy vault");
        require(address(ERC4626Strategy(MORPHO_STRATEGY).vault()) == morphoVault, "wrong Morpho strategy vault");
        require(IOwnableView(COVER_POOL_BEACON).owner() == TIMELOCK, "wrong beacon owner");

        IERC4626 savings = IERC4626(SAVINGS_VAULT);
        require(savings.asset() == USD8_PROXY, "wrong savings asset");
        require(savings.totalSupply() == 10e18, "wrong savings seed supply");
        require(IERC20(SAVINGS_VAULT).balanceOf(SEED_SINK) == 10e18, "wrong seed sink balance");
        require(IERC20(USDC).balanceOf(TREASURY) == 10e6, "wrong backing seed");

        DefiInsurance insurance = DefiInsurance(DEFI_INSURANCE);
        require(insurance.isInsuredToken(IERC20(USD8_PROXY)), "USD8 not insured");
        require(insurance.isInsuredToken(IERC20(SAVINGS_VAULT)), "sUSD8 not insured");
        require(insurance.isInsuredToken(IERC20(sgho)), "sGHO not insured");
        require(insurance.isInsuredToken(IERC20(susds)), "sUSDS not insured");
        require(insurance.activeIncidentId() == 0, "incident unexpectedly active");

        console2.log("USD8 Sepolia deployment verified");
        console2.log("Registry:", REGISTRY);
        console2.log("USD8:", USD8_PROXY);
        console2.log("Treasury:", TREASURY);
        console2.log("sUSD8:", SAVINGS_VAULT);
        console2.log("DefiInsurance:", DEFI_INSURANCE);
    }

    function _requireCode(address candidate) private view {
        require(candidate.code.length != 0, "configured address has no code");
    }

    function _requirePositiveOracle(address oracle) private view {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok && data.length >= 160, "invalid oracle response");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        require(answer > 0 && updatedAt != 0 && answeredInRound >= roundId, "invalid oracle round");
    }
}
