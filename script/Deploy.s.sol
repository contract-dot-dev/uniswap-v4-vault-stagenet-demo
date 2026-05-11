// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {UniswapV4Vault} from "../src/UniswapV4Vault.sol";
import {VaultHook} from "../src/VaultHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

/// @notice Deploys the VaultHook (with a CREATE2-mined address that carries
///         the AFTER_SWAP permission bit) and the UniswapV4Vault, then wires
///         them together. The vault constructor initializes the V4 pool.
///
/// Required env vars:
///   PRIVATE_KEY  Funded key for deployment gas.
contract Deploy is Script {
    // Canonical CREATE2 factory used by forge `new Contract{salt: x}(...)`.
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // Mine a salt that produces a hook address with the AFTER_SWAP bit set.
        (address expectedHook, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            uint160(Hooks.AFTER_SWAP_FLAG),
            type(VaultHook).creationCode,
            abi.encode(),
            200_000
        );

        console.log("Mined hook address:", expectedHook);

        vm.startBroadcast(deployerKey);

        VaultHook hook = new VaultHook{salt: salt}();
        require(address(hook) == expectedHook, "Hook address mismatch");

        // sqrtPriceX96 = 0 makes the vault initialize at the live price of the
        // existing hookless V4 USDC/WETH 0.05% pool.
        UniswapV4Vault vault = new UniswapV4Vault(IHooks(address(hook)), 0);

        hook.setVault(address(vault));

        vm.stopBroadcast();

        console.log("VaultHook deployed at:        ", address(hook));
        console.log("UniswapV4Vault deployed at:   ", address(vault));
        console.log(
            "Initial tick range: [%s, %s]",
            vm.toString(vault.tickLower()),
            vm.toString(vault.tickUpper())
        );
    }
}
