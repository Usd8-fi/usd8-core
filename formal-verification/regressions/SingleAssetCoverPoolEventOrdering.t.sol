// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SingleAssetCoverPool} from "../../src/SingleAssetCoverPool.sol";
import {Registry} from "../../src/Registry.sol";
import {CoverPoolHarnessToken, SingleAssetCoverPoolKontrolBase} from "../properties/SingleAssetCoverPoolHarness.k.sol";

/// @notice Foundry-only exact multi-emitter ordering for pool ABI logs that are
///         later than token/module logs and cannot be expressed by Kontrol v1.0.255.
contract SingleAssetCoverPoolEventOrderingForgeTest is SingleAssetCoverPoolKontrolBase {
    event Upgraded(address indexed implementation);
    event RegistryChanged(address indexed oldRegistry, address indexed newRegistry);
    event Initialized(uint64 version);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event RedeemRequested(address indexed user, uint256 shares);
    event ExitEpochSettled(uint64 indexed exitEpoch, uint256 shares, uint256 assets);
    event ExitClaimed(address indexed user, address indexed receiver, uint256 shares, uint256 assets);
    event RewardNotified(uint256 amount, uint128 newRate, uint64 newPeriodFinish);
    event RewardClaimed(address indexed user, uint256 amount);
    event ClaimPaid(address indexed to, uint256 amount);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    uint256 internal constant PERMIT_OWNER_KEY = 0x5151;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function test_initializeDeploymentOrdersProxyUpgradeRegistryAndInitialized() public {
        SingleAssetCoverPool freshImplementation = new SingleAssetCoverPool();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        // Upgraded is emitted by ERC1967Proxy construction but is not present in
        // the pool implementation ABI because the pool itself is not UUPS.
        vm.expectEmit(true, false, false, true, predicted);
        emit Upgraded(address(freshImplementation));
        vm.expectEmit(true, true, false, true, predicted);
        emit RegistryChanged(address(0), address(registry));
        vm.expectEmit(false, false, false, true, predicted);
        emit Initialized(1);
        ERC1967Proxy fresh = new ERC1967Proxy(
            address(freshImplementation),
            abi.encodeCall(
                SingleAssetCoverPool.initialize, (registry, IERC20(address(assetToken)), "Fresh Cover", "cpFRESH")
            )
        );
        assertEq(address(fresh), predicted);
    }

    function test_depositOrdersAssetTransferShareTransferThenDeposit() public {
        uint256 assets = 17;
        uint256 shares = pool.previewDeposit(assets);
        assetToken.mint(ALICE, assets);
        vm.prank(ALICE);
        assetToken.approve(address(pool), assets);

        vm.expectEmit(true, true, false, true, address(assetToken));
        emit Transfer(ALICE, address(pool), assets);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(address(0), ALICE, shares);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Deposit(ALICE, ALICE, assets, shares);
        vm.prank(ALICE);
        pool.deposit(assets, ALICE);
    }

    function test_mintWithDistinctSenderReceiverOrdersExactTrace() public {
        uint256 shares = 17_000;
        uint256 assets = 17;
        assetToken.mint(ALICE, assets);
        vm.prank(ALICE);
        assetToken.approve(address(pool), assets);

        vm.expectEmit(true, true, false, true, address(assetToken));
        emit Transfer(ALICE, address(pool), assets);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(address(0), BOB, shares);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Deposit(ALICE, BOB, assets, shares);
        vm.prank(ALICE);
        assertEq(pool.mint(shares, BOB), assets);
    }

    function test_permitEmitsExactApproval() public {
        address owner = vm.addr(PERMIT_OWNER_KEY);
        uint256 value = 19;
        uint256 deadline = block.timestamp + 1;
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("USD8 Asset Cover")),
                keccak256(bytes("1")),
                block.chainid,
                address(pool)
            )
        );
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, BOB, value, uint256(0), deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PERMIT_OWNER_KEY, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));

        vm.expectEmit(true, true, false, true, address(pool));
        emit Approval(owner, BOB, value);
        pool.permit(owner, BOB, value, deadline, v, r, s);
    }

    function test_requestRedeemOrdersEscrowTransferThenRequest() public {
        uint256 shares = _deposit(ALICE, 17);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(ALICE, address(pool), shares);
        vm.expectEmit(true, false, false, true, address(pool));
        emit RedeemRequested(ALICE, shares);
        vm.prank(ALICE);
        pool.requestRedeem(shares);
    }

    function test_requestRedeemAutoSettlementHasExactBurnSettlementTransferRequestPrefix() public {
        uint256 aliceShares = _deposit(ALICE, 10);
        uint256 bobShares = _deposit(BOB, 10);
        uint64 aliceEpoch = _request(ALICE, aliceShares);
        vm.warp(aliceEpoch);

        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(address(pool), address(0), aliceShares);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ExitEpochSettled(aliceEpoch, aliceShares, 10);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(BOB, address(pool), bobShares);
        vm.expectEmit(true, false, false, true, address(pool));
        emit RedeemRequested(BOB, bobShares);
        vm.prank(BOB);
        pool.requestRedeem(bobShares);
    }

    function test_settlementOrdersBurnThenExactEpochSettlement() public {
        uint256 shares = _deposit(ALICE, 17);
        uint64 epoch = _request(ALICE, shares);
        vm.warp(epoch);

        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(address(pool), address(0), shares);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ExitEpochSettled(epoch, shares, 17);
        pool.settleMaturedExitEpochs(1);
    }

    function test_multiEpochSettlementOrdersEachBurnBeforeItsExactSettlement() public {
        registry.setExitTimingConfig(Registry.ExitTimingConfig({unstakeCooldown: 10, exitBatchInterval: 10}));
        uint256 aliceShares = _deposit(ALICE, 10);
        uint256 bobShares = _deposit(BOB, 10);
        uint64 first = _request(ALICE, aliceShares);
        _freeze();
        vm.warp(block.timestamp + 11);
        uint64 second = _request(BOB, bobShares);
        _unfreeze();
        vm.warp(second);

        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(address(pool), address(0), aliceShares);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ExitEpochSettled(first, aliceShares, 10);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(address(pool), address(0), bobShares);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ExitEpochSettled(second, bobShares, 10);
        assertEq(pool.settleMaturedExitEpochs(2), 2);
    }

    function test_nonFinalAndDustDrainingExitClaimsHaveDistinctExactTraces() public {
        uint256 aliceShares = _deposit(ALICE, 1);
        uint256 bobShares = _deposit(BOB, 2);
        uint64 epoch = _request(ALICE, aliceShares);
        assertEq(_request(BOB, bobShares), epoch);
        vm.warp(epoch);
        pool.settleMaturedExitEpochs(1);

        vm.expectEmit(true, true, false, true, address(assetToken));
        emit Transfer(address(pool), ALICE, 1);
        vm.expectEmit(true, true, false, true, address(pool));
        emit ExitClaimed(ALICE, ALICE, aliceShares, 1);
        vm.prank(ALICE);
        pool.completeRedeem(ALICE);

        vm.expectEmit(true, true, false, true, address(assetToken));
        emit Transfer(address(pool), BOB, 2);
        vm.expectEmit(true, true, false, true, address(pool));
        emit ExitClaimed(BOB, BOB, bobShares, 2);
        vm.prank(BOB);
        pool.completeRedeem(BOB);
    }

    function test_completeRedeemOrdersAssetTransferThenExactClaim() public {
        uint256 shares = _deposit(ALICE, 17);
        uint64 epoch = _request(ALICE, shares);
        vm.warp(epoch);
        pool.settleMaturedExitEpochs(1);

        vm.expectEmit(true, true, false, true, address(assetToken));
        emit Transfer(address(pool), RECIPIENT, 17);
        vm.expectEmit(true, true, false, true, address(pool));
        emit ExitClaimed(ALICE, RECIPIENT, shares, 17);
        vm.prank(ALICE);
        pool.completeRedeem(RECIPIENT);
    }

    function test_completeRedeemAutoSettlementHasExactBurnSettlementTransferClaimPrefix() public {
        uint256 shares = _deposit(ALICE, 17);
        uint64 epoch = _request(ALICE, shares);
        vm.warp(epoch);

        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(address(pool), address(0), shares);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ExitEpochSettled(epoch, shares, 17);
        vm.expectEmit(true, true, false, true, address(assetToken));
        emit Transfer(address(pool), RECIPIENT, 17);
        vm.expectEmit(true, true, false, true, address(pool));
        emit ExitClaimed(ALICE, RECIPIENT, shares, 17);
        vm.prank(ALICE);
        pool.completeRedeem(RECIPIENT);
    }

    function test_rewardNotificationOrdersTokenTransferThenExactSchedule() public {
        _deposit(ALICE, 10);
        pool.setRewardsDuration(10);
        rewardToken.mint(BOB, 100);
        vm.prank(BOB);
        rewardToken.approve(address(pool), 100);
        uint64 finish = uint64(block.timestamp + 10);

        vm.expectEmit(true, true, false, true, address(rewardToken));
        emit Transfer(BOB, address(pool), 100);
        vm.expectEmit(false, false, false, true, address(pool));
        emit RewardNotified(100, 10, finish);
        vm.prank(BOB);
        pool.receiveProfitDistribution(100);
    }

    function test_overlappingRewardNotificationOrdersExactTransferAndBlendedSchedule() public {
        _deposit(ALICE, 10);
        pool.setRewardsDuration(10);
        _notify(BOB, 100);
        vm.warp(block.timestamp + 5);
        rewardToken.mint(BOB, 50);
        vm.prank(BOB);
        rewardToken.approve(address(pool), 50);

        vm.expectEmit(true, true, false, true, address(rewardToken));
        emit Transfer(BOB, address(pool), 50);
        vm.expectEmit(false, false, false, true, address(pool));
        emit RewardNotified(50, 14, uint64(block.timestamp + 7));
        vm.prank(BOB);
        pool.receiveProfitDistribution(50);
    }

    function test_rewardClaimOrdersTokenTransferThenExactClaim() public {
        _deposit(ALICE, 10);
        pool.setRewardsDuration(10);
        _notify(BOB, 100);
        vm.warp(block.timestamp + 10);

        vm.expectEmit(true, true, false, true, address(rewardToken));
        emit Transfer(address(pool), ALICE, 100);
        vm.expectEmit(true, false, false, true, address(pool));
        emit RewardClaimed(ALICE, 100);
        vm.prank(ALICE);
        pool.claimReward();
    }

    function test_payClaimOrdersAssetTransferThenExactClaimPaid() public {
        _deposit(ALICE, 17);
        vm.expectEmit(true, true, false, true, address(assetToken));
        emit Transfer(address(pool), RECIPIENT, 7);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ClaimPaid(RECIPIENT, 7);
        insurance.pay(pool, RECIPIENT, 7);
    }

    function test_sweepTokenOrdersTokenTransferThenExactSweep() public {
        CoverPoolHarnessToken stray = new CoverPoolHarnessToken("Stray", "STRAY", 18);
        stray.mint(address(pool), 19);
        vm.expectEmit(true, true, false, true, address(stray));
        emit Transfer(address(pool), RECIPIENT, 19);
        vm.expectEmit(true, true, false, true, address(pool));
        emit TokenSwept(address(stray), RECIPIENT, 19);
        pool.sweepToken(IERC20(address(stray)), RECIPIENT);
    }
}
