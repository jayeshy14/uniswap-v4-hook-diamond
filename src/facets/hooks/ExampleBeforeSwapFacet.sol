// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: replace HookFacet's beforeSwap selector with this facet via diamondCut.
// Shows how to read/write AppStorage and return a custom result from beforeSwap.

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { LibDiamond } from "../../libraries/LibDiamond.sol";

contract ExampleBeforeSwapFacet {
    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    )
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Increment the shared swap counter stored in AppStorage.
        LibDiamond.AppStorage storage s = LibDiamond.appStorage();
        s.swapCount++;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
