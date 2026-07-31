// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {Registry} from "../../src/Registry.sol";

contract CoverPoolHarnessToken is ERC20 {
    uint8 internal immutable customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CoverPoolHarnessFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

contract CoverPoolHarnessInsurance {
    uint256 public activeIncidentId;

    function setActiveIncidentId(uint256 id) external {
        activeIncidentId = id;
    }

    function pay(SingleAssetCoverPool pool, address to, uint256 amount) external {
        pool.payClaim(to, amount);
    }
}

/// @notice Shared production-proxy fixture for SingleAssetCoverPool properties.
/// @dev [B:EPOCHS<=3,USERS<=3] queue/order proofs state explicit finite bounds.
///      [C:TOKEN] vanilla OZ ERC20 behavior is concrete; adversarial callbacks and
///      malformed returns are isolated in dedicated properties.
abstract contract SingleAssetCoverPoolKontrolBase is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant OUTSIDER = address(0xBAD);
    address internal constant RECIPIENT = address(0xBEEF);

    Registry internal registry;
    SingleAssetCoverPool internal implementation;
    SingleAssetCoverPool internal pool;
    CoverPoolHarnessToken internal assetToken;
    CoverPoolHarnessToken internal rewardToken;
    CoverPoolHarnessFeed internal feed;
    CoverPoolHarnessInsurance internal insurance;

    function setUp() public virtual {
        vm.warp(1_000_000);
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        assetToken = new CoverPoolHarnessToken("Pool Asset", "ASSET", 18);
        rewardToken = new CoverPoolHarnessToken("USD8", "USD8", 18);
        feed = new CoverPoolHarnessFeed();
        insurance = new CoverPoolHarnessInsurance();
        registry.setUsd8(address(rewardToken));
        implementation = new SingleAssetCoverPool();
        pool = SingleAssetCoverPool(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(assetToken)), "USD8 Asset Cover", "cpASSET")
                    )
                )
            )
        );
        registry.addPool(address(pool), address(feed));
        registry.setDefiInsurance(address(insurance));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _assertExactFourByteError(bool success, bytes memory returndata, bytes4 expected) internal pure {
        assert(!success);
        assert(returndata.length == 4);
        assert(_selector(returndata) == expected);
    }

    function _callPoolAs(address caller, bytes memory data) internal returns (bool success, bytes memory returndata) {
        vm.prank(caller);
        return address(pool).call(data);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        assetToken.mint(user, assets);
        vm.startPrank(user);
        assetToken.approve(address(pool), assets);
        shares = pool.deposit(assets, user);
        vm.stopPrank();
    }

    function _mintShares(address user, uint256 shares) internal returns (uint256 assets) {
        assets = pool.previewMint(shares);
        assetToken.mint(user, assets);
        vm.startPrank(user);
        assetToken.approve(address(pool), assets);
        assets = pool.mint(shares, user);
        vm.stopPrank();
    }

    function _notify(address distributor, uint256 amount) internal {
        rewardToken.mint(distributor, amount);
        vm.startPrank(distributor);
        rewardToken.approve(address(pool), amount);
        pool.receiveProfitDistribution(amount);
        vm.stopPrank();
    }

    function _request(address user, uint256 shares) internal returns (uint64 epoch) {
        vm.prank(user);
        pool.requestRedeem(shares);
        (, epoch) = pool.exitRequests(user);
    }

    function _freeze() internal {
        insurance.setActiveIncidentId(1);
    }

    function _unfreeze() internal {
        insurance.setActiveIncidentId(0);
    }
}
