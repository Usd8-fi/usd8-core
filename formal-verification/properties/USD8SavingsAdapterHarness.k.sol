// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {USD8SavingsAdapter} from "../../src/adapters/USD8SavingsAdapter.sol";

/// @notice Independent, configurable parent-vault model. No expected adapter
/// arithmetic is imported from VaultV2. The IVaultV2 boundary is intentionally
/// limited to asset(), allocation(bytes32), and accrueInterest().
contract USD8SavingsParent {
    address public asset;
    mapping(bytes32 id => uint256 amount) internal allocations;
    uint256 public accrueCalls;
    bool public checkpointed;
    bool public revertAccrue;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSuccess;
    uint256 public callbackResultLength;
    bytes32 public callbackResultHash;
    bytes4 public callbackResultSelector;
    bool public revertAllocationRead;
    bool public malformedAllocationRead;

    error AccrualRejected();
    error AllocationReadRejected(bytes32 id);

    constructor(address asset_) {
        asset = asset_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setAllocation(bytes32 id, uint256 amount) external {
        allocations[id] = amount;
    }

    function setAllocationReadMode(bool revertRead, bool malformedRead) external {
        revertAllocationRead = revertRead;
        malformedAllocationRead = malformedRead;
    }

    function allocation(bytes32 id) external view returns (uint256) {
        if (revertAllocationRead) revert AllocationReadRejected(id);
        if (malformedAllocationRead) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 1)
            }
        }
        return allocations[id];
    }

    function setRevertAccrue(bool value) external {
        revertAccrue = value;
    }

    function setAccrueCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function accrueInterest() external {
        if (revertAccrue) revert AccrualRejected();
        accrueCalls++;
        checkpointed = true;
        if (callbackTarget != address(0)) {
            bytes memory returndata;
            (callbackSuccess, returndata) = callbackTarget.call(callbackData);
            callbackResultLength = returndata.length;
            callbackResultHash = keccak256(returndata);
            callbackResultSelector = _selector(returndata);
        }
    }

    function callAllocate(
        USD8SavingsAdapter adapter,
        bytes memory data,
        uint256 assets,
        bytes4 selector,
        address sender
    ) external view returns (bytes32[] memory ids, int256 change) {
        return adapter.allocate(data, assets, selector, sender);
    }

    function callDeallocate(
        USD8SavingsAdapter adapter,
        bytes memory data,
        uint256 assets,
        bytes4 selector,
        address sender
    ) external view returns (bytes32[] memory ids, int256 change) {
        return adapter.deallocate(data, assets, selector, sender);
    }

    function _selector(bytes memory returndata) private pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") {
                result := mload(add(returndata, 0x20))
            }
        }
    }
}

contract USD8SavingsToken is ERC20 {
    USD8SavingsParent public observedParent;
    bool public observedCheckpoint;
    uint256 public transferFromCalls;
    bool public revertBalanceRead;
    bool public malformedBalanceRead;
    address public poisonedBalanceAccount;

    error BalanceReadRejected(address account);

    constructor() ERC20("Savings asset", "SAVE") {}

    function setObservedParent(USD8SavingsParent parent_) external {
        observedParent = parent_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBalanceReadMode(bool revertRead, bool malformedRead) external {
        revertBalanceRead = revertRead;
        malformedBalanceRead = malformedRead;
        poisonedBalanceAccount = address(0);
    }

    function setBalanceReadTarget(bool revertRead, bool malformedRead, address account) external {
        revertBalanceRead = revertRead;
        malformedBalanceRead = malformedRead;
        poisonedBalanceAccount = account;
    }

    function balanceOf(address account) public view override returns (uint256) {
        bool poisoned = poisonedBalanceAccount == address(0) || poisonedBalanceAccount == account;
        if (poisoned && revertBalanceRead) revert BalanceReadRejected(account);
        if (poisoned && malformedBalanceRead) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 1)
            }
        }
        return super.balanceOf(account);
    }

    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        transferFromCalls++;
        if (address(observedParent) != address(0)) observedCheckpoint = observedParent.checkpointed();
        return super.transferFrom(from, to, value);
    }
}

contract USD8SavingsFeeToken is USD8SavingsToken {
    address internal constant FEE_SINK = address(0xFEE);

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        uint256 fee = value == 0 ? 0 : 1;
        _transfer(from, to, value - fee);
        if (fee != 0) _transfer(from, FEE_SINK, fee);
        return true;
    }
}

contract USD8SavingsRevertingToken is USD8SavingsToken {
    error TransferFromRejected();

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransferFromRejected();
    }
}

contract USD8SavingsFalseReturnToken is USD8SavingsToken {
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Mutates balances and returns one malformed byte. SafeERC20 rejects the
/// response and the whole transaction must roll the mutation and checkpoint back.
contract USD8SavingsMalformedToken is USD8SavingsToken {
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

/// @dev Legacy token shape accepted by SafeERC20: approve and transferFrom
/// return no data.
contract USD8SavingsNoReturnToken {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract USD8SavingsFalseApprovalToken {
    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract USD8SavingsRevertingApprovalToken {
    error ApprovalRejected(address spender, uint256 amount);

    function approve(address spender, uint256 amount) external pure returns (bool) {
        revert ApprovalRejected(spender, amount);
    }
}

contract USD8SavingsMalformedApprovalToken {
    function approve(address, uint256) external pure returns (bool) {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

/// @dev Exercises forceApprove's false -> approve(0) -> approve(max) fallback.
contract USD8SavingsForceApproveFallbackToken {
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    uint256 public approveCalls;
    uint256 public zeroCalls;
    uint256 public maxCalls;
    bool public failZero;
    bool public failFinal;

    constructor(bool failZero_, bool failFinal_) {
        failZero = failZero_;
        failFinal = failFinal_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        approveCalls++;
        if (amount == 0) {
            zeroCalls++;
            if (failZero) return false;
            allowance[msg.sender][spender] = 0;
            return true;
        }
        maxCalls++;
        if (maxCalls == 1 || failFinal) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract USD8SavingsRevertingParent {
    error AssetReadRejected();

    function asset() external pure returns (address) {
        revert AssetReadRejected();
    }
}

contract USD8SavingsMalformedParent {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

contract USD8SavingsAdapterFactory {
    function deploy(address parent) external returns (USD8SavingsAdapter) {
        return new USD8SavingsAdapter(parent);
    }
}

contract USD8SavingsCallbackToken is USD8SavingsToken {
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackEnabled;
    bool public callbackSuccess;
    uint256 public callbackResultLength;
    bytes32 public callbackResultHash;
    bytes4 public callbackResultSelector;

    function configureCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackEnabled = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        transferFromCalls++;
        if (address(observedParent) != address(0)) observedCheckpoint = observedParent.checkpointed();
        if (callbackEnabled) {
            callbackEnabled = false;
            bytes memory returndata;
            (callbackSuccess, returndata) = callbackTarget.call(callbackData);
            callbackResultLength = returndata.length;
            callbackResultHash = keccak256(returndata);
            callbackResultSelector = _selector(returndata);
        }
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    function _selector(bytes memory returndata) private pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") {
                result := mload(add(returndata, 0x20))
            }
        }
    }
}

abstract contract USD8SavingsAdapterKontrolBase is Test {
    address internal constant OUTSIDER = address(0xBAD);
    address internal constant DISTRIBUTOR = address(0xD157);

    USD8SavingsToken internal token;
    USD8SavingsParent internal parent;
    USD8SavingsAdapter internal adapter;

    function setUp() public virtual {
        token = new USD8SavingsToken();
        parent = new USD8SavingsParent(address(token));
        adapter = new USD8SavingsAdapter(address(parent));
        token.setObservedParent(parent);
    }

    function _deployWith(address tokenAddress)
        internal
        returns (USD8SavingsParent configuredParent, USD8SavingsAdapter configuredAdapter)
    {
        configuredParent = new USD8SavingsParent(tokenAddress);
        configuredAdapter = new USD8SavingsAdapter(address(configuredParent));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _word(bytes memory returndata, uint256 index) internal pure returns (uint256 result) {
        if (returndata.length >= 4 + 32 * (index + 1)) {
            assembly ("memory-safe") {
                result := mload(add(add(returndata, 0x24), mul(index, 0x20)))
            }
        }
    }

    function _assertExactRevert(bytes memory actual, bytes memory expected) internal pure {
        assert(actual.length == expected.length);
        assert(keccak256(actual) == keccak256(expected));
    }
}
