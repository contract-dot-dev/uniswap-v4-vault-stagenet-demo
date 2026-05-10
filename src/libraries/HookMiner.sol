// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// CREATE2 salt miner for V4 hooks.
// The PoolManager decides which hook callbacks to invoke by inspecting the
// lowest 14 bits of the hook's deployed address. To get a hook deployed at an
// address whose bits match the desired permission flags, we mine a CREATE2
// salt that produces such an address.
library HookMiner {
    uint160 internal constant FLAG_MASK = uint160((1 << 14) - 1);

    // Brute-force search up to `maxLoops` salts for one that produces an
    // address whose lowest 14 bits equal `flags`.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 maxLoops
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);

        for (uint256 i = 0; i < maxLoops; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags) {
                return (hookAddress, salt);
            }
        }

        revert("HookMiner: no salt found");
    }

    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }
}
