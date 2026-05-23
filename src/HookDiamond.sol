// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IDiamondCut } from "./interfaces/IDiamondCut.sol";
import { LibDiamond } from "./libraries/LibDiamond.sol";

/// @notice Diamond proxy that routes each Uniswap V4 hook callback to its registered facet.
/// The hook address encodes V4 permission bits — mine the correct CREATE2 salt with HookMiner.
/// Replace any callback's facet post-deploy via DiamondCutFacet without migrating LPs.
contract HookDiamond {
    constructor(
        address _contractOwner,
        IDiamondCut.FacetCut[] memory _diamondCut,
        address _init,
        bytes memory _calldata
    )
        payable {
        LibDiamond.setContractOwner(_contractOwner);
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }

    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "HookDiamond: Function does not exist");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable { }
}
