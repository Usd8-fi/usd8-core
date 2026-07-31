// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultV2} from "vault-v2/src/interfaces/IVaultV2.sol";
import {USD8} from "../../src/USD8.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";
import {USD8SavingsBootstrap} from "../../src/deployment/USD8SavingsBootstrap.sol";
import {ErrorsLib} from "vault-v2/src/libraries/ErrorsLib.sol";

error BootstrapModelFailure(uint8 point);

interface IBootstrapCallback {
    function onBootstrapCallback() external;
}

/// @dev Stateful ERC20 model. Return modes: 0=true, 1=false, 2=empty,
///      3=one-byte malformed, 4=revert. Modes are selected by occurrence.
contract USD8SavingsBootstrapTokenModel {
    string public name;
    string public symbol;
    uint8 public immutable tokenDecimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    // Six occurrences cover two USD8 forceApprove sites when both take the
    // first-attempt / zero-reset / retry path in one bootstrap transaction.
    uint8[6] public approveMode;
    uint8[6] public transferFromMode;
    uint8 public approveCalls;
    uint8 public transferFromCalls;
    address public callback;
    uint8 public callbackApproveAt = type(uint8).max;
    uint8 public callbackTransferFromAt = type(uint8).max;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        tokenDecimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return tokenDecimals;
    }

    function setFailure(uint8 approveAt, uint8 transferAt) external {
        if (approveAt < 6) approveMode[approveAt] = 4;
        if (transferAt < 6) transferFromMode[transferAt] = 4;
    }

    function setApproveMode(uint8 index, uint8 mode) external {
        approveMode[index] = mode;
    }

    function setTransferFromMode(uint8 index, uint8 mode) external {
        transferFromMode[index] = mode;
    }

    function configureCallback(address callback_, uint8 approveAt, uint8 transferAt) external {
        callback = callback_;
        callbackApproveAt = approveAt;
        callbackTransferFromAt = transferAt;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        uint8 index = approveCalls++;
        if (callback != address(0) && callbackApproveAt == index) IBootstrapCallback(callback).onBootstrapCallback();
        uint8 mode = approveMode[index];
        if (mode == 4) revert BootstrapModelFailure(40 + index);
        if (mode == 1) return false;
        allowance[msg.sender][spender] = value;
        if (mode == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint8 index = transferFromCalls++;
        if (callback != address(0) && callbackTransferFromAt == index) {
            IBootstrapCallback(callback).onBootstrapCallback();
        }
        uint8 mode = transferFromMode[index];
        if (mode == 4) revert BootstrapModelFailure(50 + index);
        if (mode == 1) return false;
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "ALLOWANCE");
        require(balanceOf[from] >= value, "BALANCE");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        if (mode == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return true;
    }
}

contract USD8SavingsBootstrapTreasuryModel {
    using SafeERC20 for IERC20;

    USD8SavingsBootstrapTokenModel public immutable reserve;
    USD8SavingsBootstrapTokenModel public immutable usd8Token;
    uint256 internal immutable scale;
    uint8 public failPoint;
    address public callback;
    uint8 public callbackPoint;

    constructor(USD8SavingsBootstrapTokenModel reserve_, USD8SavingsBootstrapTokenModel usd8Token_, uint256 scale_) {
        reserve = reserve_;
        usd8Token = usd8Token_;
        scale = scale_;
    }

    function setFailure(uint8 point) external {
        failPoint = point;
    }

    function configureCallback(address callback_, uint8 point) external {
        callback = callback_;
        callbackPoint = point;
    }

    function _callback(uint8 point) internal {
        if (callback != address(0) && callbackPoint == point) IBootstrapCallback(callback).onBootstrapCallback();
    }

    function USDC() external returns (IERC20) {
        _callback(1);
        if (failPoint == 1) revert BootstrapModelFailure(61);
        return IERC20(address(reserve));
    }

    function USDC_TO_USD8_SCALE() external returns (uint256) {
        _callback(3);
        if (failPoint == 3) revert BootstrapModelFailure(63);
        return scale;
    }

    function mintUSD8(uint256 amount) external returns (uint256 minted) {
        _callback(2);
        if (failPoint == 2) revert BootstrapModelFailure(62);
        if (amount == 0) revert Treasury.ZeroAmount();
        IERC20(address(reserve)).safeTransferFrom(msg.sender, address(this), amount);
        minted = amount * scale;
        usd8Token.mint(msg.sender, minted);
    }
}

contract USD8SavingsBootstrapVaultModel {
    using SafeERC20 for IERC20;

    USD8SavingsBootstrapTokenModel public immutable token;
    address public owner;
    address public curator;
    string public name;
    string public symbol;
    uint256 public maxRate;
    address public liquidityAdapter;
    bytes public liquidityData;
    uint8 public failDirect;
    uint8 public failSubmitAt = type(uint8).max;
    uint8 public failExecuteAt = type(uint8).max;
    uint8 public submitCalls;
    uint8 public executeCalls;
    uint8 public curatorCalls;
    address public callback;
    uint8 public callbackPoint;

    mapping(address => bool) public isAllocator;
    mapping(address => bool) public isAdapter;
    mapping(bytes32 => uint256) public absoluteCap;
    mapping(bytes32 => uint256) public relativeCap;
    mapping(bytes32 => uint256) public allocation;
    mapping(address => uint256) public balanceOf;
    bytes32[6] public submittedHash;
    bytes32[6] public executedHash;
    bytes32[20] public callTrace;
    uint8 public traceCalls;

    uint256 internal constant MAX_MAX_RATE = 63_419_583_967;

    constructor(USD8SavingsBootstrapTokenModel token_, address owner_) {
        token = token_;
        owner = owner_;
    }

    function configureFailures(uint8 directPoint, uint8 submitAt, uint8 executeAt) external {
        failDirect = directPoint;
        failSubmitAt = submitAt;
        failExecuteAt = executeAt;
    }

    /// callbackPoint: direct=1..9, submit=20+i, execute=30+i.
    function configureCallback(address callback_, uint8 point) external {
        callback = callback_;
        callbackPoint = point;
    }

    function _callback(uint8 point) internal {
        if (callback != address(0) && callbackPoint == point) IBootstrapCallback(callback).onBootstrapCallback();
    }

    function _direct(uint8 point) internal {
        _callback(point);
        if (failDirect == point) revert BootstrapModelFailure(point);
    }

    function _trace(bytes memory data) internal {
        callTrace[traceCalls] = keccak256(data);
        ++traceCalls;
    }

    function asset() external returns (address) {
        _direct(1);
        return address(token);
    }

    function setName(string memory value) external {
        _direct(2);
        _trace(msg.data);
        name = value;
    }

    function setSymbol(string memory value) external {
        _direct(3);
        _trace(msg.data);
        symbol = value;
    }

    function setCurator(address value) external {
        uint8 point = curatorCalls == 0 ? 4 : 8;
        _direct(point);
        _trace(msg.data);
        ++curatorCalls;
        curator = value;
    }

    function submit(bytes memory data) external {
        uint8 index = submitCalls;
        _callback(20 + index);
        if (index == failSubmitAt) revert BootstrapModelFailure(20 + index);
        _trace(msg.data);
        submittedHash[index] = keccak256(data);
        submitCalls = index + 1;
    }

    function _executing(bytes memory data) internal {
        uint8 index = executeCalls;
        _callback(30 + index);
        if (index == failExecuteAt) revert BootstrapModelFailure(30 + index);
        _trace(data);
        executedHash[index] = keccak256(data);
        executeCalls = index + 1;
    }

    function setIsAllocator(address account, bool enabled) external {
        _executing(msg.data);
        isAllocator[account] = enabled;
    }

    function addAdapter(address account) external {
        _executing(msg.data);
        isAdapter[account] = true;
    }

    function increaseAbsoluteCap(bytes memory idData, uint256 cap) external {
        _executing(msg.data);
        absoluteCap[keccak256(idData)] = cap;
    }

    function increaseRelativeCap(bytes memory idData, uint256 cap) external {
        _executing(msg.data);
        relativeCap[keccak256(idData)] = cap;
    }

    function setMaxRate(uint256 value) external {
        _direct(5);
        if (value > MAX_MAX_RATE) revert ErrorsLib.MaxRateTooHigh();
        _trace(msg.data);
        maxRate = value;
    }

    function setLiquidityAdapterAndData(address adapter, bytes memory data) external {
        _direct(6);
        _trace(msg.data);
        liquidityAdapter = adapter;
        liquidityData = data;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _direct(7);
        _trace(msg.data);
        IERC20(address(token)).safeTransferFrom(msg.sender, liquidityAdapter, assets);
        bytes32 id = keccak256(abi.encode("this", liquidityAdapter));
        allocation[id] += assets;
        balanceOf[receiver] += assets;
        return assets;
    }

    function setOwner(address value) external {
        _direct(9);
        _trace(msg.data);
        owner = value;
    }
}

contract USD8SavingsBootstrapFactoryModel {
    USD8SavingsBootstrapVaultModel public vault;
    USD8SavingsBootstrapTokenModel public immutable token;
    uint8 public failPoint;
    bool public attest = true;
    uint256 public createCalls;
    address public lastOwner;
    address public lastAsset;
    bytes32 public lastSalt;
    address public createCallback;
    address public isVaultCallback;
    uint8 public vaultDirect;
    uint8 public vaultSubmitAt = type(uint8).max;
    uint8 public vaultExecuteAt = type(uint8).max;
    address public vaultCallback;
    uint8 public vaultCallbackPoint;

    constructor(USD8SavingsBootstrapTokenModel token_) {
        token = token_;
    }

    function configure(uint8 failPoint_, bool attest_, address callback_) external {
        failPoint = failPoint_;
        attest = attest_;
        createCallback = callback_;
    }

    function configureIsVaultCallback(address callback_) external {
        isVaultCallback = callback_;
    }

    function configureVault(uint8 directPoint, uint8 submitAt, uint8 executeAt) external {
        vaultDirect = directPoint;
        vaultSubmitAt = submitAt;
        vaultExecuteAt = executeAt;
    }

    function configureVaultCallback(address callback_, uint8 point) external {
        vaultCallback = callback_;
        vaultCallbackPoint = point;
    }

    function createVaultV2(address owner_, address asset_, bytes32 salt_) external returns (address) {
        if (failPoint == 1) revert BootstrapModelFailure(71);
        ++createCalls;
        lastOwner = owner_;
        lastAsset = asset_;
        lastSalt = salt_;
        vault = new USD8SavingsBootstrapVaultModel(token, owner_);
        vault.configureFailures(vaultDirect, vaultSubmitAt, vaultExecuteAt);
        vault.configureCallback(vaultCallback, vaultCallbackPoint);
        if (createCallback != address(0)) IBootstrapCallback(createCallback).onBootstrapCallback();
        return address(vault);
    }

    function isVaultV2(address account) external returns (bool) {
        if (isVaultCallback != address(0)) IBootstrapCallback(isVaultCallback).onBootstrapCallback();
        if (failPoint == 2) revert BootstrapModelFailure(72);
        return attest && account == address(vault);
    }
}

contract USD8SavingsBootstrapOwnerModel is IBootstrapCallback {
    USD8SavingsBootstrap public immutable bootstrap;
    bytes internal runData;
    bool public callbackSuccess;
    bytes public callbackReturndata;
    uint256 public callbackCalls;

    constructor() {
        bootstrap = new USD8SavingsBootstrap();
    }

    function setRunData(USD8SavingsBootstrap.Config memory config) external {
        runData = abi.encodeCall(USD8SavingsBootstrap.run, (config));
    }

    function run(USD8SavingsBootstrap.Config memory config) external returns (USD8SavingsBootstrap.Deployment memory) {
        return bootstrap.run(config);
    }

    function onBootstrapCallback() external {
        ++callbackCalls;
        (callbackSuccess, callbackReturndata) = address(bootstrap).call(runData);
    }
}

abstract contract USD8SavingsBootstrapKontrolBase is Test {
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant SEED_USDC = 100e6;
    uint256 internal constant MAX_RATE = 777;
    uint256 internal constant VAULT_MAX_MAX_RATE = 63_419_583_967;
    address internal constant GOVERNANCE = address(0xBEEF);
    address internal constant SEED_SINK = address(0xDEAD);
    address internal constant OUTSIDER = address(0xBAD);
    bytes32 internal constant SALT = keccak256("sUSD8-kontrol");

    USD8SavingsBootstrapTokenModel internal usdc;
    USD8SavingsBootstrapTokenModel internal usd8;
    USD8SavingsBootstrapTreasuryModel internal treasury;
    USD8SavingsBootstrapFactoryModel internal factory;
    USD8SavingsBootstrap internal bootstrap;

    function setUp() public virtual {
        usdc = new USD8SavingsBootstrapTokenModel("USD Coin", "USDC", 6);
        usd8 = new USD8SavingsBootstrapTokenModel("USD8", "USD8", 18);
        treasury = new USD8SavingsBootstrapTreasuryModel(usdc, usd8, SCALE);
        factory = new USD8SavingsBootstrapFactoryModel(usd8);
        bootstrap = new USD8SavingsBootstrap();
        usdc.mint(address(bootstrap), SEED_USDC);
    }

    function _config() internal view returns (USD8SavingsBootstrap.Config memory) {
        return USD8SavingsBootstrap.Config({
            vaultFactory: address(factory),
            usd8: USD8(address(usd8)),
            treasury: Treasury(address(treasury)),
            seedUsdc: SEED_USDC,
            seedSink: SEED_SINK,
            governance: GOVERNANCE,
            maxRate: MAX_RATE,
            salt: SALT
        });
    }

    function _runLowLevel(USD8SavingsBootstrap.Config memory config)
        internal
        returns (bool success, bytes memory returndata)
    {
        return address(bootstrap).call(abi.encodeCall(USD8SavingsBootstrap.run, (config)));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") { result := mload(add(returndata, 0x20)) }
        }
    }

    function _assertExact4(bytes memory returndata, bytes4 expected) internal pure {
        assertEq(returndata.length, 4);
        assertEq(_selector(returndata), expected);
    }

    function _assertPristine() internal view {
        address predictedVault = _createAddress(address(factory), 1);
        address predictedAdapter = _createAddress(address(bootstrap), 1);
        assertFalse(bootstrap.executed());
        assertEq(factory.createCalls(), 0);
        assertEq(address(factory.vault()), address(0));
        assertEq(usdc.balanceOf(address(bootstrap)), SEED_USDC);
        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(usd8.balanceOf(address(bootstrap)), 0);
        assertEq(usdc.allowance(address(bootstrap), address(treasury)), 0);
        assertEq(usd8.allowance(address(bootstrap), predictedVault), 0);
        assertEq(usd8.allowance(predictedAdapter, predictedVault), 0);
        assertEq(usd8.allowance(address(bootstrap), predictedAdapter), 0);
        assertEq(usdc.approveCalls(), 0);
        assertEq(usdc.transferFromCalls(), 0);
        assertEq(usd8.approveCalls(), 0);
        assertEq(usd8.transferFromCalls(), 0);
        assertEq(usd8.totalSupply(), 0);
        assertEq(predictedVault.code.length, 0);
        assertEq(predictedAdapter.code.length, 0);
    }

    function _createAddress(address deployer, uint256 nonce) internal pure returns (address) {
        assertEq(nonce, 1);
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", deployer, hex"01")))));
    }

    function _expectedConfigData(uint8 index, address adapter) internal view returns (bytes memory) {
        if (index == 0) return abi.encodeCall(IVaultV2.setIsAllocator, (address(bootstrap), true));
        if (index == 1) return abi.encodeCall(IVaultV2.addAdapter, (adapter));
        bytes memory idData = abi.encode("this", adapter);
        if (index == 2) return abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max));
        if (index == 3) return abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18));
        if (index == 4) return abi.encodeCall(IVaultV2.setIsAllocator, (GOVERNANCE, true));
        return abi.encodeCall(IVaultV2.setIsAllocator, (address(bootstrap), false));
    }

    function _expectedVaultCall(uint8 index, address adapter) internal view returns (bytes memory) {
        if (index == 0) return abi.encodeCall(IVaultV2.setName, ("Savings USD8"));
        if (index == 1) return abi.encodeCall(IVaultV2.setSymbol, ("sUSD8"));
        if (index == 2) return abi.encodeCall(IVaultV2.setCurator, (address(bootstrap)));
        if (index >= 3 && index <= 10) {
            uint8 configIndex = (index - 3) / 2;
            bytes memory data = _expectedConfigData(configIndex, adapter);
            return index % 2 == 1 ? abi.encodeCall(IVaultV2.submit, (data)) : data;
        }
        if (index == 11) return abi.encodeCall(IVaultV2.setMaxRate, (MAX_RATE));
        if (index == 12) return abi.encodeCall(IVaultV2.setLiquidityAdapterAndData, (adapter, ""));
        if (index == 13) return abi.encodeWithSignature("deposit(uint256,address)", SEED_USDC * SCALE, SEED_SINK);
        if (index >= 14 && index <= 17) {
            uint8 configIndex = 4 + (index - 14) / 2;
            bytes memory data = _expectedConfigData(configIndex, adapter);
            return index % 2 == 0 ? abi.encodeCall(IVaultV2.submit, (data)) : data;
        }
        if (index == 18) return abi.encodeCall(IVaultV2.setCurator, (GOVERNANCE));
        return abi.encodeCall(IVaultV2.setOwner, (GOVERNANCE));
    }
}
