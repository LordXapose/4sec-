// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AMMPair} from "./AMMPair.sol"

/// @title AMMFactory
/// @notice Deploys one canonical AMMPair per unordered token pair and indexes them.
contract AMMFactory {
    // token0 => token1 => pair (stored under the sorted ordering)
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 index);

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "IDENTICAL_TOKENS");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "PAIR_EXISTS");

        // CREATE2 with the sorted pair as salt => deterministic, collision-free address.
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        pair = address(new AMMPair{salt: salt}(token0, token1));

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // both directions point to the same pool
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length - 1);
    }
}
