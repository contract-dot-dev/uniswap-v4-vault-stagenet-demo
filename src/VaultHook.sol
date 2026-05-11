// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

interface IVaultMaintenance {
    function tickLower() external view returns (int24);
    function tickUpper() external view returns (int24);
    function compoundFromHook() external returns (uint128);
    function rebalanceFromHook() external;
}

// Hook attached to the vault's pool. After every swap it checks two things:
//
//   1. Has the pool's tick drifted outside the vault's range? If yes, ask the
//      vault to recenter.
//   2. Has it been `compoundEvery` swaps since the last compound? If yes, ask
//      the vault to harvest fees and redeposit.
//
// The hook performs no liquidity operations itself; it only pokes the vault.
// The vault still exposes the same `compound()` / `rebalance()` functions as
// the V3 demo for manual triggering.
contract VaultHook is IHooks {
    using StateLibrary for IPoolManager;

    // Only PoolManager may invoke hook callbacks.
    IPoolManager public immutable poolManager;

    // Owner may set the vault address once after deployment.
    address public immutable owner;

    IVaultMaintenance public vault;

    // Auto-compound cadence: trigger every N swaps.
    uint256 public swapCount;
    uint256 public compoundEvery = 50;

    error NotPoolManager();
    error NotOwner();
    error VaultAlreadySet();
    error HookNotImplemented();

    event VaultSet(address vault);
    event AutoCompound(uint256 swapCount);
    event AutoRebalance(int24 currentTick, int24 oldLower, int24 oldUpper);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor() {
        poolManager = IPoolManager(
            0x000000000004444c5dc75cB358380D2e3dE08A90
        );
        owner = msg.sender;

        // Confirm the deployed address actually carries the AFTER_SWAP flag
        // (mined off-chain via CREATE2). Reverts if the salt was wrong.
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function setVault(address _vault) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(vault) != address(0)) revert VaultAlreadySet();
        vault = IVaultMaintenance(_vault);
        emit VaultSet(_vault);
    }

    function setCompoundEvery(uint256 n) external {
        if (msg.sender != owner) revert NotOwner();
        require(n > 0, "n=0");
        compoundEvery = n;
    }

    // *** IHooks ***

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        IVaultMaintenance _vault = vault;
        if (address(_vault) != address(0)) {
            // 1. Auto-rebalance if the live tick has drifted outside the
            //    vault's current range.
            (, int24 currentTick, , ) = poolManager.getSlot0(
                key.toId()
            );
            int24 vLower = _vault.tickLower();
            int24 vUpper = _vault.tickUpper();
            if (currentTick < vLower || currentTick >= vUpper) {
                _vault.rebalanceFromHook();
                emit AutoRebalance(currentTick, vLower, vUpper);
            }

            // 2. Auto-compound every Nth swap.
            uint256 next = swapCount + 1;
            swapCount = next;
            if (next % compoundEvery == 0) {
                _vault.compoundFromHook();
                emit AutoCompound(next);
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // The remaining IHooks callbacks are not enabled by this hook's address
    // bits. PoolManager will not call them, but we revert defensively so any
    // surprise call fails loudly.

    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external pure returns (bytes4, BeforeSwapDelta, uint24) {
        revert HookNotImplemented();
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
