// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IInsuredTokenAdapter} from "../interfaces/IInsuredTokenAdapter.sol";

/// @title  ERC4626RateAdapter
/// @notice {IInsuredTokenAdapter} for ERC-4626 yield vaults (sGHO, scrvUSD,
///         sUSDS, …): the vault's own share rate serves BOTH metrics. The rate
///         is HWM-safe — it grows with yield and drops only when the vault's
///         assets actually shrink (a hack, bad debt): withdrawals are
///         proportional, flash loans don't move it, and donations only push it
///         UP (inflating the mark enough to matter means gifting the vault
///         ≥ the trigger drop — not an attack). Residual risk: a vault
///         compromised at the proxy level can lie about its rate; that case is
///         the admin open path's job.
/// @dev    Immutable and ownerless. Deploy one per insured vault token and
///         point {DefiInsurance.setAdapter} at it (deployment seeds the mark).
contract ERC4626RateAdapter is IInsuredTokenAdapter {
    /// @notice The vault whose share token is insured.
    IERC4626 public immutable vault;

    /// @notice 10^(18 − asset decimals), normalizing the rate to WAD.
    uint256 public immutable assetScale;

    /// @notice Highest rate seen and the block it was seen at.
    uint192 public hwmRate;
    uint64 public hwmBlock;

    event HighWaterMarkRaised(uint192 rate, uint64 blockNumber);

    error UnsupportedAssetDecimals(uint8 decimals);
    error ZeroRate();

    constructor(IERC4626 _vault) {
        uint8 dec = IERC20Metadata(_vault.asset()).decimals();
        if (dec > 18) revert UnsupportedAssetDecimals(dec);
        vault = _vault;
        assetScale = 10 ** (18 - dec);
        poke(); // seed the mark; also validates the vault reports a live rate
    }

    /// @inheritdoc IInsuredTokenAdapter
    function valuationRate() public view returns (uint256) {
        return vault.convertToAssets(1e18) * assetScale;
    }

    /// @inheritdoc IInsuredTokenAdapter
    function triggerState() external view returns (uint256, uint256, uint64) {
        return (valuationRate(), hwmRate, hwmBlock);
    }

    /// @inheritdoc IInsuredTokenAdapter
    function poke() public {
        uint256 rate = valuationRate();
        if (rate == 0 || rate > type(uint192).max) revert ZeroRate();
        if (rate > hwmRate) {
            (hwmRate, hwmBlock) = (uint192(rate), uint64(block.number));
            emit HighWaterMarkRaised(uint192(rate), uint64(block.number));
        }
    }
}
