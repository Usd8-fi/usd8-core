// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {IAdapter} from "vault-v2/src/interfaces/IAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IProfitDistributionReceiver} from "../interfaces/IProfitDistributionReceiver.sol";

/// @title USD8 Savings Adapter
/// @notice Idle-liquidity adapter for the canonical Morpho Vault V2 sUSD8 vault.
/// @dev The parent vault transfers USD8 to this adapter before {allocate} and
///      pulls USD8 with `transferFrom` after {deallocate}. The hooks therefore
///      update Morpho's allocation accounting but must not transfer USD8 again.
///      Assets remain idle here; sUSD8 yield comes from Treasury-funded profit
///      distributions rather than an external lending position.
contract USD8SavingsAdapter is IAdapter, IProfitDistributionReceiver {
    using SafeERC20 for IERC20;

    /// @notice Account that directly deployed this adapter.
    address public immutable deployer;

    /// @notice Morpho Vault V2 instance that exclusively invokes adapter hooks.
    address public immutable parentVault;

    /// @notice USD8 asset held by this adapter on behalf of the parent vault.
    address public immutable asset;

    /// @notice Morpho allocation identifier assigned to this adapter position.
    bytes32 public immutable adapterId;

    /// @notice Caller is not the parent vault.
    error NotAuthorized();

    /// @notice Adapter data must be empty because this adapter has no markets or routes.
    error InvalidData();

    /// @notice Emitted after Treasury profit is transferred into the adapter.
    /// @param distributor Account that supplied the profit.
    /// @param assets Amount of USD8 received.
    event ProfitDistributed(address indexed distributor, uint256 assets);

    /// @param _parentVault Morpho Vault V2 sUSD8 vault served by this adapter.
    /// @dev Permanently approves the parent vault to pull USD8 during deallocation.
    constructor(address _parentVault) {
        deployer = msg.sender;
        parentVault = _parentVault;
        asset = IVaultV2(_parentVault).asset();
        adapterId = keccak256(abi.encode("this", address(this)));
        IERC20(asset).forceApprove(_parentVault, type(uint256).max);
    }

    /// @notice Reports the adapter's balance after the parent vault transfers an allocation to it.
    /// @dev The parent vault transfers the requested assets before invoking this hook.
    ///      Reading the resulting balance also reconciles any previously unaccounted USD8.
    /// @param data Must be empty.
    /// @return ids_ Single allocation identifier for this adapter.
    /// @return change Signed change from the recorded allocation to the current balance.
    function allocate(bytes memory data, uint256, bytes4, address)
        external
        view
        returns (bytes32[] memory ids_, int256 change)
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        if (data.length != 0) revert InvalidData();

        uint256 oldAllocation = allocation();
        uint256 newAllocation = IERC20(asset).balanceOf(address(this));
        // Both operands are in [0, int256.max], so either directional delta is representable.
        return (ids(), SafeCast.toInt256(newAllocation) - SafeCast.toInt256(oldAllocation));
    }

    /// @notice Reports the projected balance before the parent vault pulls a deallocation.
    /// @dev The parent vault invokes this hook first and then pulls `assets` via
    ///      `transferFrom`; this hook must not transfer the assets itself.
    /// @param data Must be empty.
    /// @param assets Amount of USD8 the parent vault will pull after this hook.
    /// @return ids_ Single allocation identifier for this adapter.
    /// @return change Signed change from the recorded allocation to the post-pull balance.
    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        view
        returns (bytes32[] memory ids_, int256 change)
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        if (data.length != 0) revert InvalidData();

        uint256 oldAllocation = allocation();
        uint256 newAllocation = IERC20(asset).balanceOf(address(this)) - assets;
        // Both operands are in [0, int256.max], so either directional delta is representable.
        return (ids(), SafeCast.toInt256(newAllocation) - SafeCast.toInt256(oldAllocation));
    }

    /// @notice Returns the single Morpho allocation identifier used by this adapter.
    function ids() public view returns (bytes32[] memory ids_) {
        ids_ = new bytes32[](1);
        ids_[0] = adapterId;
    }

    /// @notice Returns the allocation currently recorded by the parent vault.
    function allocation() public view returns (uint256) {
        return IVaultV2(parentVault).allocation(adapterId);
    }

    /// @notice Returns the adapter's current USD8 balance when its allocation is active.
    /// @dev Returns zero for a disabled/unallocated adapter so an unsolicited
    ///      transfer cannot create an uncapped position in parent-vault accounting.
    function realAssets() external view returns (uint256) {
        return allocation() == 0 ? 0 : IERC20(asset).balanceOf(address(this));
    }

    /// @notice Pulls realized USD8 profit into the sUSD8 max-rate buffer.
    /// @dev Checkpoints the vault before receiving USD8 so elapsed time cannot
    ///      release profit that had not yet arrived.
    /// @param assets Amount of USD8 to pull from the caller.
    function receiveProfitDistribution(uint256 assets) external {
        IVaultV2(parentVault).accrueInterest();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        emit ProfitDistributed(msg.sender, assets);
    }
}
