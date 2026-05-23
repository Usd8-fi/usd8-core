// SPDX-License-Identifier: MIT
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title  USD8
/// @notice Non-upgradeable ERC20 stablecoin. Only the Treasury contract can
///         mint or burn USD8; transfers and approvals follow the standard
///         ERC20 semantics from OpenZeppelin v5.
/// @dev    The Treasury is a separate contract that escrows collateral and
///         calls into this token to mint USD8 against deposits and burn USD8
///         on redemption. From this token's perspective the Treasury is the
///         owner; all mint/burn authority is delegated to it.
///
///         Security choices:
///         - `Ownable2Step` is used so Treasury handover requires explicit
///           `acceptOwnership` from the incoming Treasury contract. This
///           prevents accidentally pointing the token at a wrong or
///           non-controllable address. The incoming Treasury contract must
///           expose a path to call `acceptOwnership` on this token.
///         - `renounceOwnership` is disabled. Renouncing would permanently
///           remove the only address able to mint or burn, bricking supply
///           management forever.
///         - The Treasury address is validated by `Ownable`'s constructor,
///           which reverts with `OwnableInvalidOwner(0)` if zero is supplied.
///         - Zero-address mint/burn targets are rejected by OpenZeppelin's
///           `_mint` / `_burn` (`ERC20InvalidReceiver` / `ERC20InvalidSender`).
///         - No external calls are made by mint or burn, so no reentrancy
///           surface is introduced beyond standard ERC20 behavior.
/// @custom:security-contact rick@usd8.fi
contract USD8 is ERC20, Ownable2Step {
    /// @notice Thrown when `renounceOwnership` is called. Renouncing the
    ///         Treasury role is intentionally disabled to avoid permanently
    ///         bricking mint and burn.
    error RenounceOwnershipDisabled();

    /// @param treasury Initial Treasury contract address. Must be non-zero;
    ///                 reverts with `OwnableInvalidOwner(0)` otherwise. Use
    ///                 `transferOwnership` + `acceptOwnership` to migrate to
    ///                 a new Treasury later.
    constructor(address treasury) ERC20("USD8", "USD8") Ownable(treasury) {}

    /// @notice Mint `amount` USD8 to `to`. Callable only by the Treasury.
    /// @param  to     Recipient address. Must be non-zero.
    /// @param  amount Token amount, denominated in the token's 18 decimals.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burn `amount` USD8 from `from`. Callable only by the Treasury.
    /// @param  from   Account whose balance is reduced. Must be non-zero and
    ///                hold at least `amount`.
    /// @param  amount Token amount, denominated in the token's 18 decimals.
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /// @notice Disabled. Reverts with {RenounceOwnershipDisabled}.
    /// @dev    Overrides `Ownable.renounceOwnership` to prevent a one-way
    ///         transition to a state with no Treasury.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }
}
