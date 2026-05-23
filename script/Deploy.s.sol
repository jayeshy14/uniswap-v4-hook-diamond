// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { OwnershipFacet } from "../src/facets/OwnershipFacet.sol";
import { HookFacet } from "../src/facets/hooks/HookFacet.sol";
import { HookDiamond } from "../src/HookDiamond.sol";
import { HookMiner } from "./HookMiner.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

contract DeployHookDiamond is Script {
    function run() external {
        address owner = msg.sender;
        vm.startBroadcast();

        // 1. Deploy standard facets
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        HookFacet hookFacet = new HookFacet();

        // 2. Build FacetCut array
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

        // 3. Mine CREATE2 salt for correct permission bits
        bytes memory constructorArgs = abi.encode(owner, cuts, address(0), bytes(""));
        (, bytes32 salt) = HookMiner.find(owner, HookMiner.ALL_FLAGS, type(HookDiamond).creationCode, constructorArgs);

        // 4. Deploy via CREATE2
        HookDiamond diamond = new HookDiamond{ salt: salt }(owner, cuts, address(0), bytes(""));

        require(
            uint160(address(diamond)) & HookMiner.ALL_FLAGS == HookMiner.ALL_FLAGS, "Deploy: permission bits not set"
        );

        console.log("HookDiamond deployed at:", address(diamond));
        vm.stopBroadcast();
    }
}
