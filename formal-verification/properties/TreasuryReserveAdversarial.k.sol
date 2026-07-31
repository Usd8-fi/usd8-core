// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Registry} from "../../src/Registry.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";

/// @dev Six-decimal reserve model whose transfer directions can independently
///      revert, return false, deliver short, or callback. Adversarial behavior is
///      limited to Treasury-initiated pulls/pushes so a strategy can successfully
///      return liquidity before a configured Treasury payout failure.
contract TreasuryAdversarialReserve is ERC20 {
    enum Behavior {
        Exact,
        Revert,
        False,
        NonExact,
        Callback
    }

    error TransferFromReverted();
    error TransferReverted();

    Treasury public treasury;
    IStrategy public callbackStrategy;
    Behavior public transferFromBehavior;
    Behavior public transferBehavior;
    uint256 public transferFromShortfall;
    uint256 public transferShortfall;
    uint256 public callbackAttempts;
    uint256 public callbackSuccesses;
    mapping(uint256 index => bytes4 selector) public callbackSelector;

    constructor() ERC20("Adversarial USDC", "aUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function configureTreasury(Treasury treasury_) external {
        treasury = treasury_;
        _approve(address(this), address(treasury_), type(uint256).max);
    }

    function configureCallbackStrategy(IStrategy strategy_) external {
        callbackStrategy = strategy_;
    }

    function configureTransferFrom(Behavior behavior_, uint256 shortfall_) external {
        transferFromBehavior = behavior_;
        transferFromShortfall = shortfall_;
    }

    function configureTransfer(Behavior behavior_, uint256 shortfall_) external {
        transferBehavior = behavior_;
        transferShortfall = shortfall_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        Behavior selected = msg.sender == address(treasury) ? transferFromBehavior : Behavior.Exact;
        if (selected == Behavior.Revert) revert TransferFromReverted();
        if (selected == Behavior.False) return false;
        if (selected == Behavior.NonExact) {
            _spendAllowance(from, msg.sender, amount);
            _transfer(from, to, amount - transferFromShortfall);
            return true;
        }

        bool success = super.transferFrom(from, to, amount);
        if (selected == Behavior.Callback) _attemptFundPathReentry();
        return success;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Behavior selected = msg.sender == address(treasury) ? transferBehavior : Behavior.Exact;
        if (selected == Behavior.Revert) revert TransferReverted();
        if (selected == Behavior.False) return false;
        if (selected == Behavior.NonExact) {
            _transfer(msg.sender, to, amount - transferShortfall);
            return true;
        }

        bool success = super.transfer(to, amount);
        if (selected == Behavior.Callback) _attemptFundPathReentry();
        return success;
    }

    function _attemptFundPathReentry() internal {
        _attempt(abi.encodeCall(Treasury.mintUSD8, (uint256(1))));
        _attempt(abi.encodeCall(Treasury.redeemUSD8, (uint256(1), uint256(0))));
        _attempt(abi.encodeCall(Treasury.depositToStrategy, (callbackStrategy, uint256(1))));
        _attempt(abi.encodeCall(Treasury.withdrawFromStrategy, (callbackStrategy, uint256(1))));
        _attempt(abi.encodeCall(Treasury.harvestAndDistribute, ()));
    }

    function _attempt(bytes memory data) internal {
        uint256 index = callbackAttempts;
        callbackAttempts = index + 1;
        (bool success, bytes memory returndata) = address(treasury).call(data);
        if (success) callbackSuccesses++;
        if (returndata.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(returndata, 0x20))
            }
            callbackSelector[index] = selector;
        }
    }
}

contract TreasuryAdversarialStrategy is IStrategy {
    IERC20 public immutable reserve;
    uint256 public deployCalls;
    uint256 public withdrawCalls;
    uint256 public lastWithdrawAmount;

    constructor(IERC20 reserve_) {
        reserve = reserve_;
    }

    function underlying() external view returns (address) {
        return address(reserve);
    }

    function deploy(uint256) external {
        deployCalls++;
    }

    function withdraw(uint256 amount) external {
        withdrawCalls++;
        lastWithdrawAmount = amount;
        require(reserve.transfer(msg.sender, amount), "strategy transfer failed");
    }

    function totalAssets() external view returns (uint256) {
        return reserve.balanceOf(address(this));
    }
}

contract TreasuryAdversarialCaller {
    function approveReserve(IERC20 reserve, Treasury treasury, uint256 amount) external {
        reserve.approve(address(treasury), amount);
    }

    function mint(Treasury treasury, uint256 amount) external {
        treasury.mintUSD8(amount);
    }

    function tryMint(Treasury treasury, uint256 amount) external returns (bool success, bytes memory returndata) {
        return address(treasury).call(abi.encodeCall(Treasury.mintUSD8, (amount)));
    }

    function redeem(Treasury treasury, uint256 amount, uint256 minOut) external {
        treasury.redeemUSD8(amount, minOut);
    }

    function tryRedeem(Treasury treasury, uint256 amount, uint256 minOut)
        external
        returns (bool success, bytes memory returndata)
    {
        return address(treasury).call(abi.encodeCall(Treasury.redeemUSD8, (amount, minOut)));
    }

    function transferToken(IERC20 token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

/// @notice E10-E16 reserve-token adversarial properties over production Registry,
///         USD8, and Treasury implementations behind real ERC1967 proxies.
/// @dev Reserve-domain symbolic inputs are uint64 and USD8 redemption inputs are
///      uint128, with explicit assumptions before 1e12 scaling. Strategy count is
///      fixed at N=1. The reserve model is deliberately nonstandard only in the
///      property-selected transfer direction; exact mode is standard OZ ERC-20.
///      NonExact assumes shortfall <= requested amount. Callback properties make
///      the reserve an admin and use an approved strategy so every nested path is
///      rejected specifically by the transient guard, not by ACL or list checks.
contract TreasuryReserveAdversarialKontrolTest is Test {
    uint256 internal constant SCALE = 1e12;

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasury;
    TreasuryAdversarialReserve internal reserve;
    TreasuryAdversarialCaller internal user;
    TreasuryAdversarialStrategy internal strategy;

    function setUp() public {
        reserve = new TreasuryAdversarialReserve();
        user = new TreasuryAdversarialCaller();

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
                    address(new Treasury()), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(reserve))))
                )
            )
        );
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
        reserve.configureTreasury(treasury);

        strategy = new TreasuryAdversarialStrategy(reserve);
        reserve.configureCallbackStrategy(strategy);
        treasury.addStrategy(strategy, type(uint256).max);
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _seedUser(uint64 amount) internal {
        vm.assume(amount > 0);
        reserve.mint(address(user), amount);
        user.approveReserve(reserve, treasury, amount);
        user.mint(treasury, amount);
    }

    function _assertFiveCallbacksBlocked() internal view {
        assert(reserve.callbackAttempts() == 5);
        assert(reserve.callbackSuccesses() == 0);
        bytes4 expected = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
        for (uint256 i = 0; i < 5; i++) {
            assert(reserve.callbackSelector(i) == expected);
        }
    }

    function _assertFailedMintUnchanged(uint256 amount, uint256 walletBefore, uint256 allowanceBefore) internal view {
        assert(reserve.balanceOf(address(user)) == walletBefore);
        assert(reserve.allowance(address(user), address(treasury)) == allowanceBefore);
        assert(reserve.balanceOf(address(treasury)) == 0);
        assert(usd8.balanceOf(address(user)) == 0);
        assert(usd8.totalSupply() == 0);
        assert(amount > 0);
    }

    function test_E10_zeroSupplyNonzeroRedeemRevertsExactNoUsd8Supply(uint128 amount, uint64 donatedReserve) public {
        vm.assume(amount > 0);
        reserve.mint(address(treasury), donatedReserve);
        uint256 reserveBefore = reserve.balanceOf(address(treasury));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, amount, 0);

        assert(!success);
        assert(_selector(returndata) == Treasury.NoUsd8Supply.selector);
        assert(usd8.totalSupply() == 0);
        assert(usd8.balanceOf(address(user)) == 0);
        assert(reserve.balanceOf(address(treasury)) == reserveBefore);
        assert(reserve.balanceOf(address(user)) == 0);
    }

    function test_E11_redeemAboveCallerBalanceFailsBurnAndIsAtomic(uint64 mintedReserve, uint64 retainedUsd8) public {
        vm.assume(mintedReserve > 0);
        _seedUser(mintedReserve);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(retainedUsd8 < supplyBefore);
        user.transferToken(usd8, address(0xBEEF), supplyBefore - retainedUsd8);
        uint256 redeemAmount = uint256(retainedUsd8) + 1;
        uint256 reserveBefore = reserve.balanceOf(address(treasury));
        uint256 recipientBefore = usd8.balanceOf(address(0xBEEF));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, redeemAmount, 0);

        assert(!success);
        assert(_selector(returndata) == IERC20Errors.ERC20InsufficientBalance.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(user)) == retainedUsd8);
        assert(usd8.balanceOf(address(0xBEEF)) == recipientBefore);
        assert(reserve.balanceOf(address(treasury)) == reserveBefore);
        assert(reserve.balanceOf(address(user)) == 0);
    }

    function test_E12_revertingTransferFromRollsBackMint(uint64 amount) public {
        vm.assume(amount > 0);
        reserve.mint(address(user), amount);
        user.approveReserve(reserve, treasury, amount);
        reserve.configureTransferFrom(TreasuryAdversarialReserve.Behavior.Revert, 0);

        (bool success, bytes memory returndata) = user.tryMint(treasury, amount);

        assert(!success);
        assert(_selector(returndata) == TreasuryAdversarialReserve.TransferFromReverted.selector);
        _assertFailedMintUnchanged(amount, amount, amount);
    }

    function test_E12_falseTransferFromRollsBackMint(uint64 amount) public {
        vm.assume(amount > 0);
        reserve.mint(address(user), amount);
        user.approveReserve(reserve, treasury, amount);
        reserve.configureTransferFrom(TreasuryAdversarialReserve.Behavior.False, 0);

        (bool success, bytes memory returndata) = user.tryMint(treasury, amount);

        assert(!success);
        assert(_selector(returndata) == SafeERC20.SafeERC20FailedOperation.selector);
        _assertFailedMintUnchanged(amount, amount, amount);
    }

    function test_E13_inboundShortByExactlyToleranceIsAccepted(uint64 amount) public {
        uint256 tolerance = treasury.RESERVE_CHECK_TOLERANCE();
        vm.assume(amount > tolerance);
        reserve.mint(address(user), amount);
        user.approveReserve(reserve, treasury, amount);
        reserve.configureTransferFrom(TreasuryAdversarialReserve.Behavior.NonExact, tolerance);

        user.mint(treasury, amount);

        assert(reserve.balanceOf(address(user)) == tolerance);
        assert(reserve.balanceOf(address(treasury)) == uint256(amount) - tolerance);
        assert(reserve.allowance(address(user), address(treasury)) == 0);
        assert(usd8.balanceOf(address(user)) == uint256(amount) * SCALE);
        assert(usd8.totalSupply() == uint256(amount) * SCALE);
        assert(treasury.getReserveBalance() * SCALE + tolerance * SCALE == usd8.totalSupply());
    }

    function test_E13_inboundShortByTolerancePlusOneIsRejectedAtomically(uint64 amount) public {
        uint256 shortfall = treasury.RESERVE_CHECK_TOLERANCE() + 1;
        vm.assume(amount > shortfall);
        reserve.mint(address(user), amount);
        user.approveReserve(reserve, treasury, amount);
        reserve.configureTransferFrom(TreasuryAdversarialReserve.Behavior.NonExact, shortfall);

        (bool success, bytes memory returndata) = user.tryMint(treasury, amount);

        assert(!success);
        assert(_selector(returndata) == Treasury.ReserveSupplyStatusWorsened.selector);
        _assertFailedMintUnchanged(amount, amount, amount);
    }

    function test_E14_revertingOutboundTransferAfterStrategyPullRollsEverythingBack(uint64 amount) public {
        vm.assume(amount > 0);
        _seedUser(amount);
        treasury.depositToStrategy(strategy, amount);
        reserve.configureTransfer(TreasuryAdversarialReserve.Behavior.Revert, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userUsd8Before = usd8.balanceOf(address(user));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, uint256(amount) * SCALE, amount);

        assert(!success);
        // This selector can only come from the final Treasury payout: the strategy's
        // preceding transfer into Treasury is deliberately exact for non-Treasury callers.
        assert(_selector(returndata) == TreasuryAdversarialReserve.TransferReverted.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(user)) == userUsd8Before);
        assert(reserve.balanceOf(address(user)) == 0);
        assert(reserve.balanceOf(address(treasury)) == 0);
        assert(reserve.balanceOf(address(strategy)) == amount);
        assert(strategy.withdrawCalls() == 0);
        assert(strategy.lastWithdrawAmount() == 0);
    }

    function test_E14_falseOutboundTransferAfterStrategyPullRollsEverythingBack(uint64 amount) public {
        vm.assume(amount > 0);
        _seedUser(amount);
        treasury.depositToStrategy(strategy, amount);
        reserve.configureTransfer(TreasuryAdversarialReserve.Behavior.False, 0);
        uint256 supplyBefore = usd8.totalSupply();
        uint256 userUsd8Before = usd8.balanceOf(address(user));

        (bool success, bytes memory returndata) = user.tryRedeem(treasury, uint256(amount) * SCALE, amount);

        assert(!success);
        assert(_selector(returndata) == SafeERC20.SafeERC20FailedOperation.selector);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(address(user)) == userUsd8Before);
        assert(reserve.balanceOf(address(user)) == 0);
        assert(reserve.balanceOf(address(treasury)) == 0);
        assert(reserve.balanceOf(address(strategy)) == amount);
        assert(strategy.withdrawCalls() == 0);
        assert(strategy.lastWithdrawAmount() == 0);
    }

    function test_E15_transferFromCallbackCannotReenterFiveGuardedFundPaths(uint64 initial, uint64 callbackMint)
        public
    {
        vm.assume(initial > 0 && callbackMint > 0);
        _seedUser(initial);
        registry.setAdmin(address(reserve), true);
        reserve.mint(address(user), callbackMint);
        user.approveReserve(reserve, treasury, callbackMint);
        reserve.configureTransferFrom(TreasuryAdversarialReserve.Behavior.Callback, 0);
        uint256 supplyBefore = usd8.totalSupply();

        user.mint(treasury, callbackMint);

        _assertFiveCallbacksBlocked();
        assert(usd8.totalSupply() == supplyBefore + uint256(callbackMint) * SCALE);
        assert(usd8.balanceOf(address(user)) == usd8.totalSupply());
        assert(reserve.balanceOf(address(user)) == 0);
        assert(reserve.balanceOf(address(treasury)) == uint256(initial) + callbackMint);
        assert(strategy.deployCalls() == 0 && strategy.withdrawCalls() == 0);
    }

    function test_E16_transferCallbackCannotReenterFiveGuardedFundPaths(uint64 amount) public {
        vm.assume(amount > 0);
        _seedUser(amount);
        registry.setAdmin(address(reserve), true);
        reserve.configureTransfer(TreasuryAdversarialReserve.Behavior.Callback, 0);

        user.redeem(treasury, uint256(amount) * SCALE, amount);

        _assertFiveCallbacksBlocked();
        assert(usd8.totalSupply() == 0);
        assert(usd8.balanceOf(address(user)) == 0);
        assert(reserve.balanceOf(address(user)) == amount);
        assert(reserve.balanceOf(address(treasury)) == 0);
        assert(strategy.deployCalls() == 0 && strategy.withdrawCalls() == 0);
    }

    function test_minOutEqualitySucceedsAtComputedPayout(uint64 mintedReserve, uint128 redeemAmount) public {
        vm.assume(mintedReserve > 0);
        _seedUser(mintedReserve);
        uint256 supplyBefore = usd8.totalSupply();
        vm.assume(redeemAmount > 0 && redeemAmount <= supplyBefore);
        uint256 expectedPayout = uint256(redeemAmount) / SCALE;

        user.redeem(treasury, redeemAmount, expectedPayout);

        assert(reserve.balanceOf(address(user)) == expectedPayout);
        assert(reserve.balanceOf(address(treasury)) == uint256(mintedReserve) - expectedPayout);
        assert(usd8.balanceOf(address(user)) == supplyBefore - redeemAmount);
        assert(usd8.totalSupply() == supplyBefore - redeemAmount);
    }
}
