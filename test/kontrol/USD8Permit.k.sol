// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {Registry} from "../../src/Registry.sol";
import {USD8} from "../../src/USD8.sol";

/// @notice EIP-2612 properties for the production USD8 implementation behind a
///         real ERC1967 proxy, including the proxy-bound EIP-712 domain.
/// @dev Tests with arguments are intended as symbolic protocol properties under
///      Kontrol. They assume keccak256 collision resistance and correctness of
///      the ECDSA precompile / `vm.sign`; they do not prove those cryptographic
///      primitives. Tests without arguments are concrete cryptographic
///      regressions using fixed private keys. The v/r/s ABI has no variable-length
///      signature form, so malformed coverage is the tractable all-zero tuple.
contract USD8PermitKontrolTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant NAME_HASH = keccak256("USD8");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant SECOND_OWNER_KEY = 0xB0B;
    uint256 internal constant SECP256K1_HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    Registry internal registry;
    USD8 internal usd8;
    address internal owner;
    address internal secondOwner;

    function setUp() public {
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(new Registry()), abi.encodeCall(Registry.initialize, (address(this), address(this)))
                )
            )
        );
        usd8 = _deployUsd8Proxy();
        registry.setUsd8(address(usd8));
        registry.setTreasury(address(this));
        owner = vm.addr(OWNER_KEY);
        secondOwner = vm.addr(SECOND_OWNER_KEY);
    }

    function _deployUsd8Proxy() internal returns (USD8) {
        return USD8(address(new ERC1967Proxy(address(new USD8()), abi.encodeCall(USD8.initialize, (registry)))));
    }

    /// @dev Mirrors OZ ERC20PermitUpgradeable exactly: current token nonce,
    ///      canonical Permit type string, and the token's live domain separator.
    function _permitDigest(USD8 token, address owner_, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender, value, token.nonces(owner_), deadline));
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _signPermit(USD8 token, uint256 key, address owner_, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(key, _permitDigest(token, owner_, spender, value, deadline));
    }

    function _callPermit(
        USD8 token,
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal returns (bool success, bytes memory returndata) {
        return address(token).call(abi.encodeCall(IERC20Permit.permit, (owner_, spender, value, deadline, v, r, s)));
    }

    function _selector(bytes memory returndata) internal pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _assertAtomicFailure(
        address owner_,
        address spender,
        uint256 nonceBefore,
        uint256 allowanceBefore,
        bool success,
        bytes memory returndata,
        bytes4 expectedSelector
    ) internal view {
        assert(!success);
        assert(_selector(returndata) == expectedSelector);
        assert(usd8.nonces(owner_) == nonceBefore);
        assert(usd8.allowance(owner_, spender) == allowanceBefore);
    }

    // ENVIRONMENT-BOUND PROTOCOL PROPERTY (chain id and proxy address are live values).
    function test_domainSeparatorIsExactProductionEip712Domain() public view {
        bytes32 expected =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(usd8)));
        assert(usd8.DOMAIN_SEPARATOR() == expected);
    }

    // ENVIRONMENT-BOUND PROTOCOL PROPERTY: verifies every EIP-5267 field, including empties.
    function test_eip5267TupleIsExact() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = usd8.eip712Domain();

        assert(fields == hex"0f");
        assert(keccak256(bytes(name)) == NAME_HASH);
        assert(keccak256(bytes(version)) == VERSION_HASH);
        assert(chainId == block.chainid);
        assert(verifyingContract == address(usd8));
        assert(salt == bytes32(0));
        assert(extensions.length == 0);
    }

    // SYMBOLIC PROTOCOL PROPERTY over spender, value, and deadline.
    // [C:ECDSA_CORRECT] Boundary: the proof assumes that ecrecover returns the
    // signer for a syntactically valid low-s signature; cryptography is not in
    // the state-property proof obligation.
    function test_validPermitSetsExactAllowanceAndIncrementsNonce(address spender, uint256 value, uint256 deadline)
        public
    {
        vm.assume(spender != address(0));
        vm.assume(deadline >= block.timestamp);
        vm.mockCall(address(1), bytes(""), abi.encode(owner));
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(1));

        uint256 nonceBefore = usd8.nonces(owner);
        usd8.permit(owner, spender, value, deadline, v, r, s);

        assert(usd8.allowance(owner, spender) == value);
        assert(usd8.nonces(owner) == nonceBefore + 1);
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: OZ uses `>` rather than `>=`.
    function test_deadlineEqualitySucceeds() public {
        vm.warp(777);
        address spender = address(0xCAFE);
        uint256 value = 123e18;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usd8, OWNER_KEY, owner, spender, value, block.timestamp);

        usd8.permit(owner, spender, value, block.timestamp, v, r, s);

        assert(usd8.allowance(owner, spender) == value);
        assert(usd8.nonces(owner) == 1);
    }

    // SYMBOLIC STATE REGRESSION over spender/value with concrete time. The
    // arbitrary signature is syntactically valid and low-s, so observing the
    // expiry selector proves expiration is checked before ecrecover.
    function test_expiredPermitFailsAtomically(address spender, uint256 value) public {
        vm.assume(spender != address(0));
        vm.warp(100);
        uint256 deadline = 99;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(1));
        uint256 nonceBefore = usd8.nonces(owner);
        uint256 allowanceBefore = usd8.allowance(owner, spender);

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, spender, value, deadline, v, r, s);

        _assertAtomicFailure(
            owner,
            spender,
            nonceBefore,
            allowanceBefore,
            success,
            returndata,
            ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector
        );
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: first execution succeeds, and replaying
    // the same concrete digest/signature after nonce advancement is atomic.
    function test_replayFailsAtomically() public {
        vm.warp(1_000);
        address spender = address(0xCAFE);
        uint256 value = 17;
        uint256 deadline = 2_000;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usd8, OWNER_KEY, owner, spender, value, deadline);
        usd8.permit(owner, spender, value, deadline, v, r, s);
        uint256 nonceBefore = usd8.nonces(owner);
        uint256 allowanceBefore = usd8.allowance(owner, spender);

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, spender, value, deadline, v, r, s);

        _assertAtomicFailure(
            owner,
            spender,
            nonceBefore,
            allowanceBefore,
            success,
            returndata,
            ERC20PermitUpgradeable.ERC2612InvalidSigner.selector
        );
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: spender is covered by the signed struct.
    function test_changedSpenderSignatureFailsAtomically() public {
        address signedSpender = address(0xCAFE);
        address calledSpender = address(0xBEEF);
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usd8, OWNER_KEY, owner, signedSpender, 17, deadline);

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, calledSpender, 17, deadline, v, r, s);

        _assertAtomicFailure(
            owner, calledSpender, 0, 0, success, returndata, ERC20PermitUpgradeable.ERC2612InvalidSigner.selector
        );
        assert(usd8.allowance(owner, signedSpender) == 0);
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: value is covered by the signed struct.
    function test_changedValueSignatureFailsAtomically() public {
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usd8, OWNER_KEY, owner, spender, 17, deadline);

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, spender, 18, deadline, v, r, s);

        _assertAtomicFailure(
            owner, spender, 0, 0, success, returndata, ERC20PermitUpgradeable.ERC2612InvalidSigner.selector
        );
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: deadline is covered by the signed struct.
    function test_changedDeadlineSignatureFailsAtomically() public {
        vm.warp(1_000);
        address spender = address(0xCAFE);
        uint256 signedDeadline = 2_000;
        uint256 calledDeadline = 2_001;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usd8, OWNER_KEY, owner, spender, 17, signedDeadline);

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, spender, 17, calledDeadline, v, r, s);

        _assertAtomicFailure(
            owner, spender, 0, 0, success, returndata, ERC20PermitUpgradeable.ERC2612InvalidSigner.selector
        );
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: verifyingContract is the proxy, not implementation.
    function test_signatureForWrongProxyFailsAtomically() public {
        USD8 otherProxy = _deployUsd8Proxy();
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(otherProxy, OWNER_KEY, owner, spender, 17, deadline);

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, spender, 17, deadline, v, r, s);

        _assertAtomicFailure(
            owner, spender, 0, 0, success, returndata, ERC20PermitUpgradeable.ERC2612InvalidSigner.selector
        );
        assert(otherProxy.nonces(owner) == 0);
    }

    // SYMBOLIC STATE PROPERTY: `_useNonce` and `_approve` are one atomic transaction.
    // [C:ECDSA_CORRECT] Boundary: ecrecover is modeled as returning the owner;
    // the obligation here is rollback when the recovered owner's spender is zero.
    function test_zeroSpenderRollsNonceAndAllowanceBack(uint256 value) public {
        uint256 deadline = type(uint256).max;
        vm.mockCall(address(1), bytes(""), abi.encode(owner));
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(1));

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, address(0), value, deadline, v, r, s);

        _assertAtomicFailure(owner, address(0), 0, 0, success, returndata, IERC20Errors.ERC20InvalidSpender.selector);
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: only v=27/28 can recover here.
    function test_invalidVFailsAtomically() public {
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;
        (, bytes32 r, bytes32 s) = _signPermit(usd8, OWNER_KEY, owner, spender, 17, deadline);

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, spender, 17, deadline, 29, r, s);

        _assertAtomicFailure(owner, spender, 0, 0, success, returndata, ECDSA.ECDSAInvalidSignature.selector);
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: EIP-2 upper-half s is rejected.
    function test_highSFailsAtomically() public {
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;
        bytes32 highS = bytes32(SECP256K1_HALF_ORDER + 1);

        (bool success, bytes memory returndata) =
            _callPermit(usd8, owner, spender, 17, deadline, 27, bytes32(uint256(1)), highS);

        _assertAtomicFailure(owner, spender, 0, 0, success, returndata, ECDSA.ECDSAInvalidSignatureS.selector);
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: tractable malformed v/r/s tuple.
    function test_malformedZeroSignatureFailsAtomically() public {
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;

        (bool success, bytes memory returndata) =
            _callPermit(usd8, owner, spender, 17, deadline, 0, bytes32(0), bytes32(0));

        _assertAtomicFailure(owner, spender, 0, 0, success, returndata, ECDSA.ECDSAInvalidSignature.selector);
    }

    // SYMBOLIC STATE PROPERTY over independent allowance values.
    // [C:ECDSA_CORRECT] Boundary: each ecrecover call is modeled as returning
    // the corresponding owner; nonce isolation and allowance state remain symbolic.
    function test_perOwnerNoncesAreIsolated(uint256 ownerValue, uint256 secondOwnerValue) public {
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;
        vm.mockCall(address(1), bytes(""), abi.encode(owner));
        usd8.permit(owner, spender, ownerValue, deadline, 27, bytes32(uint256(1)), bytes32(uint256(1)));

        assert(usd8.nonces(owner) == 1);
        assert(usd8.nonces(secondOwner) == 0);

        vm.mockCall(address(1), bytes(""), abi.encode(secondOwner));
        usd8.permit(secondOwner, spender, secondOwnerValue, deadline, 27, bytes32(uint256(1)), bytes32(uint256(1)));

        assert(usd8.nonces(owner) == 1);
        assert(usd8.nonces(secondOwner) == 1);
        assert(usd8.allowance(owner, spender) == ownerValue);
        assert(usd8.allowance(secondOwner, spender) == secondOwnerValue);
    }

    // SYMBOLIC STATE PROPERTY: two permits exercise nonce 0 then nonce 1.
    // [C:ECDSA_CORRECT] Boundary: ecrecover is modeled as returning the owner;
    // nonce progression and allowance overwrite remain symbolic obligations.
    function test_secondPermitOverwritesAllowanceAndAdvancesNonceToTwo(uint256 firstValue, uint256 replacement) public {
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;
        vm.mockCall(address(1), bytes(""), abi.encode(owner));

        usd8.permit(owner, spender, firstValue, deadline, 27, bytes32(uint256(1)), bytes32(uint256(1)));
        assert(usd8.nonces(owner) == 1);
        assert(usd8.allowance(owner, spender) == firstValue);

        usd8.permit(owner, spender, replacement, deadline, 27, bytes32(uint256(1)), bytes32(uint256(1)));

        assert(usd8.nonces(owner) == 2);
        assert(usd8.allowance(owner, spender) == replacement);
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: owner is covered by the signed struct.
    function test_changedOwnerSignatureFailsAtomically() public {
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usd8, OWNER_KEY, owner, spender, 17, deadline);

        (bool success, bytes memory returndata) = _callPermit(usd8, secondOwner, spender, 17, deadline, v, r, s);

        _assertAtomicFailure(
            secondOwner, spender, 0, 0, success, returndata, ERC20PermitUpgradeable.ERC2612InvalidSigner.selector
        );
        assert(usd8.nonces(owner) == 0);
        assert(usd8.allowance(owner, spender) == 0);
    }

    // CONCRETE CRYPTOGRAPHIC REGRESSION: a valid signature from the wrong key is rejected.
    function test_wrongSigningKeyFailsAtomically() public {
        address spender = address(0xCAFE);
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(usd8, SECOND_OWNER_KEY, owner, spender, 17, deadline);

        (bool success, bytes memory returndata) = _callPermit(usd8, owner, spender, 17, deadline, v, r, s);

        _assertAtomicFailure(
            owner, spender, 0, 0, success, returndata, ERC20PermitUpgradeable.ERC2612InvalidSigner.selector
        );
        assert(usd8.nonces(secondOwner) == 0);
    }

    // SYMBOLIC LIFECYCLE PROPERTY: permit's finite allowance is immediately usable
    // by transferFrom and is consumed by the exact transferred amount.
    // [C:ECDSA_CORRECT] Boundary: the proof assumes that ecrecover returns the
    // signer for a syntactically valid low-s signature; all nonce, allowance,
    // balance, and supply transitions remain symbolic proof obligations.
    function test_permitThenTransferFromConsumesExactFiniteAllowance(
        uint64 ownerSeed,
        uint64 amount,
        uint64 allowanceRemainder
    ) public {
        address spender = address(0xCAFE);
        address recipient = address(0xBEEF);
        vm.assume(amount > 0);
        vm.assume(amount <= ownerSeed);

        usd8.mint(owner, ownerSeed);
        uint256 approved = uint256(amount) + allowanceRemainder;
        uint256 deadline = type(uint256).max;
        vm.mockCall(address(1), bytes(""), abi.encode(owner));
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(1));

        usd8.permit(owner, spender, approved, deadline, v, r, s);
        vm.prank(spender);
        bool transferred = usd8.transferFrom(owner, recipient, amount);

        assert(transferred);
        assert(usd8.nonces(owner) == 1);
        assert(usd8.allowance(owner, spender) == allowanceRemainder);
        assert(usd8.balanceOf(owner) == uint256(ownerSeed) - amount);
        assert(usd8.balanceOf(recipient) == amount);
        assert(usd8.totalSupply() == ownerSeed);
    }
}
