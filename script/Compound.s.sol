// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {UniswapV4Vault} from "../src/UniswapV4Vault.sol";

/// @notice Manually collects fees from the vault's V4 position and redeposits
///         them as additional liquidity in the same range. Equivalent to what
///         the hook does automatically every Nth swap.
///
/// Required env vars:
///   VAULT        Address of the deployed UniswapV4Vault.
///   PRIVATE_KEY  Funded key to broadcast the transaction.
contract Compound is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");

        UniswapV4Vault vault = UniswapV4Vault(vaultAddr);

        uint256 tvlBefore = vault.getUsdTvl();
        uint256 sharePriceBefore = vault.getUsdSharePrice();

        console.log("USD TVL before:         ", tvlBefore);
        console.log("USD share price before: ", sharePriceBefore);

        vm.startBroadcast(deployerKey);
        uint128 liquidityAdded = vault.compound();
        vm.stopBroadcast();

        console.log("Liquidity added:        ", uint256(liquidityAdded));
        console.log("Compound count:         ", vault.compoundCount());
        console.log("USD TVL after:          ", vault.getUsdTvl());
        console.log("USD share price after:  ", vault.getUsdSharePrice());
    }
}
