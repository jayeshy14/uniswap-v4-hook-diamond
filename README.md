# hook-diamond

A modular, upgradeable Uniswap V4 hook framework built on [EIP-2535 Diamond](https://eips.ethereum.org/EIPS/eip-2535). Each V4 callback is a separately-deployable facet, replaceable post-deploy without migrating LPs or redeploying the hook address.

## Architecture

```
HookDiamond (proxy)
│
├── DiamondCutFacet      ← owner-only upgrade control
├── DiamondLoupeFacet    ← read facet/selector mappings
├── OwnershipFacet       ← ERC-173 ownership
└── HookFacet            ← all 10 V4 callbacks (no-op base)
     ├── beforeInitialize / afterInitialize
     ├── beforeAddLiquidity / afterAddLiquidity
     ├── beforeRemoveLiquidity / afterRemoveLiquidity
     ├── beforeSwap / afterSwap
     └── beforeDonate / afterDonate
```

`HookDiamond.sol` is a pure proxy. Its `fallback()` reads `msg.sig` from a mapping in storage and `delegatecall`s the matching facet. The proxy never knows V4's ABI — assembly `returndatacopy` passes the raw return bytes through, so typed tuple returns (`BeforeSwapDelta`, `BalanceDelta`) work without any ABI encoding at the proxy layer.

All facet state lives in `LibDiamond.AppStorage` at a fixed keccak256 slot (`keccak256("hook.diamond.app.storage")`). Facets never declare storage variables — they call `LibDiamond.appStorage()` to get a storage pointer to the shared struct. This is the AppStorage pattern and is what prevents storage collisions across upgrades.

## Permission bit mining

Uniswap V4 encodes hook permissions in the lower 14 bits of the hook address. For a hook address to be accepted by the pool manager, those bits must match the callbacks that are actually implemented.

`ALL_FLAGS = 0x3FC0` encodes all 8 primary callbacks:

```
beforeInitialize   (1<<13) = 0x2000
afterInitialize    (1<<12) = 0x1000
beforeAddLiquidity (1<<11) = 0x0800
afterAddLiquidity  (1<<10) = 0x0400
beforeRemoveLiquidity (1<<9) = 0x0200
afterRemoveLiquidity  (1<<8) = 0x0100
beforeSwap (1<<7) = 0x0080
afterSwap  (1<<6) = 0x0040
```

The deploy script mines a CREATE2 salt until `uint160(address(diamond)) & ALL_FLAGS == ALL_FLAGS`, then deploys with that salt. The hook address is stable as long as constructor arguments and bytecode don't change.

```bash
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

## How to extend

Fork this repo and add your callback logic in a new facet. The only rule: use `LibDiamond.appStorage()` for any state you need to persist.

**Step 1 — Add your state to AppStorage** (`src/libraries/LibDiamond.sol`):

```solidity
struct AppStorage {
    uint256 swapCount;  // existing example field
    // add your fields here
    mapping(address => uint256) userDeposits;
}
```

**Step 2 — Write your facet**:

```solidity
// src/facets/hooks/MyBeforeSwapFacet.sol
contract MyBeforeSwapFacet {
    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        LibDiamond.AppStorage storage s = LibDiamond.appStorage();
        s.swapCount++;
        // your logic here
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
```

**Step 3 — Replace the selector via `diamondCut`**:

```solidity
MyBeforeSwapFacet newFacet = new MyBeforeSwapFacet();
bytes4[] memory sels = new bytes4[](1);
sels[0] = IHooks.beforeSwap.selector;

IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
cuts[0] = IDiamondCut.FacetCut({
    facetAddress: address(newFacet),
    action: IDiamondCut.FacetCutAction.Replace,
    functionSelectors: sels
});

IDiamondCut(address(diamond)).diamondCut(cuts, address(0), bytes(""));
```

The hook address never changes. Existing pools keep their reference. No LP migration required.

Replacing multiple callbacks at once is supported — add them all to the `cuts` array in a single `diamondCut` call (atomic).

## Development

```bash
git clone <repo>
cd hook-diamond
forge install
forge build
forge test
```

Requirements: [Foundry](https://book.getfoundry.sh/), solc 0.8.24. `via_ir = true` is set in `foundry.toml` and is required — facet contracts hit stack-depth limits without the IR pipeline.

## Project structure

```
src/
  HookDiamond.sol                 ← proxy entry point
  libraries/LibDiamond.sol        ← Diamond storage + cut logic + AppStorage
  interfaces/                     ← IDiamondCut, IDiamondLoupe, IERC173, IERC165
  facets/
    DiamondCutFacet.sol
    DiamondLoupeFacet.sol
    OwnershipFacet.sol
    hooks/
      HookFacet.sol               ← no-op base for all 10 callbacks
      ExampleBeforeSwapFacet.sol  ← example override with AppStorage usage
script/
  Deploy.s.sol                    ← CREATE2 deploy with permission-bit salt search
  HookMiner.sol                   ← brute-force CREATE2 salt finder
test/
  HookDiamond.t.sol               ← routing tests for all 10 callbacks
  DiamondCut.t.sol                ← upgrade + access-control tests
```
