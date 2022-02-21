// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.6;

/**
 * @title Triple Triad Interface
 */
interface ITripleTriad {
    /**
     * @dev External function for opening starter pack. This function can be called by only RandomNumberGenerator.
     * @param _requestId Request Id
     * @param _randomness Random Number
     */
    function enableClaim(bytes32 _requestId, uint256 _randomness) external;
}
