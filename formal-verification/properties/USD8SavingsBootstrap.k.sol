// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {ErrorsLib} from "vault-v2/src/libraries/ErrorsLib.sol";
import {USD8} from "../../src/USD8.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";
import {USD8SavingsBootstrap} from "../../src/deployment/USD8SavingsBootstrap.sol";
import {
    BootstrapModelFailure,
    USD8SavingsBootstrapKontrolBase,
    USD8SavingsBootstrapFactoryModel,
    USD8SavingsBootstrapOwnerModel,
    USD8SavingsBootstrapTokenModel,
    USD8SavingsBootstrapTreasuryModel,
    USD8SavingsBootstrapVaultModel
} from "./USD8SavingsBootstrapHarness.k.sol";

/// @notice Bounded Kontrol properties for the one-transaction bootstrap.
/// @dev The factory, Vault V2, Treasury and ERC20s are stateful executable models.
///      Factory attestation honesty, SCALE=1e12, six fixed submit/execute
///      operations, one nested callback attempt, and six occurrence-bounded
///      ERC20 return schedules are explicit model boundaries. ERC20 paths cover
///      true/false/empty/malformed returns and forceApprove's zero-first retry.
///      No vm.mockCall(s) is used.
contract USD8SavingsBootstrapKontrolTest is USD8SavingsBootstrapKontrolBase {
    function test_ownerAndExecutedInitialize() public view {
        assertEq(bootstrap.owner(), address(this));
        assertFalse(bootstrap.executed());
    }

    function test_nonOwnerRejectedBeforeOneShotCheck() public {
        USD8SavingsBootstrap.Config memory config = _config();
        vm.prank(OUTSIDER);
        (bool success, bytes memory returndata) =
            address(bootstrap).call(abi.encodeCall(USD8SavingsBootstrap.run, (config)));
        assertFalse(success);
        _assertExact4(returndata, USD8SavingsBootstrap.NotOwner.selector);
        _assertPristine();

        bootstrap.run(config);
        vm.prank(OUTSIDER);
        (success, returndata) = address(bootstrap).call(abi.encodeCall(USD8SavingsBootstrap.run, (config)));
        assertFalse(success);
        _assertExact4(returndata, USD8SavingsBootstrap.NotOwner.selector);
        assertTrue(bootstrap.executed());
        assertEq(factory.createCalls(), 1);
    }

    function test_aclAndOneShotChecksPrecedeEveryInvalidPosition(uint8 invalidIndex, uint8 overlap) public {
        vm.assume(invalidIndex < 5 && overlap < 3);
        USD8SavingsBootstrap.Config memory config = _config();
        if (invalidIndex == 0) config.vaultFactory = address(0);
        else if (invalidIndex == 1) config.usd8 = USD8(address(0));
        else if (invalidIndex == 2) config.treasury = Treasury(address(0));
        else if (invalidIndex == 3) config.seedSink = address(0);
        else config.governance = address(0);

        if (overlap != 0) bootstrap.run(_config());
        bool success;
        bytes memory returndata;
        if (overlap < 2) {
            vm.prank(OUTSIDER);
            (success, returndata) = address(bootstrap).call(abi.encodeCall(USD8SavingsBootstrap.run, (config)));
            assertFalse(success);
            _assertExact4(returndata, USD8SavingsBootstrap.NotOwner.selector);
        } else {
            (success, returndata) = _runLowLevel(config);
            assertFalse(success);
            _assertExact4(returndata, USD8SavingsBootstrap.AlreadyExecuted.selector);
        }
        assertEq(factory.createCalls(), overlap == 0 ? 0 : 1);
    }

    function test_ownerCannotExecuteTwiceAndFirstDeploymentIsUnchanged() public {
        USD8SavingsBootstrap.Config memory config = _config();
        USD8SavingsBootstrap.Deployment memory first = bootstrap.run(config);
        (bool success, bytes memory returndata) = _runLowLevel(config);
        assertFalse(success);
        _assertExact4(returndata, USD8SavingsBootstrap.AlreadyExecuted.selector);
        assertTrue(bootstrap.executed());
        assertEq(factory.createCalls(), 1);
        assertEq(first.bootstrap, address(bootstrap));
        assertEq(first.vault, address(factory.vault()));
    }

    function test_everyInvalidAddressRevertsBeforeExecution(uint8 invalidIndex) public {
        vm.assume(invalidIndex < 5);
        USD8SavingsBootstrap.Config memory config = _config();
        if (invalidIndex == 0) config.vaultFactory = address(0);
        else if (invalidIndex == 1) config.usd8 = USD8(address(0));
        else if (invalidIndex == 2) config.treasury = Treasury(address(0));
        else if (invalidIndex == 3) config.seedSink = address(0);
        else config.governance = address(0);

        (bool success, bytes memory returndata) = _runLowLevel(config);
        assertFalse(success);
        _assertExact4(returndata, USD8SavingsBootstrap.InvalidAddress.selector);
        _assertPristine();
    }

    function test_factoryMustAttestItsCreateResult() public {
        factory.configure(0, false, address(0));
        (bool success, bytes memory returndata) = _runLowLevel(_config());
        assertFalse(success);
        _assertExact4(returndata, USD8SavingsBootstrap.InvalidFactory.selector);
        _assertPristine();
        assertEq(address(factory.vault()), address(0));
    }

    function test_successReturnsAndConfiguresExactDeploymentTuple() public {
        USD8SavingsBootstrap.Config memory config = _config();
        USD8SavingsBootstrap.Deployment memory d = bootstrap.run(config);
        USD8SavingsBootstrapVaultModel vault = factory.vault();
        USD8SavingsAdapter adapter = USD8SavingsAdapter(d.adapter);
        bytes memory idData = abi.encode("this", d.adapter);
        bytes32 id = keccak256(idData);

        assertTrue(bootstrap.executed());
        assertEq(d.bootstrap, address(bootstrap));
        assertEq(d.vault, address(vault));
        assertTrue(d.adapter != address(0));
        assertEq(factory.createCalls(), 1);
        assertEq(factory.lastOwner(), address(bootstrap));
        assertEq(factory.lastAsset(), address(usd8));
        assertEq(factory.lastSalt(), SALT);

        assertEq(keccak256(bytes(vault.name())), keccak256(bytes("Savings USD8")));
        assertEq(keccak256(bytes(vault.symbol())), keccak256(bytes("sUSD8")));
        assertEq(vault.owner(), GOVERNANCE);
        assertEq(vault.curator(), GOVERNANCE);
        assertTrue(vault.isAllocator(GOVERNANCE));
        assertFalse(vault.isAllocator(address(bootstrap)));
        assertTrue(vault.isAdapter(d.adapter));
        assertEq(vault.absoluteCap(id), type(uint128).max);
        assertEq(vault.relativeCap(id), 1e18);
        assertEq(vault.maxRate(), MAX_RATE);
        assertEq(vault.liquidityAdapter(), d.adapter);
        assertEq(vault.liquidityData().length, 0);

        assertEq(adapter.deployer(), address(bootstrap));
        assertEq(adapter.parentVault(), d.vault);
        assertEq(adapter.asset(), address(usd8));
        assertEq(adapter.adapterId(), id);
        assertEq(usd8.allowance(d.adapter, d.vault), type(uint256).max);

        uint256 seedUsd8 = SEED_USDC * SCALE;
        assertEq(usdc.balanceOf(address(bootstrap)), 0);
        assertEq(usdc.balanceOf(address(treasury)), SEED_USDC);
        assertEq(usd8.balanceOf(address(bootstrap)), 0);
        assertEq(usd8.balanceOf(d.adapter), seedUsd8);
        assertEq(vault.balanceOf(SEED_SINK), seedUsd8);
        assertEq(vault.allocation(id), seedUsd8);
        assertEq(adapter.realAssets(), seedUsd8);
    }

    function test_sixConfigurationPayloadsAreSubmittedThenExecutedExactly() public {
        USD8SavingsBootstrap.Deployment memory d = bootstrap.run(_config());
        USD8SavingsBootstrapVaultModel vault = factory.vault();
        assertEq(vault.submitCalls(), 6);
        assertEq(vault.executeCalls(), 6);
        assertEq(vault.traceCalls(), 20);
        for (uint8 i; i < 6; ++i) {
            bytes32 expected = keccak256(_expectedConfigData(i, d.adapter));
            assertEq(vault.submittedHash(i), expected);
            assertEq(vault.executedHash(i), expected);
        }
        for (uint8 i; i < 20; ++i) {
            assertEq(vault.callTrace(i), keccak256(_expectedVaultCall(i, d.adapter)));
        }
    }

    function test_zeroSeedRevertsExactTreasuryZeroAmountAndRollsBack() public {
        USD8SavingsBootstrap.Config memory config = _config();
        config.seedUsdc = 0;
        (bool success, bytes memory returndata) = _runLowLevel(config);
        assertFalse(success);
        assertEq(returndata.length, 4);
        assertEq(_selector(returndata), Treasury.ZeroAmount.selector);
        _assertPristine();
        assertEq(address(factory.vault()), address(0));
    }

    /// [C:ADDRESS_REPRESENTATIVE] SEED_SINK and GOVERNANCE are fixed,
    /// pairwise-distinct nonzero representatives. Address-renaming is sound for
    /// this partition because the successful path observes them only as mapping
    /// keys and equality operands. Relevant aliases have separate properties.
    function test_representativeConfigBindsSymbolicScalars(uint64 seedUsdc, uint64 maxRate_, bytes32 salt_) public {
        vm.assume(seedUsdc > 0);
        vm.assume(maxRate_ <= VAULT_MAX_MAX_RATE);
        USD8SavingsBootstrap localBootstrap = new USD8SavingsBootstrap();
        usdc.mint(address(localBootstrap), seedUsdc);
        USD8SavingsBootstrap.Config memory config = USD8SavingsBootstrap.Config({
            vaultFactory: address(factory),
            usd8: USD8(address(usd8)),
            treasury: Treasury(address(treasury)),
            seedUsdc: seedUsdc,
            seedSink: SEED_SINK,
            governance: GOVERNANCE,
            maxRate: maxRate_,
            salt: salt_
        });

        USD8SavingsBootstrap.Deployment memory d = localBootstrap.run(config);
        USD8SavingsBootstrapVaultModel vault = factory.vault();
        uint256 expectedUsd8 = uint256(seedUsdc) * SCALE;
        bytes32 id = keccak256(abi.encode("this", d.adapter));
        assertEq(factory.lastOwner(), address(localBootstrap));
        assertEq(factory.lastAsset(), address(usd8));
        assertEq(factory.lastSalt(), salt_);
        assertEq(vault.owner(), GOVERNANCE);
        assertEq(vault.curator(), GOVERNANCE);
        assertTrue(vault.isAllocator(GOVERNANCE));
        assertFalse(vault.isAllocator(address(localBootstrap)));
        assertEq(vault.maxRate(), maxRate_);
        assertEq(vault.balanceOf(SEED_SINK), expectedUsd8);
        assertEq(vault.allocation(id), expectedUsd8);
        assertEq(usdc.balanceOf(address(localBootstrap)), 0);
        assertEq(usdc.balanceOf(address(treasury)), seedUsdc);
        assertEq(usd8.balanceOf(address(localBootstrap)), 0);
        assertEq(usd8.balanceOf(d.adapter), expectedUsd8);
    }

    function test_maxRateAtRealVaultLimitSucceeds() public {
        USD8SavingsBootstrap.Config memory config = _config();
        config.maxRate = VAULT_MAX_MAX_RATE;
        bootstrap.run(config);
        assertEq(factory.vault().maxRate(), VAULT_MAX_MAX_RATE);
    }

    function test_maxRateOverRealVaultLimitRevertsExactAndRollsBack() public {
        USD8SavingsBootstrap.Config memory config = _config();
        config.maxRate = VAULT_MAX_MAX_RATE + 1;
        (bool success, bytes memory returndata) = _runLowLevel(config);
        assertFalse(success);
        _assertExact4(returndata, ErrorsLib.MaxRateTooHigh.selector);
        _assertPristine();
    }

    function test_governanceEqualBootstrapHasAllowedTerminalSelfBinding() public {
        USD8SavingsBootstrap.Config memory config = _config();
        config.governance = address(bootstrap);
        USD8SavingsBootstrap.Deployment memory d = bootstrap.run(config);
        USD8SavingsBootstrapVaultModel vault = factory.vault();
        assertEq(vault.owner(), address(bootstrap));
        assertEq(vault.curator(), address(bootstrap));
        assertFalse(vault.isAllocator(address(bootstrap)));
        assertEq(vault.balanceOf(SEED_SINK), SEED_USDC * SCALE);
        assertEq(d.bootstrap, address(bootstrap));
    }

    function test_seedSinkEqualGovernanceAliasCreditsGovernance() public {
        USD8SavingsBootstrap.Config memory config = _config();
        config.seedSink = GOVERNANCE;
        bootstrap.run(config);
        assertEq(factory.vault().balanceOf(GOVERNANCE), SEED_USDC * SCALE);
        assertEq(factory.vault().owner(), GOVERNANCE);
    }

    function test_seedSinkEqualBootstrapAliasCreditsBootstrap() public {
        USD8SavingsBootstrap.Config memory config = _config();
        config.seedSink = address(bootstrap);
        bootstrap.run(config);
        assertEq(factory.vault().balanceOf(address(bootstrap)), SEED_USDC * SCALE);
        assertEq(factory.vault().owner(), GOVERNANCE);
    }

    function test_seedSinkAndGovernanceEqualBootstrapAlias() public {
        USD8SavingsBootstrap.Config memory config = _config();
        config.seedSink = address(bootstrap);
        config.governance = address(bootstrap);
        bootstrap.run(config);
        USD8SavingsBootstrapVaultModel vault = factory.vault();
        assertEq(vault.balanceOf(address(bootstrap)), SEED_USDC * SCALE);
        assertEq(vault.owner(), address(bootstrap));
        assertEq(vault.curator(), address(bootstrap));
        assertFalse(vault.isAllocator(address(bootstrap)));
    }

    function test_factoryCreateFailureBubblesExactAndRollsBack() public {
        factory.configure(1, true, address(0));
        _assertModelFailureAndPristine(71);
    }

    function test_factoryValidationFailureBubblesExactAndRollsBack() public {
        factory.configure(2, true, address(0));
        _assertModelFailureAndPristine(72);
    }

    function test_vaultSetNameFailureExactAndAtomic() public {
        _assertDirectVaultFailure(2);
    }

    function test_vaultSetSymbolFailureExactAndAtomic() public {
        _assertDirectVaultFailure(3);
    }

    function test_vaultInitialCuratorFailureExactAndAtomic() public {
        _assertDirectVaultFailure(4);
    }

    function test_vaultSetMaxRateFailureExactAndAtomic() public {
        _assertDirectVaultFailure(5);
    }

    function test_vaultSetLiquidityFailureExactAndAtomic() public {
        _assertDirectVaultFailure(6);
    }

    function test_vaultDepositFailureExactAndAtomic() public {
        _assertDirectVaultFailure(7);
    }

    function test_vaultFinalCuratorFailureExactAndAtomic() public {
        _assertDirectVaultFailure(8);
    }

    function test_vaultSetOwnerFailureExactAndAtomic() public {
        _assertDirectVaultFailure(9);
    }

    function test_vaultAssetFailureExactAndAtomic() public {
        _assertDirectVaultFailure(1);
    }

    function test_submitAllocatorEnableFailureExactAndAtomic() public {
        _assertSubmitFailure(0);
    }

    function test_submitAddAdapterFailureExactAndAtomic() public {
        _assertSubmitFailure(1);
    }

    function test_submitAbsoluteCapFailureExactAndAtomic() public {
        _assertSubmitFailure(2);
    }

    function test_submitRelativeCapFailureExactAndAtomic() public {
        _assertSubmitFailure(3);
    }

    function test_submitGovernanceAllocatorFailureExactAndAtomic() public {
        _assertSubmitFailure(4);
    }

    function test_submitBootstrapDisableFailureExactAndAtomic() public {
        _assertSubmitFailure(5);
    }

    function test_executeAllocatorEnableFailureExactAndAtomic() public {
        _assertExecuteFailure(0);
    }

    function test_executeAddAdapterFailureExactAndAtomic() public {
        _assertExecuteFailure(1);
    }

    function test_executeAbsoluteCapFailureExactAndAtomic() public {
        _assertExecuteFailure(2);
    }

    function test_executeRelativeCapFailureExactAndAtomic() public {
        _assertExecuteFailure(3);
    }

    function test_executeGovernanceAllocatorFailureExactAndAtomic() public {
        _assertExecuteFailure(4);
    }

    function test_executeBootstrapDisableFailureExactAndAtomic() public {
        _assertExecuteFailure(5);
    }

    function test_treasuryUsdcReadFailureBubblesExactAndAtomic() public {
        treasury.setFailure(1);
        _assertModelFailureAndPristine(61);
    }

    function test_treasuryMintFailureBubblesExactAndAtomic() public {
        treasury.setFailure(2);
        _assertModelFailureAndPristine(62);
    }

    function test_treasuryScaleReadFailureBubblesExactAndAtomic() public {
        treasury.setFailure(3);
        _assertModelFailureAndPristine(63);
    }

    function test_usdcEmptyApproveAndTransfersSucceed() public {
        usdc.setApproveMode(0, 2);
        usdc.setTransferFromMode(0, 2);
        _assertSuccessfulRun();
    }

    function test_usd8EmptyConstructorApprovalAndTransferSucceed() public {
        usd8.setApproveMode(0, 2);
        usd8.setTransferFromMode(0, 2);
        _assertSuccessfulRun();
    }

    function test_usd8EmptyBootstrapApprovalSucceeds() public {
        usd8.setApproveMode(1, 2);
        _assertSuccessfulRun();
    }

    function test_adapterApprovalFirstFalseFallsBackSuccessfully() public {
        _assertUsd8FirstFailureFallsBack(0, 1, 4);
    }

    function test_adapterApprovalFirstMalformedFallsBackSuccessfully() public {
        _assertUsd8FirstFailureFallsBack(0, 3, 4);
    }

    function test_adapterApprovalFirstRevertBubblesFromResetAndIsAtomic() public {
        _assertUsd8FirstRevert(0);
    }

    function test_bootstrapApprovalFirstFalseFallsBackSuccessfully() public {
        _assertUsd8FirstFailureFallsBack(1, 1, 4);
    }

    function test_bootstrapApprovalFirstMalformedFallsBackSuccessfully() public {
        _assertUsd8FirstFailureFallsBack(1, 3, 4);
    }

    function test_bootstrapApprovalFirstRevertBubblesFromResetAndIsAtomic() public {
        _assertUsd8FirstRevert(1);
    }

    function test_bothUsd8ApprovalSitesTakeFirstResetRetry() public {
        usd8.setApproveMode(0, 1);
        usd8.setApproveMode(3, 3);
        _assertSuccessfulRun();
        assertEq(usd8.approveCalls(), 6);
    }

    function test_adapterApprovalResetFalseIsExactSafeERC20AndAtomic() public {
        _assertUsd8FallbackFailure(0, 1, 1, false);
    }

    function test_adapterApprovalResetMalformedIsExactSafeERC20AndAtomic() public {
        _assertUsd8FallbackFailure(0, 1, 3, false);
    }

    function test_adapterApprovalResetRevertBubblesExactAndIsAtomic() public {
        _assertUsd8FallbackFailure(0, 1, 4, true);
    }

    function test_adapterApprovalRetryFalseIsExactSafeERC20AndAtomic() public {
        _assertUsd8FallbackFailure(0, 2, 1, false);
    }

    function test_adapterApprovalRetryMalformedIsExactSafeERC20AndAtomic() public {
        _assertUsd8FallbackFailure(0, 2, 3, false);
    }

    function test_adapterApprovalRetryRevertBubblesExactAndIsAtomic() public {
        _assertUsd8FallbackFailure(0, 2, 4, true);
    }

    function test_bootstrapApprovalResetFalseIsExactSafeERC20AndAtomic() public {
        _assertUsd8FallbackFailure(1, 2, 1, false);
    }

    function test_bootstrapApprovalResetMalformedIsExactSafeERC20AndAtomic() public {
        _assertUsd8FallbackFailure(1, 2, 3, false);
    }

    function test_bootstrapApprovalResetRevertBubblesExactAndIsAtomic() public {
        _assertUsd8FallbackFailure(1, 2, 4, true);
    }

    function test_bootstrapApprovalRetryFalseIsExactSafeERC20AndAtomic() public {
        _assertUsd8FallbackFailure(1, 3, 1, false);
    }

    function test_bootstrapApprovalRetryMalformedIsExactSafeERC20AndAtomic() public {
        _assertUsd8FallbackFailure(1, 3, 3, false);
    }

    function test_bootstrapApprovalRetryRevertBubblesExactAndIsAtomic() public {
        _assertUsd8FallbackFailure(1, 3, 4, true);
    }

    function test_usdcApprovalResetFalseIsExactSafeERC20AndAtomic() public {
        _assertUsdcFallbackFailure(1, 1, false);
    }

    function test_usdcApprovalResetMalformedIsExactSafeERC20AndAtomic() public {
        _assertUsdcFallbackFailure(1, 3, false);
    }

    function test_usdcApprovalResetRevertBubblesExactAndIsAtomic() public {
        _assertUsdcFallbackFailure(1, 4, true);
    }

    function test_usdcApprovalRetryFalseIsExactSafeERC20AndAtomic() public {
        _assertUsdcFallbackFailure(2, 1, false);
    }

    function test_usdcApprovalRetryMalformedIsExactSafeERC20AndAtomic() public {
        _assertUsdcFallbackFailure(2, 3, false);
    }

    function test_usdcApprovalRetryRevertBubblesExactAndIsAtomic() public {
        _assertUsdcFallbackFailure(2, 4, true);
    }

    function test_usdcTransferFromFalseIsExactSafeERC20AndAtomic() public {
        _assertTransferFailure(usdc, 1, false);
    }

    function test_usdcTransferFromMalformedIsExactSafeERC20AndAtomic() public {
        _assertTransferFailure(usdc, 3, false);
    }

    function test_usd8TransferFromFalseIsExactSafeERC20AndAtomic() public {
        _assertTransferFailure(usd8, 1, false);
    }

    function test_usd8TransferFromMalformedIsExactSafeERC20AndAtomic() public {
        _assertTransferFailure(usd8, 3, false);
    }

    function test_transferFromRevertBubblesExactTokenErrorAndIsAtomic() public {
        _assertTransferFailure(usdc, 4, true);
    }

    function test_usd8TransferFromRevertBubblesExactTokenErrorAndIsAtomic() public {
        _assertTransferFailure(usd8, 4, true);
    }

    // Fixed callback phases avoid a symbolic hook branch across a full transaction.
    function test_callbackAtFactoryCreate() public {
        _assertMutatingCallbackAt(0);
    }

    function test_callbackAtVaultSetName() public {
        _assertMutatingCallbackAt(1);
    }

    function test_callbackAtVaultSetSymbol() public {
        _assertMutatingCallbackAt(2);
    }

    function test_callbackAtVaultInitialCurator() public {
        _assertMutatingCallbackAt(3);
    }

    function test_callbackAtVaultSetMaxRate() public {
        _assertMutatingCallbackAt(4);
    }

    function test_callbackAtVaultSetLiquidity() public {
        _assertMutatingCallbackAt(5);
    }

    function test_callbackAtVaultDeposit() public {
        _assertMutatingCallbackAt(6);
    }

    function test_callbackAtVaultFinalCurator() public {
        _assertMutatingCallbackAt(7);
    }

    function test_callbackAtVaultSetOwner() public {
        _assertMutatingCallbackAt(8);
    }

    function test_callbackAtSubmitAllocatorEnable() public {
        _assertMutatingCallbackAt(9);
    }

    function test_callbackAtSubmitAddAdapter() public {
        _assertMutatingCallbackAt(10);
    }

    function test_callbackAtSubmitAbsoluteCap() public {
        _assertMutatingCallbackAt(11);
    }

    function test_callbackAtSubmitRelativeCap() public {
        _assertMutatingCallbackAt(12);
    }

    function test_callbackAtSubmitGovernanceAllocator() public {
        _assertMutatingCallbackAt(13);
    }

    function test_callbackAtSubmitBootstrapDisable() public {
        _assertMutatingCallbackAt(14);
    }

    function test_callbackAtExecuteAllocatorEnable() public {
        _assertMutatingCallbackAt(15);
    }

    function test_callbackAtExecuteAddAdapter() public {
        _assertMutatingCallbackAt(16);
    }

    function test_callbackAtExecuteAbsoluteCap() public {
        _assertMutatingCallbackAt(17);
    }

    function test_callbackAtExecuteRelativeCap() public {
        _assertMutatingCallbackAt(18);
    }

    function test_callbackAtExecuteGovernanceAllocator() public {
        _assertMutatingCallbackAt(19);
    }

    function test_callbackAtExecuteBootstrapDisable() public {
        _assertMutatingCallbackAt(20);
    }

    function test_callbackAtTreasuryMint() public {
        _assertMutatingCallbackAt(21);
    }

    function test_callbackAtUsdcApprovalFirst() public {
        _assertApprovalCallback(false, 0, type(uint8).max);
    }

    function test_callbackAtUsdcApprovalReset() public {
        _assertApprovalCallback(false, 1, 0);
    }

    function test_callbackAtUsdcApprovalRetry() public {
        _assertApprovalCallback(false, 2, 0);
    }

    function test_callbackAtUsdcTransferFrom() public {
        _assertMutatingCallbackAt(23);
    }

    function test_callbackAtAdapterApprovalFirst() public {
        _assertApprovalCallback(true, 0, type(uint8).max);
    }

    function test_callbackAtAdapterApprovalReset() public {
        _assertApprovalCallback(true, 1, 0);
    }

    function test_callbackAtAdapterApprovalRetry() public {
        _assertApprovalCallback(true, 2, 0);
    }

    function test_callbackAtBootstrapApprovalFirst() public {
        _assertApprovalCallback(true, 1, type(uint8).max);
    }

    function test_callbackAtBootstrapApprovalReset() public {
        _assertApprovalCallback(true, 2, 1);
    }

    function test_callbackAtBootstrapApprovalRetry() public {
        _assertApprovalCallback(true, 3, 1);
    }

    function test_callbackAtBootstrapApprovalFirstAfterAdapterFallback() public {
        _assertDualFallbackApprovalCallback(3);
    }

    function test_callbackAtBootstrapApprovalResetAfterAdapterFallback() public {
        _assertDualFallbackApprovalCallback(4);
    }

    function test_callbackAtBootstrapApprovalRetryAfterAdapterFallback() public {
        _assertDualFallbackApprovalCallback(5);
    }

    function test_callbackAtUsd8TransferFrom() public {
        _assertMutatingCallbackAt(25);
    }

    function test_staticCallbackAtFactoryAttestationRollsBack() public {
        _assertStaticCallbackAt(0);
    }

    function test_staticCallbackAtVaultAssetRollsBack() public {
        _assertStaticCallbackAt(1);
    }

    function test_staticCallbackAtTreasuryUsdcRollsBack() public {
        _assertStaticCallbackAt(2);
    }

    function test_staticCallbackAtTreasuryScaleRollsBack() public {
        _assertStaticCallbackAt(3);
    }

    function _assertSuccessfulRun() internal {
        USD8SavingsBootstrap.Deployment memory d = bootstrap.run(_config());
        assertTrue(bootstrap.executed());
        assertEq(factory.createCalls(), 1);
        assertEq(factory.vault().balanceOf(SEED_SINK), SEED_USDC * SCALE);
        assertEq(usd8.balanceOf(d.adapter), SEED_USDC * SCALE);
    }

    function _assertModelFailureAndPristine(uint8 point) internal {
        (bool success, bytes memory returndata) = _runLowLevel(_config());
        assertFalse(success);
        assertEq(returndata, abi.encodeWithSelector(BootstrapModelFailure.selector, point));
        _assertPristine();
    }

    function _assertDirectVaultFailure(uint8 point) internal {
        factory.configureVault(point, type(uint8).max, type(uint8).max);
        _assertModelFailureAndPristine(point);
    }

    function _assertSubmitFailure(uint8 index) internal {
        factory.configureVault(0, index, type(uint8).max);
        _assertModelFailureAndPristine(uint8(20 + index));
    }

    function _assertExecuteFailure(uint8 index) internal {
        factory.configureVault(0, type(uint8).max, index);
        address predictedAdapter = _createAddress(address(bootstrap), 1);
        bytes memory data = _expectedConfigData(index, predictedAdapter);
        (bool success, bytes memory returndata) = _runLowLevel(_config());
        assertFalse(success);
        assertEq(returndata, abi.encodeWithSelector(USD8SavingsBootstrap.ConfigurationCallFailed.selector, data));
        _assertPristine();
    }

    function _assertUsd8FirstFailureFallsBack(uint8 occurrence, uint8 mode, uint8 expectedCalls) internal {
        usd8.setApproveMode(occurrence, mode);
        _assertSuccessfulRun();
        assertEq(usd8.approveCalls(), expectedCalls);
    }

    function _assertUsd8FirstRevert(uint8 occurrence) internal {
        usd8.setApproveMode(occurrence, 4);
        (bool success, bytes memory returndata) = _runLowLevel(_config());
        assertFalse(success);
        // The reverting token call rolls its occurrence increment back, so
        // forceApprove's zero-reset reaches the same configured occurrence and
        // bubbles that exact token error.
        assertEq(returndata, abi.encodeWithSelector(BootstrapModelFailure.selector, uint8(40 + occurrence)));
        _assertPristine();
    }

    function _assertUsd8FallbackFailure(uint8 firstOccurrence, uint8 failedOccurrence, uint8 mode, bool bubbles)
        internal
    {
        usd8.setApproveMode(firstOccurrence, 1);
        usd8.setApproveMode(failedOccurrence, mode);
        (bool success, bytes memory returndata) = _runLowLevel(_config());
        assertFalse(success);
        if (bubbles) {
            assertEq(returndata, abi.encodeWithSelector(BootstrapModelFailure.selector, uint8(40 + failedOccurrence)));
        } else {
            assertEq(returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usd8)));
        }
        _assertPristine();
    }

    function _assertUsdcFallbackFailure(uint8 failedOccurrence, uint8 mode, bool bubbles) internal {
        usdc.setApproveMode(0, 1);
        usdc.setApproveMode(failedOccurrence, mode);
        (bool success, bytes memory returndata) = _runLowLevel(_config());
        assertFalse(success);
        if (bubbles) {
            assertEq(returndata, abi.encodeWithSelector(BootstrapModelFailure.selector, uint8(40 + failedOccurrence)));
        } else {
            assertEq(returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        }
        _assertPristine();
    }

    function _assertTransferFailure(USD8SavingsBootstrapTokenModel token, uint8 mode, bool bubbles) internal {
        token.setTransferFromMode(0, mode);
        (bool success, bytes memory returndata) = _runLowLevel(_config());
        assertFalse(success);
        if (bubbles) {
            assertEq(returndata, abi.encodeWithSelector(BootstrapModelFailure.selector, uint8(50)));
        } else {
            assertEq(returndata, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        }
        _assertPristine();
    }

    function _assertMutatingCallbackAt(uint8 phase) internal {
        (
            USD8SavingsBootstrapOwnerModel ownerModel,
            USD8SavingsBootstrapFactoryModel callbackFactory,
            USD8SavingsBootstrap.Config memory config
        ) = _callbackFixture();
        USD8SavingsBootstrapTreasuryModel callbackTreasury = USD8SavingsBootstrapTreasuryModel(address(config.treasury));
        USD8SavingsBootstrapTokenModel callbackUsdc = callbackTreasury.reserve();
        USD8SavingsBootstrapTokenModel callbackUsd8 = USD8SavingsBootstrapTokenModel(address(config.usd8));

        if (phase == 0) callbackFactory.configure(0, true, address(ownerModel));
        else if (phase <= 8) callbackFactory.configureVaultCallback(address(ownerModel), uint8(1 + phase));
        else if (phase <= 14) callbackFactory.configureVaultCallback(address(ownerModel), uint8(11 + phase));
        else if (phase <= 20) callbackFactory.configureVaultCallback(address(ownerModel), uint8(15 + phase));
        else if (phase == 21) callbackTreasury.configureCallback(address(ownerModel), 2);
        else if (phase == 23) callbackUsdc.configureCallback(address(ownerModel), type(uint8).max, 0);
        else callbackUsd8.configureCallback(address(ownerModel), type(uint8).max, 0);
        ownerModel.setRunData(config);

        _runAndAssertCallbackOuter(ownerModel, callbackFactory, config);
    }

    function _assertApprovalCallback(bool useUsd8, uint8 callbackOccurrence, uint8 firstFailureOccurrence) internal {
        (
            USD8SavingsBootstrapOwnerModel ownerModel,
            USD8SavingsBootstrapFactoryModel callbackFactory,
            USD8SavingsBootstrap.Config memory config
        ) = _callbackFixture();
        USD8SavingsBootstrapTreasuryModel callbackTreasury = USD8SavingsBootstrapTreasuryModel(address(config.treasury));
        USD8SavingsBootstrapTokenModel token =
            useUsd8 ? USD8SavingsBootstrapTokenModel(address(config.usd8)) : callbackTreasury.reserve();
        if (firstFailureOccurrence < 6) token.setApproveMode(firstFailureOccurrence, 1);
        token.configureCallback(address(ownerModel), callbackOccurrence, type(uint8).max);
        ownerModel.setRunData(config);

        _runAndAssertCallbackOuter(ownerModel, callbackFactory, config);
    }

    function _assertDualFallbackApprovalCallback(uint8 callbackOccurrence) internal {
        (
            USD8SavingsBootstrapOwnerModel ownerModel,
            USD8SavingsBootstrapFactoryModel callbackFactory,
            USD8SavingsBootstrap.Config memory config
        ) = _callbackFixture();
        USD8SavingsBootstrapTokenModel token = USD8SavingsBootstrapTokenModel(address(config.usd8));
        token.setApproveMode(0, 1);
        token.setApproveMode(3, 1);
        token.configureCallback(address(ownerModel), callbackOccurrence, type(uint8).max);
        ownerModel.setRunData(config);

        _runAndAssertCallbackOuter(ownerModel, callbackFactory, config);
        assertEq(token.approveCalls(), 6);
    }

    function _runAndAssertCallbackOuter(
        USD8SavingsBootstrapOwnerModel ownerModel,
        USD8SavingsBootstrapFactoryModel callbackFactory,
        USD8SavingsBootstrap.Config memory config
    ) internal {
        USD8SavingsBootstrapTreasuryModel callbackTreasury = USD8SavingsBootstrapTreasuryModel(address(config.treasury));
        USD8SavingsBootstrapTokenModel callbackUsdc = callbackTreasury.reserve();
        USD8SavingsBootstrapTokenModel callbackUsd8 = USD8SavingsBootstrapTokenModel(address(config.usd8));
        USD8SavingsBootstrap.Deployment memory d = ownerModel.run(config);
        USD8SavingsBootstrapVaultModel vault = callbackFactory.vault();
        assertEq(ownerModel.callbackCalls(), 1);
        assertFalse(ownerModel.callbackSuccess());
        _assertExact4(ownerModel.callbackReturndata(), USD8SavingsBootstrap.AlreadyExecuted.selector);
        assertTrue(ownerModel.bootstrap().executed());
        assertEq(callbackFactory.createCalls(), 1);
        assertEq(vault.submitCalls(), 6);
        assertEq(vault.executeCalls(), 6);
        assertEq(vault.traceCalls(), 20);
        assertEq(callbackUsdc.balanceOf(address(callbackTreasury)), SEED_USDC);
        assertEq(callbackUsd8.totalSupply(), SEED_USDC * SCALE);
        assertEq(callbackUsd8.balanceOf(d.adapter), SEED_USDC * SCALE);
        assertEq(vault.balanceOf(SEED_SINK), SEED_USDC * SCALE);
    }

    function _assertStaticCallbackAt(uint8 phase) internal {
        // Interface view calls compile to STATICCALL. Persisting the nested
        // result therefore reverts the getter and the entire outer transaction.
        (
            USD8SavingsBootstrapOwnerModel ownerModel,
            USD8SavingsBootstrapFactoryModel callbackFactory,
            USD8SavingsBootstrap.Config memory config
        ) = _callbackFixture();
        USD8SavingsBootstrapTreasuryModel callbackTreasury = USD8SavingsBootstrapTreasuryModel(address(config.treasury));
        USD8SavingsBootstrapTokenModel callbackUsdc = callbackTreasury.reserve();
        if (phase == 0) callbackFactory.configureIsVaultCallback(address(ownerModel));
        else if (phase == 1) callbackFactory.configureVaultCallback(address(ownerModel), 1);
        else if (phase == 2) callbackTreasury.configureCallback(address(ownerModel), 1);
        else callbackTreasury.configureCallback(address(ownerModel), 3);
        ownerModel.setRunData(config);

        (bool success,) = address(ownerModel).call(abi.encodeCall(USD8SavingsBootstrapOwnerModel.run, (config)));
        assertFalse(success);
        assertFalse(ownerModel.bootstrap().executed());
        assertEq(ownerModel.callbackCalls(), 0);
        assertEq(callbackFactory.createCalls(), 0);
        assertEq(address(callbackFactory.vault()), address(0));
        assertEq(callbackUsdc.balanceOf(address(ownerModel.bootstrap())), SEED_USDC);
        assertEq(callbackUsdc.balanceOf(address(callbackTreasury)), 0);
        assertEq(callbackTreasury.usd8Token().totalSupply(), 0);
    }

    function _callbackFixture()
        internal
        returns (
            USD8SavingsBootstrapOwnerModel ownerModel,
            USD8SavingsBootstrapFactoryModel callbackFactory,
            USD8SavingsBootstrap.Config memory config
        )
    {
        USD8SavingsBootstrapTokenModel callbackUsdc = new USD8SavingsBootstrapTokenModel("Callback USDC", "cUSDC", 6);
        USD8SavingsBootstrapTokenModel callbackUsd8 = new USD8SavingsBootstrapTokenModel("Callback USD8", "cUSD8", 18);
        USD8SavingsBootstrapTreasuryModel callbackTreasury =
            new USD8SavingsBootstrapTreasuryModel(callbackUsdc, callbackUsd8, SCALE);
        callbackFactory = new USD8SavingsBootstrapFactoryModel(callbackUsd8);
        ownerModel = new USD8SavingsBootstrapOwnerModel();
        callbackUsdc.mint(address(ownerModel.bootstrap()), SEED_USDC);
        config = USD8SavingsBootstrap.Config({
            vaultFactory: address(callbackFactory),
            usd8: USD8(address(callbackUsd8)),
            treasury: Treasury(address(callbackTreasury)),
            seedUsdc: SEED_USDC,
            seedSink: SEED_SINK,
            governance: GOVERNANCE,
            maxRate: MAX_RATE,
            salt: SALT
        });
    }
}
