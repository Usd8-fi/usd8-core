// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {SingleAssetCoverPoolKontrolBase} from "./SingleAssetCoverPoolHarness.k.sol";

contract CoverPoolModeToken is ERC20 {
    enum ReturnMode {
        Normal,
        NoReturn,
        False,
        Malformed,
        Revert
    }

    ReturnMode public transferMode;
    ReturnMode public transferFromMode;

    constructor() ERC20("Mode Token", "MODE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferModes(ReturnMode transfer_, ReturnMode transferFrom_) external {
        transferMode = transfer_;
        transferFromMode = transferFrom_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        ReturnMode mode = transferMode;
        if (mode == ReturnMode.Revert) revert("TRANSFER_REVERT");
        if (mode == ReturnMode.False) return false;
        _transfer(msg.sender, to, amount);
        if (mode == ReturnMode.NoReturn) {
            assembly { return(0, 0) }
        }
        if (mode == ReturnMode.Malformed) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        ReturnMode mode = transferFromMode;
        if (mode == ReturnMode.Revert) revert("TRANSFER_FROM_REVERT");
        if (mode == ReturnMode.False) return false;
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        if (mode == ReturnMode.NoReturn) {
            assembly { return(0, 0) }
        }
        if (mode == ReturnMode.Malformed) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return true;
    }
}

contract CoverPoolFalseReturnToken is ERC20 {
    constructor() ERC20("False Token", "FALSE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract CoverPoolReentrantToken is ERC20 {
    SingleAssetCoverPool public target;
    bytes public reentryData;

    constructor() ERC20("Reentrant Token", "REENTER") {}

    function setTarget(SingleAssetCoverPool target_) external {
        target = target_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (address(target) != address(0)) {
            (, reentryData) =
                address(target).call(abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(0), address(this))));
        }
        return super.transferFrom(from, to, value);
    }
}

/// @notice Fixed-bytecode callback token used to characterize outward token
///         callbacks without allowing recursion in the model itself.
contract CoverPoolCallbackToken is ERC20 {
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnTransfer;
    bool public callbackOnTransferFrom;
    bool public nestedSuccess;
    bytes public nestedReturndata;
    bool private entered;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureCallback(address target, bytes calldata data, bool onTransfer, bool onTransferFrom) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnTransfer = onTransfer;
        callbackOnTransferFrom = onTransferFrom;
        delete nestedReturndata;
        nestedSuccess = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        if (callbackOnTransfer) _callback();
        return result;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (callbackOnTransferFrom) _callback();
        return result;
    }

    function _callback() internal {
        if (entered || callbackTarget == address(0)) return;
        entered = true;
        (nestedSuccess, nestedReturndata) = callbackTarget.call(callbackData);
        entered = false;
    }
}

/// @notice Exact reachable-error payload closure for the pool's compiled ABI.
/// @dev ABI-declared but structurally unreachable vendor errors are classified in
///      single-asset-cover-pool-abi-closure.md rather than fabricated as obligations.
contract SingleAssetCoverPoolErrorsKontrolTest is SingleAssetCoverPoolKontrolBase {
    uint256 internal constant OWNER_KEY = 0xA11CE55;
    uint256 internal constant WRONG_KEY = 0xB0B55;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant HIGH_S = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a1;

    function _freshPool(IERC20 asset_) internal returns (SingleAssetCoverPool fresh) {
        fresh = SingleAssetCoverPool(
            address(
                new ERC1967Proxy(
                    address(new SingleAssetCoverPool()),
                    abi.encodeCall(SingleAssetCoverPool.initialize, (registry, asset_, "Error Cover", "cpERR"))
                )
            )
        );
    }

    function _assertExactRevert(address target, bytes memory callData, bytes memory expected) internal {
        (bool success, bytes memory data) = target.call(callData);
        assert(!success);
        assert(keccak256(data) == keccak256(expected));
    }

    function _assertModeFailureAs(
        address caller,
        address target,
        bytes memory callData,
        CoverPoolModeToken.ReturnMode mode,
        address token,
        string memory revertReason
    ) internal {
        vm.prank(caller);
        (bool success, bytes memory data) = target.call(callData);
        assert(!success);
        bytes memory expected = mode == CoverPoolModeToken.ReturnMode.Revert
            ? abi.encodeWithSignature("Error(string)", revertReason)
            : abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, token);
        assert(data.length == expected.length);
        assert(keccak256(data) == keccak256(expected));
    }

    function test_contractSpecificArgumentErrorsCarryExactPayloads() public {
        uint256 shares = _deposit(ALICE, 10);
        vm.prank(ALICE);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(SingleAssetCoverPool.requestRedeem, (shares + 1)),
            abi.encodeWithSelector(SingleAssetCoverPool.InsufficientShares.selector, shares + 1, shares)
        );

        uint64 epoch = _request(ALICE, shares);
        vm.prank(ALICE);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(SingleAssetCoverPool.completeRedeem, (ALICE)),
            abi.encodeWithSelector(SingleAssetCoverPool.CooldownNotElapsed.selector, epoch)
        );

        _assertExactRevert(
            address(pool),
            abi.encodeCall(SingleAssetCoverPool.payClaim, (RECIPIENT, uint256(1))),
            abi.encodeWithSelector(SingleAssetCoverPool.NotDefiInsurance.selector, address(this))
        );
        _assertExactRevert(
            address(insurance),
            abi.encodeCall(insurance.pay, (pool, RECIPIENT, uint256(11))),
            abi.encodeWithSelector(SingleAssetCoverPool.PayoutExceedsPoolAssets.selector, uint256(11), uint256(10))
        );
    }

    function test_rewardRateZeroCarriesExactTotalAndDuration() public {
        _deposit(ALICE, 1);
        pool.setRewardsDuration(10);
        rewardToken.mint(BOB, 1);
        vm.prank(BOB);
        rewardToken.approve(address(pool), 1);
        vm.prank(BOB);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(SingleAssetCoverPool.receiveProfitDistribution, (uint256(1))),
            abi.encodeWithSelector(SingleAssetCoverPool.RewardRateZero.selector, uint256(1), uint256(10))
        );
    }

    function test_sweepErrorsCarryExactRecipientAndTokenPayloads() public {
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.sweepToken, (IERC20(address(assetToken)), address(pool))),
            abi.encodeWithSelector(SharedBase.InvalidSweepRecipient.selector, address(pool))
        );
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.sweepToken, (IERC20(address(assetToken)), RECIPIENT)),
            abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(assetToken))
        );
    }

    function test_reachableERC20ErrorsCarryExactPayloads() public {
        uint256 shares = _deposit(ALICE, 10);
        vm.prank(ALICE);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.transfer, (BOB, shares + 1)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, shares, shares + 1)
        );
        vm.prank(ALICE);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.transfer, (address(0), uint256(1))),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        vm.prank(ALICE);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.approve, (address(0), uint256(1))),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
        vm.prank(BOB);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.transferFrom, (ALICE, BOB, uint256(1))),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, uint256(0), uint256(1))
        );
        vm.prank(BOB);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.transferFrom, (address(0), BOB, uint256(0))),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
        );
    }

    function test_reachablePermitErrorsAreExactAndRollbackNonce() public {
        address owner = vm.addr(OWNER_KEY);
        uint256 nonce = pool.nonces(owner);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(
                pool.permit, (owner, BOB, uint256(1), block.timestamp - 1, uint8(27), bytes32(0), bytes32(0))
            ),
            abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, block.timestamp - 1)
        );
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.permit, (owner, BOB, uint256(1), block.timestamp, uint8(0), bytes32(0), bytes32(0))),
            abi.encodeWithSelector(ECDSA.ECDSAInvalidSignature.selector)
        );
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.permit, (owner, BOB, uint256(1), block.timestamp, uint8(27), bytes32(0), HIGH_S)),
            abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, HIGH_S)
        );

        uint256 deadline = block.timestamp + 1;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, BOB, uint256(1), nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", pool.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_KEY, digest);
        address wrongSigner = vm.addr(WRONG_KEY);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(pool.permit, (owner, BOB, uint256(1), deadline, v, r, s)),
            abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, wrongSigner, owner)
        );
        assert(pool.nonces(owner) == nonce);
        assert(pool.allowance(owner, BOB) == 0);
    }

    function test_initializeZeroBindingsAndReinitializationUseExactErrors() public {
        SingleAssetCoverPool fresh = SingleAssetCoverPool(
            address(new ERC1967Proxy(address(new SingleAssetCoverPool()), abi.encodeWithSignature("totalAssets()")))
        );
        _assertExactRevert(
            address(fresh),
            abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(0)), "x", "x")),
            abi.encodeWithSelector(SharedBase.ZeroAddress.selector)
        );
        _assertExactRevert(
            address(fresh),
            abi.encodeCall(
                SingleAssetCoverPool.initialize, (Registry(address(0)), IERC20(address(assetToken)), "x", "x")
            ),
            abi.encodeWithSelector(SharedBase.ZeroAddress.selector)
        );
    }

    function test_initializeRejectsRegistryWithZeroUsd8ExactlyAndFailedAttemptIsRetryable() public {
        Registry blankRegistry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        SingleAssetCoverPool fresh = SingleAssetCoverPool(
            address(new ERC1967Proxy(address(new SingleAssetCoverPool()), abi.encodeWithSignature("totalAssets()")))
        );

        _assertExactRevert(
            address(fresh),
            abi.encodeCall(
                SingleAssetCoverPool.initialize, (blankRegistry, IERC20(address(assetToken)), "Retry Cover", "cpRETRY")
            ),
            abi.encodeWithSelector(SharedBase.ZeroAddress.selector)
        );
        assert(address(fresh.registry()) == address(0));
        assert(fresh.asset() == address(0));
        assert(address(fresh.usd8()) == address(0));
        assert(fresh.rewardsDuration() == 0);
        assert(fresh.totalAssets() == 0 && fresh.totalSupply() == 0);

        blankRegistry.setUsd8(address(rewardToken));
        fresh.initialize(blankRegistry, IERC20(address(assetToken)), "Retry Cover", "cpRETRY");
        assert(address(fresh.registry()) == address(blankRegistry));
        assert(fresh.asset() == address(assetToken));
        assert(address(fresh.usd8()) == address(rewardToken));
        assert(keccak256(bytes(fresh.name())) == keccak256(bytes("Retry Cover")));
    }

    function test_exitEpochUint64DowncastErrorIsExact() public {
        registry.setExitTimingConfig(Registry.ExitTimingConfig({unstakeCooldown: 1, exitBatchInterval: 1}));
        uint256 shares = _deposit(ALICE, 1);
        vm.warp(type(uint64).max);
        vm.prank(ALICE);
        _assertExactRevert(
            address(pool),
            abi.encodeCall(SingleAssetCoverPool.requestRedeem, (shares)),
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(64), uint256(type(uint64).max) + 1
            )
        );
    }

    function test_falseReturnAssetUsesExactSafeERC20ErrorAndRollsBack() public {
        CoverPoolFalseReturnToken falseToken = new CoverPoolFalseReturnToken();
        SingleAssetCoverPool falsePool = _freshPool(IERC20(address(falseToken)));
        falseToken.mint(ALICE, 10);
        vm.prank(ALICE);
        falseToken.approve(address(falsePool), 10);
        vm.prank(ALICE);
        _assertExactRevert(
            address(falsePool),
            abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(10), ALICE)),
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falseToken))
        );
        assert(falsePool.totalAssets() == 0 && falsePool.totalSupply() == 0);
    }

    function _entryModePool(CoverPoolModeToken.ReturnMode mode)
        internal
        returns (SingleAssetCoverPool modePool, CoverPoolModeToken token)
    {
        token = new CoverPoolModeToken();
        modePool = _freshPool(IERC20(address(token)));
        token.mint(ALICE, 10);
        vm.prank(ALICE);
        token.approve(address(modePool), 10);
        token.setTransferModes(CoverPoolModeToken.ReturnMode.Normal, mode);
    }

    function _assertEntryModeFailure(bool mintCall, CoverPoolModeToken.ReturnMode mode, string memory revertReason)
        internal
    {
        (SingleAssetCoverPool modePool, CoverPoolModeToken token) = _entryModePool(mode);
        bytes memory callData = mintCall
            ? abi.encodeCall(SingleAssetCoverPool.mint, (uint256(10_000), BOB))
            : abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(10), BOB));
        _assertModeFailureAs(ALICE, address(modePool), callData, mode, address(token), revertReason);
        _assertEntryRollback(modePool, token, 10);
    }

    function test_depositTransferFromFalseHasExactErrorAndCompleteRollback() public {
        _assertEntryModeFailure(false, CoverPoolModeToken.ReturnMode.False, "");
    }

    function test_depositTransferFromRevertHasExactReturndataAndCompleteRollback() public {
        _assertEntryModeFailure(false, CoverPoolModeToken.ReturnMode.Revert, "TRANSFER_FROM_REVERT");
    }

    function test_depositTransferFromMalformedHasExactErrorAndCompleteRollback() public {
        _assertEntryModeFailure(false, CoverPoolModeToken.ReturnMode.Malformed, "");
    }

    function test_depositTransferFromNoReturnSucceedsWithExactDeltas() public {
        (SingleAssetCoverPool modePool, CoverPoolModeToken token) =
            _entryModePool(CoverPoolModeToken.ReturnMode.NoReturn);
        vm.prank(ALICE);
        assert(modePool.deposit(10, BOB) == 10_000);
        _assertEntrySuccess(modePool, token);
    }

    function test_mintTransferFromFalseHasExactErrorAndCompleteRollback() public {
        _assertEntryModeFailure(true, CoverPoolModeToken.ReturnMode.False, "");
    }

    function test_mintTransferFromRevertHasExactReturndataAndCompleteRollback() public {
        _assertEntryModeFailure(true, CoverPoolModeToken.ReturnMode.Revert, "TRANSFER_FROM_REVERT");
    }

    function test_mintTransferFromMalformedHasExactErrorAndCompleteRollback() public {
        _assertEntryModeFailure(true, CoverPoolModeToken.ReturnMode.Malformed, "");
    }

    function test_mintTransferFromNoReturnSucceedsWithExactDeltas() public {
        (SingleAssetCoverPool modePool, CoverPoolModeToken token) =
            _entryModePool(CoverPoolModeToken.ReturnMode.NoReturn);
        vm.prank(ALICE);
        assert(modePool.mint(10_000, BOB) == 10);
        _assertEntrySuccess(modePool, token);
    }

    function _assertEntryRollback(SingleAssetCoverPool modePool, CoverPoolModeToken token, uint256 ownerBalance)
        internal
        view
    {
        assert(modePool.totalAssets() == 0 && modePool.totalSupply() == 0);
        assert(modePool.balanceOf(ALICE) == 0 && modePool.balanceOf(BOB) == 0);
        assert(token.balanceOf(ALICE) == ownerBalance && token.balanceOf(address(modePool)) == 0);
        assert(token.allowance(ALICE, address(modePool)) == ownerBalance);
    }

    function _assertEntrySuccess(SingleAssetCoverPool modePool, CoverPoolModeToken token) internal view {
        assert(modePool.totalAssets() == 10 && modePool.totalSupply() == 10_000);
        assert(modePool.balanceOf(BOB) == 10_000 && modePool.balanceOf(ALICE) == 0);
        assert(token.balanceOf(ALICE) == 0 && token.balanceOf(address(modePool)) == 10);
        assert(token.allowance(ALICE, address(modePool)) == 0);
    }

    function _settledExitModePool(CoverPoolModeToken.ReturnMode mode)
        internal
        returns (SingleAssetCoverPool modePool, CoverPoolModeToken token, uint256 shares, uint64 epoch)
    {
        token = new CoverPoolModeToken();
        modePool = _freshPool(IERC20(address(token)));
        token.mint(ALICE, 10);
        vm.startPrank(ALICE);
        token.approve(address(modePool), 10);
        shares = modePool.deposit(10, ALICE);
        modePool.requestRedeem(shares);
        vm.stopPrank();
        (, epoch) = modePool.exitRequests(ALICE);
        vm.warp(epoch);
        modePool.settleMaturedExitEpochs(1);
        token.setTransferModes(mode, CoverPoolModeToken.ReturnMode.Normal);
    }

    function _assertCompleteRedeemModeFailure(CoverPoolModeToken.ReturnMode mode, string memory revertReason) internal {
        (SingleAssetCoverPool modePool, CoverPoolModeToken token, uint256 shares, uint64 epoch) =
            _settledExitModePool(mode);
        _assertModeFailureAs(
            ALICE,
            address(modePool),
            abi.encodeCall(SingleAssetCoverPool.completeRedeem, (RECIPIENT)),
            mode,
            address(token),
            revertReason
        );
        assert(modePool.withdrawalReserve() == 10 && token.balanceOf(RECIPIENT) == 0);
        (uint256 pending, uint64 storedEpoch) = modePool.exitRequests(ALICE);
        assert(pending == shares && storedEpoch == epoch);
        (uint256 totalShares, uint256 epochAssets, uint256 remainingShares, uint256 remainingAssets) =
            modePool.exitEpochs(epoch);
        assert(totalShares == shares && epochAssets == 10);
        assert(remainingShares == shares && remainingAssets == 10);
        assert(modePool.totalAssets() == 0 && modePool.totalSupply() == 0);
        assert(token.balanceOf(address(modePool)) == 10 && token.balanceOf(ALICE) == 0);
    }

    function test_completeRedeemTransferFalseHasExactErrorAndCompleteRollback() public {
        _assertCompleteRedeemModeFailure(CoverPoolModeToken.ReturnMode.False, "");
    }

    function test_completeRedeemTransferRevertHasExactReturndataAndCompleteRollback() public {
        _assertCompleteRedeemModeFailure(CoverPoolModeToken.ReturnMode.Revert, "TRANSFER_REVERT");
    }

    function test_completeRedeemTransferMalformedHasExactErrorAndCompleteRollback() public {
        _assertCompleteRedeemModeFailure(CoverPoolModeToken.ReturnMode.Malformed, "");
    }

    function test_completeRedeemTransferNoReturnSucceedsWithExactOneTimeDeltas() public {
        (SingleAssetCoverPool modePool, CoverPoolModeToken token, uint256 shares, uint64 epoch) =
            _settledExitModePool(CoverPoolModeToken.ReturnMode.NoReturn);
        vm.prank(ALICE);
        assert(modePool.completeRedeem(RECIPIENT) == 10);
        assert(modePool.withdrawalReserve() == 0 && token.balanceOf(RECIPIENT) == 10);
        assert(token.balanceOf(address(modePool)) == 0 && token.balanceOf(ALICE) == 0);
        assert(modePool.totalAssets() == 0 && modePool.totalSupply() == 0);
        (uint256 pending, uint64 storedEpoch) = modePool.exitRequests(ALICE);
        assert(pending == 0 && storedEpoch == 0);
        (uint256 totalShares, uint256 epochAssets, uint256 remainingShares, uint256 remainingAssets) =
            modePool.exitEpochs(epoch);
        assert(totalShares == shares && epochAssets == 10);
        assert(remainingShares == 0 && remainingAssets == 0);
    }

    function _fundedClaimModePool(CoverPoolModeToken.ReturnMode mode)
        internal
        returns (SingleAssetCoverPool modePool, CoverPoolModeToken token)
    {
        token = new CoverPoolModeToken();
        modePool = _freshPool(IERC20(address(token)));
        token.mint(ALICE, 10);
        vm.startPrank(ALICE);
        token.approve(address(modePool), 10);
        modePool.deposit(10, ALICE);
        vm.stopPrank();
        token.setTransferModes(mode, CoverPoolModeToken.ReturnMode.Normal);
    }

    function _assertPayClaimModeFailure(CoverPoolModeToken.ReturnMode mode, string memory revertReason) internal {
        (SingleAssetCoverPool modePool, CoverPoolModeToken token) = _fundedClaimModePool(mode);
        _assertModeFailureAs(
            address(this),
            address(insurance),
            abi.encodeCall(insurance.pay, (modePool, RECIPIENT, uint256(4))),
            mode,
            address(token),
            revertReason
        );
        assert(modePool.totalAssets() == 10 && token.balanceOf(RECIPIENT) == 0);
        assert(modePool.totalSupply() == 10_000 && modePool.balanceOf(ALICE) == 10_000);
        assert(token.balanceOf(address(modePool)) == 10 && token.balanceOf(ALICE) == 0);
        assert(modePool.withdrawalReserve() == 0 && modePool.rewardReserve() == 0);
    }

    function test_payClaimTransferFalseHasExactErrorAndCompleteRollback() public {
        _assertPayClaimModeFailure(CoverPoolModeToken.ReturnMode.False, "");
    }

    function test_payClaimTransferRevertHasExactReturndataAndCompleteRollback() public {
        _assertPayClaimModeFailure(CoverPoolModeToken.ReturnMode.Revert, "TRANSFER_REVERT");
    }

    function test_payClaimTransferMalformedHasExactErrorAndCompleteRollback() public {
        _assertPayClaimModeFailure(CoverPoolModeToken.ReturnMode.Malformed, "");
    }

    function test_payClaimTransferNoReturnSucceedsWithExactOneTimeDeltas() public {
        (SingleAssetCoverPool modePool, CoverPoolModeToken token) =
            _fundedClaimModePool(CoverPoolModeToken.ReturnMode.NoReturn);
        insurance.pay(modePool, RECIPIENT, 4);
        assert(modePool.totalAssets() == 6 && token.balanceOf(RECIPIENT) == 4);
        assert(modePool.totalSupply() == 10_000 && modePool.balanceOf(ALICE) == 10_000);
        assert(token.balanceOf(address(modePool)) == 6 && token.balanceOf(ALICE) == 0);
        assert(modePool.withdrawalReserve() == 0 && modePool.rewardReserve() == 0);
    }

    function _sweepModeToken(CoverPoolModeToken.ReturnMode mode) internal returns (CoverPoolModeToken token) {
        token = new CoverPoolModeToken();
        token.mint(address(pool), 9);
        token.setTransferModes(mode, CoverPoolModeToken.ReturnMode.Normal);
    }

    function _assertSweepModeFailure(CoverPoolModeToken.ReturnMode mode, string memory revertReason) internal {
        CoverPoolModeToken token = _sweepModeToken(mode);
        _assertModeFailureAs(
            address(this),
            address(pool),
            abi.encodeCall(pool.sweepToken, (IERC20(address(token)), RECIPIENT)),
            mode,
            address(token),
            revertReason
        );
        assert(token.balanceOf(address(pool)) == 9 && token.balanceOf(RECIPIENT) == 0);
        assert(pool.totalAssets() == 0 && pool.withdrawalReserve() == 0 && pool.rewardReserve() == 0);
        assert(pool.totalSupply() == 0);
    }

    function test_sweepTokenTransferFalseHasExactErrorAndCompleteRollback() public {
        _assertSweepModeFailure(CoverPoolModeToken.ReturnMode.False, "");
    }

    function test_sweepTokenTransferRevertHasExactReturndataAndCompleteRollback() public {
        _assertSweepModeFailure(CoverPoolModeToken.ReturnMode.Revert, "TRANSFER_REVERT");
    }

    function test_sweepTokenTransferMalformedHasExactErrorAndCompleteRollback() public {
        _assertSweepModeFailure(CoverPoolModeToken.ReturnMode.Malformed, "");
    }

    function test_sweepTokenTransferNoReturnSucceedsWithExactOneTimeDeltas() public {
        CoverPoolModeToken token = _sweepModeToken(CoverPoolModeToken.ReturnMode.NoReturn);
        pool.sweepToken(IERC20(address(token)), RECIPIENT);
        assert(token.balanceOf(address(pool)) == 0 && token.balanceOf(RECIPIENT) == 9);
        assert(pool.totalAssets() == 0 && pool.withdrawalReserve() == 0 && pool.rewardReserve() == 0);
        assert(pool.totalSupply() == 0);
    }

    function _rewardModePool() internal returns (SingleAssetCoverPool modePool, CoverPoolModeToken modeReward) {
        Registry localRegistry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        modeReward = new CoverPoolModeToken();
        localRegistry.setUsd8(address(modeReward));
        localRegistry.setDefiInsurance(address(insurance));
        modePool = SingleAssetCoverPool(
            address(
                new ERC1967Proxy(
                    address(new SingleAssetCoverPool()),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (localRegistry, IERC20(address(assetToken)), "Mode Reward", "cpMODE")
                    )
                )
            )
        );
        assetToken.mint(ALICE, 10);
        vm.startPrank(ALICE);
        assetToken.approve(address(modePool), 10);
        modePool.deposit(10, ALICE);
        vm.stopPrank();
        modePool.setRewardsDuration(10);
        modeReward.mint(BOB, 100);
        vm.prank(BOB);
        modeReward.approve(address(modePool), 100);
    }

    function _assertRewardDistributionModeFailure(CoverPoolModeToken.ReturnMode mode, string memory revertReason)
        internal
    {
        (SingleAssetCoverPool modePool, CoverPoolModeToken modeReward) = _rewardModePool();
        modeReward.setTransferModes(CoverPoolModeToken.ReturnMode.Normal, mode);
        _assertModeFailureAs(
            BOB,
            address(modePool),
            abi.encodeCall(SingleAssetCoverPool.receiveProfitDistribution, (uint256(100))),
            mode,
            address(modeReward),
            revertReason
        );
        assert(modePool.rewardReserve() == 0 && modeReward.balanceOf(BOB) == 100);
        assert(modeReward.balanceOf(address(modePool)) == 0);
        assert(modeReward.allowance(BOB, address(modePool)) == 100);
        assert(modePool.rewardRate() == 0 && modePool.lastUpdateTime() == block.timestamp);
        assert(modePool.periodFinish() == 0);
        assert(modePool.totalAssets() == 10 && modePool.totalSupply() == 10_000);
        assert(modePool.balanceOf(ALICE) == 10_000);
    }

    function test_rewardDistributionTransferFromFalseHasExactErrorAndCompleteRollback() public {
        _assertRewardDistributionModeFailure(CoverPoolModeToken.ReturnMode.False, "");
    }

    function test_rewardDistributionTransferFromRevertHasExactReturndataAndCompleteRollback() public {
        _assertRewardDistributionModeFailure(CoverPoolModeToken.ReturnMode.Revert, "TRANSFER_FROM_REVERT");
    }

    function test_rewardDistributionTransferFromMalformedHasExactErrorAndCompleteRollback() public {
        _assertRewardDistributionModeFailure(CoverPoolModeToken.ReturnMode.Malformed, "");
    }

    function test_rewardDistributionTransferFromNoReturnSucceedsWithExactOneTimeDeltas() public {
        (SingleAssetCoverPool modePool, CoverPoolModeToken modeReward) = _rewardModePool();
        modeReward.setTransferModes(CoverPoolModeToken.ReturnMode.Normal, CoverPoolModeToken.ReturnMode.NoReturn);
        vm.prank(BOB);
        modePool.receiveProfitDistribution(100);
        assert(modePool.rewardReserve() == 100 && modeReward.balanceOf(address(modePool)) == 100);
        assert(modeReward.balanceOf(BOB) == 0 && modeReward.allowance(BOB, address(modePool)) == 0);
        assert(modePool.rewardRate() == 10 && modePool.periodFinish() == block.timestamp + 10);
        assert(modePool.totalAssets() == 10 && modePool.totalSupply() == 10_000);
        assert(modePool.balanceOf(ALICE) == 10_000);
    }

    function _claimModePool(CoverPoolModeToken.ReturnMode mode)
        internal
        returns (SingleAssetCoverPool modePool, CoverPoolModeToken modeReward)
    {
        (modePool, modeReward) = _rewardModePool();
        vm.prank(BOB);
        modePool.receiveProfitDistribution(100);
        vm.warp(block.timestamp + 10);
        modeReward.setTransferModes(mode, CoverPoolModeToken.ReturnMode.Normal);
    }

    function _assertClaimRewardModeFailure(CoverPoolModeToken.ReturnMode mode, string memory revertReason) internal {
        (SingleAssetCoverPool modePool, CoverPoolModeToken modeReward) = _claimModePool(mode);
        _assertModeFailureAs(
            ALICE,
            address(modePool),
            abi.encodeCall(SingleAssetCoverPool.claimReward, ()),
            mode,
            address(modeReward),
            revertReason
        );
        assert(modePool.rewardReserve() == 100 && modeReward.balanceOf(ALICE) == 0);
        assert(modeReward.balanceOf(address(modePool)) == 100);
        assert(modePool.rewardRate() == 10 && modePool.periodFinish() == block.timestamp);
        assert(modePool.earned(ALICE) == 100);
        (, uint256 accrued) = modePool.rewardState(ALICE);
        assert(accrued == 0);
        assert(modePool.totalAssets() == 10 && modePool.totalSupply() == 10_000);
        assert(modePool.balanceOf(ALICE) == 10_000);
    }

    function test_claimRewardTransferFalseHasExactErrorAndCompleteRollback() public {
        _assertClaimRewardModeFailure(CoverPoolModeToken.ReturnMode.False, "");
    }

    function test_claimRewardTransferRevertHasExactReturndataAndCompleteRollback() public {
        _assertClaimRewardModeFailure(CoverPoolModeToken.ReturnMode.Revert, "TRANSFER_REVERT");
    }

    function test_claimRewardTransferMalformedHasExactErrorAndCompleteRollback() public {
        _assertClaimRewardModeFailure(CoverPoolModeToken.ReturnMode.Malformed, "");
    }

    function test_claimRewardTransferNoReturnSucceedsWithExactOneTimeDeltas() public {
        (SingleAssetCoverPool modePool, CoverPoolModeToken modeReward) =
            _claimModePool(CoverPoolModeToken.ReturnMode.NoReturn);
        vm.prank(ALICE);
        assert(modePool.claimReward() == 100);
        assert(modePool.rewardReserve() == 0 && modeReward.balanceOf(ALICE) == 100);
        assert(modeReward.balanceOf(address(modePool)) == 0 && modePool.earned(ALICE) == 0);
        (, uint256 accrued) = modePool.rewardState(ALICE);
        assert(accrued == 0);
        assert(modePool.totalAssets() == 10 && modePool.totalSupply() == 10_000);
        assert(modePool.balanceOf(ALICE) == 10_000);
    }

    function test_completeRedeemCallbackGetsExactGuardErrorAndOuterDeltasOccurOnce() public {
        CoverPoolCallbackToken token = new CoverPoolCallbackToken("Callback Asset", "cbAST");
        SingleAssetCoverPool modePool = _freshPool(IERC20(address(token)));
        token.mint(ALICE, 10);
        vm.startPrank(ALICE);
        token.approve(address(modePool), 10);
        uint256 shares = modePool.deposit(10, ALICE);
        modePool.requestRedeem(shares);
        vm.stopPrank();
        (, uint64 epoch) = modePool.exitRequests(ALICE);
        vm.warp(epoch);
        modePool.settleMaturedExitEpochs(1);
        token.configureCallback(
            address(modePool), abi.encodeCall(SingleAssetCoverPool.completeRedeem, (RECIPIENT)), true, false
        );

        vm.prank(ALICE);
        assert(modePool.completeRedeem(RECIPIENT) == 10);
        _assertNestedReentrancy(token);
        assert(token.balanceOf(address(modePool)) == 0 && token.balanceOf(RECIPIENT) == 10);
        assert(modePool.withdrawalReserve() == 0 && modePool.totalAssets() == 0 && modePool.totalSupply() == 0);
        (uint256 pending, uint64 storedEpoch) = modePool.exitRequests(ALICE);
        assert(pending == 0 && storedEpoch == 0);
        (,, uint256 remainingShares, uint256 remainingAssets) = modePool.exitEpochs(epoch);
        assert(remainingShares == 0 && remainingAssets == 0);
    }

    function test_payClaimCallbackGetsExactGuardErrorAndOuterDeltasOccurOnce() public {
        CoverPoolCallbackToken token = new CoverPoolCallbackToken("Callback Asset", "cbAST");
        SingleAssetCoverPool modePool = _freshPool(IERC20(address(token)));
        token.mint(ALICE, 10);
        vm.startPrank(ALICE);
        token.approve(address(modePool), 10);
        modePool.deposit(10, ALICE);
        vm.stopPrank();
        uint256 supplyBefore = modePool.totalSupply();
        token.configureCallback(
            address(modePool), abi.encodeCall(SingleAssetCoverPool.payClaim, (RECIPIENT, uint256(4))), true, false
        );

        insurance.pay(modePool, RECIPIENT, 4);
        _assertNestedReentrancy(token);
        assert(modePool.totalAssets() == 6 && modePool.totalSupply() == supplyBefore);
        assert(token.balanceOf(address(modePool)) == 6 && token.balanceOf(RECIPIENT) == 4);
    }

    function test_rewardDistributionCallbackGetsExactGuardErrorAndOuterDeltasOccurOnce() public {
        (SingleAssetCoverPool modePool, CoverPoolCallbackToken token) = _callbackRewardPool();
        modePool.setRewardsDuration(10);
        token.mint(BOB, 100);
        vm.prank(BOB);
        token.approve(address(modePool), 100);
        token.configureCallback(
            address(modePool),
            abi.encodeCall(SingleAssetCoverPool.receiveProfitDistribution, (uint256(100))),
            false,
            true
        );

        vm.prank(BOB);
        modePool.receiveProfitDistribution(100);
        _assertNestedReentrancy(token);
        assert(token.balanceOf(BOB) == 0 && token.balanceOf(address(modePool)) == 100);
        assert(token.allowance(BOB, address(modePool)) == 0);
        assert(modePool.rewardReserve() == 100 && modePool.rewardRate() == 10);
        assert(modePool.periodFinish() == block.timestamp + 10);
    }

    function test_claimRewardCallbackGetsExactGuardErrorAndOuterDeltasOccurOnce() public {
        (SingleAssetCoverPool modePool, CoverPoolCallbackToken token) = _callbackRewardPool();
        modePool.setRewardsDuration(10);
        token.mint(BOB, 100);
        vm.startPrank(BOB);
        token.approve(address(modePool), 100);
        modePool.receiveProfitDistribution(100);
        vm.stopPrank();
        vm.warp(block.timestamp + 10);
        token.configureCallback(address(modePool), abi.encodeCall(SingleAssetCoverPool.claimReward, ()), true, false);

        vm.prank(ALICE);
        assert(modePool.claimReward() == 100);
        _assertNestedReentrancy(token);
        assert(token.balanceOf(ALICE) == 100 && token.balanceOf(address(modePool)) == 0);
        assert(modePool.rewardReserve() == 0 && modePool.earned(ALICE) == 0);
        (, uint256 accrued) = modePool.rewardState(ALICE);
        assert(accrued == 0);
    }

    function test_sweepTokenCallbackSeesExactPostTransferNothingToSweepAndOuterDeltaOccursOnce() public {
        CoverPoolCallbackToken token = new CoverPoolCallbackToken("Callback Stray", "cbSTRAY");
        token.mint(address(pool), 9);
        registry.setAdmin(address(token), true);
        token.configureCallback(
            address(pool), abi.encodeCall(pool.sweepToken, (IERC20(address(token)), RECIPIENT)), true, false
        );

        pool.sweepToken(IERC20(address(token)), RECIPIENT);
        assert(!token.nestedSuccess());
        bytes memory nested = token.nestedReturndata();
        assert(nested.length == 36);
        assert(
            keccak256(nested) == keccak256(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(token)))
        );
        assert(token.balanceOf(address(pool)) == 0 && token.balanceOf(RECIPIENT) == 9);
        assert(pool.totalAssets() == 0 && pool.totalSupply() == 0);
    }

    function _callbackRewardPool() internal returns (SingleAssetCoverPool modePool, CoverPoolCallbackToken token) {
        Registry localRegistry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        token = new CoverPoolCallbackToken("Callback Reward", "cbRWD");
        localRegistry.setUsd8(address(token));
        modePool = SingleAssetCoverPool(
            address(
                new ERC1967Proxy(
                    address(new SingleAssetCoverPool()),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (localRegistry, IERC20(address(assetToken)), "Callback Reward Cover", "cpCB")
                    )
                )
            )
        );
        assetToken.mint(ALICE, 10);
        vm.startPrank(ALICE);
        assetToken.approve(address(modePool), 10);
        modePool.deposit(10, ALICE);
        vm.stopPrank();
    }

    function _assertNestedReentrancy(CoverPoolCallbackToken token) internal view {
        assert(!token.nestedSuccess());
        bytes memory nested = token.nestedReturndata();
        assert(nested.length == 4);
        assert(
            keccak256(nested)
                == keccak256(abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector))
        );
    }

    function test_assetCallbackObservesExactReentrancyGuardErrorWhileOuterDepositSucceeds() public {
        CoverPoolReentrantToken reentrantToken = new CoverPoolReentrantToken();
        SingleAssetCoverPool reentrantPool = _freshPool(IERC20(address(reentrantToken)));
        reentrantToken.setTarget(reentrantPool);
        reentrantToken.mint(ALICE, 10);
        vm.prank(ALICE);
        reentrantToken.approve(address(reentrantPool), 10);
        vm.prank(ALICE);
        reentrantPool.deposit(10, ALICE);
        bytes memory nested = reentrantToken.reentryData();
        assert(nested.length == 4);
        assert(
            keccak256(nested)
                == keccak256(abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector))
        );
        assert(reentrantPool.totalAssets() == 10);
        assert(reentrantPool.totalSupply() == 10_000);
        assert(reentrantPool.balanceOf(ALICE) == 10_000);
        assert(reentrantToken.balanceOf(address(reentrantPool)) == 10);
        assert(reentrantToken.balanceOf(ALICE) == 0);
    }
}
