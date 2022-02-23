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
     * @dev External function to get the user balance.
     * @param _account Address of token owner
     * @return Balance.
     */
    function balanceOf(address _account)
        external
        view
        returns (uint256);

    /**
     * @dev External function to transfer the token.
     * @param _from Sender address
     * @param _to Receiver address
     * @param _id Token id
     * @param _data Data array
     */
    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _id,
        bytes memory _data
    ) external;

    /**
     * @dev External function to get owned items of _owner.
     * @param _owner Player whose items we want to look at.
     * @return All tokenIds the _owner owns.
     */
    function getItemsByOwner(
        address _owner
    ) 
        external 
        view 
        returns(uint[] memory) ;

    /**
     * @dev External function to get templateIds of given tokenIds.
     * @param _tokenIds The tokenIds we want to look at.
     * @return Array of templateIds corresponding to the tokenIds.
     */
    function getTemplateIDsByTokenIDs(
        uint[] memory _tokenIds
    )
        external
        view
        returns(uint[] memory);

    /**
     * @dev Total supply of any one item owned by _owner Ask for example how many of "Torch" item does the _owner have 
     * @param _templateId The templateId we want to get a count for.
     * @param _owner The owner of the templateId.
     * @return Count of how many of this templateId owner owns.
     */
    function getIndividualOwnedCount(
        uint256 _templateId,
        address _owner
    )
        external 
        view 
        returns(uint256);

    function ownerOf(uint256 tokenId) external view returns (address owner);
}
