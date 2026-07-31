// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {SingleAssetCoverPoolKontrolBase, CoverPoolHarnessToken} from "./SingleAssetCoverPoolHarness.k.sol";

contract CoverPoolFeeToken is ERC20 {
    constructor() ERC20("Fee Asset", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 1) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice ERC-20/ERC-4626 identity, accounting, deposit, cap, transfer, and permit properties.
contract SingleAssetCoverPoolERC4626KontrolTest is SingleAssetCoverPoolKontrolBase {
    uint256 internal constant OWNER_KEY = 0xA11CE55;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _independentDomain(address verifyingContract, string memory name_) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name_)), keccak256(bytes("1")), block.chainid, verifyingContract
            )
        );
    }

    function test_initializationMetadataRegistryAssetsAndTimingAreExact() public view {
        assert(address(pool.registry()) == address(registry));
        assert(pool.asset() == address(assetToken));
        assert(address(pool.usd8()) == address(rewardToken));
        assert(keccak256(bytes(pool.name())) == keccak256("USD8 Asset Cover"));
        assert(keccak256(bytes(pool.symbol())) == keccak256("cpASSET"));
        assert(pool.decimals() == 21);
        assert(pool.rewardsDuration() == 7 days);
        assert(pool.MAX_REWARDS_DURATION() == 365 days);
        assert(pool.totalAssets() == 0 && pool.totalSupply() == 0);
        assert(pool.rewardRate() == 0 && pool.rewardReserve() == 0);
        assert(pool.withdrawalReserve() == 0 && pool.nextExitEpochIndex() == 0);
    }

    function test_directImplementationAndProxyReinitializationAreLocked() public {
        (bool direct, bytes memory dd) = address(implementation)
            .call(abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(assetToken)), "x", "x")));
        _assertExactFourByteError(direct, dd, Initializable.InvalidInitialization.selector);
        (bool proxy, bytes memory pd) = address(pool)
            .call(abi.encodeCall(SingleAssetCoverPool.initialize, (registry, IERC20(address(assetToken)), "x", "x")));
        _assertExactFourByteError(proxy, pd, Initializable.InvalidInitialization.selector);
        assert(pool.asset() == address(assetToken));
    }

    function test_eip712DomainTupleAndIndependentSeparatorAreExact() public view {
        (
            bytes1 fields,
            string memory name_,
            string memory version_,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = pool.eip712Domain();
        assert(fields == hex"0f");
        assert(keccak256(bytes(name_)) == keccak256(bytes("USD8 Asset Cover")));
        assert(keccak256(bytes(version_)) == keccak256(bytes("1")));
        assert(chainId == block.chainid);
        assert(verifyingContract == address(pool));
        assert(salt == bytes32(0));
        assert(extensions.length == 0);
        bytes32 expected = _independentDomain(address(pool), "USD8 Asset Cover");
        assert(pool.DOMAIN_SEPARATOR() == expected);
    }

    function test_initialVirtualOffsetConversionsAndDepositAreExact(uint128 assets) public {
        vm.assume(assets > 0);
        assert(pool.convertToShares(assets) == uint256(assets) * 1000);
        assert(pool.previewDeposit(assets) == uint256(assets) * 1000);
        uint256 shares = _deposit(ALICE, assets);
        assert(shares == uint256(assets) * 1000);
        assert(pool.balanceOf(ALICE) == shares);
        assert(pool.totalSupply() == shares);
        assert(pool.totalAssets() == assets);
        assert(assetToken.balanceOf(address(pool)) == assets);
        assert(pool.convertToAssets(shares) == assets);
    }

    function test_secondDepositUsesIndependentOZFormulaAndPreservesAccounting(uint96 first, uint96 second) public {
        vm.assume(first > 0 && second > 0);
        _deposit(ALICE, first);
        uint256 expected = Math.mulDiv(second, pool.totalSupply() + 1000, pool.totalAssets() + 1);
        uint256 aliceShares = pool.balanceOf(ALICE);
        uint256 minted = _deposit(BOB, second);
        assert(minted == expected);
        assert(pool.balanceOf(ALICE) == aliceShares);
        assert(pool.balanceOf(BOB) == expected);
        assert(pool.totalAssets() == uint256(first) + second);
        assert(assetToken.balanceOf(address(pool)) == uint256(first) + second);
    }

    function test_mintChargesIndependentOZCeilFormulaAndMintsRequestedShares(uint96 seededAssets, uint96 shares)
        public
    {
        vm.assume(seededAssets > 0 && shares > 0);
        _deposit(ALICE, seededAssets);
        uint256 expected = Math.mulDiv(shares, pool.totalAssets() + 1, pool.totalSupply() + 1000, Math.Rounding.Ceil);
        uint256 charged = _mintShares(BOB, shares);
        assert(charged == expected);
        assert(pool.balanceOf(BOB) == shares);
        assert(pool.totalAssets() == uint256(seededAssets) + charged);
        assert(assetToken.balanceOf(address(pool)) == pool.totalAssets());
    }

    function test_directAssetDonationDoesNotChangeAccountingOrShareConversions(uint96 depositAmount, uint96 donation)
        public
    {
        vm.assume(depositAmount > 0 && donation > 0);
        _deposit(ALICE, depositAmount);
        uint256 assetsBefore = pool.totalAssets();
        uint256 sharesBefore = pool.convertToShares(depositAmount);
        assetToken.mint(address(pool), donation);
        assert(pool.totalAssets() == assetsBefore);
        assert(pool.convertToShares(depositAmount) == sharesBefore);
        assert(assetToken.balanceOf(address(pool)) == uint256(depositAmount) + donation);
    }

    function test_capMaxDepositAndMaxMintExactAtBelowEqualAndAboveSize(uint96 stake, uint96 room) public {
        vm.assume(stake > 0 && room > 0);
        _deposit(ALICE, stake);
        pool.setDepositCap(uint256(stake) + room);
        assert(pool.maxDeposit(BOB) == room);
        assert(pool.maxMint(BOB) == pool.convertToShares(room));

        assetToken.mint(BOB, room);
        vm.startPrank(BOB);
        assetToken.approve(address(pool), room);
        pool.deposit(room, BOB);
        vm.stopPrank();
        assert(pool.totalAssets() == uint256(stake) + room);
        assert(pool.maxDeposit(CAROL) == 0);
        assert(pool.maxMint(CAROL) == 0);

        pool.setDepositCap(stake);
        assert(pool.totalAssets() > pool.depositCap());
        assert(pool.maxDeposit(CAROL) == 0 && pool.maxMint(CAROL) == 0);
    }

    function test_zeroCapIsUnboundedAndDepositAboveFiniteCapRevertsAtomically() public {
        assert(pool.maxDeposit(ALICE) == type(uint256).max);
        assert(pool.maxMint(ALICE) == type(uint256).max);
        pool.setDepositCap(10);
        assetToken.mint(ALICE, 11);
        vm.prank(ALICE);
        assetToken.approve(address(pool), 11);
        vm.prank(ALICE);
        (bool success, bytes memory data) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(11), ALICE)));
        assert(
            !success
                && keccak256(data)
                    == keccak256(
                        abi.encodeWithSelector(
                            ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, ALICE, uint256(11), uint256(10)
                        )
                    )
        );
        (bool mintSuccess, bytes memory mintData) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.mint, (uint256(10_001), ALICE)));
        assert(
            !mintSuccess
                && keccak256(mintData)
                    == keccak256(
                        abi.encodeWithSelector(
                            ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, ALICE, uint256(10_001), uint256(10_000)
                        )
                    )
        );
        assert(pool.totalAssets() == 0 && pool.totalSupply() == 0);
        assert(assetToken.balanceOf(address(pool)) == 0);
    }

    function test_capAndRewardDurationAclAndBoundsAreExact(uint64 duration, uint128 cap) public {
        vm.assume(duration > 0 && duration <= pool.MAX_REWARDS_DURATION());
        pool.setDepositCap(cap);
        pool.setRewardsDuration(duration);
        assert(pool.depositCap() == cap);
        assert(pool.rewardsDuration() == duration);

        (bool unauthorizedCap, bytes memory cd) =
            _callPoolAs(OUTSIDER, abi.encodeCall(SingleAssetCoverPool.setDepositCap, (uint256(1))));
        assert(!unauthorizedCap);
        assert(keccak256(cd) == keccak256(abi.encodeWithSelector(Registry.UnauthorizedAdmin.selector, OUTSIDER)));
        (bool unauthorizedDuration, bytes memory dd) =
            _callPoolAs(OUTSIDER, abi.encodeCall(SingleAssetCoverPool.setRewardsDuration, (uint64(1))));
        assert(!unauthorizedDuration);
        assert(keccak256(dd) == keccak256(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, OUTSIDER)));

        registry.setAdmin(ALICE, true);
        (bool adminDuration, bytes memory ad) =
            _callPoolAs(ALICE, abi.encodeCall(SingleAssetCoverPool.setRewardsDuration, (uint64(1))));
        assert(!adminDuration);
        assert(keccak256(ad) == keccak256(abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, ALICE)));

        (bool zero, bytes memory zd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.setRewardsDuration, (uint64(0))));
        _assertExactFourByteError(zero, zd, SingleAssetCoverPool.InvalidRewardsDuration.selector);
        (bool excessive, bytes memory ed) = address(pool)
            .call(abi.encodeCall(SingleAssetCoverPool.setRewardsDuration, (pool.MAX_REWARDS_DURATION() + 1)));
        _assertExactFourByteError(excessive, ed, SingleAssetCoverPool.InvalidRewardsDuration.selector);
        assert(pool.rewardsDuration() == duration);
    }

    function test_pauseAndIncidentFreezeMakeMaximaZeroAndBlockDepositMint() public {
        registry.setPaused(address(pool), true);
        assert(pool.maxDeposit(ALICE) == 0 && pool.maxMint(ALICE) == 0);
        (bool paused, bytes memory pd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(1), ALICE)));
        _assertExactFourByteError(paused, pd, Registry.Paused.selector);
        (bool pausedMint, bytes memory pmd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.mint, (uint256(1), ALICE)));
        _assertExactFourByteError(pausedMint, pmd, Registry.Paused.selector);
        registry.setPaused(address(pool), false);

        _freeze();
        assert(pool.maxDeposit(ALICE) == 0 && pool.maxMint(ALICE) == 0);
        (bool frozenDeposit, bytes memory fd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(1), ALICE)));
        assert(
            !frozenDeposit
                && keccak256(fd)
                    == keccak256(
                        abi.encodeWithSelector(
                            ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, ALICE, uint256(1), uint256(0)
                        )
                    )
        );
        (bool frozenMint, bytes memory fm) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.mint, (uint256(1), ALICE)));
        assert(
            !frozenMint
                && keccak256(fm)
                    == keccak256(
                        abi.encodeWithSelector(
                            ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, ALICE, uint256(1), uint256(0)
                        )
                    )
        );
        assert(pool.totalAssets() == 0 && pool.totalSupply() == 0);
    }

    function test_depositAndMintRejectZeroAndPoolReceiversWithExactErrorsAndRollback() public {
        assetToken.mint(ALICE, 10);
        vm.prank(ALICE);
        assetToken.approve(address(pool), 10);
        vm.prank(ALICE);
        (bool zeroDeposit, bytes memory zdd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(1), address(0))));
        assert(
            !zeroDeposit
                && keccak256(zdd)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)))
        );
        vm.prank(ALICE);
        (bool poolDeposit, bytes memory pdd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(1), address(pool))));
        _assertExactFourByteError(poolDeposit, pdd, SingleAssetCoverPool.InvalidRecipient.selector);
        vm.prank(ALICE);
        (bool zeroMint, bytes memory zmd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.mint, (uint256(1), address(0))));
        assert(
            !zeroMint
                && keccak256(zmd)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)))
        );
        vm.prank(ALICE);
        (bool poolMint, bytes memory pmd) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.mint, (uint256(1), address(pool))));
        _assertExactFourByteError(poolMint, pmd, SingleAssetCoverPool.InvalidRecipient.selector);
        assert(pool.totalAssets() == 0 && pool.totalSupply() == 0);
        assert(assetToken.balanceOf(ALICE) == 10 && assetToken.balanceOf(address(pool)) == 0);
    }

    function test_disabledSynchronousExitSelectorsAndSummariesAreExact() public view {
        assert(pool.maxRedeem(ALICE) == 0);
        assert(pool.maxWithdraw(ALICE) == 0);
        (bool redeemSuccess, bytes memory rd) =
            address(pool).staticcall(abi.encodeCall(SingleAssetCoverPool.redeem, (uint256(1), ALICE, ALICE)));
        _assertExactFourByteError(redeemSuccess, rd, SingleAssetCoverPool.RedeemNotSupported.selector);
        (bool withdrawSuccess, bytes memory wd) =
            address(pool).staticcall(abi.encodeCall(SingleAssetCoverPool.withdraw, (uint256(1), ALICE, ALICE)));
        _assertExactFourByteError(withdrawSuccess, wd, SingleAssetCoverPool.WithdrawNotSupported.selector);
    }

    function test_previewWithdrawGetterIsExactButDoesNotEnableSynchronousWithdrawal(uint96 seededAssets, uint96 assets)
        public
    {
        vm.assume(seededAssets > 0 && assets > 0);
        assert(pool.previewWithdraw(0) == 0);
        assert(pool.previewWithdraw(assets) == uint256(assets) * 1000);
        _deposit(ALICE, seededAssets);

        uint256 expectedShares =
            Math.mulDiv(assets, pool.totalSupply() + 1000, pool.totalAssets() + 1, Math.Rounding.Ceil);
        // [C:OZ_ERC4626_ARITHMETIC] Expand the pinned vendor's virtual-share
        // conversion independently; this getter does not make withdraw reachable.
        assert(pool.previewWithdraw(assets) == expectedShares);

        (bool success, bytes memory data) =
            address(pool).call(abi.encodeCall(SingleAssetCoverPool.withdraw, (uint256(assets), ALICE, ALICE)));
        assert(!success);
        assert(keccak256(data) == keccak256(abi.encodeWithSelector(SingleAssetCoverPool.WithdrawNotSupported.selector)));
        assert(pool.totalAssets() == seededAssets);
        assert(pool.balanceOf(ALICE) == uint256(seededAssets) * 1000);
    }

    function test_shareTransfersAndAllowancesAreStandardButPoolRecipientIsForbidden(uint96 assets) public {
        vm.assume(assets > 1);
        _deposit(ALICE, assets);
        uint256 shares = pool.balanceOf(ALICE);
        uint256 moved = shares / 2;
        vm.prank(ALICE);
        pool.transfer(BOB, moved);
        assert(pool.balanceOf(ALICE) == shares - moved);
        assert(pool.balanceOf(BOB) == moved);

        vm.prank(ALICE);
        pool.approve(CAROL, shares - moved);
        vm.prank(CAROL);
        pool.transferFrom(ALICE, BOB, shares - moved);
        assert(pool.balanceOf(ALICE) == 0);
        assert(pool.balanceOf(BOB) == shares);
        assert(pool.allowance(ALICE, CAROL) == 0);

        vm.prank(BOB);
        (bool direct, bytes memory data) =
            address(pool).call(abi.encodeCall(IERC20.transfer, (address(pool), uint256(1))));
        _assertExactFourByteError(direct, data, SingleAssetCoverPool.InvalidRecipient.selector);
        assert(pool.balanceOf(address(pool)) == 0);
    }

    function test_finiteAndMaximumAllowancesAliasesSelfTransferAndRewardCheckpoints() public {
        _deposit(ALICE, 10);
        pool.setRewardsDuration(10);
        _notify(CAROL, 100);
        vm.warp(block.timestamp + 2);

        uint256 aliceBefore = pool.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.transfer(ALICE, 1);
        assert(pool.balanceOf(ALICE) == aliceBefore);
        (uint256 paid, uint256 accrued) = pool.rewardState(ALICE);
        assert(paid == pool.rewardPerShareStored());
        assert(accrued == 20);

        vm.prank(ALICE);
        pool.approve(BOB, 3);
        vm.prank(BOB);
        pool.transferFrom(ALICE, BOB, 2);
        assert(pool.allowance(ALICE, BOB) == 1);

        vm.prank(ALICE);
        pool.approve(CAROL, type(uint256).max);
        vm.prank(CAROL);
        pool.transferFrom(ALICE, CAROL, 2);
        assert(pool.allowance(ALICE, CAROL) == type(uint256).max);

        vm.prank(BOB);
        pool.approve(BOB, 1);
        vm.prank(BOB);
        pool.transferFrom(BOB, BOB, 1);
        assert(pool.allowance(BOB, BOB) == 0);

        // owner == spender, owner != recipient
        uint256 aliceBeforeOwnerSpender = pool.balanceOf(ALICE);
        uint256 bobBeforeOwnerSpender = pool.balanceOf(BOB);
        vm.prank(ALICE);
        pool.approve(ALICE, 1);
        vm.prank(ALICE);
        pool.transferFrom(ALICE, BOB, 1);
        assert(pool.allowance(ALICE, ALICE) == 0);
        assert(pool.balanceOf(ALICE) == aliceBeforeOwnerSpender - 1);
        assert(pool.balanceOf(BOB) == bobBeforeOwnerSpender + 1);

        // owner == recipient, owner != spender
        uint256 aliceBeforeOwnerRecipient = pool.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.approve(CAROL, 1);
        vm.prank(CAROL);
        pool.transferFrom(ALICE, ALICE, 1);
        assert(pool.allowance(ALICE, CAROL) == 0);
        assert(pool.balanceOf(ALICE) == aliceBeforeOwnerRecipient);
    }

    function test_finiteAllowanceInsufficientBalanceFailurePreservesAllowanceBalancesAndSupply() public {
        _deposit(ALICE, 10);
        uint256 shares = pool.balanceOf(ALICE);
        uint256 attempted = shares + 1;
        vm.prank(ALICE);
        pool.approve(CAROL, attempted);
        uint256 aliceBefore = pool.balanceOf(ALICE);
        uint256 bobBefore = pool.balanceOf(BOB);
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(CAROL);
        (bool success, bytes memory data) =
            address(pool).call(abi.encodeCall(pool.transferFrom, (ALICE, BOB, attempted)));
        assert(!success);
        assert(
            keccak256(data)
                == keccak256(
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, shares, attempted)
                )
        );
        assert(pool.allowance(ALICE, CAROL) == attempted);
        assert(pool.balanceOf(ALICE) == aliceBefore && pool.balanceOf(BOB) == bobBefore);
        assert(pool.totalSupply() == supplyBefore);
    }

    function test_permitSetsExactAllowanceConsumesNonceAndCannotReplay(uint96 value) public {
        address owner = vm.addr(OWNER_KEY);
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = pool.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, BOB, value, nonce, deadline));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", _independentDomain(address(pool), "USD8 Asset Cover"), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);
        pool.permit(owner, BOB, value, deadline, v, r, s);
        assert(pool.allowance(owner, BOB) == value);
        assert(pool.nonces(owner) == nonce + 1);

        (bool replay, bytes memory data) =
            address(pool).call(abi.encodeCall(IERC20Permit.permit, (owner, BOB, value, deadline, v, r, s)));
        bytes32 replayDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _independentDomain(address(pool), "USD8 Asset Cover"),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, BOB, value, nonce + 1, deadline))
            )
        );
        address replaySigner = ecrecover(replayDigest, v, r, s);
        assert(!replay);
        assert(
            keccak256(data)
                == keccak256(
                    abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, replaySigner, owner)
                )
        );
        assert(pool.nonces(owner) == nonce + 1);
    }

    function test_permitZeroSpenderUsesExactErrorAndRollsBack() public {
        address owner = vm.addr(OWNER_KEY);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 zeroStruct = keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(0), uint256(7), uint256(0), deadline));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", _independentDomain(address(pool), "USD8 Asset Cover"), zeroStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, digest);
        (bool success, bytes memory data) =
            address(pool).call(abi.encodeCall(IERC20Permit.permit, (owner, address(0), uint256(7), deadline, v, r, s)));
        assert(
            !success
                && keccak256(data)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)))
        );
        assert(pool.nonces(owner) == 0 && pool.allowance(owner, address(0)) == 0);
    }

    function test_permitWrongProxyBindingUsesExactSignerErrorAndRollsBack() public {
        address owner = vm.addr(OWNER_KEY);
        uint256 deadline = block.timestamp + 1 days;
        SingleAssetCoverPool other = SingleAssetCoverPool(
            address(
                new ERC1967Proxy(
                    address(new SingleAssetCoverPool()),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize,
                        (registry, IERC20(address(assetToken)), "USD8 Asset Cover", "cpOTHER")
                    )
                )
            )
        );
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, BOB, uint256(9), uint256(0), deadline));
        bytes32 poolDigest =
            keccak256(abi.encodePacked("\x19\x01", _independentDomain(address(pool), "USD8 Asset Cover"), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, poolDigest);
        bytes32 otherDigest =
            keccak256(abi.encodePacked("\x19\x01", _independentDomain(address(other), "USD8 Asset Cover"), structHash));
        address recovered = ecrecover(otherDigest, v, r, s);
        bytes memory callData = abi.encodeCall(IERC20Permit.permit, (owner, BOB, uint256(9), deadline, v, r, s));
        bytes memory expected =
            abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, recovered, owner);
        (bool success, bytes memory data) = address(other).call(callData);
        assert(!success && keccak256(data) == keccak256(expected));
        assert(other.nonces(owner) == 0 && other.allowance(owner, BOB) == 0);
    }

    function test_feeOnTransferAssetDepositRevertsAllAccounting() public {
        CoverPoolFeeToken feeAsset = new CoverPoolFeeToken();
        SingleAssetCoverPool feePool = SingleAssetCoverPool(
            address(
                new ERC1967Proxy(
                    address(new SingleAssetCoverPool()),
                    abi.encodeCall(
                        SingleAssetCoverPool.initialize, (registry, IERC20(address(feeAsset)), "Fee Cover", "cpFEE")
                    )
                )
            )
        );
        feeAsset.mint(ALICE, 10);
        vm.prank(ALICE);
        feeAsset.approve(address(feePool), 10);
        vm.prank(ALICE);
        (bool success, bytes memory data) =
            address(feePool).call(abi.encodeCall(SingleAssetCoverPool.deposit, (uint256(10), ALICE)));
        _assertExactFourByteError(success, data, SingleAssetCoverPool.FeeOnTransferUnsupported.selector);
        assert(feePool.totalAssets() == 0 && feePool.totalSupply() == 0);
        assert(feeAsset.balanceOf(address(feePool)) == 0);
        assert(feeAsset.balanceOf(ALICE) == 10);
    }
}
