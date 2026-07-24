// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {Registry} from "../../src/Registry.sol";
import {SharedBase} from "../../src/SharedBase.sol";
import {Treasury} from "../../src/Treasury.sol";
import {USD8} from "../../src/USD8.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

contract TreasuryInitUpgradeReserve is ERC20 {
    constructor() ERC20("Treasury proof USDC", "tpUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TreasuryInitUpgradeWrongDecimals is ERC20 {
    uint8 internal immutable _decimals;

    constructor(uint8 decimals_) ERC20("Wrong decimals", "WRONG") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract TreasuryInitUpgradeRevertingDecimals {
    error DecimalsUnavailable();

    function decimals() external pure returns (uint8) {
        revert DecimalsUnavailable();
    }
}

/// @dev Returns one byte for every call, including decimals(), so ABI decoding fails.
contract TreasuryInitUpgradeMalformedDecimals {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 6)
            return(31, 1)
        }
    }
}

contract TreasuryInitUpgradeStrategy is IStrategy {
    IERC20 internal immutable reserve;

    constructor(IERC20 reserve_) {
        reserve = reserve_;
    }

    function underlying() external view returns (address) {
        return address(reserve);
    }

    function deploy(uint256) external {}

    function withdraw(uint256 amount) external {
        reserve.transfer(msg.sender, amount);
    }

    function totalAssets() external view returns (uint256) {
        return reserve.balanceOf(address(this));
    }
}

/// @dev Named benign candidate: inherited layout plus appended behavior only.
contract TreasuryInitUpgradeV2 is Treasury {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Named payable candidate used to prove value reaches a delegate initializer.
contract TreasuryInitUpgradePayableV2 is Treasury {
    uint256 public candidateValue;
    uint256 public initializerValue;

    function initializeV2Payable(uint256 value) external payable reinitializer(2) {
        candidateValue = value;
        initializerValue = msg.value;
    }
}

contract TreasuryInitUpgradeNonUUPS {
    function version() external pure returns (uint256) {
        return 999;
    }
}

contract TreasuryInitUpgradeWrongUUID {
    bytes32 public constant WRONG_UUID = keccak256("usd8.treasury.kontrol.wrong.uuid");

    function proxiableUUID() external pure returns (bytes32) {
        return WRONG_UUID;
    }
}

contract TreasuryInitUpgradeFailingInitializer is Treasury {
    error InitializationFailed();

    uint256 public candidateValue;

    function initializeV2ThenRevert(uint256 value) external payable reinitializer(2) {
        candidateValue = value;
        revert InitializationFailed();
    }
}

/// @notice Initialization and beta-only UUPS compatibility properties for Treasury.
/// @dev Registry, USD8, and Treasury are production implementations behind real
///      ERC1967 proxies. Upgrade safety is claimed only for the named benign V2;
///      arbitrary UUPS-compatible implementations remain a governance trust boundary.
contract TreasuryInitUpgradeKontrolTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant USER = address(0xBEEF);
    address internal constant RECEIVER_A = address(0xCAFE);
    address internal constant RECEIVER_B = address(0xD00D);
    address internal constant NO_CODE_RESERVE = address(0xDEAD);
    address internal constant NO_CODE_CANDIDATE = address(0xF00D);

    Registry internal registry;
    USD8 internal usd8;
    Treasury internal treasuryImplementation;
    Treasury internal treasury;
    TreasuryInitUpgradeReserve internal reserve;
    TreasuryInitUpgradeReserve internal representativeForeign;
    TreasuryInitUpgradeStrategy internal representativeStrategyA;
    TreasuryInitUpgradeStrategy internal representativeStrategyB;

    struct RepresentativeState {
        bytes32 implementation;
        address registryPointer;
        address reservePointer;
        address usd8Pointer;
        address registryTreasury;
        address usd8Treasury;
        address strategyA;
        address strategyB;
        address receiverA;
        uint256 receiverAWeight;
        uint256 receiverAMode;
        address receiverB;
        uint256 receiverBWeight;
        uint256 receiverBMode;
        uint256 idleReserve;
        uint256 strategyAReserve;
        uint256 strategyBReserve;
        uint256 totalReserve;
        uint256 usd8Supply;
        uint256 userUsd8;
        uint256 treasuryUsd8;
        uint256 treasuryEth;
        uint256 foreignHolding;
    }

    function setUp() public {
        reserve = new TreasuryInitUpgradeReserve();
        registry = _newRegistry();
        usd8 = USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
        treasuryImplementation = new Treasury();
        treasury = _newTreasury(registry, IERC20(address(reserve)), treasuryImplementation);
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(treasury));
    }

    function _newRegistry() internal returns (Registry) {
        return Registry(
            address(
                new ERC1967Proxy(address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), ADMIN)))
            )
        );
    }

    function _newTreasury(Registry registry_, IERC20 reserve_, Treasury implementation_) internal returns (Treasury) {
        return Treasury(
            address(
                new ERC1967Proxy(address(implementation_), abi.encodeCall(Treasury.initialize, (registry_, reserve_)))
            )
        );
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _implementationWord() internal view returns (bytes32) {
        return vm.load(address(treasury), IMPLEMENTATION_SLOT);
    }

    function _implementationWord(address implementation) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(implementation)));
    }

    function _assertExactRevert(bytes memory returndata, bytes memory expected) internal pure {
        assert(keccak256(returndata) == keccak256(expected));
    }

    function _seedRepresentativeState() internal returns (RepresentativeState memory state) {
        representativeStrategyA = new TreasuryInitUpgradeStrategy(reserve);
        representativeStrategyB = new TreasuryInitUpgradeStrategy(reserve);
        treasury.addStrategy(representativeStrategyA, 0);
        treasury.addStrategy(representativeStrategyB, 1);
        treasury.setProfitReceiver(RECEIVER_A, 7, Treasury.RevenueDistributionMode.DirectTransfer);
        treasury.setProfitReceiver(RECEIVER_B, 11, Treasury.RevenueDistributionMode.ReceiveProfitDistribution);

        uint256 reserveAmount = 4e6;
        reserve.mint(USER, reserveAmount);
        vm.startPrank(USER);
        reserve.approve(address(treasury), reserveAmount);
        treasury.mintUSD8(reserveAmount);
        usd8.transfer(address(treasury), 1e18);
        vm.stopPrank();
        treasury.depositToStrategy(representativeStrategyA, 1e6);
        treasury.depositToStrategy(representativeStrategyB, 2e6);

        representativeForeign = new TreasuryInitUpgradeReserve();
        representativeForeign.mint(address(treasury), 123456);
        vm.deal(address(treasury), 1 ether);
        return _snapshotRepresentativeState();
    }

    function _snapshotRepresentativeState() internal view returns (RepresentativeState memory state) {
        state.implementation = _implementationWord();
        state.registryPointer = address(treasury.registry());
        state.reservePointer = address(treasury.USDC());
        state.usd8Pointer = address(treasury.usd8());
        state.registryTreasury = registry.treasury();
        state.usd8Treasury = usd8.treasury();
        state.strategyA = address(treasury.strategies(0));
        state.strategyB = address(treasury.strategies(1));
        (address receiverA, uint256 receiverAWeight, Treasury.RevenueDistributionMode modeA) =
            treasury.profitReceivers(0);
        state.receiverA = receiverA;
        state.receiverAWeight = receiverAWeight;
        state.receiverAMode = uint256(modeA);
        (address receiverB, uint256 receiverBWeight, Treasury.RevenueDistributionMode modeB) =
            treasury.profitReceivers(1);
        state.receiverB = receiverB;
        state.receiverBWeight = receiverBWeight;
        state.receiverBMode = uint256(modeB);
        state.idleReserve = reserve.balanceOf(address(treasury));
        state.strategyAReserve = reserve.balanceOf(address(representativeStrategyA));
        state.strategyBReserve = reserve.balanceOf(address(representativeStrategyB));
        state.totalReserve = treasury.getReserveBalance();
        state.usd8Supply = usd8.totalSupply();
        state.userUsd8 = usd8.balanceOf(USER);
        state.treasuryUsd8 = usd8.balanceOf(address(treasury));
        state.treasuryEth = address(treasury).balance;
        state.foreignHolding = representativeForeign.balanceOf(address(treasury));
    }

    function _assertRepresentativeState(
        RepresentativeState memory expected,
        bytes32 expectedImplementation,
        uint256 expectedEth
    ) internal view {
        RepresentativeState memory actual = _snapshotRepresentativeState();
        assert(actual.implementation == expectedImplementation);
        assert(actual.registryPointer == expected.registryPointer);
        assert(actual.reservePointer == expected.reservePointer);
        assert(actual.usd8Pointer == expected.usd8Pointer);
        assert(actual.registryTreasury == expected.registryTreasury);
        assert(actual.usd8Treasury == expected.usd8Treasury);
        assert(actual.strategyA == expected.strategyA && actual.strategyB == expected.strategyB);
        assert(actual.receiverA == expected.receiverA && actual.receiverAWeight == expected.receiverAWeight);
        assert(actual.receiverAMode == expected.receiverAMode);
        assert(actual.receiverB == expected.receiverB && actual.receiverBWeight == expected.receiverBWeight);
        assert(actual.receiverBMode == expected.receiverBMode);
        assert(actual.idleReserve == expected.idleReserve);
        assert(actual.strategyAReserve == expected.strategyAReserve);
        assert(actual.strategyBReserve == expected.strategyBReserve);
        assert(actual.totalReserve == expected.totalReserve);
        assert(actual.usd8Supply == expected.usd8Supply);
        assert(actual.userUsd8 == expected.userUsd8);
        assert(actual.treasuryUsd8 == expected.treasuryUsd8);
        assert(actual.treasuryEth == expectedEth);
        assert(actual.foreignHolding == expected.foreignHolding);
        assert(treasury.strategiesLength() == 2);
        assert(treasury.profitReceiversLength() == 2);
    }

    function _assertRepresentativeStateUnchanged(RepresentativeState memory expected) internal view {
        _assertRepresentativeState(expected, expected.implementation, expected.treasuryEth);
    }

    function test_implementationInitializationIsLocked() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        treasuryImplementation.initialize(registry, IERC20(address(reserve)));
    }

    function test_successfulProxyInitializationHasExactPointersAndEmptyConfiguration() public view {
        assert(address(treasury.registry()) == address(registry));
        assert(address(treasury.USDC()) == address(reserve));
        assert(address(treasury.usd8()) == address(usd8));
        assert(treasury.strategiesLength() == 0);
        assert(treasury.profitReceiversLength() == 0);
    }

    function test_initializeRejectsZeroRegistryAndZeroReserve() public {
        Treasury implementationA = new Treasury();
        vm.expectRevert(SharedBase.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementationA),
            abi.encodeCall(Treasury.initialize, (Registry(address(0)), IERC20(address(reserve))))
        );

        Treasury implementationB = new Treasury();
        vm.expectRevert(SharedBase.ZeroAddress.selector);
        new ERC1967Proxy(address(implementationB), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(0)))));
    }

    function test_initializeRejectsReserveWithoutCode() public {
        assert(NO_CODE_RESERVE.code.length == 0);
        Treasury implementation = new Treasury();
        vm.expectRevert(abi.encodeWithSelector(Treasury.InvalidReserveAsset.selector, NO_CODE_RESERVE));
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(Treasury.initialize, (registry, IERC20(NO_CODE_RESERVE)))
        );
    }

    function test_initializeRejectsSymbolicWrongReserveDecimals(uint8 wrongDecimals) public {
        vm.assume(wrongDecimals != 6);
        TreasuryInitUpgradeWrongDecimals wrong = new TreasuryInitUpgradeWrongDecimals(wrongDecimals);
        Treasury implementation = new Treasury();
        vm.expectRevert(abi.encodeWithSelector(Treasury.InvalidReserveDecimals.selector, wrongDecimals));
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(wrong))))
        );
    }

    function test_initializeRejectsRevertingDecimals() public {
        TreasuryInitUpgradeRevertingDecimals revertingReserve = new TreasuryInitUpgradeRevertingDecimals();
        Treasury implementation = new Treasury();
        vm.expectRevert(TreasuryInitUpgradeRevertingDecimals.DecimalsUnavailable.selector);
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(revertingReserve))))
        );
    }

    function test_initializeRejectsMalformedDecimals() public {
        TreasuryInitUpgradeMalformedDecimals malformed = new TreasuryInitUpgradeMalformedDecimals();
        Treasury implementation = new Treasury();
        vm.expectRevert();
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(Treasury.initialize, (registry, IERC20(address(malformed))))
        );
    }

    function test_reinitializeFailsAtomically() public {
        address registryBefore = address(treasury.registry());
        address reserveBefore = address(treasury.USDC());
        bytes32 implementationBefore = _implementationWord();

        (bool success, bytes memory returndata) = address(treasury)
            .call(
                abi.encodeCall(Treasury.initialize, (_newRegistry(), IERC20(address(new TreasuryInitUpgradeReserve()))))
            );

        assert(!success);
        assert(_selector(returndata) == Initializable.InvalidInitialization.selector);
        assert(address(treasury.registry()) == registryBefore);
        assert(address(treasury.USDC()) == reserveBefore);
        assert(treasury.strategiesLength() == 0);
        assert(treasury.profitReceiversLength() == 0);
        assert(_implementationWord() == implementationBefore);
    }

    function test_usd8ResolutionRotatesDynamicallyWhileRegistryAndReserveStayFixed() public {
        address registryBefore = address(treasury.registry());
        address reserveBefore = address(treasury.USDC());
        USD8 replacement =
            USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));

        registry.setUsd8(address(replacement));

        assert(address(treasury.usd8()) == address(replacement));
        assert(address(treasury.usd8()) != address(usd8));
        assert(address(treasury.registry()) == registryBefore);
        assert(address(treasury.USDC()) == reserveBefore);
    }

    function test_getterConstantsAndLengthsMatchSpecification() public view {
        assert(treasury.USDC_TO_USD8_SCALE() == 1e12);
        assert(treasury.HARVEST_BUFFER_DIVISOR() == 1000);
        assert(treasury.RESERVE_CHECK_TOLERANCE() == 100);
        assert(treasury.strategiesLength() == 0);
        assert(treasury.profitReceiversLength() == 0);
    }

    function test_proxiableUUIDImplementationAndProxyAreDistinct() public view {
        assert(treasuryImplementation.proxiableUUID() == IMPLEMENTATION_SLOT);
        (bool success, bytes memory returndata) =
            address(treasury).staticcall(abi.encodeCall(IERC1822Proxiable.proxiableUUID, ()));
        assert(!success);
        assert(_selector(returndata) == UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
    }

    function test_upgradeInterfaceVersionIsExactOnImplementationAndProxy() public view {
        assert(keccak256(bytes(treasuryImplementation.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")));
        assert(keccak256(bytes(treasury.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")));
    }

    function test_symbolicNonTimelockCannotUpgradeAtomically(address caller) public {
        vm.assume(caller != registry.timelock());
        TreasuryInitUpgradeV2 candidate = new TreasuryInitUpgradeV2();
        RepresentativeState memory beforeState = _seedRepresentativeState();

        vm.prank(caller);
        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(Registry.UnauthorizedTimelock.selector, caller));
        _assertRepresentativeStateUnchanged(beforeState);
    }

    function test_upgradeRejectedAfterBetaEnds() public {
        registry.endBetaMode();
        TreasuryInitUpgradeV2 candidate = new TreasuryInitUpgradeV2();
        bytes32 implementationBefore = _implementationWord();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        assert(_selector(returndata) == SharedBase.NotBetaMode.selector);
        assert(_implementationWord() == implementationBefore);
        assert(!registry.betaMode());
    }

    function test_namedBenignV2PreservesAllRepresentativeState() public {
        RepresentativeState memory beforeState = _seedRepresentativeState();
        TreasuryInitUpgradeV2 candidate = new TreasuryInitUpgradeV2();
        treasury.upgradeToAndCall(address(candidate), "");

        assert(TreasuryInitUpgradeV2(address(treasury)).version() == 2);
        _assertRepresentativeState(beforeState, _implementationWord(address(candidate)), beforeState.treasuryEth);
    }

    function test_noCodeUpgradeCandidateIsRejectedAtomically() public {
        assert(NO_CODE_CANDIDATE.code.length == 0);
        RepresentativeState memory beforeState = _seedRepresentativeState();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (NO_CODE_CANDIDATE, bytes(""))));

        assert(!success);
        // A code-less target returns empty data for proxiableUUID(); ABI decoding fails before OZ's catch body.
        assert(returndata.length == 0);
        _assertRepresentativeStateUnchanged(beforeState);
    }

    function test_nonUUPSCandidateIsRejectedAtomically() public {
        TreasuryInitUpgradeNonUUPS candidate = new TreasuryInitUpgradeNonUUPS();
        RepresentativeState memory beforeState = _seedRepresentativeState();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(candidate))
        );
        _assertRepresentativeStateUnchanged(beforeState);
    }

    function test_wrongUUIDCandidateIsRejectedAtomically() public {
        TreasuryInitUpgradeWrongUUID candidate = new TreasuryInitUpgradeWrongUUID();
        RepresentativeState memory beforeState = _seedRepresentativeState();

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes(""))));

        assert(!success);
        _assertExactRevert(
            returndata,
            abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, candidate.WRONG_UUID())
        );
        _assertRepresentativeStateUnchanged(beforeState);
    }

    function test_emptyUpgradeDataWithValueIsRejectedAtomically() public {
        RepresentativeState memory beforeState = _seedRepresentativeState();
        TreasuryInitUpgradeV2 candidate = new TreasuryInitUpgradeV2();
        uint256 upgradeValue = 0.25 ether;
        vm.deal(address(this), upgradeValue);
        uint256 callerEthBefore = address(this).balance;

        (bool success, bytes memory returndata) = address(treasury).call{value: upgradeValue}(
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), bytes("")))
        );

        assert(!success);
        _assertExactRevert(returndata, abi.encodeWithSelector(ERC1967Utils.ERC1967NonPayable.selector));
        _assertRepresentativeStateUnchanged(beforeState);
        assert(address(this).balance == callerEthBefore);
    }

    function test_namedPayableV2InitializerAcceptsValueAndPreservesRepresentativeState() public {
        RepresentativeState memory beforeState = _seedRepresentativeState();
        TreasuryInitUpgradePayableV2 candidate = new TreasuryInitUpgradePayableV2();
        uint256 upgradeValue = 0.25 ether;
        uint256 initializedValue = 0xB0B;
        vm.deal(address(this), upgradeValue);

        treasury.upgradeToAndCall{value: upgradeValue}(
            address(candidate), abi.encodeCall(TreasuryInitUpgradePayableV2.initializeV2Payable, (initializedValue))
        );

        TreasuryInitUpgradePayableV2 upgraded = TreasuryInitUpgradePayableV2(payable(address(treasury)));
        assert(upgraded.candidateValue() == initializedValue);
        assert(upgraded.initializerValue() == upgradeValue);
        _assertRepresentativeState(
            beforeState, _implementationWord(address(candidate)), beforeState.treasuryEth + upgradeValue
        );
    }

    function test_failedPayableInitializerWithValueFullyRollsBack() public {
        RepresentativeState memory beforeState = _seedRepresentativeState();
        TreasuryInitUpgradeFailingInitializer candidate = new TreasuryInitUpgradeFailingInitializer();
        uint256 upgradeValue = 0.25 ether;
        uint256 initializedValue = 0xBAD;
        vm.deal(address(this), upgradeValue);
        uint256 callerEthBefore = address(this).balance;
        bytes memory initializer =
            abi.encodeCall(TreasuryInitUpgradeFailingInitializer.initializeV2ThenRevert, (initializedValue));

        (bool success, bytes memory returndata) = address(treasury).call{value: upgradeValue}(
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), initializer))
        );

        assert(!success);
        _assertExactRevert(
            returndata, abi.encodeWithSelector(TreasuryInitUpgradeFailingInitializer.InitializationFailed.selector)
        );
        _assertRepresentativeStateUnchanged(beforeState);
        assert(address(this).balance == callerEthBefore);
        (bool getterSuccess,) = address(treasury).staticcall(abi.encodeCall(candidate.candidateValue, ()));
        assert(!getterSuccess);
    }

    function test_failedUpgradeInitializerRollsBackImplementationAndState(uint64 reserveAmount, uint128 value) public {
        vm.assume(reserveAmount > 0);
        reserve.mint(address(treasury), reserveAmount);
        treasury.setProfitReceiver(RECEIVER_A, 9, Treasury.RevenueDistributionMode.DirectTransfer);

        bytes32 implementationBefore = _implementationWord();
        address registryBefore = address(treasury.registry());
        address reservePointerBefore = address(treasury.USDC());
        uint256 reserveBalanceBefore = reserve.balanceOf(address(treasury));
        TreasuryInitUpgradeFailingInitializer candidate = new TreasuryInitUpgradeFailingInitializer();
        bytes memory initializer =
            abi.encodeCall(TreasuryInitUpgradeFailingInitializer.initializeV2ThenRevert, (uint256(value)));

        (bool success, bytes memory returndata) =
            address(treasury).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(candidate), initializer)));

        assert(!success);
        assert(_selector(returndata) == TreasuryInitUpgradeFailingInitializer.InitializationFailed.selector);
        assert(_implementationWord() == implementationBefore);
        assert(address(treasury.registry()) == registryBefore);
        assert(address(treasury.USDC()) == reservePointerBefore);
        assert(reserve.balanceOf(address(treasury)) == reserveBalanceBefore);
        assert(treasury.profitReceiversLength() == 1);
        (address receiver, uint256 weight, Treasury.RevenueDistributionMode mode) = treasury.profitReceivers(0);
        assert(receiver == RECEIVER_A && weight == 9);
        assert(uint256(mode) == uint256(Treasury.RevenueDistributionMode.DirectTransfer));
        (bool getterSuccess,) = address(treasury).staticcall(abi.encodeWithSignature("candidateValue()"));
        assert(!getterSuccess);
    }
}
