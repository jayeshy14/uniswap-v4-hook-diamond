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
import { ExampleBeforeSwapFacet } from "../src/facets/hooks/ExampleBeforeSwapFacet.sol";
import { HookDiamond } from "../src/HookDiamond.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";

contract DiamondCutTest is Test {
    HookDiamond diamond;
    address owner = address(0xBEEF);

    PoolKey dummyKey;
    IPoolManager.SwapParams dummySwapParams;
    IPoolManager.ModifyLiquidityParams dummyLpParams;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        HookFacet hookFacet = new HookFacet();

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

        dummyKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(diamond))
        });

        dummySwapParams = IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0 });

        dummyLpParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)
        });
    }

    function test_diamondCut_replacesBeforeSwapFacet() public {
        ExampleBeforeSwapFacet exampleFacet = new ExampleBeforeSwapFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IHooks.beforeSwap.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(exampleFacet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), bytes(""));

        // After replacement the call still returns the correct selector
        (bytes4 sel,,) = IHooks(address(diamond)).beforeSwap(address(this), dummyKey, dummySwapParams, bytes(""));
        assertEq(sel, IHooks.beforeSwap.selector);

        // Verify the new facet is registered via loupe
        address registered = IDiamondLoupe(address(diamond)).facetAddress(IHooks.beforeSwap.selector);
        assertEq(registered, address(exampleFacet));
    }

    function test_diamondCut_replacingOneCallbackDoesNotAffectOthers() public {
        ExampleBeforeSwapFacet exampleFacet = new ExampleBeforeSwapFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IHooks.beforeSwap.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(exampleFacet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), bytes(""));

        IHooks hook = IHooks(address(diamond));

        // All other 7 callbacks must still return their correct selectors
        assertEq(hook.beforeInitialize(address(this), dummyKey, 1e18), IHooks.beforeInitialize.selector);
        assertEq(hook.afterInitialize(address(this), dummyKey, 1e18, 0), IHooks.afterInitialize.selector);
        assertEq(
            hook.beforeAddLiquidity(address(this), dummyKey, dummyLpParams, bytes("")),
            IHooks.beforeAddLiquidity.selector
        );
        assertEq(
            hook.beforeRemoveLiquidity(address(this), dummyKey, dummyLpParams, bytes("")),
            IHooks.beforeRemoveLiquidity.selector
        );
        (bytes4 afterSwapSel,) =
            hook.afterSwap(address(this), dummyKey, dummySwapParams, BalanceDelta.wrap(0), bytes(""));
        assertEq(afterSwapSel, IHooks.afterSwap.selector);
        (bytes4 afterAddSel,) = hook.afterAddLiquidity(
            address(this), dummyKey, dummyLpParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), bytes("")
        );
        assertEq(afterAddSel, IHooks.afterAddLiquidity.selector);
        (bytes4 afterRemSel,) = hook.afterRemoveLiquidity(
            address(this), dummyKey, dummyLpParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), bytes("")
        );
        assertEq(afterRemSel, IHooks.afterRemoveLiquidity.selector);
    }

    function test_diamondCut_revertsIfNotOwner() public {
        ExampleBeforeSwapFacet exampleFacet = new ExampleBeforeSwapFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IHooks.beforeSwap.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(exampleFacet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });

        address nonOwner = address(0xDEAD);
        vm.prank(nonOwner);
        vm.expectRevert("LibDiamond: Must be contract owner");
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), bytes(""));
    }
}
