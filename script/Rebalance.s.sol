// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {UniswapV4Vault} from "../src/UniswapV4Vault.sol";

/// @notice Manually closes the vault's current V4 position and re-opens a new
///         one centred on the live tick, spanning the vault's hardcoded
///         `ticksEitherSide` above and below. Equivalent to what the hook
///         does automatically when the live tick exits the range.
///
/// Required env vars:
///   VAULT        Address of the deployed UniswapV4Vault.
///   PRIVATE_KEY  Funded key to broadcast the transaction.
contract Rebalance is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");

        UniswapV4Vault vault = UniswapV4Vault(vaultAddr);

        int24 oldTickLower = vault.tickLower();
        int24 oldTickUpper = vault.tickUpper();
        uint256 tvlBefore = vault.getUsdTvl();

        console.log("Old tickLower:", vm.toString(oldTickLower));
        console.log("Old tickUpper:", vm.toString(oldTickUpper));
        console.log("USD TVL before:", tvlBefore);

        vm.startBroadcast(deployerKey);
        vault.rebalance();
        vm.stopBroadcast();

        console.log("New tickLower:", vm.toString(vault.tickLower()));
        console.log("New tickUpper:", vm.toString(vault.tickUpper()));
        console.log("USD TVL after: ", vault.getUsdTvl());
        console.log("Rebalance count:", vault.rebalanceCount());
    }
}
