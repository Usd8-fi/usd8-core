// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {ERC4626Strategy} from "../../src/strategies/ERC4626Strategy.sol";

/// @notice Fixed-bytecode ERC-20 model. Modes are state, rather than symbolic
/// runtime bytecode, so the solver sees one concrete implementation.
contract ERC4626StrategyModeToken is ERC20 {
    enum ReturnMode {
        Normal,
        NoReturn,
        False,
        Malformed,
        Revert
    }

    ReturnMode public approveMode0;
    ReturnMode public approveMode1;
    ReturnMode public approveMode2;
    ReturnMode public transferMode;
    ReturnMode public transferFromMode;
    ReturnMode public balanceMode;
    bool public zeroFirst;
    uint256 public approveCalls;
    uint256 public balanceOffset;
    bool public subtractBalanceOffset;

    constructor() ERC20("Mode USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setApprovalScript(ReturnMode first, ReturnMode second, ReturnMode third, bool zeroFirst_) external {
        approveMode0 = first;
        approveMode1 = second;
        approveMode2 = third;
        zeroFirst = zeroFirst_;
        approveCalls = 0;
    }

    function setTransferModes(ReturnMode transfer_, ReturnMode transferFrom_) external {
        transferMode = transfer_;
        transferFromMode = transferFrom_;
    }

    function setBalanceMode(ReturnMode mode, uint256 offset, bool subtract_) external {
        balanceMode = mode;
        balanceOffset = offset;
        subtractBalanceOffset = subtract_;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        ReturnMode mode = approveCalls == 0 ? approveMode0 : approveCalls == 1 ? approveMode1 : approveMode2;
        ++approveCalls;
        if (zeroFirst && amount != 0 && allowance(msg.sender, spender) != 0) return false;
        if (mode == ReturnMode.Revert) revert("APPROVE_REVERT");
        if (mode == ReturnMode.False) return false;
        _approve(msg.sender, spender, amount);
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

    function balanceOf(address account) public view override returns (uint256 result) {
        ReturnMode mode = balanceMode;
        if (mode == ReturnMode.Revert) revert("BALANCE_REVERT");
        if (mode == ReturnMode.Malformed) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        result = super.balanceOf(account);
        if (subtractBalanceOffset) return result - balanceOffset;
        return result + balanceOffset;
    }
}

contract ERC4626StrategyModeTreasury {
    enum ResponseMode {
        Normal,
        Zero,
        Revert,
        Empty,
        Short,
        Malformed
    }

    IERC20 public reserve;
    ResponseMode public mode;

    constructor(IERC20 reserve_) {
        reserve = reserve_;
    }

    function setMode(ResponseMode mode_) external {
        mode = mode_;
    }

    function USDC() external view returns (IERC20 token) {
        ResponseMode current = mode;
        if (current == ResponseMode.Revert) revert("TREASURY_USDC_REVERT");
        if (current == ResponseMode.Empty) {
            assembly { return(0, 0) }
        }
        if (current == ResponseMode.Short) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (current == ResponseMode.Malformed) {
            assembly {
                mstore(0, not(0))
                return(0, 32)
            }
        }
        return current == ResponseMode.Zero ? IERC20(address(0)) : reserve;
    }

    function deployInto(ERC4626Strategy strategy, uint256 amount) external {
        strategy.deploy(amount);
    }

    function withdrawFrom(ERC4626Strategy strategy, uint256 amount) external {
        strategy.withdraw(amount);
    }
}

/// @notice Minimal fixed-bytecode constructor dependency. Its fallback can
/// return every ABI shape reached by IERC4626.asset().
contract ERC4626StrategyAssetResponseVault {
    enum Mode {
        Normal,
        Revert,
        Empty,
        Short,
        Malformed
    }

    address public immutable configuredAsset;
    Mode public mode;

    constructor(address asset_) {
        configuredAsset = asset_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    fallback() external {
        Mode current = mode;
        if (current == Mode.Revert) revert("VAULT_ASSET_REVERT");
        if (current == Mode.Empty) {
            assembly { return(0, 0) }
        }
        if (current == Mode.Short) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (current == Mode.Malformed) {
            assembly {
                mstore(0, not(0))
                return(0, 32)
            }
        }
        address value = configuredAsset;
        assembly {
            mstore(0, value)
            return(0, 32)
        }
    }
}

contract ERC4626StrategyModeVault is ERC20, ERC4626 {
    enum DepositMode {
        Standard,
        ReturnZero,
        PositiveNoShares,
        BurnOneShare,
        Revert,
        Empty,
        Malformed
    }

    enum RedeemMode {
        Standard,
        Short,
        Over,
        TreasuryDecrease,
        Revert,
        Empty,
        Malformed,
        PoisonPostBalance,
        PoisonPostBalanceMalformed,
        ReportPostBalanceShort,
        ReportPostBalanceOver
    }

    ERC4626StrategyModeToken public immutable modeAsset;
    DepositMode public depositMode;
    RedeemMode public redeemMode;
    uint256 public delta;
    uint256 public fixedOneShareValue;
    bool public useFixedOneShareValue;
    bool public convertReverts;
    bool public convertMalformed;
    bool public shareBalanceReverts;
    bool public shareBalanceMalformed;
    bool public previewReverts;
    bool public previewMalformed;

    constructor(ERC4626StrategyModeToken asset_) ERC20("Mode Vault", "mVLT") ERC4626(asset_) {
        modeAsset = asset_;
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function setDepositMode(DepositMode mode_, uint256 delta_) external {
        depositMode = mode_;
        delta = delta_;
    }

    function setRedeemMode(RedeemMode mode_, uint256 delta_) external {
        redeemMode = mode_;
        delta = delta_;
    }

    function setViewModes(
        bool convertReverts_,
        bool convertMalformed_,
        bool shareBalanceReverts_,
        bool shareBalanceMalformed_,
        bool previewReverts_,
        bool previewMalformed_
    ) external {
        convertReverts = convertReverts_;
        convertMalformed = convertMalformed_;
        shareBalanceReverts = shareBalanceReverts_;
        shareBalanceMalformed = shareBalanceMalformed_;
        previewReverts = previewReverts_;
        previewMalformed = previewMalformed_;
    }

    function setOneShareValue(uint256 value, bool enabled) external {
        fixedOneShareValue = value;
        useFixedOneShareValue = enabled;
    }

    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnShares(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        if (shareBalanceReverts) revert("SHARE_BALANCE_REVERT");
        if (shareBalanceMalformed) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return super.balanceOf(account);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        if (convertReverts) revert("CONVERT_REVERT");
        if (convertMalformed) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (useFixedOneShareValue && shares == 1) return fixedOneShareValue;
        return super.convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        if (previewReverts) revert("PREVIEW_REVERT");
        if (previewMalformed) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return super.previewWithdraw(assets);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        DepositMode current = depositMode;
        if (current == DepositMode.Revert) revert("DEPOSIT_REVERT");
        if (current == DepositMode.Empty) {
            assembly { return(0, 0) }
        }
        if (current == DepositMode.Malformed) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (current == DepositMode.ReturnZero) {
            modeAsset.transferFrom(msg.sender, address(this), assets);
            return 0;
        }
        if (current == DepositMode.PositiveNoShares) {
            modeAsset.transferFrom(msg.sender, address(this), assets);
            return 1;
        }
        if (current == DepositMode.BurnOneShare) {
            modeAsset.transferFrom(msg.sender, address(this), assets);
            _burn(receiver, 1);
            return 1;
        }
        return super.deposit(assets, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        RedeemMode current = redeemMode;
        if (current == RedeemMode.Revert) revert("REDEEM_REVERT");
        if (current == RedeemMode.Empty) {
            assembly { return(0, 0) }
        }
        if (current == RedeemMode.Malformed) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (current == RedeemMode.Standard) return super.redeem(shares, receiver, owner);

        assets = previewRedeem(shares);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        uint256 delivered = assets;
        if (current == RedeemMode.Short) delivered = assets - delta;
        if (current == RedeemMode.Over) delivered = assets + delta;
        if (current == RedeemMode.TreasuryDecrease) {
            modeAsset.burn(receiver, delta);
        }
        modeAsset.transfer(receiver, delivered);
        emit Withdraw(msg.sender, receiver, owner, delivered, shares);
        if (current == RedeemMode.PoisonPostBalance) {
            modeAsset.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Revert, 0, false);
        }
        if (current == RedeemMode.PoisonPostBalanceMalformed) {
            modeAsset.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Malformed, 0, false);
        }
        if (current == RedeemMode.ReportPostBalanceShort) {
            modeAsset.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Normal, delta, true);
        }
        if (current == RedeemMode.ReportPostBalanceOver) {
            modeAsset.setBalanceMode(ERC4626StrategyModeToken.ReturnMode.Normal, delta, false);
        }
    }
}

contract ERC4626StrategyModeRouter {
    function outputOnly(ERC4626StrategyModeToken output, address recipient, uint256 amountOut) external {
        output.mint(recipient, amountOut);
    }

    function outputAndIncreaseShares(
        ERC4626StrategyModeToken output,
        address recipient,
        uint256 amountOut,
        ERC4626StrategyModeVault vault,
        uint256 shareIncrease
    ) external {
        output.mint(recipient, amountOut);
        vault.mintShares(recipient, shareIncrease);
    }

    function destroyVaultAssetsAndOutput(
        ERC4626StrategyModeToken asset,
        address vault,
        uint256 loss,
        address recipient,
        uint256 amountOut
    ) external {
        asset.burn(vault, loss);
        asset.mint(recipient, amountOut);
    }

    function consume(
        ERC4626StrategyModeToken input,
        address owner,
        uint256 amountIn,
        ERC4626StrategyModeToken output,
        address recipient,
        uint256 amountOut
    ) external {
        input.transferFrom(owner, address(this), amountIn);
        output.mint(recipient, amountOut);
    }

    function depleteOutput(ERC4626StrategyModeToken output, address owner, uint256 amount) external {
        output.burn(owner, amount);
    }

    function increaseShares(ERC4626StrategyModeVault vault, address owner, uint256 amount) external {
        vault.mintShares(owner, amount);
    }

    function decreaseShares(ERC4626StrategyModeVault vault, address owner, uint256 amount) external {
        vault.burnShares(owner, amount);
    }

    function treasuryDeployAndOutput(
        ERC4626StrategyModeTreasury treasury,
        ERC4626Strategy strategy,
        uint256 amount,
        ERC4626StrategyModeToken output,
        uint256 amountOut
    ) external {
        treasury.deployInto(strategy, amount);
        output.mint(address(strategy), amountOut);
    }

    function treasuryWithdrawAndOutput(
        ERC4626StrategyModeTreasury treasury,
        ERC4626Strategy strategy,
        uint256 amount,
        ERC4626StrategyModeToken output,
        uint256 amountOut
    ) external {
        treasury.withdrawFrom(strategy, amount);
        output.mint(address(strategy), amountOut);
    }

    function sweepEthAndOutput(
        ERC4626Strategy strategy,
        address payable recipient,
        ERC4626StrategyModeToken output,
        uint256 amountOut
    ) external {
        strategy.sweepETH(recipient);
        output.mint(address(strategy), amountOut);
    }

    function sweepTokenCatchAndOutput(
        ERC4626Strategy strategy,
        IERC20 token,
        address recipient,
        ERC4626StrategyModeToken output,
        uint256 amountOut
    ) external {
        (bool success, bytes memory data) =
            address(strategy).call(abi.encodeCall(strategy.sweepToken, (token, recipient)));
        require(
            !success && data.length == abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(token)).length
                && keccak256(data)
                    == keccak256(abi.encodeWithSelector(SharedBase.NothingToSweep.selector, address(token))),
            "BAD_SWEEP_BYTES"
        );
        output.mint(address(strategy), amountOut);
    }

    function reenterBubble(ERC4626Strategy strategy, IERC20 tokenIn, IERC20 tokenOut) external {
        strategy.swap(tokenIn, tokenOut, 1, address(this), address(this), bytes(""), 1);
    }

    function reenterCatchAndRevert(ERC4626Strategy strategy, IERC20 tokenIn, IERC20 tokenOut) external {
        (bool success, bytes memory data) = address(strategy)
            .call(abi.encodeCall(strategy.swap, (tokenIn, tokenOut, 1, address(this), address(this), bytes(""), 1)));
        require(
            !success
                && data.length
                    == abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector).length
                && keccak256(data)
                    == keccak256(
                        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
                    ),
            "BAD_REENTRANCY_BYTES"
        );
        revert("OUTER_REVERT");
    }
}
