// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract KontrolTransientStorageSmokeTest {
    function testTransientStorageRoundTrip() public {
        bytes32 slot = keccak256("usd8.kontrol.transient-storage-smoke");
        uint256 loaded;

        assembly {
            tstore(slot, 42)
            loaded := tload(slot)
        }

        assert(loaded == 42);
    }
}
