// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {USD8} from "../../src/USD8.sol";

/// @dev Named benign candidate. It appends behavior only and deliberately does
///      not alter inherited storage or initialization state.
contract USD8UpgradeV2 is USD8 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Named deployed candidate with code but no ERC-1822 compatibility hook.
contract USD8UpgradeNonUUPS {
    function version() external pure returns (uint256) {
        return 999;
    }
}

/// @dev Named adversarial candidate reporting a non-ERC1967 implementation slot.
contract USD8UpgradeWrongUUID {
    bytes32 internal constant WRONG_UUID = keccak256("usd8.kontrol.wrong.uuid");

    function proxiableUUID() external pure returns (bytes32) {
        return WRONG_UUID;
    }
}

/// @dev Named UUPS-compatible candidate whose initializer writes and then reverts.
contract USD8UpgradeFailingInitializer is USD8 {
    error InitializationFailed();

    uint256 public candidateValue;

    function initializeV2ThenRevert(uint256 value) external reinitializer(2) {
        candidateValue = value;
        revert InitializationFailed();
    }
}

/// @dev Named UUPS-compatible candidate with successful nonpayable and payable
///      reinitializers, used on separate fresh proxy deployments.
contract USD8UpgradeSuccessfulInitializer is USD8 {
    uint256 public candidateValue;
    uint256 public initializerValue;
    address public initializerCaller;

    function initializeV2(uint256 value) external reinitializer(2) {
        candidateValue = value;
        initializerCaller = msg.sender;
    }

    function initializeV2Payable(uint256 value) external payable reinitializer(2) {
        candidateValue = value;
        initializerValue = msg.value;
        initializerCaller = msg.sender;
    }
}

contract USD8UpgradeHeldToken is ERC20 {
    constructor() ERC20("Held Token", "HELD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Foundry/Kontrol properties for USD8's beta-only UUPS upgrade boundary.
/// @dev The production Registry and USD8 implementations run behind real ERC1967
///      proxies. The preservation claim is intentionally candidate-specific: the
///      named benign USD8UpgradeV2 is checked against representative complete USD8
///      state (registry pointer, ERC20/EIP-712 metadata, supply, balances,
///      allowances, and foreign-token/ETH holdings). Arbitrary future implementation
///      safety cannot be proved by UUPS compatibility; these properties prove live
///      authorization, beta finality, compatibility checks, and rollback behavior.
contract USD8UpgradeKontrolTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    uint256 internal constant NONCE_OWNER_KEY = 0xA11CE55;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant HOLDER = address(0xBEEF);
    address internal constant SPENDER = address(0xCAFE);
    address internal constant NEW_TIMELOCK = address(0xD00D);
    address internal constant NO_CODE_CANDIDATE = address(0xDEAD);

    Registry internal registry;
    USD8 internal usd8Implementation;
    USD8 internal usd8;

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
        usd8Implementation = new USD8();
        usd8 = USD8(address(new ERC1967Proxy(address(usd8Implementation), abi.encodeCall(USD8.initialize, (registry)))));
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(this));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _implementationWord() internal view returns (bytes32) {
        return vm.load(address(usd8), IMPLEMENTATION_SLOT);
    }

    /// @dev Fixed-key cryptographic setup only; the preservation assertion is a
    ///      state property and does not claim to prove ECDSA or keccak correctness.
    function _seedPermitNonce(uint256 value) internal returns (address nonceOwner) {
        nonceOwner = vm.addr(NONCE_OWNER_KEY);
        uint256 deadline = type(uint256).max;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, nonceOwner, SPENDER, value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usd8.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(NONCE_OWNER_KEY, digest);
        usd8.permit(nonceOwner, SPENDER, value, deadline, v, r, s);
    }

    function test_nonTimelockCannotUpgradeAtomically(address caller) public {
        vm.assume(caller != registry.timelock());
        USD8UpgradeV2 candidate = new USD8UpgradeV2();
        bytes32 implementationBefore = _implementationWord();

        vm.prank(caller);
        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        assert(_selector(returndata) == Registry.UnauthorizedTimelock.selector);
        assert(_implementationWord() == implementationBefore);
        assert(address(usd8.registry()) == address(registry));
    }

    function test_timelockRotationImmediatelyRevokesOldAndGrantsNew() public {
        registry.setTimelock(NEW_TIMELOCK);
        USD8UpgradeV2 candidate = new USD8UpgradeV2();
        bytes32 implementationBefore = _implementationWord();

        (bool oldSuccess, bytes memory oldReturndata) =
            address(usd8).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));
        assert(!oldSuccess);
        assert(_selector(oldReturndata) == Registry.UnauthorizedTimelock.selector);
        assert(_implementationWord() == implementationBefore);

        vm.prank(NEW_TIMELOCK);
        usd8.upgradeToAndCall(address(candidate), "");
        assert(USD8UpgradeV2(address(usd8)).version() == 2);
        assert(_implementationWord() == bytes32(uint256(uint160(address(candidate)))));
    }

    function test_validBetaUpgradeToNamedV2PreservesAllRepresentativeState(
        uint128 holderAmount,
        uint128 selfAmount,
        uint128 allowanceAmount,
        uint128 heldTokenAmount,
        uint128 heldETH
    ) public {
        vm.assume(holderAmount > 0);
        vm.assume(selfAmount > 0);
        vm.assume(allowanceAmount > 0);
        vm.assume(heldTokenAmount > 0);
        vm.assume(heldETH > 0);

        USD8UpgradeHeldToken heldToken = new USD8UpgradeHeldToken();
        usd8.mint(HOLDER, holderAmount);
        usd8.mint(address(usd8), selfAmount);
        vm.prank(HOLDER);
        usd8.approve(SPENDER, allowanceAmount);
        heldToken.mint(address(usd8), heldTokenAmount);
        vm.deal(address(usd8), heldETH);

        address registryBefore = address(usd8.registry());
        string memory nameBefore = usd8.name();
        string memory symbolBefore = usd8.symbol();
        uint8 decimalsBefore = usd8.decimals();
        bytes32 domainBefore = usd8.DOMAIN_SEPARATOR();
        uint256 supplyBefore = usd8.totalSupply();
        uint256 holderBalanceBefore = usd8.balanceOf(HOLDER);
        uint256 selfBalanceBefore = usd8.balanceOf(address(usd8));
        uint256 allowanceBefore = usd8.allowance(HOLDER, SPENDER);
        uint256 tokenHoldingBefore = heldToken.balanceOf(address(usd8));
        uint256 ethHoldingBefore = address(usd8).balance;

        USD8UpgradeV2 candidate = new USD8UpgradeV2();
        usd8.upgradeToAndCall(address(candidate), "");

        assert(USD8UpgradeV2(address(usd8)).version() == 2);
        assert(address(usd8.registry()) == registryBefore);
        assert(keccak256(bytes(usd8.name())) == keccak256(bytes(nameBefore)));
        assert(keccak256(bytes(usd8.symbol())) == keccak256(bytes(symbolBefore)));
        assert(usd8.decimals() == decimalsBefore);
        assert(usd8.DOMAIN_SEPARATOR() == domainBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(HOLDER) == holderBalanceBefore);
        assert(usd8.balanceOf(address(usd8)) == selfBalanceBefore);
        assert(usd8.allowance(HOLDER, SPENDER) == allowanceBefore);
        assert(heldToken.balanceOf(address(usd8)) == tokenHoldingBefore);
        assert(address(usd8).balance == ethHoldingBefore);
    }

    function test_upgradeRejectedAfterBetaEnds() public {
        registry.endBetaMode();
        USD8UpgradeV2 candidate = new USD8UpgradeV2();
        bytes32 implementationBefore = _implementationWord();

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.NotBetaMode.selector);
        assert(_implementationWord() == implementationBefore);
        assert(!registry.betaMode());
    }

    function test_directImplementationUpgradeCallIsRejected() public {
        USD8UpgradeV2 candidate = new USD8UpgradeV2();

        (bool success, bytes memory returndata) = address(usd8Implementation)
            .call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        assert(_selector(returndata) == UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        assert(_implementationWord() == bytes32(uint256(uint160(address(usd8Implementation)))));
    }

    function test_proxyRejectsProxiableUUIDWhileImplementationReturnsERC1967Slot() public view {
        (bool proxySuccess, bytes memory proxyReturndata) =
            address(usd8).staticcall(abi.encodeCall(IERC1822Proxiable.proxiableUUID, ()));
        assert(!proxySuccess);
        assert(_selector(proxyReturndata) == UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);

        assert(usd8Implementation.proxiableUUID() == IMPLEMENTATION_SLOT);
    }

    function test_noCodeUpgradeCandidateIsRejectedAtomically() public {
        assert(NO_CODE_CANDIDATE.code.length == 0);
        bytes32 implementationBefore = _implementationWord();

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (NO_CODE_CANDIDATE, bytes(""))));

        assert(!success);
        // Solidity 0.8.28 rejects the typed ERC-1822 call before returndata is
        // produced when the target has no code; the atomic slot check is stable.
        assert(returndata.length == 0);
        assert(_implementationWord() == implementationBefore);
    }

    function test_nonUUPSCandidateIsRejectedAtomically() public {
        USD8UpgradeNonUUPS candidate = new USD8UpgradeNonUUPS();
        bytes32 implementationBefore = _implementationWord();

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        assert(_selector(returndata) == ERC1967Utils.ERC1967InvalidImplementation.selector);
        assert(_implementationWord() == implementationBefore);
    }

    function test_wrongUUIDCandidateIsRejectedAtomically() public {
        USD8UpgradeWrongUUID candidate = new USD8UpgradeWrongUUID();
        bytes32 implementationBefore = _implementationWord();

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        assert(_selector(returndata) == UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector);
        assert(_implementationWord() == implementationBefore);
    }

    function test_failedUpgradeInitializerRollsBackImplementationAndState(uint128 holderAmount, uint128 heldETH)
        public
    {
        vm.assume(holderAmount > 0);
        vm.assume(heldETH > 0);
        usd8.mint(HOLDER, holderAmount);
        vm.deal(address(usd8), heldETH);

        bytes32 implementationBefore = _implementationWord();
        uint256 supplyBefore = usd8.totalSupply();
        uint256 balanceBefore = usd8.balanceOf(HOLDER);
        uint256 ethBefore = address(usd8).balance;
        USD8UpgradeFailingInitializer candidate = new USD8UpgradeFailingInitializer();
        bytes memory initializer =
            abi.encodeCall(USD8UpgradeFailingInitializer.initializeV2ThenRevert, (uint256(holderAmount)));

        (bool success, bytes memory returndata) =
            address(usd8).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), initializer)));

        assert(!success);
        assert(_selector(returndata) == USD8UpgradeFailingInitializer.InitializationFailed.selector);
        assert(_implementationWord() == implementationBefore);
        assert(usd8.totalSupply() == supplyBefore);
        assert(usd8.balanceOf(HOLDER) == balanceBefore);
        assert(address(usd8).balance == ethBefore);
        (bool candidateGetterSuccess,) = address(usd8).staticcall(abi.encodeWithSignature("candidateValue()"));
        assert(!candidateGetterSuccess);
    }

    function test_upgradeInterfaceVersionIsExact() public view {
        assert(keccak256(bytes(usd8.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")));
        assert(keccak256(bytes(usd8Implementation.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")));
    }

    function test_validUpgradePreservesPermitNonceAndAllowance(uint128 permitValue) public {
        address nonceOwner = _seedPermitNonce(permitValue);
        USD8UpgradeV2 candidate = new USD8UpgradeV2();

        usd8.upgradeToAndCall(address(candidate), "");

        assert(USD8UpgradeV2(address(usd8)).version() == 2);
        assert(usd8.nonces(nonceOwner) == 1);
        assert(usd8.allowance(nonceOwner, SPENDER) == permitValue);
    }

    function test_emptyCalldataUpgradeRejectsNonzeroValueAtomically(uint128 value) public {
        vm.assume(value > 0);
        vm.deal(address(this), value);
        USD8UpgradeV2 candidate = new USD8UpgradeV2();
        bytes32 implementationBefore = _implementationWord();

        (bool success, bytes memory returndata) = address(usd8).call{value: value}(
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes("")))
        );

        assert(!success);
        assert(_selector(returndata) == ERC1967Utils.ERC1967NonPayable.selector);
        assert(_implementationWord() == implementationBefore);
        assert(address(usd8).balance == 0);
        assert(address(this).balance == value);
    }

    function test_nonemptyDelegateInitializerSucceeds(uint128 initializedValue) public {
        USD8UpgradeSuccessfulInitializer candidate = new USD8UpgradeSuccessfulInitializer();
        bytes memory initializer =
            abi.encodeCall(USD8UpgradeSuccessfulInitializer.initializeV2, (uint256(initializedValue)));

        usd8.upgradeToAndCall(address(candidate), initializer);

        USD8UpgradeSuccessfulInitializer upgraded = USD8UpgradeSuccessfulInitializer(address(usd8));
        assert(_implementationWord() == bytes32(uint256(uint160(address(candidate)))));
        assert(upgraded.candidateValue() == initializedValue);
        assert(upgraded.initializerCaller() == address(this));
        assert(address(upgraded.registry()) == address(registry));
    }

    function test_nonemptyPayableDelegateInitializerAcceptsValue(uint128 initializedValue, uint128 value) public {
        vm.assume(value > 0);
        vm.deal(address(this), value);
        USD8UpgradeSuccessfulInitializer candidate = new USD8UpgradeSuccessfulInitializer();
        bytes memory initializer =
            abi.encodeCall(USD8UpgradeSuccessfulInitializer.initializeV2Payable, (uint256(initializedValue)));

        usd8.upgradeToAndCall{value: value}(address(candidate), initializer);

        USD8UpgradeSuccessfulInitializer upgraded = USD8UpgradeSuccessfulInitializer(address(usd8));
        assert(_implementationWord() == bytes32(uint256(uint160(address(candidate)))));
        assert(upgraded.candidateValue() == initializedValue);
        assert(upgraded.initializerValue() == value);
        assert(upgraded.initializerCaller() == address(this));
        assert(address(usd8).balance == value);
        assert(address(this).balance == 0);
    }
}
