// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {IAdapter} from "vault-v2/src/interfaces/IAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProfitDistributionReceiver} from "../interfaces/IProfitDistributionReceiver.sol";

/// @title USD8 Savings Adapter
/// @notice Morpho Vault V2 adapter that holds USD8 principal and Treasury-funded profit without deploying capital.
contract USD8SavingsAdapter is IAdapter, IProfitDistributionReceiver {
    using SafeERC20 for IERC20;

    address public immutable deployer;
    address public immutable parentVault;
    address public immutable asset;
    bytes32 public immutable adapterId;

    error NotAuthorized();
    error InvalidData();
    error AllocationTooLarge();

    event ProfitDistributed(address indexed distributor, uint256 assets);

    constructor(address _parentVault) {
        deployer = msg.sender;
        parentVault = _parentVault;
        asset = IVaultV2(_parentVault).asset();
        adapterId = keccak256(abi.encode("this", address(this)));
        IERC20(asset).forceApprove(_parentVault, type(uint256).max);
    }

    function allocate(bytes memory data, uint256, bytes4, address) external view returns (bytes32[] memory, int256) {
        if (msg.sender != parentVault) revert NotAuthorized();
        if (data.length != 0) revert InvalidData();

        uint256 oldAllocation = allocation();
        uint256 newAllocation = IERC20(asset).balanceOf(address(this));
        return (ids(), _change(newAllocation, oldAllocation));
    }

    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        view
        returns (bytes32[] memory, int256)
    {
        if (msg.sender != parentVault) revert NotAuthorized();
        if (data.length != 0) revert InvalidData();

        uint256 oldAllocation = allocation();
        uint256 newAllocation = IERC20(asset).balanceOf(address(this)) - assets;
        return (ids(), _change(newAllocation, oldAllocation));
    }

    function ids() public view returns (bytes32[] memory ids_) {
        ids_ = new bytes32[](1);
        ids_[0] = adapterId;
    }

    function allocation() public view returns (uint256) {
        return IVaultV2(parentVault).allocation(adapterId);
    }

    function realAssets() external view returns (uint256) {
        return allocation() == 0 ? 0 : IERC20(asset).balanceOf(address(this));
    }

    function _change(uint256 newAllocation, uint256 oldAllocation) internal pure returns (int256) {
        uint256 maxSigned = uint256(type(int256).max);
        if (newAllocation > maxSigned || oldAllocation > maxSigned) revert AllocationTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast) bounds checked above.
        return int256(newAllocation) - int256(oldAllocation);
    }

    /// @notice Pulls realized USD8 profit after checkpointing the vault so the donation enters its maxRate buffer.
    function receiveProfitDistribution(uint256 assets) external {
        IVaultV2(parentVault).accrueInterest();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        emit ProfitDistributed(msg.sender, assets);
    }
}
