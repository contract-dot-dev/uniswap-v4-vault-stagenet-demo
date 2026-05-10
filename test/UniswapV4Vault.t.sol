// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {Actions} from "v4-periphery/libraries/Actions.sol";

import {UniswapV4Vault} from "../src/UniswapV4Vault.sol";
import {VaultHook} from "../src/VaultHook.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

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

contract UniswapV4VaultTest is Test {
    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IPoolManager constant POOL_MANAGER =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant UNIVERSAL_ROUTER =
        0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint8 constant V4_SWAP = 0x10;

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;

    UniswapV4Vault vault;
    VaultHook hook;
    PoolKey poolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address trader = makeAddr("trader");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"));

        // Mine a salt for the hook address with the AFTER_SWAP flag set.
        // In a foundry test, `new VaultHook{salt:s}()` deploys via the test
        // contract's address, so we mine using `address(this)` as the
        // CREATE2 deployer.
        (address expected, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.AFTER_SWAP_FLAG),
            type(VaultHook).creationCode,
            abi.encode(POOL_MANAGER, address(this)),
            200_000
        );

        hook = new VaultHook{salt: salt}(POOL_MANAGER, address(this));
        require(address(hook) == expected, "Hook addr mismatch");

        vault = new UniswapV4Vault(IHooks(address(hook)), 0);
        hook.setVault(address(vault));

        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        _fundAndApprove(alice, 500_000e6, 200e18);
        _fundAndApprove(bob, 500_000e6, 200e18);

        deal(USDC, trader, 10_000_000e6);
        deal(WETH, trader, 5000e18);

        // Permit2 dance for the trader: ERC20 approve Permit2 once, then
        // grant UniversalRouter a max Permit2 allowance for each token.
        vm.startPrank(trader);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            USDC,
            UNIVERSAL_ROUTER,
            type(uint160).max,
            type(uint48).max
        );
        IPermit2(PERMIT2).approve(
            WETH,
            UNIVERSAL_ROUTER,
            type(uint160).max,
            type(uint48).max
        );
        vm.stopPrank();
    }

    // ========== Deployment ==========

    function testDeployment() public view {
        assertEq(vault.token0(), USDC);
        assertEq(vault.token1(), WETH);
        assertEq(vault.poolFee(), POOL_FEE);
        assertEq(vault.poolTickSpacing(), TICK_SPACING);
        assertEq(address(vault.hook()), address(hook));
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.rebalanceCount(), 0);
        assertEq(vault.compoundCount(), 0);
        assertTrue(vault.tickLower() < vault.tickUpper());
        assertEq(uint256(vault.positionLiquidity()), 0);
    }

    function testHookAddressBitsValid() public view {
        // The hook's address must encode the AFTER_SWAP permission bit.
        uint160 flagMask = uint160((1 << 14) - 1);
        assertEq(uint160(address(hook)) & flagMask, Hooks.AFTER_SWAP_FLAG);
    }

    function testPreviewMintBeforeFirstDeposit() public view {
        (uint256 amount0, uint256 amount1) = vault.previewMint(1e18);
        assertTrue(
            amount0 > 0 || amount1 > 0,
            "Preview should return non-zero amounts"
        );
    }

    // ========== Mint ==========

    function testFirstMint() public {
        uint256 shares = 1e18;

        (uint256 previewAmount0, uint256 previewAmount1) = vault.previewMint(
            shares
        );

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = vault.mint(shares);

        assertEq(vault.totalSupply(), shares);
        assertEq(vault.balanceOf(alice), shares);
        assertTrue(vault.positionLiquidity() > 0, "Should have liquidity");
        assertEq(amount0, previewAmount0);
        assertEq(amount1, previewAmount1);

        console2.log("First mint - USDC deposited:", amount0);
        console2.log("First mint - WETH deposited:", amount1);
    }

    function testSecondMintKeepsSamePosition() public {
        vm.prank(alice);
        vault.mint(1e18);

        uint128 liquidityAfterFirst = vault.positionLiquidity();

        vm.prank(bob);
        vault.mint(1e18);

        assertEq(vault.totalSupply(), 2e18);
        assertEq(vault.balanceOf(alice), 1e18);
        assertEq(vault.balanceOf(bob), 1e18);
        assertTrue(vault.positionLiquidity() > liquidityAfterFirst);
    }

    function testMintMultipleShares() public {
        vm.prank(alice);
        vault.mint(5e18);

        assertEq(vault.totalSupply(), 5e18);
        assertEq(vault.balanceOf(alice), 5e18);
    }

    function testCannotMintZeroShares() public {
        vm.expectRevert("Must mint more than zero shares");
        vm.prank(alice);
        vault.mint(0);
    }

    // ========== Withdraw ==========

    function testWithdrawAll() public {
        uint256 shares = 1e18;

        vm.prank(alice);
        vault.mint(shares);

        uint256 usdc0 = IERC20(USDC).balanceOf(alice);
        uint256 weth0 = IERC20(WETH).balanceOf(alice);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = vault.withdraw(shares);

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(IERC20(USDC).balanceOf(alice), usdc0 + amount0);
        assertEq(IERC20(WETH).balanceOf(alice), weth0 + amount1);

        console2.log("Withdraw - returned USDC:", amount0);
        console2.log("Withdraw - returned WETH:", amount1);
    }

    function testWithdrawPartial() public {
        vm.prank(alice);
        vault.mint(2e18);

        vm.prank(alice);
        vault.withdraw(1e18);

        assertEq(vault.totalSupply(), 1e18);
        assertEq(vault.balanceOf(alice), 1e18);
    }

    function testCannotWithdrawZeroShares() public {
        vm.prank(alice);
        vault.mint(1e18);

        vm.expectRevert("Can't withdraw zero shares");
        vm.prank(alice);
        vault.withdraw(0);
    }

    function testCannotWithdrawMoreThanSupply() public {
        vm.prank(alice);
        vault.mint(1e18);

        vm.expectRevert("Can't withdraw more shares than the total supply");
        vm.prank(alice);
        vault.withdraw(2e18);
    }

    // ========== Compound ==========

    function testCompound() public {
        // Mint enough to give the pool real liquidity — small mints leave the
        // pool so thin that any swap blows the tick out of range and the hook
        // auto-rebalances into a degenerate (zero-liquidity) position.
        vm.prank(alice);
        vault.mint(100_000e18);

        _swap(true, 5_000e6);
        _swap(false, 1e18);

        uint128 liquidityAdded = vault.compound();

        assertEq(vault.compoundCount(), 1);
        console2.log("Compound - liquidity added:", uint256(liquidityAdded));
    }

    function testCannotCompoundWithoutPosition() public {
        vm.expectRevert("No position");
        vault.compound();
    }

    // ========== Rebalance ==========

    function testRebalance() public {
        vm.prank(alice);
        vault.mint(100_000e18);

        int24 oldTickLower = vault.tickLower();
        int24 oldTickUpper = vault.tickUpper();

        // Move price enough to shift the aligned tick range, but stay within
        // the vault's current range so the hook does not auto-rebalance and
        // the manual call below still has work to do.
        _swap(true, 10_000e6);

        vault.rebalance();

        assertEq(vault.rebalanceCount(), 1);
        assertTrue(
            vault.tickLower() != oldTickLower ||
                vault.tickUpper() != oldTickUpper,
            "Tick range should change"
        );
        assertTrue(vault.tickLower() < vault.tickUpper());
        assertTrue(vault.positionLiquidity() > 0);

        console2.log("Old tickLower:", oldTickLower);
        console2.log("Old tickUpper:", oldTickUpper);
        console2.log("New tickLower:", vault.tickLower());
        console2.log("New tickUpper:", vault.tickUpper());
    }

    function testRebalanceMultipleTimes() public {
        vm.prank(alice);
        vault.mint(100_000e18);

        _swap(true, 5_000e6);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 1);

        _swap(false, 2e18);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 2);

        _swap(true, 3_000e6);
        vault.rebalance();
        assertEq(vault.rebalanceCount(), 3);
    }

    function testCannotRebalanceWithoutPosition() public {
        vm.expectRevert("No position");
        vault.rebalance();
    }

    // ========== View Functions ==========

    function testTotalUnderlyingAfterDeposit() public {
        (uint256 before0, uint256 before1) = vault.totalUnderlying();
        assertEq(before0, 0);
        assertEq(before1, 0);

        vm.prank(alice);
        vault.mint(1e18);

        (uint256 after0, uint256 after1) = vault.totalUnderlying();
        assertTrue(
            after0 > 0 || after1 > 0,
            "Underlying should be non-zero after deposit"
        );

        console2.log("Total underlying USDC:", after0);
        console2.log("Total underlying WETH:", after1);
    }

    function testGetUsdTvl() public {
        vm.prank(alice);
        vault.mint(1e18);

        uint256 tvl = vault.getUsdTvl();
        assertTrue(tvl > 0, "TVL should be non-zero");

        console2.log("USD TVL (1e0):", tvl);
    }

    function testGetUsdSharePrice() public {
        assertEq(vault.getUsdSharePrice(), 0);

        vm.prank(alice);
        vault.mint(1e18);

        uint256 sharePrice = vault.getUsdSharePrice();
        assertTrue(sharePrice > 0, "Share price should be non-zero");

        console2.log("USD share price (1e0):", sharePrice);
    }

    // ========== Hook Auto-Triggering ==========

    function testHookAutoCompoundsEveryNthSwap() public {
        vm.prank(alice);
        vault.mint(100_000e18);

        // Lower the threshold so we don't need 50 swaps in a test.
        hook.setCompoundEvery(3);

        assertEq(vault.compoundCount(), 0);

        _swap(true, 1_000e6);
        assertEq(vault.compoundCount(), 0);

        _swap(false, 0.2e18);
        assertEq(vault.compoundCount(), 0);

        _swap(true, 1_000e6); // 3rd swap → should trigger compound
        assertEq(vault.compoundCount(), 1, "Hook did not auto-compound");

        _swap(false, 0.2e18);
        _swap(true, 1_000e6);
        _swap(false, 0.2e18); // 6th swap → another compound
        assertEq(vault.compoundCount(), 2);
    }

    function testHookAutoRebalancesWhenTickExitsRange() public {
        vm.prank(alice);
        vault.mint(10e18);

        // Disable auto-compound so we can isolate the rebalance behavior.
        hook.setCompoundEvery(1_000_000);

        assertEq(vault.rebalanceCount(), 0);
        int24 oldLower = vault.tickLower();
        int24 oldUpper = vault.tickUpper();

        // Hammer the pool until the tick exits the vault's range. With a
        // ~12% half-range and a fresh pool, this requires several large
        // one-directional swaps.
        for (uint256 i = 0; i < 10; i++) {
            _swap(false, 500e18);
            if (vault.rebalanceCount() > 0) break;
        }

        assertGt(vault.rebalanceCount(), 0, "Hook should have rebalanced");
        assertTrue(
            vault.tickLower() != oldLower || vault.tickUpper() != oldUpper,
            "Tick range should change"
        );
    }

    // ========== Integration ==========

    function testMultipleDepositorsWithdrawAll() public {
        vm.prank(alice);
        (uint256 aliceDep0, uint256 aliceDep1) = vault.mint(2e18);

        vm.prank(bob);
        (uint256 bobDep0, uint256 bobDep1) = vault.mint(1e18);

        assertEq(vault.totalSupply(), 3e18);

        vm.prank(alice);
        (uint256 aliceRet0, uint256 aliceRet1) = vault.withdraw(2e18);

        vm.prank(bob);
        (uint256 bobRet0, uint256 bobRet1) = vault.withdraw(1e18);

        assertEq(vault.totalSupply(), 0);
        assertTrue(aliceRet0 > 0 || aliceRet1 > 0, "Alice should get tokens");
        assertTrue(bobRet0 > 0 || bobRet1 > 0, "Bob should get tokens");

        uint256 totalDep0 = aliceDep0 + bobDep0;
        uint256 totalDep1 = aliceDep1 + bobDep1;
        uint256 totalRet0 = aliceRet0 + bobRet0;
        uint256 totalRet1 = aliceRet1 + bobRet1;

        assertTrue(
            totalRet0 >= (totalDep0 * 99) / 100,
            "Total USDC out should be >= 99% of USDC in"
        );
        assertTrue(
            totalRet1 >= (totalDep1 * 99) / 100,
            "Total WETH out should be >= 99% of WETH in"
        );

        console2.log("Alice returned USDC:", aliceRet0, "WETH:", aliceRet1);
        console2.log("Bob   returned USDC:", bobRet0, "WETH:", bobRet1);
    }

    function testDepositWithdrawNoMajorValueLeak() public {
        vm.prank(alice);
        (uint256 dep0, uint256 dep1) = vault.mint(1e18);

        vm.prank(alice);
        (uint256 ret0, uint256 ret1) = vault.withdraw(1e18);

        assertTrue(ret0 >= (dep0 * 99) / 100, "Should not lose >1% of USDC");
        assertTrue(ret1 >= (dep1 * 99) / 100, "Should not lose >1% of WETH");

        console2.log("Deposited USDC:", dep0, "Returned:", ret0);
        console2.log("Deposited WETH:", dep1, "Returned:", ret1);
    }

    function testSharePriceDoesNotDecreaseAfterCompound() public {
        vm.prank(alice);
        vault.mint(100_000e18);

        // Stop the hook from interfering with this isolated compound test.
        hook.setCompoundEvery(1_000_000);

        uint256 priceBefore = vault.getUsdSharePrice();

        _swap(false, 1e18);
        _swap(true, 5_000e6);

        vault.compound();

        uint256 priceAfter = vault.getUsdSharePrice();
        assertTrue(
            priceAfter >= priceBefore,
            "Share price should not decrease after compound"
        );

        console2.log("Price before compound:", priceBefore);
        console2.log("Price after compound: ", priceAfter);
    }

    function testRebalancePreservesValue() public {
        vm.prank(alice);
        vault.mint(10e18);

        uint256 tvlBefore = vault.getUsdTvl();

        vault.rebalance();

        uint256 tvlAfter = vault.getUsdTvl();

        assertTrue(
            tvlAfter >= (tvlBefore * 99) / 100,
            "Rebalance should not destroy >1% of TVL"
        );

        console2.log("TVL before rebalance:", tvlBefore);
        console2.log("TVL after rebalance: ", tvlAfter);
    }

    // ========== Helpers ==========

    function _fundAndApprove(
        address user,
        uint256 usdcAmount,
        uint256 wethAmount
    ) internal {
        deal(USDC, user, usdcAmount);
        deal(WETH, user, wethAmount);
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        Currency currencyIn = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency currencyOut = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(currencyIn, uint256(amountIn));
        params[2] = abi.encode(currencyOut, uint256(0));

        bytes memory commands = abi.encodePacked(V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(
            commands,
            inputs,
            block.timestamp + 60
        );
    }
}
