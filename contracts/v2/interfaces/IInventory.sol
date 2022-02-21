// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.6;

/**
 * @title Inventory Interface
 */
interface IInventory {
    struct Item {
        uint256 templateId; // id of Template in the itemTemplates array
        uint8 feature1;
        uint8 feature2;
        uint8 feature3;
        uint8 feature4;
        uint8 equipmentPosition;
        bool burned;
    }

    /**
     * @dev External function to create item from templates. This function can be called by approved games only.
     * @param _templateId Id of template
     * @param _feature1 Feature 1
     * @param _feature2 Feature 2
     * @param _feature3 Feature 3
     * @param _feature4 Feature 4
     * @param _equipmentPosition Equipment position
     * @return Token Id
     */
    function createFromTemplate(
        uint256 _templateId,
        uint8 _feature1,
        uint8 _feature2,
        uint8 _feature3,
        uint8 _feature4,
        uint8 _equipmentPosition
    ) external returns (uint256);

    /**
     * @dev External function to get the Item of Inventory.
     * @param _tokenId Token id
     */
    function allItems(uint256 _tokenId) external view returns (Item memory);

    /**
     * @dev External function to get the token counts the account owned.
     * @param _account Address of token owner
     * @param _id Token id
     * @return Token counts
     */
    function balanceOf(address _account, uint256 _id)
        external
        view
        returns (uint256);

    /**
     * @dev External function to transfer the token.
     * @param _from Sender address
     * @param _to Receiver address
     * @param _id Token id
     * @param _amount Token amount
     * @param _data Data array
     */
    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _id,
        uint256 _amount,
        bytes memory _data
    ) external;
}
