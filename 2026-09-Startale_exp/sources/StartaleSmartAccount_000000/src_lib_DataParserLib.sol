// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library DataParserLib {
  /// @dev Parses the `userOp.signature` to extract the module type, module initialization data,
  ///      enable mode signature, and user operation signature. The `userOp.signature` must be
  ///      encoded in a specific way to be parsed correctly.
  /// @param packedData The packed signature data, typically coming from `userOp.signature`.
  /// @return module The address of the module.
  /// @return moduleType The type of module as a `uint256`.
  /// @return moduleInitData Initialization data specific to the module.
  /// @return enableModeSignature Signature used to enable the module mode.
  /// @return userOpSignature The remaining user operation signature data.
  function parseEnableModeData(bytes calldata packedData)
    internal
    pure
    returns (
      address module,
      uint256 moduleType,
      bytes calldata moduleInitData,
      bytes calldata enableModeSignature,
      bytes calldata userOpSignature
    )
  {
    uint256 p;
    assembly ("memory-safe") {
      let dataSize := calldatasize() // Get total calldata size
      p := packedData.offset

      // Check if reading module address is within bounds
      if gt(add(p, 0x14), dataSize) { revert(0, 0) }
      module := shr(96, calldataload(p))

      p := add(p, 0x14)
      // Check if reading moduleType is within bounds
      if gt(add(p, 0x20), dataSize) { revert(0, 0) }
      moduleType := calldataload(p)

      // Check if reading moduleInitData length pointer (32 bytes) is within bounds
      if gt(add(add(p, 0x20), 0x20), dataSize) { revert(0, 0) }
      moduleInitData.length := shr(224, calldataload(add(p, 0x20)))
      moduleInitData.offset := add(p, 0x24)
      // Boundary Check: Ensure the calculated moduleInitData segment (offset + length)
      // does not exceed the actual calldata size. Revert if it does.
      if gt(add(moduleInitData.offset, moduleInitData.length), dataSize) { revert(0, 0) }
      p := add(moduleInitData.offset, moduleInitData.length)

      // Check if reading enableModeSignature length is within bounds
      if gt(add(p, 0x20), dataSize) { revert(0, 0) }
      enableModeSignature.length := shr(224, calldataload(p))
      enableModeSignature.offset := add(p, 0x04)
      // Boundary Check: Ensure enableModeSignature segment doesn't exceed calldata
      if gt(add(enableModeSignature.offset, enableModeSignature.length), dataSize) { revert(0, 0) }
      p := sub(add(enableModeSignature.offset, enableModeSignature.length), packedData.offset)
    }
    userOpSignature = packedData[p:];
  }

  /// @dev Parses the data to obtain types and initdata's for Multi Type module install mode
  /// @param initData Multi Type module init data, abi.encoded
  function parseMultiTypeInitData(bytes calldata initData)
    internal
    pure
    returns (uint256[] calldata types, bytes[] calldata initDatas)
  {
    // equivalent of:
    // (types, initDatas) = abi.decode(initData,(uint[],bytes[]))
    assembly ("memory-safe") {
      let dataSize := calldatasize() // Get total calldata size
      let offset := initData.offset
      let baseOffset := offset

      // Check if reading first pointer is within bounds
      if gt(add(offset, 0x20), dataSize) { revert(0, 0) }
      let dataPointer := add(baseOffset, calldataload(offset))

      // Check if reading types array length is within bounds
      if gt(add(dataPointer, 0x20), dataSize) { revert(0, 0) }
      types.offset := add(dataPointer, 32)
      types.length := calldataload(dataPointer)
      // Check if types array data doesn't exceed calldata
      if gt(add(types.offset, mul(types.length, 32)), dataSize) { revert(0, 0) }
      offset := add(offset, 32)

      // Check if reading second pointer is within bounds
      if gt(add(offset, 0x20), dataSize) { revert(0, 0) }
      dataPointer := add(baseOffset, calldataload(offset))

      // Check if reading initDatas array length is within bounds
      if gt(add(dataPointer, 0x20), dataSize) { revert(0, 0) }
      initDatas.offset := add(dataPointer, 32)
      initDatas.length := calldataload(dataPointer)
      // Check if initDatas array data doesn't exceed calldata
      if gt(add(initDatas.offset, mul(initDatas.length, 32)), dataSize) { revert(0, 0) }
    }
  }
}
