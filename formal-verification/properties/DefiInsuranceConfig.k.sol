// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {DefiInsurance} from "../../src/DefiInsurance.sol";
import {Registry} from "../../src/Registry.sol";
import {
    DefiInsuranceKontrolBase,
    DefiInsuranceHarnessToken,
    DefiInsuranceHarnessPool
} from "./DefiInsuranceHarness.k.sol";

/// @notice Initialization, selector identity, token configuration, ACL, and freeze properties.
contract DefiInsuranceConfigKontrolTest is DefiInsuranceKontrolBase {
    function test_initializationAndStaticGettersAreExact() public view {
        assert(address(defi.registry()) == address(registry));
        assert(defi.nextIncidentId() == 1);
        assert(defi.nextClaimId() == 1);
        assert(_boosterCollection() == address(booster));
        assert(_boosterId() == 1);
        assert(_boosterBoostBps() == 100);
        assert(defi.MAX_CLAIMANT_COVERAGE_BPS() == 8_000);
        assert(defi.activeIncidentId() == 0);
        assert(defi.isInsuredToken(IERC20(address(insured))));
        assert(defi.isInsuredToken(IERC20(address(secondInsured))));
        assert(!defi.isInsuredToken(IERC20(address(poolAsset))));
        (,,, uint128 storedBooster,,) = defi.claims(0);
        assert(storedBooster == 0);
        assert(_incidentPhaseDeadline(0) == 0);
        assert(defi.incidentPhaseWindow(0) == 0);
        assert(_incidentResolvedAt(0) == 0);
        assert(defi.escrowedInsuredTokens(IERC20(address(insured))) == 0);
        assert(defi.supportsInterface(type(IERC1155Receiver).interfaceId));
        assert(!defi.supportsInterface(bytes4(0xffffffff)));
    }

    function test_upgradeInterfaceVersionAndEip712DomainAreIndependentlyExact() public view {
        assert(keccak256(bytes(defi.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")));
        assert(keccak256(bytes(implementation.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")));

        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = defi.eip712Domain();
        assert(fields == hex"0f");
        assert(keccak256(bytes(name)) == keccak256(bytes("DefiInsurance")));
        assert(keccak256(bytes(version)) == keccak256(bytes("1")));
        assert(chainId == block.chainid);
        assert(verifyingContract == address(defi));
        assert(salt == bytes32(0));
        assert(extensions.length == 0);

        bytes32 tupleDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        bytes32 independentlyExpectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DefiInsurance"),
                keccak256("1"),
                block.chainid,
                address(defi)
            )
        );
        assert(tupleDomain == independentlyExpectedDomain);
    }

    function test_incidentOpenEligibilityHashBindsExactPricePolicyAndConversionRecipe() public {
        Registry.IncidentOpenPriceConfig memory price =
            Registry.IncidentOpenPriceConfig({twapBlocks: 1200, sampleStepBlocks: 300, minimumDropBps: 1234});
        registry.setIncidentOpenPriceConfig(price);
        address conversion = address(0xC0DE);
        bytes memory conversionData = hex"12345678";
        defi.editInsuredToken(IERC20(address(insured)), 8000, address(0x0A11CE), conversion, conversionData);

        bytes32 expected = keccak256(
            abi.encode(
                address(registry),
                price.twapBlocks,
                price.sampleStepBlocks,
                price.minimumDropBps,
                conversion,
                keccak256(conversionData)
            )
        );
        assert(defi.incidentOpenEligibilityHash(IERC20(address(insured))) == expected);

        defi.editInsuredToken(IERC20(address(insured)), 8000, address(0xBEEF), conversion, conversionData);
        assert(defi.incidentOpenEligibilityHash(IERC20(address(insured))) == expected);
    }

    function test_directImplementationAndProxyReinitializationAreLocked() public {
        address proxyRegistryBefore = address(defi.registry());
        uint64 nextIncidentBefore = defi.nextIncidentId();
        uint64 nextClaimBefore = defi.nextClaimId();
        (bool directSuccess, bytes memory directData) =
            address(implementation).call(abi.encodeCall(DefiInsurance.initialize, (registry)));
        assert(!directSuccess);
        assert(_sameBytes(directData, abi.encodeWithSelector(Initializable.InvalidInitialization.selector)));
        assert(address(implementation.registry()) == address(0));
        assert(implementation.nextIncidentId() == 0 && implementation.nextClaimId() == 0);

        (bool proxySuccess, bytes memory proxyData) =
            address(defi).call(abi.encodeCall(DefiInsurance.initialize, (registry)));
        assert(!proxySuccess);
        assert(_sameBytes(proxyData, abi.encodeWithSelector(Initializable.InvalidInitialization.selector)));
        assert(address(defi.registry()) == proxyRegistryBefore);
        assert(defi.nextIncidentId() == nextIncidentBefore);
        assert(defi.nextClaimId() == nextClaimBefore);
    }

    function test_insuredTokenConfigAndDynamicBytesAreStoredExactly(uint16 coverage, bytes4 conversionData) public {
        vm.assume(coverage > 0 && coverage <= 8_000);
        DefiInsuranceHarnessToken token = new DefiInsuranceHarnessToken("Third", "INS3");
        address conversion = address(0xC0DE);
        bytes memory data = abi.encodePacked(conversionData);

        defi.editInsuredToken(IERC20(address(token)), coverage, address(feed), conversion, data);
        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(token)));
        assert(config.maxCoverageBps == coverage);
        assert(config.underlyingPriceOracle == address(feed));
        assert(config.underlyingConversionAddress == conversion);
        assert(keccak256(config.underlyingConversionCallData) == keccak256(data));
        assert(defi.isInsuredToken(IERC20(address(token))));
    }

    function test_editInsuredTokenRejectsInvalidBoundariesAndUpdatesInPlace() public {
        DefiInsuranceHarnessToken candidate = new DefiInsuranceHarnessToken("Candidate", "CAN");

        (bool zeroToken, bytes memory zeroTokenData) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (IERC20(address(0)), uint256(1), address(feed), address(0), bytes(""))
                )
            );
        assert(!zeroToken && _sameBytes(zeroTokenData, abi.encodeWithSelector(Registry.ZeroAddress.selector)));

        (bool zeroOracle, bytes memory zeroOracleData) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (IERC20(address(candidate)), uint256(1), address(0), address(0), bytes(""))
                )
            );
        assert(!zeroOracle && _selector(zeroOracleData) == Registry.ZeroAddress.selector);

        (bool zeroCoverage, bytes memory zeroCoverageData) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (IERC20(address(candidate)), uint256(0), address(feed), address(0), bytes(""))
                )
            );
        assert(
            !zeroCoverage
                && _sameBytes(
                    zeroCoverageData,
                    abi.encodeWithSelector(DefiInsurance.InsuredTokenNotApproved.selector, address(candidate))
                )
        );

        (bool excessiveCoverage, bytes memory excessiveData) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (IERC20(address(candidate)), uint256(8_001), address(feed), address(0), bytes(""))
                )
            );
        assert(
            !excessiveCoverage
                && _sameBytes(
                    excessiveData,
                    abi.encodeWithSelector(
                        DefiInsurance.InvalidMaxCoverageBps.selector, uint256(8_001), uint256(8_000)
                    )
                )
        );
        assert(!defi.isInsuredToken(IERC20(address(candidate))));

        (bool update,) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (IERC20(address(insured)), uint256(1), address(feed), address(0), bytes(""))
                )
            );
        assert(update);
        assert(defi.getInsuredToken(IERC20(address(insured))).maxCoverageBps == 1);
    }

    function test_editInsuredTokenRejectsCoverPoolAsset() public {
        DefiInsuranceHarnessPool pool = _registerPool(100, 50);
        (bool success, bytes memory data) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken, (pool.asset(), uint256(1), address(feed), address(0), bytes(""))
                )
            );
        assert(!success);
        assert(_sameBytes(data, abi.encodeWithSelector(DefiInsurance.TokenConflict.selector)));
        assert(!defi.isInsuredToken(pool.asset()));
        assert(registry.coverPool(pool.asset()) == address(pool));
    }

    function test_symbolicConfigUpdatesAreExact(uint16 coverage, bytes4 conversionData) public {
        vm.assume(coverage > 0 && coverage <= 8_000);
        address conversion = address(0xC0DE);
        address oracle = address(0x0A11CE);
        bytes memory data = abi.encodePacked(conversionData);

        defi.editInsuredToken(IERC20(address(insured)), coverage, oracle, conversion, data);

        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(insured)));
        assert(config.maxCoverageBps == coverage);
        assert(config.underlyingConversionAddress == conversion);
        assert(keccak256(config.underlyingConversionCallData) == keccak256(data));
        assert(config.underlyingPriceOracle == oracle);
    }

    function test_invalidConfigUpdatesRevertAtomically() public {
        DefiInsurance.InsuredToken memory before_ = defi.getInsuredToken(IERC20(address(insured)));
        (bool c1, bytes memory d1) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (
                        IERC20(address(insured)),
                        uint256(10_001),
                        before_.underlyingPriceOracle,
                        before_.underlyingConversionAddress,
                        before_.underlyingConversionCallData
                    )
                )
            );
        assert(!c1 && _selector(d1) == DefiInsurance.InvalidMaxCoverageBps.selector);

        (bool o0, bytes memory od) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (
                        IERC20(address(insured)),
                        before_.maxCoverageBps,
                        address(0),
                        before_.underlyingConversionAddress,
                        before_.underlyingConversionCallData
                    )
                )
            );
        assert(!o0 && _selector(od) == Registry.ZeroAddress.selector);
        DefiInsurance.InsuredToken memory after_ = defi.getInsuredToken(IERC20(address(insured)));
        assert(keccak256(abi.encode(after_)) == keccak256(abi.encode(before_)));
    }

    function test_unauthorizedCallerCannotMutateConfiguration() public {
        (bool a, bytes memory ad) = _callAs(
            OUTSIDER,
            abi.encodeCall(
                DefiInsurance.editInsuredToken,
                (IERC20(address(poolAsset)), uint256(1), address(feed), address(0), bytes(""))
            )
        );
        assert(!a && _selector(ad) == Registry.UnauthorizedTimelock.selector);
        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(insured)));
        config.maxCoverageBps = 1;
        (bool c, bytes memory cd) = _callAs(
            OUTSIDER,
            abi.encodeCall(
                DefiInsurance.editInsuredToken,
                (
                    IERC20(address(insured)),
                    config.maxCoverageBps,
                    config.underlyingPriceOracle,
                    config.underlyingConversionAddress,
                    config.underlyingConversionCallData
                )
            )
        );
        assert(!c && _selector(cd) == Registry.UnauthorizedTimelock.selector);
        (bool s, bytes memory sd) = _callAs(
            OUTSIDER,
            abi.encodeCall(
                DefiInsurance.setSettlementParams,
                (DefiInsurance.SettlementParams({twapLookbackBlocks: 1, minHoldingRequired: 1, sampleStepBlocks: 1}))
            )
        );
        assert(!s && _selector(sd) == Registry.UnauthorizedTimelock.selector);
        (bool r, bytes memory rd) = _callAs(
            OUTSIDER,
            abi.encodeCall(
                DefiInsurance.editInsuredToken,
                (IERC20(address(insured)), uint256(0), address(0), address(0), bytes(""))
            )
        );
        assert(!r && _selector(rd) == Registry.UnauthorizedTimelock.selector);
        assert(defi.isInsuredToken(IERC20(address(insured))));
        assert(defi.isInsuredToken(IERC20(address(secondInsured))));
    }

    function test_activeIncidentFreezesUpdatesButAllowsIndependentListing() public {
        _open(IERC20(address(insured)));
        DefiInsurance.InsuredToken memory config = defi.getInsuredToken(IERC20(address(insured)));
        config.maxCoverageBps = 1;
        (bool c, bytes memory cd) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (
                        IERC20(address(insured)),
                        config.maxCoverageBps,
                        config.underlyingPriceOracle,
                        config.underlyingConversionAddress,
                        config.underlyingConversionCallData
                    )
                )
            );
        assert(!c && _selector(cd) == DefiInsurance.IncidentsActive.selector);
        (bool r, bytes memory rd) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.editInsuredToken,
                    (IERC20(address(insured)), uint256(0), address(0), address(0), bytes(""))
                )
            );
        assert(!r && _selector(rd) == DefiInsurance.IncidentsActive.selector);

        DefiInsuranceHarnessToken independent = new DefiInsuranceHarnessToken("Independent", "IND");
        defi.editInsuredToken(IERC20(address(independent)), 1, address(feed), address(0), "");
        assert(defi.isInsuredToken(IERC20(address(independent))));
    }

    function test_removeOneDoesNotCorruptOtherConfig() public {
        DefiInsurance.InsuredToken memory secondBefore = defi.getInsuredToken(IERC20(address(secondInsured)));
        defi.editInsuredToken(IERC20(address(insured)), 0, address(0), address(0), "");
        assert(!defi.isInsuredToken(IERC20(address(insured))));
        assert(defi.isInsuredToken(IERC20(address(secondInsured))));
        assert(
            keccak256(abi.encode(defi.getInsuredToken(IERC20(address(secondInsured)))))
                == keccak256(abi.encode(secondBefore))
        );
    }

    function test_removeLastPreservesFirst() public {
        defi.editInsuredToken(IERC20(address(secondInsured)), 0, address(0), address(0), "");
        assert(defi.isInsuredToken(IERC20(address(insured))));
        assert(!defi.isInsuredToken(IERC20(address(secondInsured))));
    }

    function test_setSettlementParamsAcceptsFullUint64FieldsWhenStrideNonzero(
        uint64 lookback,
        uint64 holding,
        uint64 stride
    ) public {
        vm.assume(stride > 0);
        DefiInsurance.SettlementParams memory params = DefiInsurance.SettlementParams({
            twapLookbackBlocks: lookback, minHoldingRequired: holding, sampleStepBlocks: stride
        });
        defi.setSettlementParams(params);
        (uint64 actualLookback, uint64 actualHolding, uint64 actualStride) = defi.settlementParams();
        assert(actualLookback == lookback);
        assert(actualHolding == holding);
        assert(actualStride == stride);
    }

    function test_zeroSettlementStrideRevertsAndPreservesConfig(uint64 lookback, uint64 holding) public {
        (uint64 beforeLookback, uint64 beforeHolding, uint64 beforeStride) = defi.settlementParams();
        (bool success, bytes memory data) = address(defi)
            .call(
                abi.encodeCall(
                    DefiInsurance.setSettlementParams,
                    (DefiInsurance.SettlementParams({
                            twapLookbackBlocks: lookback, minHoldingRequired: holding, sampleStepBlocks: 0
                        }))
                )
            );
        assert(!success && _sameBytes(data, abi.encodeWithSelector(DefiInsurance.InvalidSettlementParams.selector)));
        (uint64 afterLookback, uint64 afterHolding, uint64 afterStride) = defi.settlementParams();
        assert(beforeLookback == afterLookback && beforeHolding == afterHolding && beforeStride == afterStride);
    }

    /// @dev Zero is an approved configuration: the current contract deliberately
    ///      permits the timelock to disable claim bonds and emits no setter event.
    function test_claimBondAmountTimelockControlsFullUint128Domain(uint128 first, uint128 second) public {
        uint128 initial = defi.claimBondAmount();

        (bool unauthorized, bytes memory data) =
            _callAs(OUTSIDER, abi.encodeCall(DefiInsurance.setClaimBondAmount, (first)));
        assert(!unauthorized && _selector(data) == Registry.UnauthorizedTimelock.selector);
        assert(defi.claimBondAmount() == initial);

        defi.setClaimBondAmount(first);
        assert(defi.claimBondAmount() == first);
        defi.setClaimBondAmount(second);
        assert(defi.claimBondAmount() == second);
    }

    function test_teeSignerAuthorizationZeroAndIncidentFreeze() public {
        address signer = address(0x5151);
        defi.setTeeSigner(signer, true);
        assert(defi.isTeeSigner(signer));
        defi.setTeeSigner(signer, false);
        assert(!defi.isTeeSigner(signer));

        (bool zero, bytes memory zd) =
            address(defi).call(abi.encodeCall(DefiInsurance.setTeeSigner, (address(0), true)));
        assert(!zero && _selector(zd) == Registry.ZeroAddress.selector);

        _open(IERC20(address(insured)));
        (bool frozen, bytes memory fd) = address(defi).call(abi.encodeCall(DefiInsurance.setTeeSigner, (signer, true)));
        assert(!frozen && _selector(fd) == DefiInsurance.IncidentsActive.selector);
        assert(!defi.isTeeSigner(signer));
    }

    function test_erc1155ReceiverSelectorsAcceptSingleAndBatch() public {
        bytes4 single = defi.onERC1155Received(ALICE, BOB, 99, 7, hex"1234");
        uint256[] memory ids = new uint256[](2);
        uint256[] memory values = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        values[0] = 3;
        values[1] = 4;
        bytes4 batch = defi.onERC1155BatchReceived(ALICE, BOB, ids, values, hex"5678");
        assert(single == IERC1155Receiver.onERC1155Received.selector);
        assert(batch == IERC1155Receiver.onERC1155BatchReceived.selector);
    }
}
