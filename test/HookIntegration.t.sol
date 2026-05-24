// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { TestERC20 } from "v4-core/test/TestERC20.sol";

import { HookDiamond } from "../src/HookDiamond.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { OwnershipFacet } from "../src/facets/OwnershipFacet.sol";
import { HookFacet } from "../src/facets/hooks/HookFacet.sol";
import { ExampleBeforeSwapFacet } from "../src/facets/hooks/ExampleBeforeSwapFacet.sol";
import { HookMiner } from "../script/HookMiner.sol";

/// @notice End-to-end test: drives the diamond hook through a real Uniswap V4 PoolManager.
/// Proves three things the unit tests can't, because they call callbacks directly:
///   1. The mined CREATE2 address is actually accepted by the PoolManager at initialize.
///   2. The manager invokes the registered facets during a real add-liquidity + swap.
///   3. The delegatecall return-passing + AppStorage write survive a real swap round-trip.
contract HookIntegrationTest is Test {
    // keccak256("hook.diamond.app.storage") — swapCount is the first field (offset 0).
    bytes32 constant APP_STORAGE_POSITION = keccak256("hook.diamond.app.storage");

    // Well-known V4 sqrt-price constants.
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_SQRT_PRICE = 4_295_128_739;

    PoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    HookDiamond diamond;
    PoolKey key;

    address owner = address(this);

    function setUp() public {
        // Real V4 stack
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        // Tokens (sorted)
        TestERC20 tokenA = new TestERC20(1e30);
        TestERC20 tokenB = new TestERC20(1e30);
        (TestERC20 token0, TestERC20 token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Deploy facets
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        HookFacet hookFacet = new HookFacet();
        ExampleBeforeSwapFacet beforeSwapFacet = new ExampleBeforeSwapFacet();

        // Build the cut.
        // beforeSwap is routed to ExampleBeforeSwapFacet (increments swapCount);
        // the other 7 callbacks go to the no-op HookFacet.
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](5);

        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = IDiamondCut.diamondCut.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(cutFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: cutSelectors
        });

        bytes4[] memory loupeSelectors = new bytes4[](4);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;
        loupeSelectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSelectors[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(loupeFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: loupeSelectors
        });

        bytes4[] memory ownerSelectors = new bytes4[](2);
        ownerSelectors[0] = IERC173.owner.selector;
        ownerSelectors[1] = IERC173.transferOwnership.selector;
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: ownerSelectors
        });

        bytes4[] memory hookSelectors = new bytes4[](7);
        hookSelectors[0] = IHooks.beforeInitialize.selector;
        hookSelectors[1] = IHooks.afterInitialize.selector;
        hookSelectors[2] = IHooks.beforeAddLiquidity.selector;
        hookSelectors[3] = IHooks.afterAddLiquidity.selector;
        hookSelectors[4] = IHooks.beforeRemoveLiquidity.selector;
        hookSelectors[5] = IHooks.afterRemoveLiquidity.selector;
        hookSelectors[6] = IHooks.afterSwap.selector;
        cuts[3] = IDiamondCut.FacetCut({
            facetAddress: address(hookFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: hookSelectors
        });

        bytes4[] memory beforeSwapSelectors = new bytes4[](1);
        beforeSwapSelectors[0] = IHooks.beforeSwap.selector;
        cuts[4] = IDiamondCut.FacetCut({
            facetAddress: address(beforeSwapFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: beforeSwapSelectors
        });

        // Mine the permission-bit address and CREATE2 deploy.
        bytes memory constructorArgs = abi.encode(owner, cuts, address(0), bytes(""));
        (address mined, bytes32 salt) =
            HookMiner.find(address(this), HookMiner.ALL_FLAGS, type(HookDiamond).creationCode, constructorArgs);

        diamond = new HookDiamond{ salt: salt }(owner, cuts, address(0), bytes(""));
        assertEq(address(diamond), mined, "deployed address != mined address");

        // Build the pool key.
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(diamond))
        });
    }

    /// The address mined for ALL_FLAGS must actually carry every permission bit,
    /// otherwise the PoolManager would reject it.
    function test_minedAddressHasAllPermissionBits() public view {
        assertEq(
            uint160(address(diamond)) & HookMiner.ALL_FLAGS,
            HookMiner.ALL_FLAGS,
            "mined address missing permission bits"
        );
    }

    /// Full round-trip through the real manager: initialize → add liquidity → swap.
    /// If the mined address were invalid, initialize would revert. If the proxy's
    /// delegatecall return-passing were wrong, the manager would reject the hook's
    /// selector return and revert the swap.
    function test_realSwap_routesBeforeSwapToFacet() public {
        // initialize — exercises beforeInitialize / afterInitialize on the real manager
        manager.initialize(key, SQRT_PRICE_1_1);

        // add liquidity — exercises before/afterAddLiquidity
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: 1e21, salt: bytes32(0)
            }),
            bytes("")
        );

        assertEq(_swapCount(), 0, "swapCount should be zero before swapping");

        // swap — exercises beforeSwap (ExampleBeforeSwapFacet) + afterSwap
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        // The facet ran inside the real swap and wrote to AppStorage through the proxy.
        assertEq(_swapCount(), 1, "beforeSwap facet did not fire during real swap");
    }

    function _swapCount() internal view returns (uint256) {
        return uint256(vm.load(address(diamond), APP_STORAGE_POSITION));
    }
}
