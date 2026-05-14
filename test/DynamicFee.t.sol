// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {HookDiamond} from "../src/HookDiamond.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {DynamicFeeFacet} from "../src/facets/hooks/DynamicFeeFacet.sol";
import {LibDiamond} from "../src/libraries/LibDiamond.sol";

// ─── Mock PoolManager ─────────────────────────────────────────────────────────

contract MockPoolManager {
    uint24 public lastFeeUpdate;
    bytes32 public lastFeePoolId;

    // StateLibrary.getSlot0 calls manager.extsload(keccak256(abi.encodePacked(poolId, POOLS_SLOT)))
    // where POOLS_SLOT = bytes32(uint256(6)). sqrtPriceX96 sits in the low 160 bits of that slot.
    // We store directly at that slot so extsload returns the right encoding.
    function setSqrtPrice(bytes32 rawPoolId, uint160 sqrtPrice) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(rawPoolId, bytes32(uint256(6))));
        assembly {
            sstore(stateSlot, sqrtPrice)
        }
    }

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly {
            value := sload(slot)
        }
    }

    function updateDynamicLPFee(PoolKey calldata key, uint24 newFee) external {
        lastFeePoolId = PoolId.unwrap(key.toId());
        lastFeeUpdate = newFee;
    }
}

// ─── Test ─────────────────────────────────────────────────────────────────────

contract DynamicFeeTest is Test {
    using PoolIdLibrary for PoolKey;

    HookDiamond public diamond;
    DynamicFeeFacet public facet;
    MockPoolManager public mockPM;

    PoolKey public key;
    bytes32 public poolId;

    address owner = address(this);

    function setUp() public {
        // Deploy the mock pool manager.
        mockPM = new MockPoolManager();

        // Deploy DiamondCutFacet and DynamicFeeFacet.
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        facet = new DynamicFeeFacet();

        // Build the initial diamond cut: DiamondCutFacet + DynamicFeeFacet selectors.
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);

        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = DiamondCutFacet.diamondCut.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(cutFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: cutSelectors
        });

        bytes4[] memory dynSelectors = new bytes4[](7);
        dynSelectors[0] = DynamicFeeFacet.setPoolManager.selector;
        dynSelectors[1] = DynamicFeeFacet.setFeeConfig.selector;
        dynSelectors[2] = DynamicFeeFacet.afterInitialize.selector;
        dynSelectors[3] = DynamicFeeFacet.beforeSwap.selector;
        dynSelectors[4] = DynamicFeeFacet.afterSwap.selector;
        dynSelectors[5] = DynamicFeeFacet.getCurrentFee.selector;
        dynSelectors[6] = DynamicFeeFacet.getCurrentVolatility.selector;
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: dynSelectors
        });

        diamond = new HookDiamond(owner, cuts, address(0), "");

        // Wire pool manager.
        DynamicFeeFacet(address(diamond)).setPoolManager(address(mockPM));

        // Build a minimal pool key (tokens/hook addresses don't matter for unit tests).
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(diamond))
        });
        poolId = PoolId.unwrap(key.toId());

        // Seed the initial price in the mock.
        uint160 initialPrice = 1e18; // arbitrary sqrtPriceX96
        mockPM.setSqrtPrice(poolId, initialPrice);

        // Simulate afterInitialize.
        DynamicFeeFacet(address(diamond)).afterInitialize(address(0), key, initialPrice, 0);
    }

    function test_InitialFeeIsBase() public view {
        assertEq(DynamicFeeFacet(address(diamond)).getCurrentFee(poolId), 500);
    }

    function test_LowVolatilityKeepsBaseFee() public {
        // Tiny price movements — stays below mediumThreshold (50 bps total).
        _simulateSwap(1e18 + 1e14); // ~0.01% move
        _simulateSwap(1e18 + 2e14);
        _simulateSwap(1e18 + 3e14);

        assertEq(DynamicFeeFacet(address(diamond)).getCurrentFee(poolId), 500);
    }

    function test_MediumVolatilityElevatesFee() public {
        // Push total movement above 50 bps but below 200 bps.
        // Each step ~20 bps move, 3 swaps = ~60 bps total.
        uint160 price = 1e18;
        for (uint256 i = 0; i < 3; i++) {
            price = price + uint160(price * 20 / 10_000); // +20 bps each swap
            _simulateSwap(price);
        }

        assertEq(DynamicFeeFacet(address(diamond)).getCurrentFee(poolId), 3_000);
    }

    function test_HighVolatilityMaximizesFee() public {
        // Push total movement above 200 bps.
        // Each step ~80 bps move, 3 swaps = ~240 bps total.
        uint160 price = 1e18;
        for (uint256 i = 0; i < 3; i++) {
            price = price + uint160(price * 80 / 10_000); // +80 bps each swap
            _simulateSwap(price);
        }

        assertEq(DynamicFeeFacet(address(diamond)).getCurrentFee(poolId), 10_000);
    }

    function test_FeeDropsWhenVolCalms() public {
        // Drive fee up.
        uint160 price = 1e18;
        for (uint256 i = 0; i < 3; i++) {
            price = price + uint160(price * 80 / 10_000);
            _simulateSwap(price);
        }
        assertEq(DynamicFeeFacet(address(diamond)).getCurrentFee(poolId), 10_000);

        // Fill the window (10 observations) with flat prices to flush old volatile data.
        for (uint256 i = 0; i < 10; i++) {
            _simulateSwap(price); // zero movement
        }

        assertEq(DynamicFeeFacet(address(diamond)).getCurrentFee(poolId), 500);
    }

    function test_CustomFeeConfig() public {
        DynamicFeeFacet(address(diamond)).setFeeConfig(poolId, 100, 1_000, 5_000, 30, 100);

        // Move ~50 bps total — should hit medium tier of new config (threshold 30).
        uint160 price = 1e18;
        price = price + uint160(price * 50 / 10_000);
        _simulateSwap(price);

        assertEq(DynamicFeeFacet(address(diamond)).getCurrentFee(poolId), 1_000);
    }

    function test_BeforeSwapReturnsZeroOverride() public {
        (, BeforeSwapDelta bsDelta, uint24 override_) = DynamicFeeFacet(address(diamond)).beforeSwap(
            address(0), key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), ""
        );
        assertEq(uint24(override_), 0);
    }

    function test_VolatilityViewMatchesFeeComputation() public {
        uint160 price = 1e18;
        for (uint256 i = 0; i < 3; i++) {
            price = price + uint160(price * 80 / 10_000);
            _simulateSwap(price);
        }

        uint256 vol = DynamicFeeFacet(address(diamond)).getCurrentVolatility(poolId);
        assertTrue(vol >= 200, "volatility should exceed high threshold");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    function _simulateSwap(uint160 newPrice) internal {
        mockPM.setSqrtPrice(poolId, newPrice);
        DynamicFeeFacet(address(diamond)).afterSwap(
            address(0),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );
    }
}
