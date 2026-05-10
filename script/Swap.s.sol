// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";

import {UniswapV4Vault} from "../src/UniswapV4Vault.sol";

interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

// Matches the ExactInputSingleParams struct shipped in the version of the
// V4Router that the canonical mainnet UniversalRouter was deployed against.
// The newer v4-periphery release adds a `minHopPriceX36` field; using that
// shape would mis-decode against the deployed router and silently revert.
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @notice Swaps against the Uniswap V4 pool the vault uses, via the canonical
///         UniversalRouter (and Permit2). Each swap also runs the vault's
///         hook, which may auto-compound or auto-rebalance.
///
/// Required env vars:
///   VAULT        Address of the deployed UniswapV4Vault.
///   PRIVATE_KEY  Funded key holding the input token.
///   AMOUNT_IN    Amount of input token to swap (in the token's smallest
///                unit).
///
/// Optional env vars:
///   ZERO_FOR_ONE  Swap direction. true = token0 -> token1 (default: true).
contract Swap is Script {
    // Canonical Ethereum mainnet (and same on Ethereum-replicating Stagenets).
    address constant UNIVERSAL_ROUTER =
        0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // UniversalRouter command byte for a V4 swap.
    uint8 constant V4_SWAP = 0x10;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");
        uint256 amountIn = vm.envUint("AMOUNT_IN");
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);

        UniswapV4Vault vault = UniswapV4Vault(vaultAddr);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vault.token0()),
            currency1: Currency.wrap(vault.token1()),
            fee: vault.poolFee(),
            tickSpacing: vault.poolTickSpacing(),
            hooks: vault.hook()
        });

        address tokenIn = zeroForOne ? vault.token0() : vault.token1();
        address tokenOut = zeroForOne ? vault.token1() : vault.token0();

        address sender = vm.addr(deployerKey);
        require(
            IERC20(tokenIn).balanceOf(sender) >= amountIn,
            "Insufficient input token balance"
        );

        vm.startBroadcast(deployerKey);

        // Permit2 flow: ERC20 approval to Permit2, then a Permit2 allowance
        // to UniversalRouter. Both are idempotent — safe to re-run.
        if (IERC20(tokenIn).allowance(sender, PERMIT2) < amountIn) {
            IERC20(tokenIn).approve(PERMIT2, type(uint256).max);
        }
        IPermit2(PERMIT2).approve(
            tokenIn,
            UNIVERSAL_ROUTER,
            uint160(amountIn),
            uint48(block.timestamp + 600)
        );

        // V4_SWAP encodes a sub-program of V4 router actions:
        //   SWAP_EXACT_IN_SINGLE → SETTLE_ALL (input) → TAKE_ALL (output).
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(Currency.wrap(tokenIn), uint256(amountIn));
        params[2] = abi.encode(Currency.wrap(tokenOut), uint256(0));

        bytes memory commands = abi.encodePacked(V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 outBefore = IERC20(tokenOut).balanceOf(sender);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(
            commands,
            inputs,
            block.timestamp + 600
        );
        uint256 amountOut = IERC20(tokenOut).balanceOf(sender) - outBefore;

        vm.stopBroadcast();

        console.log("UniversalRouter:    ", UNIVERSAL_ROUTER);
        console.log("tokenIn:            ", tokenIn);
        console.log("tokenOut:           ", tokenOut);
        console.log("amountIn:           ", amountIn);
        console.log("amountOut:          ", amountOut);
        console.log("Current tick:       ", vm.toString(vault.getCurrentTick()));
        console.log("Compound count:     ", vault.compoundCount());
        console.log("Rebalance count:    ", vault.rebalanceCount());
    }
}
