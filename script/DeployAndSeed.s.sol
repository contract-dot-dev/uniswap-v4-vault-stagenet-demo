// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {UniswapV4Vault} from "../src/UniswapV4Vault.sol";
import {VaultHook} from "../src/VaultHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

/// @notice Deploys the VaultHook + UniswapV4Vault, wires them together, and
///         seeds the vault with an initial liquidity position in a single
///         broadcast.
///
/// Required env vars:
///   PRIVATE_KEY  Funded key holding token0 (USDC) and token1 (WETH).
///
/// Optional env vars:
///   SHARES       Number of shares to mint into the fresh vault.
///                Default: 500_000e18 (~$1M TVL on the first mint).
contract DeployAndSeed is Script {
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IPoolManager constant POOL_MANAGER =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 shares = vm.envOr("SHARES", uint256(500_000e18));
        address sender = vm.addr(deployerKey);

        (address expectedHook, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            uint160(Hooks.AFTER_SWAP_FLAG),
            type(VaultHook).creationCode,
            abi.encode(POOL_MANAGER, sender),
            200_000
        );

        console.log("Mined hook address:", expectedHook);

        vm.startBroadcast(deployerKey);

        VaultHook hook = new VaultHook{salt: salt}(POOL_MANAGER, sender);
        require(address(hook) == expectedHook, "Hook address mismatch");

        UniswapV4Vault vault = new UniswapV4Vault(IHooks(address(hook)), 0);
        hook.setVault(address(vault));

        console.log("VaultHook deployed at:        ", address(hook));
        console.log("UniswapV4Vault deployed at:   ", address(vault));
        console.log(
            "Initial tick range: [%s, %s]",
            vm.toString(vault.tickLower()),
            vm.toString(vault.tickUpper())
        );

        IERC20 token0 = IERC20(vault.token0());
        IERC20 token1 = IERC20(vault.token1());

        (uint256 amount0In, uint256 amount1In) = vault.previewMint(shares);
        console.log("Previewed token0 in:", amount0In);
        console.log("Previewed token1 in:", amount1In);

        require(
            token0.balanceOf(sender) >= amount0In,
            "Insufficient token0 balance for seed mint"
        );
        require(
            token1.balanceOf(sender) >= amount1In,
            "Insufficient token1 balance for seed mint"
        );

        token0.approve(address(vault), amount0In);
        token1.approve(address(vault), amount1In);

        (uint256 amount0, uint256 amount1) = vault.mint(shares);

        vm.stopBroadcast();

        console.log("Shares minted:        ", shares);
        console.log("token0 deposited:     ", amount0);
        console.log("token1 deposited:     ", amount1);
        console.log("Vault total supply:   ", vault.totalSupply());
        console.log("Sender share balance: ", vault.balanceOf(sender));
        console.log("USD TVL:              ", vault.getUsdTvl());
        console.log("USD share price:      ", vault.getUsdSharePrice());
    }
}
