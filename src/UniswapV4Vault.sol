// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {
    IUnlockCallback
} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

// Rebalanceable Uniswap V4 liquidity position vault
// Owns a single liquidity position with mutable tick range, in a custom pool
// whose hook auto-compounds and auto-rebalances on each swap.
contract UniswapV4Vault is ERC20, IUnlockCallback {
    uint public version = 1;

    // *** LIBRARIES ***

    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    // *** STATE VARIABLES ***

    // The pool's token pair (Ethereum mainnet USDC/WETH).
    // USDC < WETH numerically, so USDC is currency0.
    address public constant token0 =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address public constant token1 =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

    // The pool's fee tier (0.05%) and the matching V4 tick spacing.
    uint24 public constant poolFee = 500;
    int24 public constant poolTickSpacing = 10;

    // The Uniswap V4 PoolManager (Ethereum mainnet)
    IPoolManager public constant poolManager =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // Chainlink price feeds for token0 and token1 denominated in USD
    address public constant token0PriceFeed =
        0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC/USD
    address public constant token1PriceFeed =
        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD

    // The initial amounts of token0 and token1 to mint per 1e18 shares
    uint256 public constant init0 = 1e6; // 1 USDC (6 decimals)
    uint256 public constant init1 = 1e18; // 1 WETH (18 decimals)

    // Half-width of the initial tick range around the current pool tick
    int24 public constant ticksEitherSide = 1200; // ~12% range either side

    // The hook attached to the vault's pool. Auto-triggers compound/rebalance.
    IHooks public immutable hook;

    // The PoolKey for the vault's pool, set once at construction.
    PoolKey public poolKey;

    // The PoolId for the vault's pool (keccak256 of the PoolKey fields).
    PoolId public immutable poolId;

    // Mutable tick range (updated on rebalance)
    int24 public tickLower;
    int24 public tickUpper;

    // The constant for 1e18
    uint256 private constant ONE = 1e18;

    // Counters
    uint256 public rebalanceCount;
    uint256 public compoundCount;

    // Lifetime fees collected by the vault from its position(s),
    // accumulated across compound, rebalance, and withdraw calls.
    uint256 public totalFees0Collected;
    uint256 public totalFees1Collected;

    // Action discriminators for the unlock callback.
    uint8 private constant ACTION_MINT = 1;
    uint8 private constant ACTION_WITHDRAW = 2;
    uint8 private constant ACTION_COMPOUND = 3;
    uint8 private constant ACTION_REBALANCE = 4;

    // *** EVENTS ***

    event Mint(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );

    event Withdraw(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );

    event Compound(
        uint256 amount0Used,
        uint256 amount1Used,
        uint128 liquidityAdded
    );

    event PoolInitialized(PoolId indexed poolId);

    event Rebalance(
        int24 newTickLower,
        int24 newTickUpper,
        uint256 rebalanceCount
    );

    event FeesCollected(uint256 amount0, uint256 amount1);

    // *** CONSTRUCTOR ***

    constructor(
        IHooks _hook,
        uint160 initialSqrtPriceX96
    ) ERC20("Uniswap V4 Vault Share", "UV4") {
        hook = _hook;

        // Build the PoolKey: USDC = currency0, WETH = currency1.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: poolFee,
            tickSpacing: poolTickSpacing,
            hooks: _hook
        });

        poolKey = key;
        poolId = key.toId();

        // If the caller did not supply an initial price, fall back to the
        // current price of the existing hookless V4 USDC/WETH 0.05% pool so
        // the vault opens its position around the real market tick.
        uint160 sqrtPriceX96 = initialSqrtPriceX96;
        if (sqrtPriceX96 == 0) {
            PoolKey memory referenceKey = PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: poolFee,
                tickSpacing: poolTickSpacing,
                hooks: IHooks(address(0))
            });
            (sqrtPriceX96, , , ) = poolManager.getSlot0(referenceKey.toId());
            require(sqrtPriceX96 != 0, "Reference pool not initialized");
        }

        int24 initialTick = poolManager.initialize(key, sqrtPriceX96);

        (tickLower, tickUpper) = _computeRangeAround(initialTick);

        emit PoolInitialized(poolId);
    }

    // Compute a tick range centered on `centerTick`, half-width
    // `ticksEitherSide`, aligned to `poolTickSpacing`, and clamped to the
    // pool's usable tick bounds so we never set a position past MIN/MAX_TICK.
    function _computeRangeAround(
        int24 centerTick
    ) internal pure returns (int24 lower, int24 upper) {
        int24 spacing = poolTickSpacing;

        int24 alignedTick = (centerTick / spacing) * spacing;
        if (centerTick < 0 && centerTick % spacing != 0) {
            alignedTick -= spacing;
        }

        int24 ticksInSpacing = (ticksEitherSide / spacing) * spacing;
        require(ticksInSpacing > 0, "Invalid tick range");

        int24 maxUsable = TickMath.maxUsableTick(spacing);
        int24 minUsable = TickMath.minUsableTick(spacing);

        lower = alignedTick - ticksInSpacing;
        upper = alignedTick + ticksInSpacing;
        if (lower < minUsable) lower = minUsable;
        if (upper > maxUsable) upper = maxUsable;
        require(lower < upper, "Empty range after clamp");
    }

    // *** VIEW FUNCTIONS ***

    // Returns the token0/token1 amounts owned by the vault's position,
    // in raw token units (matches token decimals).
    function totalUnderlying()
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _totalUnderlyingRaw();
    }

    // Returns the USD TVL of the vault, in whole USD
    function getUsdTvl() public view returns (uint256 usdValue) {
        usdValue = _getUsdTvlRaw() / ONE;
    }

    // Returns the USD value of one share, in whole USD per share
    function getUsdSharePrice() external view returns (uint256 price) {
        uint256 supply = totalSupply();

        if (supply == 0) {
            return 0;
        }

        // Both _getUsdTvlRaw() and supply are 1e18-scaled, so their integer
        // ratio is USD per share at 1e0 scale.
        price = _getUsdTvlRaw() / supply;
    }

    // Returns the token amounts required to mint the given number of shares.
    function previewMint(
        uint256 shares
    ) external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _calculateMintAmountFromShares(shares);
    }

    // Returns the current pool tick
    function getCurrentTick() external view returns (int24 tick) {
        (, tick, , ) = poolManager.getSlot0(poolId);
    }

    // Returns the fees the active position has accrued but not yet collected,
    // in raw token0/token1 units. Computed from pool fee growth accumulators.
    function fees()
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _accruedFees();
    }

    // Returns the lifetime fees the vault has collected from its position(s),
    // in raw token0/token1 units. Updated whenever the vault calls
    // modifyLiquidity (mint, compound, rebalance, withdraw).
    function cumulativeFees()
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = totalFees0Collected;
        amount1 = totalFees1Collected;
    }

    // Returns the current liquidity of the vault's position.
    function positionLiquidity() public view returns (uint128 liquidity) {
        bytes32 positionKey = Position.calculatePositionKey(
            address(this),
            tickLower,
            tickUpper,
            bytes32(0)
        );
        liquidity = poolManager.getPositionLiquidity(poolId, positionKey);
    }

    // *** EXTERNAL STATE-CHANGING FUNCTIONS ***

    // Mints vault shares by depositing token0 and token1
    function mint(
        uint256 shares
    ) external returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _calculateMintAmountFromShares(shares);

        require(amount0 > 0 || amount1 > 0, "Can't deposit zero tokens");

        if (amount0 > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        }

        poolManager.unlock(
            abi.encode(ACTION_MINT, abi.encode(amount0, amount1))
        );

        _mint(msg.sender, shares);

        emit Mint(msg.sender, amount0, amount1, shares);
    }

    // Burns shares and withdraws the caller's pro-rata share of vault assets
    function withdraw(
        uint256 shares
    ) external returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "Can't withdraw zero shares");

        uint256 supplyBefore = totalSupply();

        require(
            shares <= supplyBefore,
            "Can't withdraw more shares than the total supply"
        );

        poolManager.unlock(
            abi.encode(ACTION_WITHDRAW, abi.encode(shares, supplyBefore))
        );

        _burn(msg.sender, shares);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        amount0 = FullMath.mulDiv(balance0, shares, supplyBefore);
        amount1 = FullMath.mulDiv(balance1, shares, supplyBefore);

        if (amount0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, amount1);
        }

        emit Withdraw(msg.sender, amount0, amount1, shares);
    }

    // Collects fees and adds any idle balances back into the position.
    // Public so keepers (or the manual Compound script) can still trigger it
    // even if the hook has not.
    function compound() external returns (uint128 liquidityAdded) {
        require(positionLiquidity() != 0, "No position");

        bytes memory ret = poolManager.unlock(
            abi.encode(ACTION_COMPOUND, bytes(""))
        );
        liquidityAdded = abi.decode(ret, (uint128));
    }

    // Removes all liquidity, recenters tick range around current price,
    // and re-deposits.
    function rebalance() external {
        require(positionLiquidity() != 0, "No position");

        poolManager.unlock(abi.encode(ACTION_REBALANCE, bytes("")));
    }

    // *** HOOK-CALLABLE FUNCTIONS ***

    // The hook calls these from inside its own callback (afterSwap), where
    // PoolManager is already unlocked by the original swapper. We must NOT
    // call unlock again — instead we run the same logic directly and settle
    // the vault's deltas before returning so the swapper's settlement check
    // still passes.

    function compoundFromHook() external returns (uint128 liquidityAdded) {
        require(msg.sender == address(hook), "Only hook");
        if (positionLiquidity() == 0) {
            return 0;
        }
        liquidityAdded = _compound();
    }

    function rebalanceFromHook() external {
        require(msg.sender == address(hook), "Only hook");
        if (positionLiquidity() == 0) {
            return;
        }
        _rebalance();
    }

    // *** UNLOCK CALLBACK ***

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        (uint8 action, bytes memory params) = abi.decode(
            data,
            (uint8, bytes)
        );

        if (action == ACTION_MINT) {
            (uint256 amount0, uint256 amount1) = abi.decode(
                params,
                (uint256, uint256)
            );
            _doMint(amount0, amount1);
            return "";
        } else if (action == ACTION_WITHDRAW) {
            (uint256 shares, uint256 supplyBefore) = abi.decode(
                params,
                (uint256, uint256)
            );
            _doWithdraw(shares, supplyBefore);
            return "";
        } else if (action == ACTION_COMPOUND) {
            uint128 liquidityAdded = _compound();
            return abi.encode(liquidityAdded);
        } else if (action == ACTION_REBALANCE) {
            _rebalance();
            return "";
        }

        revert("Unknown action");
    }

    // *** INTERNAL: POSITION OPS ***

    function _doMint(uint256 amount0, uint256 amount1) internal {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        require(liquidity > 0, "Insufficient liquidity for mint");

        (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager
            .modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );

        _accrueFeesFromDelta(feesAccrued);
        _settleDelta(delta);
    }

    function _doWithdraw(uint256 shares, uint256 supplyBefore) internal {
        uint128 liquidity = positionLiquidity();
        if (liquidity == 0) return;

        uint128 liquidityToBurn = uint128(
            FullMath.mulDiv(liquidity, shares, supplyBefore)
        );
        if (liquidityToBurn == 0) return;

        (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager
            .modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(uint256(liquidityToBurn)),
                    salt: bytes32(0)
                }),
                ""
            );

        _accrueFeesFromDelta(feesAccrued);
        _settleDelta(delta);
    }

    function _compound() internal returns (uint128 liquidityAdded) {
        // Step 1: poke the position with liquidityDelta=0 to surface fees.
        (BalanceDelta pokeDelta, BalanceDelta feesAccrued) = poolManager
            .modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: 0,
                    salt: bytes32(0)
                }),
                ""
            );

        _accrueFeesFromDelta(feesAccrued);
        _settleDelta(pokeDelta);

        // Step 2: re-add liquidity using the vault's full balance.
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (balance0 == 0 && balance1 == 0) {
            compoundCount++;
            emit Compound(0, 0, 0);
            return 0;
        }

        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            balance0,
            balance1
        );

        if (liquidityAdded == 0) {
            compoundCount++;
            emit Compound(0, 0, 0);
            return 0;
        }

        (BalanceDelta addDelta, ) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidityAdded)),
                salt: bytes32(0)
            }),
            ""
        );

        _settleDelta(addDelta);

        uint256 amount0Used = balance0 -
            IERC20(token0).balanceOf(address(this));
        uint256 amount1Used = balance1 -
            IERC20(token1).balanceOf(address(this));

        compoundCount++;
        emit Compound(amount0Used, amount1Used, liquidityAdded);
    }

    function _rebalance() internal {
        // Step 1: remove all liquidity (this also collects fees).
        uint128 liquidity = positionLiquidity();
        if (liquidity > 0) {
            (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager
                .modifyLiquidity(
                    poolKey,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidityDelta: -int256(uint256(liquidity)),
                        salt: bytes32(0)
                    }),
                    ""
                );

            _accrueFeesFromDelta(feesAccrued);
            _settleDelta(delta);
        }

        // Step 2: recompute tick range around the current pool tick.
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(
            poolId
        );

        (tickLower, tickUpper) = _computeRangeAround(currentTick);

        // Step 3: re-add liquidity using the vault's full balance.
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (balance0 > 0 || balance1 > 0) {
            uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                balance0,
                balance1
            );

            if (newLiquidity > 0) {
                (BalanceDelta addDelta, ) = poolManager.modifyLiquidity(
                    poolKey,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidityDelta: int256(uint256(newLiquidity)),
                        salt: bytes32(0)
                    }),
                    ""
                );

                _settleDelta(addDelta);
            }
        }

        rebalanceCount++;
        emit Rebalance(tickLower, tickUpper, rebalanceCount);
    }

    // *** INTERNAL: SETTLEMENT ***

    // Settle a BalanceDelta against the PoolManager. Positive amounts mean the
    // pool owes the vault (take); negative amounts mean the vault owes the
    // pool (sync + transfer + settle).
    function _settleDelta(BalanceDelta delta) internal {
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 > 0) {
            poolManager.take(
                Currency.wrap(token0),
                address(this),
                uint256(uint128(d0))
            );
        } else if (d0 < 0) {
            uint256 owed = uint256(uint128(-d0));
            poolManager.sync(Currency.wrap(token0));
            IERC20(token0).safeTransfer(address(poolManager), owed);
            poolManager.settle();
        }

        if (d1 > 0) {
            poolManager.take(
                Currency.wrap(token1),
                address(this),
                uint256(uint128(d1))
            );
        } else if (d1 < 0) {
            uint256 owed = uint256(uint128(-d1));
            poolManager.sync(Currency.wrap(token1));
            IERC20(token1).safeTransfer(address(poolManager), owed);
            poolManager.settle();
        }
    }

    function _accrueFeesFromDelta(BalanceDelta feesAccrued) internal {
        int128 f0 = feesAccrued.amount0();
        int128 f1 = feesAccrued.amount1();

        // feesAccrued is always non-negative for the position owner.
        if (f0 > 0) totalFees0Collected += uint256(uint128(f0));
        if (f1 > 0) totalFees1Collected += uint256(uint128(f1));

        if (f0 != 0 || f1 != 0) {
            emit FeesCollected(
                f0 > 0 ? uint256(uint128(f0)) : 0,
                f1 > 0 ? uint256(uint128(f1)) : 0
            );
        }
    }

    // *** INTERNAL: VIEWS ***

    function _totalUnderlyingRaw()
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 liquidity = positionLiquidity();

        if (liquidity > 0) {
            (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidity
            );
        }

        // Add any uncollected fees still owed to the position.
        (uint256 fee0, uint256 fee1) = _accruedFees();
        amount0 += fee0;
        amount1 += fee1;

        // Idle tokens not used in mints are included in the underlying balance
        amount0 += IERC20(token0).balanceOf(address(this));
        amount1 += IERC20(token1).balanceOf(address(this));
    }

    function _accruedFees()
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 liquidity = positionLiquidity();
        if (liquidity == 0) return (0, 0);

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);

        bytes32 positionKey = Position.calculatePositionKey(
            address(this),
            tickLower,
            tickUpper,
            bytes32(0)
        );
        (
            ,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128
        ) = poolManager.getPositionInfo(poolId, positionKey);

        unchecked {
            amount0 = FullMath.mulDiv(
                feeGrowthInside0X128 - feeGrowthInside0LastX128,
                liquidity,
                FixedPoint128.Q128
            );
            amount1 = FullMath.mulDiv(
                feeGrowthInside1X128 - feeGrowthInside1LastX128,
                liquidity,
                FixedPoint128.Q128
            );
        }
    }

    function _getUsdTvlRaw() internal view returns (uint256 usdValue) {
        (uint256 amount0, uint256 amount1) = _totalUnderlyingRaw();

        usdValue =
            _tokenUsdValue(amount0, token0, token0PriceFeed) +
            _tokenUsdValue(amount1, token1, token1PriceFeed);
    }

    function _calculateMintAmountFromShares(
        uint256 shares
    ) internal view returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "Must mint more than zero shares");

        uint256 shareSupplyBefore = totalSupply();

        (uint256 total0, uint256 total1) = _totalUnderlyingRaw();

        if (shareSupplyBefore == 0) {
            (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtLower,
                sqrtUpper,
                init0,
                init1
            );

            require(liquidity > 0, "Insufficient init liquidity");

            (uint256 initAmount0, uint256 initAmount1) = LiquidityAmounts
                .getAmountsForLiquidity(
                    sqrtPriceX96,
                    sqrtLower,
                    sqrtUpper,
                    liquidity
                );

            amount0 = FullMath.mulDivRoundingUp(shares, initAmount0, ONE);
            amount1 = FullMath.mulDivRoundingUp(shares, initAmount1, ONE);
        } else {
            amount0 = FullMath.mulDivRoundingUp(
                shares,
                total0,
                shareSupplyBefore
            );
            amount1 = FullMath.mulDivRoundingUp(
                shares,
                total1,
                shareSupplyBefore
            );
        }
    }

    function _tokenUsdValue(
        uint256 amount,
        address token,
        address priceFeed
    ) internal view returns (uint256 value) {
        (, int256 answer, , , ) = AggregatorV3Interface(priceFeed)
            .latestRoundData();

        require(answer > 0, "Invalid price");

        uint8 feedDecimals = AggregatorV3Interface(priceFeed).decimals();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        uint256 valueInFeedDecimals = FullMath.mulDiv(
            amount,
            uint256(answer),
            10 ** tokenDecimals
        );

        if (feedDecimals == 18) {
            return valueInFeedDecimals;
        }

        if (feedDecimals < 18) {
            return valueInFeedDecimals * (10 ** (18 - feedDecimals));
        }

        return valueInFeedDecimals / (10 ** (feedDecimals - 18));
    }
}
