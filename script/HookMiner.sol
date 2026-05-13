// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mines a CREATE2 salt producing a hook address with the required V4 permission bits.
library HookMiner {
    // All 8 base callbacks: beforeInitialize | afterInitialize | beforeAddLiquidity |
    // afterAddLiquidity | beforeRemoveLiquidity | afterRemoveLiquidity | beforeSwap | afterSwap
    uint160 public constant ALL_FLAGS = 0x3FC0;

    /// @param deployer  The address that will call CREATE2 (msg.sender in the deploy script).
    /// @param flags     Required lower-bits mask (use ALL_FLAGS for all 8 base callbacks).
    /// @param creationCode  type(HookDiamond).creationCode
    /// @param constructorArgs  abi.encode(owner, cuts, init, calldata)
    /// @return hookAddress  The mined address satisfying address & flags == flags.
    /// @return salt         The CREATE2 salt to pass to the deployment.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 bytecodeHash = keccak256(bytecode);
        uint256 saltNum = 0;
        while (true) {
            salt = bytes32(saltNum);
            hookAddress = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash))
                    )
                )
            );
            if (uint160(hookAddress) & flags == flags) break;
            unchecked {
                saltNum++;
            }
        }
    }
}
