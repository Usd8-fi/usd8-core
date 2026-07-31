// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultV2} from "vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/src/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {EventsLib} from "vault-v2/src/libraries/EventsLib.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";
import {USD8SavingsFeeToken, USD8SavingsToken} from "../properties/USD8SavingsAdapterHarness.k.sol";

/// @notice Foundry-only production-vault transaction-wide log proofs. Kontrol
/// v1.0.255 cannot soundly skip VaultV2's first AccrueInterest log or an ERC20
/// Transfer to assert the adapter's later application log. The independent mock
/// properties prove only relative checkpoint-before-transfer behavior; these
/// regressions close exact order against the pinned vendor VaultV2 bytecode.
contract USD8SavingsAdapterEventOrderingForgeTest is Test {
    event ProfitDistributed(address indexed distributor, uint256 assets);

    address internal constant DISTRIBUTOR = address(0xD157);
    USD8SavingsToken internal viewToken;
    VaultV2 internal viewVault;
    USD8SavingsAdapter internal viewAdapter;

    function setUp() public {
        viewToken = new USD8SavingsToken();
        (viewVault, viewAdapter) = _deploy(viewToken);
        _configure(viewVault, viewAdapter);
        viewToken.mint(address(this), 1);
        viewToken.approve(address(viewVault), 1);
        viewVault.deposit(1, address(this));
        assertEq(viewVault.allocation(viewAdapter.adapterId()), 1);
    }

    function test_realNoFeeVaultOrdersAccrueThenTransferThenNominalProfit(uint128 assets) public {
        USD8SavingsToken token = new USD8SavingsToken();
        (VaultV2 vault, USD8SavingsAdapter adapter) = _deploy(token);
        token.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        token.approve(address(adapter), assets);

        vm.recordLogs();
        vm.prank(DISTRIBUTOR);
        adapter.receiveProfitDistribution(assets);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 3);
        _assertAccrue(logs[0], vault, 0, 0, 0, 0);
        _assertTransfer(logs[1], address(token), DISTRIBUTOR, address(adapter), assets);
        _assertProfit(logs[2], adapter, DISTRIBUTOR, assets);
    }

    function test_realFeeTokenEmitsReceivedThenFeeThenNominalProfit(uint128 assets) public {
        vm.assume(assets > 0);
        USD8SavingsFeeToken token = new USD8SavingsFeeToken();
        (VaultV2 vault, USD8SavingsAdapter adapter) = _deploy(token);
        token.mint(DISTRIBUTOR, assets);
        vm.prank(DISTRIBUTOR);
        token.approve(address(adapter), assets);

        vm.recordLogs();
        vm.prank(DISTRIBUTOR);
        adapter.receiveProfitDistribution(assets);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 4);
        _assertAccrue(logs[0], vault, 0, 0, 0, 0);
        _assertTransfer(logs[1], address(token), DISTRIBUTOR, address(adapter), uint256(assets) - 1);
        _assertTransfer(logs[2], address(token), DISTRIBUTOR, address(0xFEE), 1);
        _assertProfit(logs[3], adapter, DISTRIBUTOR, assets);
        assertEq(token.balanceOf(address(adapter)), uint256(assets) - 1);
    }

    /// @dev Setup runs in the preceding transaction so VaultV2's EIP-1153
    /// transaction cache is naturally clear. accrueInterestView traverses the
    /// active adapter and reaches the asset's balanceOf(adapter) callback.
    function test_realVaultAccrueInterestCallsActiveAdapterRealAssetsView() public {
        viewToken.setBalanceReadTarget(true, false, address(viewAdapter));
        (bool success, bytes memory returndata) = address(viewVault).call(abi.encodeCall(IVaultV2.accrueInterest, ()));
        assertFalse(success);
        bytes memory expected =
            abi.encodeWithSelector(USD8SavingsToken.BalanceReadRejected.selector, address(viewAdapter));
        assertEq(returndata.length, expected.length);
        assertEq(keccak256(returndata), keccak256(expected));
    }

    function _deploy(USD8SavingsToken token) internal returns (VaultV2 vault, USD8SavingsAdapter adapter) {
        vault = VaultV2(new VaultV2Factory().createVaultV2(address(this), address(token), bytes32("sUSD8")));
        adapter = new USD8SavingsAdapter(address(vault));
    }

    function _configure(VaultV2 vault, USD8SavingsAdapter adapter) internal {
        vault.setCurator(address(this));
        _execute(vault, abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
        _execute(vault, abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        bytes memory idData = abi.encode("this", address(adapter));
        _execute(vault, abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _execute(vault, abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.setLiquidityAdapterAndData(address(adapter), "");
    }

    function _execute(VaultV2 vault, bytes memory data) internal {
        vault.submit(data);
        (bool success, bytes memory returndata) = address(vault).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 32), mload(returndata))
            }
        }
    }

    function _assertAccrue(
        Vm.Log memory log,
        VaultV2 vault,
        uint256 previousTotalAssets,
        uint256 newTotalAssets,
        uint256 performanceFeeShares,
        uint256 managementFeeShares
    ) internal pure {
        assertEq(log.emitter, address(vault));
        assertEq(log.topics.length, 1);
        assertEq(log.topics[0], EventsLib.AccrueInterest.selector);
        assertEq(
            keccak256(log.data),
            keccak256(abi.encode(previousTotalAssets, newTotalAssets, performanceFeeShares, managementFeeShares))
        );
    }

    function _assertTransfer(Vm.Log memory log, address emitter, address from, address to, uint256 amount)
        internal
        pure
    {
        assertEq(log.emitter, emitter);
        assertEq(log.topics.length, 3);
        assertEq(log.topics[0], IERC20.Transfer.selector);
        assertEq(log.topics[1], bytes32(uint256(uint160(from))));
        assertEq(log.topics[2], bytes32(uint256(uint160(to))));
        assertEq(abi.decode(log.data, (uint256)), amount);
    }

    function _assertProfit(Vm.Log memory log, USD8SavingsAdapter adapter, address distributor, uint256 assets)
        internal
        pure
    {
        assertEq(log.emitter, address(adapter));
        assertEq(log.topics.length, 2);
        assertEq(log.topics[0], ProfitDistributed.selector);
        assertEq(log.topics[1], bytes32(uint256(uint160(distributor))));
        assertEq(abi.decode(log.data, (uint256)), assets);
    }
}
