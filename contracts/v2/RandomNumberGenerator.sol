// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ITripleTriad.sol";

/**
 * @title RandomNumberGenerator Contract
 */
contract RandomNumberGenerator is VRFConsumerBase, Ownable {
    using SafeERC20 for IERC20;

    bytes32 internal keyHash;
    uint256 internal fee;

    address public tripleTriad;

    /// @notice Event emitted when contract has deployed.
    event RandomNumberGeneratorDeployed();

    /// @notice Event emitted when chainlink verified random number arrived or requested.
    event randomNumberArrived(
        bool arrived,
        uint256 randomNumber,
        bytes32 batchID
    );

    /// @notice Event emitted when triple triad contract address has set.
    event TripleTriadAddressSet(address tripleTriad);

    /// @notice Event emitted when owner withdrew the ETH.
    event EthWithdrew(address receiver);

    /// @notice Event emitted when owner withdrew the ERC20 token.
    event ERC20TokenWithdrew(address receiver);

    modifier onlyTripleTriad() {
        require(
            msg.sender == tripleTriad,
            "RandomNumberGenerator: Caller is not the Triple Triad contract address"
        );
        _;
    }

    /**
     * Constructor inherits VRFConsumerBase
     *
     * Network: Ethereum Mainnet
     * Chainlink VRF Coordinator address: 0xf0d54349aDdcf704F77AE15b96510dEA15cb7952
     * LINK token address:                0x514910771AF9Ca656af840dff83E8264EcF986CA
     * Key Hash:                          0xAA77729D3466CA35AE8D28B3BBAC7CC36A5031EFDC430821C02BC31A238AF445
     * Fee : 2 LINK
     */
    constructor(
        address _vrfCoordinator,
        address _link,
        bytes32 _keyHash,
        uint256 _fee,
        address _tripleTriad
    )
        VRFConsumerBase(
            _vrfCoordinator, // VRF Coordinator
            _link // LINK Token
        )
    {
        keyHash = _keyHash;
        fee = _fee;
        tripleTriad = _tripleTriad;

        emit RandomNumberGeneratorDeployed();
    }

    /**
     * @dev External function to request randomness and returns request Id. This function can be called by only triple triad.
     */
    function requestRandomNumber()
        external
        onlyTripleTriad
        returns (bytes32 requestId)
    {
        require(
            LINK.balanceOf(address(this)) >= fee,
            "RandomNumberGenerator: Not enough LINK"
        );

        bytes32 _requestId = requestRandomness(keyHash, fee);

        emit randomNumberArrived(false, 0, _requestId);

        return _requestId;
    }

    /**
     * @dev Callback function used by VRF Coordinator. This function calls the playStarterPack method of current game contract with random number.
     * @param _requestId Request Id
     * @param _randomness Random Number
     */
    function fulfillRandomness(bytes32 _requestId, uint256 _randomness)
        internal
        override
    {
        ITripleTriad(tripleTriad).enableClaim(_requestId, _randomness);

        emit randomNumberArrived(true, _randomness, _requestId);
    }

    /**
     * @dev External function to set the triple triad contract address. This function can be called by only owner.
     * @param _tripleTriad New Triple Triad contract address
     */
    function setTripleTriadAddress(address _tripleTriad) external onlyOwner {
        tripleTriad = _tripleTriad;

        emit TripleTriadAddressSet(tripleTriad);
    }

    /**
     * Fallback function to receive ETH
     */
    receive() external payable {}

    /**
     * @dev External function to withdraw ETH in contract. This function can be called only by owner.
     * @param _amount ETH amount
     */
    function withdrawETH(uint256 _amount) external onlyOwner {
        uint256 balance = address(this).balance;
        require(_amount <= balance, "RandomNumberGenerator: Out of balance");

        payable(msg.sender).transfer(_amount);

        emit EthWithdrew(msg.sender);
    }

    /**
     * @dev External function to withdraw ERC-20 tokens in contract. This function can be called only by owner.
     * @param _tokenAddr Address of ERC-20 token
     * @param _amount ERC-20 token amount
     */
    function withdrawERC20Token(address _tokenAddr, uint256 _amount)
        external
        onlyOwner
    {
        IERC20 token = IERC20(_tokenAddr);

        uint256 balance = token.balanceOf(address(this));
        require(_amount <= balance, "RandomNumberGenerator: Out of balance");

        token.safeTransfer(msg.sender, _amount);

        emit ERC20TokenWithdrew(msg.sender);
    }
}
