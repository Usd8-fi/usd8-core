// SPDX-License-Identifier: BUSL-1.1

//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\: \/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Registry} from "../Registry.sol";
import {SharedBase} from "../SharedBase.sol";

interface ITreasuryReserveAsset {
    function USDC() external view returns (IERC20);
}

/// @title StrategyBase
/// @notice Shared authorization and reserve-asset discovery for Treasury strategies.
abstract contract StrategyBase is SharedBase {
    /// @notice Chain-specific USDC reserve asset.
    IERC20 public immutable USDC;

    /// @notice Treasury that owns this strategy.
    address public immutable treasury;

    error UnauthorizedTreasury(address caller);

    constructor(address treasury_, Registry registry_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        IERC20 usdc_ = ITreasuryReserveAsset(treasury_).USDC();
        if (address(usdc_) == address(0)) revert ZeroAddress();
        treasury = treasury_;
        USDC = usdc_;
        _setRegistry(registry_);
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert UnauthorizedTreasury(msg.sender);
        _;
    }
}
