// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DefiInsurance, ISingleAssetCoverPool} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {MockERC1155} from "../../test/mocks/MockERC1155.sol";

contract DefiInsuranceHarnessToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DefiInsuranceHarnessFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev Controllable but production-shaped pool summary. It records calls and can
///      revert to prove whole-transition rollback across external boundaries.
contract DefiInsuranceHarnessPool is ISingleAssetCoverPool {
    IERC20 public immutable asset;
    uint256 public assets;
    uint256 public cap;
    uint256 public settleCalls;
    uint256 public payCalls;
    uint256 public totalPaid;
    address public lastRecipient;
    bool public revertSettle;
    bool public revertCap;
    bool public revertPay;
    address internal callbackTarget;
    bytes internal callbackData;
    uint256 public callbackAttempts;
    bool public callbackSuccess;
    bytes4 public callbackSelector;
    uint256 public callbackReturndataLength;

    constructor(IERC20 asset_, uint256 assets_, uint256 cap_) {
        asset = asset_;
        assets = assets_;
        cap = cap_;
    }

    function setModes(bool settle_, bool cap_, bool pay_) external {
        revertSettle = settle_;
        revertCap = cap_;
        revertPay = pay_;
    }

    function setAssetsAndCap(uint256 assets_, uint256 cap_) external {
        assets = assets_;
        cap = cap_;
    }

    function configureCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function settleMaturedExitEpochs(uint256) external returns (uint256) {
        if (revertSettle) revert("settle failed");
        settleCalls++;
        return 0;
    }

    function totalAssets() external view returns (uint256) {
        return assets;
    }

    function maxPayoutPerIncident() external view returns (uint256) {
        if (revertCap) revert("cap failed");
        return cap;
    }

    function payClaim(address to, uint256 amount) external {
        if (revertPay) revert("pay failed");
        payCalls++;
        totalPaid += amount;
        lastRecipient = to;
        require(amount <= assets, "insufficient pool assets");
        assets -= amount;
        if (callbackTarget != address(0)) {
            callbackAttempts++;
            bytes memory returndata;
            (callbackSuccess, returndata) = callbackTarget.call(callbackData);
            callbackReturndataLength = returndata.length;
            if (returndata.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(returndata, 0x20))
                }
                callbackSelector = selector;
            }
        }
    }
}

/// @notice Shared production-proxy fixture for all DefiInsurance properties.
/// @dev [C:CRYPTO] secp256k1 recovery and Keccak collision resistance are assumed;
///      fixed-key signatures execute the production EIP-712 digest path concretely.
///      [B:POOLS<=2,CLAIMS<=2] dynamic pool/claim families publish their bounds.
abstract contract DefiInsuranceKontrolBase is Test {
    bytes32 internal constant SETTLEMENT_TYPEHASH = keccak256(
        "Settlement(uint256 incidentId,bytes32 root,uint256 unresolvedClaims,uint256[] poolPayouts,bytes32 pools,bytes32 claimSet,bytes32 teePcrHash)"
    );
    bytes32 internal constant OPEN_TYPEHASH = keccak256(
        "IncidentOpen(address insuredToken,uint64 referenceBlock,uint256 incidentId,bytes32 teePcrHash,bytes32 eligibilityHash)"
    );
    bytes32 internal constant PCR_HASH = keccak256("kontrol-defi-insurance-pcr");
    uint256 internal constant TEE_KEY = 0xA11CE;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant OUTSIDER = address(0xBAD);
    address internal constant ORACLE = address(0xFEED);

    Registry internal registry;
    DefiInsurance internal implementation;
    DefiInsurance internal defi;
    DefiInsuranceHarnessToken internal insured;
    DefiInsuranceHarnessToken internal secondInsured;
    DefiInsuranceHarnessToken internal poolAsset;
    DefiInsuranceHarnessToken internal bondToken;
    MockERC1155 internal booster;
    DefiInsuranceHarnessFeed internal feed;

    // Independent fixture oracle. These values are updated from harness actions,
    // never reconstructed from Registry/DefiInsurance getters while signing.
    address[] internal expectedRegistryPools;
    mapping(uint256 incidentId => address[]) internal expectedIncidentPools;
    mapping(uint256 incidentId => uint256 unresolved) internal expectedIncidentUnresolved;
    mapping(uint256 incidentId => bytes32 claimSetHash) internal expectedIncidentClaimSetHash;
    mapping(uint256 incidentId => bytes32 teePcrHash) internal expectedIncidentTeePcrHash;

    function setUp() public virtual {
        vm.roll(1000);
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        // Legacy settlement properties isolate claimant accounting at a zero-fee
        // boundary. Dedicated fee regressions opt back into the production rate.
        registry.setProtocolFeeConfig(
            Registry.ProtocolFeeConfig({receiver: address(this), claimProtocolFeeShareBps: 0, reserveYieldFeeBps: 0})
        );
        implementation = new DefiInsurance();
        defi = DefiInsurance(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(DefiInsurance.initialize, (registry))))
        );
        insured = new DefiInsuranceHarnessToken("Insured", "INS");
        secondInsured = new DefiInsuranceHarnessToken("Second", "INS2");
        poolAsset = new DefiInsuranceHarnessToken("Pool Asset", "POOL");
        bondToken = new DefiInsuranceHarnessToken("USD8", "USD8");
        booster = new MockERC1155();
        feed = new DefiInsuranceHarnessFeed();

        registry.setTeePcrHash(PCR_HASH);
        registry.setUsd8(address(bondToken));
        registry.setTreasury(CAROL);
        registry.setDefiInsurance(address(defi));
        registry.setBoosterConfig(address(booster), 1, 100);
        defi.setTeeSigner(vm.addr(TEE_KEY), true);
        defi.editInsuredToken(IERC20(address(insured)), 8000, address(feed), address(0), "");
        defi.editInsuredToken(IERC20(address(secondInsured)), 7000, address(feed), address(0), hex"1234");
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _sameBytes(bytes memory actual, bytes memory expected) internal pure returns (bool) {
        return actual.length == expected.length && keccak256(actual) == keccak256(expected);
    }

    function _callAs(address caller, bytes memory data) internal returns (bool success, bytes memory returndata) {
        vm.prank(caller);
        return address(defi).call(data);
    }

    function _boosterId() internal view returns (uint64 value) {
        (, value,) = registry.boosterConfig();
    }

    function _boosterBoostBps() internal view returns (uint16 value) {
        (,, value) = registry.boosterConfig();
    }

    function _boosterCollection() internal view returns (address value) {
        (value,,) = registry.boosterConfig();
    }

    function _registerPool(uint256 assets, uint256 cap) internal returns (DefiInsuranceHarnessPool pool) {
        pool = new DefiInsuranceHarnessPool(poolAsset, assets, cap);
        registry.addPool(address(pool), address(feed));
        expectedRegistryPools.push(address(pool));
    }

    function _open(IERC20 token) internal returns (uint256 incidentId) {
        incidentId = defi.openClaimIncident(token, uint64(block.number - 1));
        for (uint256 i = 0; i < expectedRegistryPools.length; i++) {
            expectedIncidentPools[incidentId].push(expectedRegistryPools[i]);
        }
        expectedIncidentTeePcrHash[incidentId] = PCR_HASH;
    }

    function _join(address user, IERC20 token, uint128 amount, uint256 scoreToSpend, uint256 boosterAmount)
        internal
        returns (uint256 claimId)
    {
        DefiInsuranceHarnessToken(address(token)).mint(user, amount);
        bondToken.mint(user, defi.claimBondAmount());
        vm.startPrank(user);
        token.approve(address(defi), amount);
        bondToken.approve(address(defi), defi.claimBondAmount());
        if (boosterAmount != 0) {
            booster.mint(user, _boosterId(), boosterAmount);
            booster.setApprovalForAll(address(defi), true);
        }
        claimId = defi.fileClaim(token, amount, scoreToSpend, boosterAmount, 0, "");
        vm.stopPrank();
        uint256 incidentId = defi.activeIncidentId();
        expectedIncidentUnresolved[incidentId]++;
        expectedIncidentClaimSetHash[incidentId] = keccak256(
            abi.encode(expectedIncidentClaimSetHash[incidentId], claimId, user, amount, scoreToSpend, boosterAmount)
        );
    }

    function _openAndJoin(address user, uint128 amount, uint256 scoreToSpend, uint256 boosterAmount)
        internal
        returns (uint256 claimId)
    {
        _open(IERC20(address(insured)));
        claimId = _join(user, IERC20(address(insured)), amount, scoreToSpend, boosterAmount);
    }

    function _incidentResolvedAt(uint256 incidentId) internal view returns (uint64 value) {
        (, value,,,,,,,,) = defi.incidents(incidentId);
    }

    function _incidentReferenceBlock(uint256 incidentId) internal view returns (uint64 value) {
        (,, value,,,,,,,) = defi.incidents(incidentId);
    }

    function _incidentPhaseDeadline(uint256 incidentId) internal view returns (uint64 value) {
        (,,,, value,,,,,) = defi.incidents(incidentId);
    }

    function _incidentRoot(uint256 incidentId) internal view returns (bytes32 value) {
        (,,,,, value,,,,) = defi.incidents(incidentId);
    }

    function _incidentUnresolved(uint256 incidentId) internal view returns (uint256 value) {
        (,,,,,, value,,,) = defi.incidents(incidentId);
    }

    function _claimSetHash(uint256 incidentId) internal view returns (bytes32 value) {
        (,,,,,,, value,,) = defi.incidents(incidentId);
    }

    function _incidentTeePcrHash(uint256 incidentId) internal view returns (bytes32 value) {
        (,,,,,,,, value,) = defi.incidents(incidentId);
    }

    function _leaf(
        uint256 incidentId,
        uint256 claimId,
        address user,
        uint256[] memory amounts,
        uint256 scoreSpent,
        uint256 boostedScore,
        uint256 eligibleAmount
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(incidentId, claimId, user, amounts, scoreSpent, boostedScore, eligibleAmount))
            )
        );
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _independentSettlementDigest(
        uint256 incidentId,
        bytes32 root,
        uint256[] memory poolPayouts,
        address[] memory expectedPools,
        uint256 expectedUnresolved,
        bytes32 expectedClaimSetHash,
        bytes32 expectedTeePcrHash
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLEMENT_TYPEHASH,
                incidentId,
                root,
                expectedUnresolved,
                keccak256(abi.encodePacked(poolPayouts)),
                keccak256(abi.encodePacked(expectedPools)),
                expectedClaimSetHash,
                expectedTeePcrHash
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DefiInsurance"),
                keccak256("1"),
                block.chainid,
                address(defi)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _settlementSignature(
        uint256 incidentId,
        bytes32 root,
        uint256[] memory poolPayouts,
        address[] memory expectedPools,
        uint256 expectedUnresolved,
        bytes32 expectedClaimSetHash,
        bytes32 expectedTeePcrHash
    ) internal view returns (bytes memory) {
        bytes32 digest = _independentSettlementDigest(
            incidentId, root, poolPayouts, expectedPools, expectedUnresolved, expectedClaimSetHash, expectedTeePcrHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fixtureSettlementSignature(uint256 incidentId, bytes32 root, uint256[] memory poolPayouts)
        internal
        view
        returns (bytes memory)
    {
        return _settlementSignature(
            incidentId,
            root,
            poolPayouts,
            expectedIncidentPools[incidentId],
            expectedIncidentUnresolved[incidentId],
            expectedIncidentClaimSetHash[incidentId],
            expectedIncidentTeePcrHash[incidentId]
        );
    }

    function _expectedIncidentOpenEligibilityHash(IERC20 token) internal view returns (bytes32) {
        Registry.IncidentOpenPriceConfig memory price = registry.incidentOpenPriceConfig();
        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(token);
        return keccak256(
            abi.encode(
                address(registry),
                price.twapBlocks,
                price.sampleStepBlocks,
                price.minimumDropBps,
                config.underlyingConversionAddress,
                keccak256(config.underlyingConversionCallData)
            )
        );
    }

    function _openSignature(IERC20 token, uint64 referenceBlock) internal view returns (bytes memory) {
        uint256 incidentId = defi.nextIncidentId();
        bytes32 structHash = keccak256(
            abi.encode(
                OPEN_TYPEHASH,
                address(token),
                referenceBlock,
                incidentId,
                registry.teePcrHash(),
                _expectedIncidentOpenEligibilityHash(token)
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DefiInsurance"),
                keccak256("1"),
                block.chainid,
                address(defi)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _settle(uint256 incidentId, bytes32 root, uint256[] memory poolPayouts) internal {
        uint64 phaseWindow = defi.incidentPhaseWindow(incidentId);
        uint64 claimEnd = _incidentPhaseDeadline(incidentId);
        vm.warp(uint256(claimEnd) + 1);
        defi.settleIncident(root, poolPayouts, _fixtureSettlementSignature(incidentId, root, poolPayouts));
        uint256 unresolved = _incidentUnresolved(incidentId);
        assert(unresolved > 0);
        assert(block.timestamp <= uint256(claimEnd) + phaseWindow);
    }

    function _warpToFinalization(uint256 incidentId) internal {
        uint64 correctionDeadline = _incidentPhaseDeadline(incidentId);
        vm.warp(uint256(correctionDeadline) + 1);
    }

    function _emptyAmounts() internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](0);
    }

    function _oneAmount(uint256 amount) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }
}
