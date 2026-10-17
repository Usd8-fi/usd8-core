// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal view of the CreateX factory used by the deployment scripts.
/// @dev    CreateX (github.com/pcaversaccio/createx) is deployed at the same address on
///         most EVM chains. Only the CREATE3 entry points are used here.
interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 salt) external view returns (address computedAddress);
}

/// @title Create3Deployer
/// @notice Deterministic, cross-chain-stable deployment helper for the USD8 scripts.
/// @dev    Every contract is created through CreateX `deployCreate3`, so its address depends
///         ONLY on (CreateX address, deployer, label) and never on init code. Constructor
///         arguments and initializer calldata may therefore differ per chain (USDC, feeds,
///         vaults...) while the resulting addresses stay identical.
///
///         Salt layout (CreateX "permissioned, no cross-chain redeploy protection"):
///           bytes  0..19  deployer address  -> only that sender can use the salt
///           byte   20     0x00              -> chain id is NOT mixed in (same address on every chain)
///           bytes 21..31  bytes11(keccak256(label))
///
///         CreateX guards such a salt as keccak256(bytes32(deployer) ++ salt). A different
///         sender submitting the same salt is not rejected but lands on an unrelated address,
///         so our addresses cannot be squatted on any chain.
///
///         Constructors run inside CreateX's CREATE3 proxy, so `msg.sender` during construction
///         is NOT the deployer. Contracts deployed here must take any owner as an explicit
///         argument (see {USD8SavingsBootstrap}).
abstract contract Create3Deployer {
    /// @notice Canonical CreateX address (identical on every chain where CreateX is deployed).
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    error CreateXMissing(address createX);
    error Create3AddressMismatch(string label, address expected, address actual);
    error Create3AddressOccupied(string label, address target);

    /// @notice Raw CreateX salt for `label` owned by `deployer`.
    function _create3Salt(address deployer, string memory label) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(deployer, bytes1(0x00), bytes11(keccak256(bytes(label)))));
    }

    /// @notice Mirrors CreateX `_guard` for a permissioned salt without chain-id protection.
    function _guardedCreate3Salt(address deployer, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encode(bytes32(uint256(uint160(deployer))), _create3Salt(deployer, label)));
    }

    /// @notice Address `label` will have when deployed by `deployer` on ANY chain with CreateX.
    function _predictCreate3(address deployer, string memory label) internal view returns (address) {
        _requireCreateX();
        return CREATEX.computeCreate3Address(_guardedCreate3Salt(deployer, label));
    }

    /// @notice Deploy `initCode` (creation code ++ abi-encoded constructor args) at the
    ///         deterministic address for (`deployer`, `label`).
    /// @dev    `deployer` must be the account that calls CreateX (the broadcaster in a script),
    ///         otherwise CreateX treats the salt as foreign and the prediction check reverts.
    function _create3(address deployer, string memory label, bytes memory initCode)
        internal
        returns (address deployed)
    {
        address expected = _predictCreate3(deployer, label);
        if (expected.code.length != 0) revert Create3AddressOccupied(label, expected);
        deployed = CREATEX.deployCreate3(_create3Salt(deployer, label), initCode);
        if (deployed != expected) revert Create3AddressMismatch(label, expected, deployed);
    }

    function _requireCreateX() internal view {
        if (address(CREATEX).code.length == 0) revert CreateXMissing(address(CREATEX));
    }
}
