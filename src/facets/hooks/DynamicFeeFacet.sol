// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {LibDiamond} from "../../libraries/LibDiamond.sol";

/// @notice Diamond facet that adjusts LP fees dynamically based on realized price volatility.
///
/// Volatility is measured as the sum of absolute sqrtPrice movements (in bps) over a
/// rolling window of OBSERVATION_WINDOW swaps. After each swap the fee tier is recomputed
/// and pushed to the PoolManager via updateDynamicLPFee — no per-swap recompute cost.
///
/// Requirements:
///   • Pool must be initialized with key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000).
///   • Call setPoolManager(address) once after deployment.
///   • Replace HookFacet's afterInitialize, beforeSwap, afterSwap selectors via diamondCut.
contract DynamicFeeFacet {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 private constant WINDOW = LibDiamond.OBSERVATION_WINDOW;

    // ─── Admin ───────────────────────────────────────────────────────────────────

    function setPoolManager(address _poolManager) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.appStorage().poolManager = _poolManager;
    }

    /// @notice Override fee tiers and thresholds for a specific pool.
    /// @param poolId   Raw bytes32 pool ID (PoolId.unwrap(key.toId())).
    /// @param baseFee  Fee when vol < mediumThreshold (bps, e.g. 500 = 0.05%).
    /// @param mediumFee Fee when mediumThreshold <= vol < highThreshold.
    /// @param highFee  Fee when vol >= highThreshold.
    /// @param mediumThreshold Total sqrtPrice movement in bps that triggers medium tier.
    /// @param highThreshold   Total sqrtPrice movement in bps that triggers high tier.
    function setFeeConfig(
        bytes32 poolId,
        uint24 baseFee,
        uint24 mediumFee,
        uint24 highFee,
        uint32 mediumThreshold,
        uint32 highThreshold
    ) external {
        LibDiamond.enforceIsContractOwner();
        require(baseFee <= LPFeeLibrary.MAX_LP_FEE, "baseFee exceeds max");
        require(mediumFee <= LPFeeLibrary.MAX_LP_FEE, "mediumFee exceeds max");
        require(highFee <= LPFeeLibrary.MAX_LP_FEE, "highFee exceeds max");
        require(mediumThreshold < highThreshold, "invalid thresholds");

        LibDiamond.appStorage().feeConfig[poolId] = LibDiamond.FeeConfig({
            baseFee: baseFee,
            mediumFee: mediumFee,
            highFee: highFee,
            mediumThreshold: mediumThreshold,
            highThreshold: highThreshold
        });
    }

    // ─── Hook callbacks ───────────────────────────────────────────────────────────

    /// @notice Seeds the first observation and initializes fee config with defaults.
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24
    ) external returns (bytes4) {
        LibDiamond.AppStorage storage s = LibDiamond.appStorage();
        bytes32 id = PoolId.unwrap(key.toId());

        s.observations[id][0] =
            LibDiamond.PriceObservation({timestamp: uint32(block.timestamp), sqrtPriceX96: sqrtPriceX96});
        s.obsIndex[id] = 1;
        s.obsCount[id] = 1;

        // Apply defaults only if the owner hasn't pre-configured this pool.
        if (s.feeConfig[id].baseFee == 0) {
            s.feeConfig[id] = LibDiamond.FeeConfig({
                baseFee: 500,
                mediumFee: 3_000,
                highFee: 10_000,
                mediumThreshold: 50,
                highThreshold: 200
            });
        }
        s.currentFee[id] = s.feeConfig[id].baseFee;

        return IHooks.afterInitialize.selector;
    }

    /// @notice The pool's stored dynamic fee is already up-to-date from the previous afterSwap.
    ///         No override needed — return 0 so the pool uses its stored fee.
    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Records the post-swap price, recomputes volatility, and updates the pool fee.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, int128) {
        LibDiamond.AppStorage storage s = LibDiamond.appStorage();
        bytes32 id = PoolId.unwrap(key.toId());

        // Read post-swap price directly from PoolManager storage.
        (uint160 sqrtPriceX96,,,) = IPoolManager(s.poolManager).getSlot0(key.toId());

        // Write to circular buffer.
        uint8 idx = s.obsIndex[id];
        s.observations[id][idx] =
            LibDiamond.PriceObservation({timestamp: uint32(block.timestamp), sqrtPriceX96: sqrtPriceX96});
        s.obsIndex[id] = (idx + 1) % WINDOW;
        if (s.obsCount[id] < WINDOW) s.obsCount[id]++;

        // Recompute and push fee only when it changes.
        uint256 vol = _computeVolatility(id);
        uint24 newFee = _feeForVol(vol, s.feeConfig[id]);
        if (newFee != s.currentFee[id]) {
            s.currentFee[id] = newFee;
            // updateDynamicLPFee is callable without an unlock — safe inside afterSwap.
            IPoolManager(s.poolManager).updateDynamicLPFee(key, newFee);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ─── Views ────────────────────────────────────────────────────────────────────

    function getCurrentFee(bytes32 poolId) external view returns (uint24) {
        return LibDiamond.appStorage().currentFee[poolId];
    }

    function getCurrentVolatility(bytes32 poolId) external view returns (uint256) {
        return _computeVolatility(poolId);
    }

    function getFeeConfig(bytes32 poolId) external view returns (LibDiamond.FeeConfig memory) {
        return LibDiamond.appStorage().feeConfig[poolId];
    }

    // ─── Internal ─────────────────────────────────────────────────────────────────

    /// @dev Sums |ΔsqrtPrice / sqrtPrice_prev| in bps over the circular observation buffer.
    ///      Returns 0 when fewer than 2 observations exist.
    function _computeVolatility(bytes32 id) internal view returns (uint256 vol) {
        LibDiamond.AppStorage storage s = LibDiamond.appStorage();
        uint8 count = s.obsCount[id];
        if (count < 2) return 0;

        // Oldest observation: index 0 when buffer not yet full, obsIndex otherwise.
        uint8 startIdx = count < WINDOW ? 0 : s.obsIndex[id];
        uint160 prevPrice = s.observations[id][startIdx].sqrtPriceX96;

        for (uint8 i = 1; i < count; i++) {
            uint160 currPrice = s.observations[id][(startIdx + i) % WINDOW].sqrtPriceX96;
            uint256 diff = currPrice > prevPrice
                ? uint256(currPrice - prevPrice)
                : uint256(prevPrice - currPrice);
            // movement in bps relative to the previous observation
            vol += (diff * 10_000) / uint256(prevPrice);
            prevPrice = currPrice;
        }
    }

    function _feeForVol(uint256 vol, LibDiamond.FeeConfig memory cfg) internal pure returns (uint24) {
        if (vol >= cfg.highThreshold) return cfg.highFee;
        if (vol >= cfg.mediumThreshold) return cfg.mediumFee;
        return cfg.baseFee;
    }
}
