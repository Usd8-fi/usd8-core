// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Admin-mintable token used only to exercise USD8's public Sepolia staging deployment.
contract SepoliaTestToken is ERC20 {
    address public immutable admin;
    uint8 private immutable _tokenDecimals;

    error Unauthorized();
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address admin_, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        _tokenDecimals = decimals_;
        if (initialSupply != 0) _mint(admin_, initialSupply);
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != admin) revert Unauthorized();
        _mint(to, amount);
    }
}

/// @notice Idle ERC-4626 staging vault. It holds its configured asset directly.
contract SepoliaTestVault is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}
}

/// @notice Mutable Chainlink-compatible staging feed controlled by the testnet admin.
contract SepoliaTestOracle {
    address public immutable admin;
    uint8 public immutable decimals;
    string public description;
    uint256 public constant version = 1;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _updatedAt;

    error Unauthorized();
    error ZeroAddress();
    error InvalidAnswer();
    error UnknownRound(uint80 roundId);

    constructor(address admin_, string memory description_, uint8 decimals_, int256 answer_) {
        if (admin_ == address(0)) revert ZeroAddress();
        if (answer_ <= 0) revert InvalidAnswer();
        admin = admin_;
        description = description_;
        decimals = decimals_;
        _roundId = 1;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function updateAnswer(int256 newAnswer) external {
        if (msg.sender != admin) revert Unauthorized();
        if (newAnswer <= 0) revert InvalidAnswer();
        unchecked {
            ++_roundId;
        }
        _answer = newAnswer;
        _updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (roundId != _roundId) revert UnknownRound(roundId);
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}

/// @notice One-transaction deployment of noncanonical dependencies for USD8's Sepolia staging system.
/// @dev These mocks validate public deployment, frontend, indexing, claims and governance workflows.
///      They do not substitute for mainnet-fork integration tests against Aave, Sky, Lido or Chainlink.
contract SepoliaDependencies {
    address public immutable admin;
    address public immutable usdc;

    address public immutable coverAsset;
    address public immutable coverAssetUsdOracle;
    address public immutable aaveUsdcVault;
    address public immutable morphoUsdcVault;
    address public immutable gho;
    address public immutable aaveSgho;
    address public immutable ghoUsdOracle;
    address public immutable usds;
    address public immutable skySusds;
    address public immutable usdsUsdOracle;
    address public immutable usdcUsdOracle;

    error ZeroAddress();

    constructor(address admin_, address usdc_) {
        if (admin_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        admin = admin_;
        usdc = usdc_;

        coverAsset = address(new SepoliaTestToken("Sepolia Mock wstETH", "mwstETH", 18, admin_, 1_000e18));
        coverAssetUsdOracle = address(new SepoliaTestOracle(admin_, "mwstETH / USD", 8, 4_000e8));

        aaveUsdcVault = address(new SepoliaTestVault(IERC20(usdc_), "Sepolia Mock Aave USDC", "maUSDC"));
        morphoUsdcVault = address(new SepoliaTestVault(IERC20(usdc_), "Sepolia Mock Morpho USDC", "mmUSDC"));

        gho = address(new SepoliaTestToken("Sepolia Mock GHO", "mGHO", 18, admin_, 1_000_000e18));
        aaveSgho = address(new SepoliaTestVault(IERC20(gho), "Sepolia Mock Savings GHO", "msGHO"));
        ghoUsdOracle = address(new SepoliaTestOracle(admin_, "mGHO / USD", 8, 1e8));

        usds = address(new SepoliaTestToken("Sepolia Mock USDS", "mUSDS", 18, admin_, 1_000_000e18));
        skySusds = address(new SepoliaTestVault(IERC20(usds), "Sepolia Mock Savings USDS", "msUSDS"));
        usdsUsdOracle = address(new SepoliaTestOracle(admin_, "mUSDS / USD", 8, 1e8));
        usdcUsdOracle = address(new SepoliaTestOracle(admin_, "USDC / USD", 8, 1e8));
    }
}
