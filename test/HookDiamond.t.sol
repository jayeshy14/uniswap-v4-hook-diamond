// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { OwnershipFacet } from "../src/facets/OwnershipFacet.sol";
import { HookFacet } from "../src/facets/hooks/HookFacet.sol";
import { HookDiamond } from "../src/HookDiamond.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";

contract HookDiamondTest is Test {
    HookDiamond diamond;
    IHooks hook;
    address owner = address(0xBEEF);

    PoolKey dummyKey;
    IPoolManager.SwapParams dummySwapParams;
    IPoolManager.ModifyLiquidityParams dummyLpParams;

    function setUp() public {
        // Deploy all facets
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        HookFacet hookFacet = new HookFacet();

        // Build cuts
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);

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

        bytes4[] memory hookSelectors = new bytes4[](8);
        hookSelectors[0] = IHooks.beforeInitialize.selector;
        hookSelectors[1] = IHooks.afterInitialize.selector;
        hookSelectors[2] = IHooks.beforeAddLiquidity.selector;
        hookSelectors[3] = IHooks.afterAddLiquidity.selector;
        hookSelectors[4] = IHooks.beforeRemoveLiquidity.selector;
        hookSelectors[5] = IHooks.afterRemoveLiquidity.selector;
        hookSelectors[6] = IHooks.beforeSwap.selector;
        hookSelectors[7] = IHooks.afterSwap.selector;
        cuts[3] = IDiamondCut.FacetCut({
            facetAddress: address(hookFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: hookSelectors
        });

        diamond = new HookDiamond(owner, cuts, address(0), bytes(""));
        hook = IHooks(address(diamond));

        dummyKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        dummySwapParams = IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0 });

        dummyLpParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)
        });
    }

    function test_beforeInitialize_routesToHookFacet() public {
        bytes4 result = hook.beforeInitialize(address(this), dummyKey, 1e18);
        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_afterInitialize_routesToHookFacet() public {
        bytes4 result = hook.afterInitialize(address(this), dummyKey, 1e18, 0);
        assertEq(result, IHooks.afterInitialize.selector);
    }

    function test_beforeSwap_routesToHookFacet() public {
        (bytes4 sel,,) = hook.beforeSwap(address(this), dummyKey, dummySwapParams, bytes(""));
        assertEq(sel, IHooks.beforeSwap.selector);
    }

    function test_afterSwap_routesToHookFacet() public {
        BalanceDelta delta = BalanceDelta.wrap(0);
        (bytes4 sel,) = hook.afterSwap(address(this), dummyKey, dummySwapParams, delta, bytes(""));
        assertEq(sel, IHooks.afterSwap.selector);
    }

    function test_beforeAddLiquidity_routesToHookFacet() public {
        bytes4 result = hook.beforeAddLiquidity(address(this), dummyKey, dummyLpParams, bytes(""));
        assertEq(result, IHooks.beforeAddLiquidity.selector);
    }

    function test_afterAddLiquidity_routesToHookFacet() public {
        BalanceDelta delta = BalanceDelta.wrap(0);
        (bytes4 sel,) = hook.afterAddLiquidity(address(this), dummyKey, dummyLpParams, delta, delta, bytes(""));
        assertEq(sel, IHooks.afterAddLiquidity.selector);
    }

    function test_beforeRemoveLiquidity_routesToHookFacet() public {
        bytes4 result = hook.beforeRemoveLiquidity(address(this), dummyKey, dummyLpParams, bytes(""));
        assertEq(result, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_afterRemoveLiquidity_routesToHookFacet() public {
        BalanceDelta delta = BalanceDelta.wrap(0);
        (bytes4 sel,) = hook.afterRemoveLiquidity(address(this), dummyKey, dummyLpParams, delta, delta, bytes(""));
        assertEq(sel, IHooks.afterRemoveLiquidity.selector);
    }

    function test_loupe_returnsAllFacets() public view {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(address(diamond)).facets();
        assertGe(facets.length, 4);
    }

    function test_owner_isSetCorrectly() public view {
        assertEq(IERC173(address(diamond)).owner(), owner);
    }
}
