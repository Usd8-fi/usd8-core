// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";

/// @dev Standard 6-decimal ERC-20 behavior plus test-only, unrestricted supply
///      controls. `burnFromAnyAddress` models an exogenous loss of idle reserve;
///      it is not intended to model a production USDC capability.
contract TreasuryKontrolUSDC is ERC20 {
    constructor() ERC20("Kontrol USDC", "kUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFromAnyAddress(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Distinct user call frame keeps token ownership, approvals, and Treasury
///      calls explicit without making these accounting proofs depend on prank
///      cheat-code state.
contract TreasuryKontrolCaller {
    function approveReserve(IERC20 reserve, Treasury treasury, uint256 amount) external {
        reserve.approve(address(treasury), amount);
    }

    function mint(Treasury treasury, uint256 amount) external {
        treasury.mintUSD8(amount);
    }

    function redeem(Treasury treasury, uint256 amount, uint256 minUsdcOut) external {
        treasury.redeemUSD8(amount, minUsdcOut);
    }

    function tryMint(Treasury treasury, uint256 amount) external returns (bool success, bytes memory returndata) {
        return address(treasury).call(abi.encodeCall(Treasury.mintUSD8, (amount)));
    }

    function tryRedeem(Treasury treasury, uint256 amount, uint256 minUsdcOut)
        external
        returns (bool success, bytes memory returndata)
    {
        return address(treasury).call(abi.encodeCall(Treasury.redeemUSD8, (amount, minUsdcOut)));
    }
}

/// @notice Small symbolic Treasury properties over real Registry, USD8, and
///         Treasury implementations behind ERC1967 proxies, with no strategies.
/// @dev Symbolic reserve-domain inputs are uint64; tests that add reserve
///      quantities assume the sum is at most type(uint64).max. Successful
///      partial-redemption amounts are uint128 but assumed in [1, supply), and
///      successful healthy amounts in [1, supply]. Since supply is at most
///      type(uint64).max * 1e12, every explicit scale and ratio cross-product
///      below fits uint256. Full distressed redemption uses amount == supply.
contract TreasuryKontrolTest is Test {
    uint256 internal constant SCALE = 1e12;

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryKontrolUSDC internal usdc;
    TreasuryKontrolCaller internal user;

    function setUp() public {
        usdc = new TreasuryKontrolUSDC();
        user = new TreasuryKontrolCaller();

        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        treasury = Treasury(
            address(
                new ERC1967Proxy(
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(usdc))))
                )
            )
        );

        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _mintToUser(uint64 amount) internal {
        usdc.mint(address(user), amount);
        user.approveReserve(usdc, treasury, amount);
        user.mint(treasury, amount);
    }

    function _makeDistressed(uint64 mintedUsdc, uint64 lossUsdc) internal {
        vm.assume(mintedUsdc > 1);
        vm.assume(lossUsdc > 0 && lossUsdc < mintedUsdc);
        _mintToUser(mintedUsdc);
        usdc.burnFromAnyAddress(address(treasury), lossUsdc);
    }

    function test_mintExactDeltasFromExistingHealthyStateAndFiniteAllowanceDecrease(
        uint64 existingUsdc,
        uint64 mintUsdc,
        uint64 allowanceRemainder
    ) public {
        vm.assume(existingUsdc > 0);
        vm.assume(mintUsdc > 0);
        vm.assume(uint256(existingUsdc) + mintUsdc <= type(uint64).max);
        _mintToUser(existingUsdc);

        usdc.mint(address(user), mintUsdc);
        // Zero remainder subsumes the old exact-sized case; every positive
        // remainder is a finite oversized allowance.
        user.approveReserve(usdc, treasury, uint256(mintUsdc) + allowanceRemainder);

        uint256 walletUsdcBefore = usdc.balanceOf(address(user));
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 walletUsd8Before = usd8.balanceOf(address(user));
        uint256 supplyBefore = usd8.totalSupply();

        user.mint(treasury, mintUsdc);

        assert(usdc.balanceOf(address(user)) == walletUsdcBefore - mintUsdc);
        assert(treasury.getReserveBalance() == reserveBefore + mintUsdc);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before + uint256(mintUsdc) * SCALE);
        assert(usd8.totalSupply() == supplyBefore + uint256(mintUsdc) * SCALE);
        assert(usdc.allowance(address(user), address(treasury)) == allowanceRemainder);
    }

    function test_mintWithMaxAllowanceDoesNotConsumeAllowance(uint64 usdcAmount) public {
        vm.assume(usdcAmount > 0);
        usdc.mint(address(user), usdcAmount);
        user.approveReserve(usdc, treasury, type(uint256).max);

        uint256 walletUsdcBefore = usdc.balanceOf(address(user));
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 walletUsd8Before = usd8.balanceOf(address(user));
        uint256 supplyBefore = usd8.totalSupply();

        user.mint(treasury, usdcAmount);

        assert(usdc.balanceOf(address(user)) == walletUsdcBefore - usdcAmount);
        assert(treasury.getReserveBalance() == reserveBefore + usdcAmount);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before + uint256(usdcAmount) * SCALE);
        assert(usd8.totalSupply() == supplyBefore + uint256(usdcAmount) * SCALE);
        assert(usdc.allowance(address(user), address(treasury)) == type(uint256).max);
    }

    function test_mintExactDeltasFromExistingLossDistressedState(uint64 existingUsdc, uint64 lossUsdc, uint64 mintUsdc)
        public
    {
        vm.assume(mintUsdc > 0);
        vm.assume(uint256(existingUsdc) + mintUsdc <= type(uint64).max);
        _makeDistressed(existingUsdc, lossUsdc);

        usdc.mint(address(user), mintUsdc);
        user.approveReserve(usdc, treasury, mintUsdc);

        uint256 walletUsdcBefore = usdc.balanceOf(address(user));
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 walletUsd8Before = usd8.balanceOf(address(user));
        uint256 supplyBefore = usd8.totalSupply();
        assert(reserveBefore * SCALE < supplyBefore);

        user.mint(treasury, mintUsdc);

        assert(usdc.balanceOf(address(user)) == walletUsdcBefore - mintUsdc);
        assert(treasury.getReserveBalance() == reserveBefore + mintUsdc);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before + uint256(mintUsdc) * SCALE);
        assert(usd8.totalSupply() == supplyBefore + uint256(mintUsdc) * SCALE);
        assert(usdc.allowance(address(user), address(treasury)) == 0);
        assert(treasury.getReserveBalance() * SCALE < usd8.totalSupply());
    }

    function test_healthyRedeemArbitraryAmountWithSymbolicSurplus(
        uint64 mintedUsdc,
        uint64 surplusUsdc,
        uint128 redeemAmount
    ) public {
        vm.assume(mintedUsdc > 0);
        vm.assume(uint256(mintedUsdc) + surplusUsdc <= type(uint64).max);
        _mintToUser(mintedUsdc);
        // Zero subsumes the exactly collateralized case; every positive value
        // exercises the strict-surplus healthy branch.
        usdc.mint(address(treasury), surplusUsdc);

        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(redeemAmount > 0 && redeemAmount <= supplyBefore);
        uint256 expectedPayout = uint256(redeemAmount) / SCALE;
        uint256 walletUsdcBefore = usdc.balanceOf(address(user));
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 walletUsd8Before = usd8.balanceOf(address(user));
        assert(reserveBefore * SCALE == supplyBefore + uint256(surplusUsdc) * SCALE);

        user.redeem(treasury, redeemAmount, expectedPayout);

        assert(usdc.balanceOf(address(user)) == walletUsdcBefore + expectedPayout);
        assert(treasury.getReserveBalance() == reserveBefore - expectedPayout);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before - redeemAmount);
        assert(usd8.totalSupply() == supplyBefore - redeemAmount);
    }

    function test_distressedRedeemArbitraryPartialAmountFormulaBurnAndRatio(
        uint64 mintedUsdc,
        uint64 lossUsdc,
        uint128 redeemAmount
    ) public {
        _makeDistressed(mintedUsdc, lossUsdc);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(redeemAmount > 0 && redeemAmount < supplyBefore);

        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 reserveInUsd8 = reserveBefore * SCALE;
        assert(reserveInUsd8 < supplyBefore);
        uint256 expectedPayout = Math.mulDiv(redeemAmount, reserveInUsd8, supplyBefore) / SCALE;
        uint256 walletUsdcBefore = usdc.balanceOf(address(user));
        uint256 walletUsd8Before = usd8.balanceOf(address(user));

        user.redeem(treasury, redeemAmount, expectedPayout);

        uint256 reserveAfter = treasury.getReserveBalance();
        uint256 supplyAfter = usd8.totalSupply();
        uint256 actualPayout = usdc.balanceOf(address(user)) - walletUsdcBefore;
        assert(actualPayout == expectedPayout);
        assert(actualPayout * supplyBefore <= uint256(redeemAmount) * reserveBefore);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before - redeemAmount);
        assert(supplyAfter == supplyBefore - redeemAmount);
        assert(reserveAfter == reserveBefore - actualPayout);

        // Floor rounding weakly improves the exact reserve/supply ratio.
        assert(reserveAfter * supplyBefore >= reserveBefore * supplyAfter);
        // This is the production modifier's weaker, 100-base-unit tolerance rule.
        uint256 toleranceInUsd8 = treasury.RESERVE_CHECK_TOLERANCE() * SCALE;
        assert((reserveAfter * SCALE + toleranceInUsd8) * supplyBefore >= reserveInUsd8 * supplyAfter);
    }

    function test_fullDistressedRedeemConsumesAllSupplyAndReserve(uint64 mintedUsdc, uint64 lossUsdc) public {
        _makeDistressed(mintedUsdc, lossUsdc);

        uint256 supplyBefore = usd8.totalSupply();
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 walletUsdcBefore = usdc.balanceOf(address(user));
        uint256 walletUsd8Before = usd8.balanceOf(address(user));
        assert(reserveBefore * SCALE < supplyBefore);

        user.redeem(treasury, supplyBefore, reserveBefore);

        assert(usdc.balanceOf(address(user)) == walletUsdcBefore + reserveBefore);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before - supplyBefore);
        assert(treasury.getReserveBalance() == 0);
        assert(usd8.totalSupply() == 0);
    }

    function test_minUsdcOutAboveDistressedPayoutRevertsAtomically(
        uint64 mintedUsdc,
        uint64 lossUsdc,
        uint128 redeemAmount
    ) public {
        _makeDistressed(mintedUsdc, lossUsdc);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(redeemAmount > 0 && redeemAmount <= supplyBefore);

        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 expectedPayout = Math.mulDiv(redeemAmount, reserveBefore * SCALE, supplyBefore) / SCALE;
        uint256 walletUsdcBefore = usdc.balanceOf(address(user));
        uint256 walletUsd8Before = usd8.balanceOf(address(user));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, redeemAmount, expectedPayout + 1);

        assert(!success);
        assert(_selector(returndata) == Treasury.InsufficientUsdcOut.selector);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usdc.balanceOf(address(user)) == walletUsdcBefore);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before);
    }

    function test_zeroMintRevertsAtomically(uint64 walletUsdc, uint64 allowance_) public {
        usdc.mint(address(user), walletUsdc);
        user.approveReserve(usdc, treasury, allowance_);
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 supplyBefore = usd8.totalSupply();

        (bool success, bytes memory returndata) = user.tryMint(treasury, 0);

        assert(!success);
        assert(_selector(returndata) == Treasury.ZeroAmount.selector);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usdc.balanceOf(address(user)) == walletUsdc);
        assert(usdc.allowance(address(user), address(treasury)) == allowance_);
        assert(usd8.balanceOf(address(user)) == 0);
    }

    function test_zeroRedeemRevertsAtomically(uint64 mintedUsdc) public {
        vm.assume(mintedUsdc > 0);
        _mintToUser(mintedUsdc);
        uint256 reserveBefore = treasury.getReserveBalance();
        uint256 supplyBefore = usd8.totalSupply();
        uint256 walletUsdcBefore = usdc.balanceOf(address(user));
        uint256 walletUsd8Before = usd8.balanceOf(address(user));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, 0, 0);

        assert(!success);
        assert(_selector(returndata) == Treasury.ZeroAmount.selector);
        assert(treasury.getReserveBalance() == reserveBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usdc.balanceOf(address(user)) == walletUsdcBefore);
        assert(usd8.balanceOf(address(user)) == walletUsd8Before);
    }
}
