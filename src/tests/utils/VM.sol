// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

abstract contract VM {
    // Loads a storage slot from an address (who, slot)
    function load(address,bytes32) external virtual returns (bytes32);

    // Stores a value to an address' storage slot, (who, slot, value)
    function store(address,bytes32,bytes32) external virtual;

    // Sets the block timestamp to x
    function warp(uint256 x) public virtual;

    // Sets the block number to x
    function roll(uint256 x) public virtual;

    function ffi(string[] calldata) public virtual returns (bytes memory);

    // Sets the *next* call's msg.sender to be the input address, and the tx.origin to be the second input
    function prank(address,address) virtual external;

    // Sets all subsequent calls' msg.sender to be the input address until `stopPrank` is called, and the tx.origin to be the second input
    function startPrank(address,address) virtual external;

    // Resets subsequent calls' msg.sender to be `address(this)`
    function stopPrank() virtual external;

    // Labels an address in call traces
    function label(address, string calldata) virtual external;

    // If the condition is false, discard this run's fuzz inputs and generate new ones
    function assume(bool) virtual external;
}
