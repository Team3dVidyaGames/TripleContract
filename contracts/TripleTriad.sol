// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IInventory.sol";
import "./interfaces/IRandomNumberGenerator.sol";

contract TripleTriad is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Event emitted only on construction.
    event TripleTriadDeployed();

    /// @notice Event emitted when owner withdrew the ETH.
    event EthWithdrew(address owner, uint256 amount);

    /// @notice Event emitted when owner withdrew the ERC20 token.
    event ERC20TokenWithdrew(address owner, address tokenAddr, uint256 amount);

    /// @notice Event emitted when owner added the ranks.
    event RanksAdded(Card[] _cards);

    /// @notice Event emitted when random number has requested.
    event RandomNumberRequested(address user, bytes32 requestId);

    /// @notice Event emitted when pack has opened.
    event PackOpened(address user, uint256[] tokenIds, uint256 openedTime);

    /// @notice Event emitted when new game has started.
    event NewGameStarted(address player, uint256 gaeId);

    /// @notice Event emitted when player joined the game.
    event GameJoined(address player, uint256 gameId);

    /// @notice Event emitted when player put the card.
    event CardPlaced(
        address user,
        uint256 gameId,
        uint256 cardId,
        uint8 position
    );

    /// @notice Event emitted when card has captured.
    event CardCaptured(address user, uint256 cardSide);

    /// @notice Event emitted when score has assigned.
    event ScoresAssigned(uint8 playerScore, uint8 opponentScore);

    /// @notice Event emitted when game has finished.
    event GameFinished(uint256 gameId, address winner);

    /// @notice Event emitted when the winner has claimed the card.
    event CardClaimed(address winner, uint256 cardId);

    /// @notice Event emitted when the cards have added.
    event CardsAdded(address user, uint256[5] cards);

    /// @notice Event emitted when owner withdrew the nft.
    event NFTWithdrew(address owner, uint256 tokenId, uint256 amount);

    // Game data
    struct GameData {
        address player; // game opener
        address opponent; // game joiner
        address turn; // whose turn it currently is?
        address winner; // who won this game? 0x0 can either mean a draw or ongoing game
        uint256[5] playerHand; // tokenIds from the player hand
        uint256[5] opponentHand; // tokenIds from the opponent hand
        uint256 startDate; // game creation date
        uint256 endDate; // time at which the game ends
        uint8 playerScore; // player score
        uint8 opponentScore; // opponent score
        uint8 cardsOnBoard; // counts how many cards on board
        uint8 avgOfTopTwo; // This is used to determine the average weight of a player's hand. It's this game's "difficulty level", set by Player A upon creation
        bool gameOpen; // is the game open to join?
        bool gameFinished; // has the game concluded?
        bool noMercy; // if set to true in startNewGame() the joinGame() doesn't check for fair hand
    }

    // A basic card struct
    struct Card {
        uint256 templateId; // same as in Inventory
        uint8 top;
        uint8 right;
        uint8 bottom;
        uint8 left;
    }

    // The range of Triple Triad card NFTs in Inventory
    uint256 public templateId_START;
    uint256 public templateId_END;

    // Unix timestamp for how long a game is allowed to stay open
    uint32 public timeLimit;

    // All games ever created
    GameData[] public gameData;

    // Ranks for level 1 cards for use in openStarterPack()
    Card[] public ranks;

    IInventory public Inventory;

    IRandomNumberGenerator public RNG;

    // GameID => (CardID => Card owner on the board)
    // Note: this is not the same as inv.ownerOf()
    mapping(uint256 => mapping(uint256 => address)) public ownerOnBoard;

    // Player hand status
    // For player to be able to open a new game or join an existing game, they need to have 5 owned cards in hand
    mapping(address => bool) public playerHasBuiltHand;

    // Player address to PlayerHand struct
    mapping(address => uint256[5]) public playerHands;

    // Card positions on the grid in any given game
    // gameID => Grid(position => cardID)
    mapping(uint256 => mapping(uint8 => uint256)) public positions;

    // Has player opened a starter pack?
    mapping(address => bool) public starterPackOpened;

    // Is the player currently in any game?
    mapping(address => bool) public ingame;

    mapping(bytes32 => address) public requestToUser;

    // Require the player to not be in any game (you can only play 1 game at a time)
    modifier notInAnyGame() {
        require(!ingame[msg.sender], "Triple Triad: Only one game at a time");
        _;
    }

    // Require that the game is not finished
    modifier notFinished(uint256 _gameId) {
        GameData memory data = gameData[_gameId];
        require(!data.gameFinished, "Triple Triad: Game finished");
        _;
    }

    // Require msg.sender to have 5 cards in hand (tokenIds)
    modifier hasBuiltHand() {
        require(
            playerHasBuiltHand[msg.sender],
            "Triple Triad: Player has not built hand"
        );
        _;
    }

    /**
     * @dev Constructor function
     * @param _Inventory Interface of Inventory contract
     * @param _Inventory Interface of RandomNumberGenerator contract
     * @param _timeLimit Ending time of game
     * @param _templateId_START The starting temlate id range of Triple Triad card NFTs in Inventory
     * @param _templateId_END The ending temlate id range of Triple Triad card NFTs in Inventory
     */
    constructor(
        IInventory _Inventory,
        IRandomNumberGenerator _RNG,
        uint32 _timeLimit,
        uint256 _templateId_START,
        uint256 _templateId_END
    ) {
        Inventory = _Inventory;
        RNG = _RNG;
        timeLimit = _timeLimit;
        templateId_START = _templateId_START;
        templateId_END = _templateId_END;

        emit TripleTriadDeployed();
    }

    /**
     * @dev External function to add ranks for level 1 cards so openStarterPack() knows the correct item features and templateIds to use. 
            This function can be called only by owner.
     * @param _cards Array of cards
     */
    function addRanks(Card[] memory _cards) external onlyOwner {
        for (uint256 i = 0; i < _cards.length; i++) {
            ranks.push(_cards[i]);
        }

        emit RanksAdded(_cards);
    }

    /**
     * @dev External function to give the user 7 random level 1 cards from ranks. Use chainlink for generating random number.
     *      Only request random number and after getting random number from chainlink, playStarterPack method is called automatically.
     */
    function openStarterPack() external {
        require(
            !starterPackOpened[msg.sender],
            "Triple Triad: Starter pack already claimed"
        );
        require(
            ranks.length > 0,
            "Triple Triad: Admin has not added ranks yet"
        );
        starterPackOpened[msg.sender] = true;
        bytes32 requestId = RNG.requestRandomNumber();
        requestToUser[requestId] = msg.sender;

        emit RandomNumberRequested(msg.sender, requestId);
    }

    /**
     * @dev External function to give the user 7 random level 1 cards from ranks. This function can be called only by RandomNumberGenerator contract.
     * @param _requestId Request id of random number
     * @param _randomness Chainlink random number
     */
    function playStarterPack(bytes32 _requestId, uint256 _randomness) external {
        require(
            msg.sender == address(RNG),
            "Triple Triad: Caller is not the RandomNumberGenerator"
        );

        address user = requestToUser[_requestId];

        uint256[] memory tokenIds = new uint256[](7);

        for (uint256 i = 0; i < 7; i++) {
            uint256 rand = uint256(
                keccak256(abi.encode(_randomness, i, block.timestamp))
            ) % ranks.length;

            uint256 tokenId = Inventory.createItemFromTemplate(
                ranks[rand].templateId,
                ranks[rand].top,
                ranks[rand].right,
                ranks[rand].bottom,
                ranks[rand].left,
                1, // equipmentPosition for Triple Triad cards is their level
                1,
                user
            );
            tokenIds[i] = tokenId;
        }

        emit PackOpened(user, tokenIds, block.timestamp);
    }

    /**
     * @dev External function to get the tempalte ids that users own.
     * @return An array of template ids (items that fall within the Triple Triad templates range in Inventory) that _player owns
     * @return Array with the total counts for each of these templateIds the _player owns
     */
    function deckOf()
        external
        view
        returns (uint256[] memory, uint256[] memory)
    {
        // Fixed arrays of 110 because Triple Triad has 110 cards total
        uint256[] memory playerDeck = new uint256[](110);
        uint256[] memory cardCount = new uint256[](110);
        uint256 index;
        uint256 count;

        for (uint256 i = templateId_START; i <= templateId_END; i++) {
            count = Inventory.balanceOf(msg.sender, i);
            if (count > 0) {
                // _player owns this card!
                playerDeck[index] = i;
                cardCount[index] = count;
                index++;
            }
        }

        return (playerDeck, cardCount);
    }

    /**
     * @dev External function to add user selected cards from the Inventory contract into the playerHand array that the user can play with.
     * @param _cardsToAdd Cards array to add
     */
    function buildPlayerHand(uint256[5] memory _cardsToAdd) external {
        for (uint256 i = 0; i < 5; i++) {
            uint256 templateId = Inventory.allItems(_cardsToAdd[i]).templateId;
            require(
                Inventory.balanceOf(msg.sender, _cardsToAdd[i]) > 0,
                "Triple Triad: Player is not the owner of this card"
            );
            require(
                templateId >= templateId_START && templateId <= templateId_END,
                "Triple Triad: Trying to add invalid card"
            );
        }

        playerHands[msg.sender] = _cardsToAdd;
        playerHasBuiltHand[msg.sender] = true;

        emit CardsAdded(msg.sender, _cardsToAdd);
    }

    /**
     * @dev External function to start the new game. This functon can be called when caller is not in any other game and have built a hand.
     * @param _noMercy Bool variable to check the fair hand
     */
    function startNewGame(bool _noMercy) external notInAnyGame hasBuiltHand {
        ingame[msg.sender] = true;

        gameData.push(
            GameData(
                msg.sender,
                address(0),
                msg.sender,
                address(0),
                playerHands[msg.sender],
                [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)],
                block.timestamp,
                block.timestamp + timeLimit,
                5,
                5,
                0,
                averageOfTopTwo(playerHands[msg.sender]),
                true,
                false,
                _noMercy
            )
        );

        for (uint256 i = 0; i < 5; i++) {
            Inventory.safeTransferFrom(
                msg.sender,
                address(this),
                playerHands[msg.sender][i],
                1,
                ""
            );
        }

        emit NewGameStarted(msg.sender, gameData.length - 1);
    }

    /**
     * @dev External function to join the new game. This functon can be called when caller is not in any other game and have built a hand. 
            Game must be opened and player must have the average of two best cards from hand to be <= from the game's avgOfTopTwo (for fair play)
     * @param _gameId Game Id
     */
    function joinGame(uint256 _gameId) external notInAnyGame hasBuiltHand {
        // set ingame status
        ingame[msg.sender] = true;

        GameData storage data = gameData[_gameId];
        require(data.gameOpen, "Triple Triad: This game is not open");

        if (data.noMercy) {
            // Require opponent hand to be fair
            require(
                averageOfTopTwo(playerHands[msg.sender]) <=
                    data.avgOfTopTwo + 1,
                "Triple Triad: Hand has unfair advantage"
            );
        }

        data.opponent = msg.sender;
        data.opponentHand = playerHands[msg.sender];
        data.gameOpen = false;

        for (uint256 i = 0; i < 5; i++) {
            Inventory.safeTransferFrom(
                msg.sender,
                address(this),
                playerHands[msg.sender][i],
                1,
                ""
            );
        }

        emit GameJoined(msg.sender, _gameId);
    }

    /**
     * @dev Private function to calculate the average of top two numbers from player hands.
     * @param _playerHand 5 cards that user owned
     * @return Average value
     */
    function averageOfTopTwo(uint256[5] memory _playerHand)
        private
        pure
        returns (uint8)
    {
        uint256 largest1 = 0;
        uint256 largest2 = 0;
        for (uint256 i = 0; i < _playerHand.length; i++) {
            if (_playerHand[i] > largest1) {
                largest2 = largest1;
                largest1 = _playerHand[i];
            } else if (_playerHand[i] > largest2) {
                largest2 = _playerHand[i];
            }
        }
        return uint8((largest1 + largest2) / 2);
    }

    /**
     * @dev External function to put the card. This function can be called when the game hasn't finished and caller must be the part of the game.
     * @param _gameId Game id
     * @param _cardId Card id
     * @param _position Card position
     */
    function putCard(
        uint256 _gameId,
        uint256 _cardId,
        uint8 _position
    )
        external
        notFinished(_gameId) // Game must not be finished
    {
        GameData storage data = gameData[_gameId];
        require(!data.gameOpen, "Triple Triad: Game needs to be closed first"); // Make sure both players are in the game
        require(
            data.player == msg.sender || data.opponent == msg.sender,
            "Triple Triad: Player not part of the game"
        );
        require(
            data.turn == msg.sender,
            "Triple Triad: Not the msg.sender's turn"
        );
        require(
            !cardIsOnBoard(_gameId, _cardId),
            "Triple Triad: Card already on board"
        );
        require(
            positions[_gameId][_position] == 0,
            "Triple Triad: Position occupied"
        );
        // Check if this was the final or 9th card
        bool isFinalCard;
        if (data.cardsOnBoard > 8) {
            isFinalCard = true;
        }

        // Relinquish turn to the other player
        if (msg.sender == data.player) {
            data.turn = data.opponent;
        } else {
            data.turn = data.player;
        }

        // +1 to card count on board, add card at position in game, set the owner on board (can change in _compareCardValuesAndCapture() if captured )

        data.cardsOnBoard++;
        // Add the card to its position
        positions[_gameId][_position] = _cardId;
        // Add the owner on board
        ownerOnBoard[_gameId][_cardId] = msg.sender;

        emit CardPlaced(msg.sender, _gameId, _cardId, _position);

        // Returns its own events on capture
        compareCardValuesAndCapture(_gameId, _cardId, _position, isFinalCard);
    }

    /**
     * @dev Private function to check whether a given card is already placed on the board or not.
     * @param _gameId Game id
     * @param _cardId Card id
     * @return Bool variable to check the given card is already placed or not
     */
    function cardIsOnBoard(uint256 _gameId, uint256 _cardId)
        private
        view
        returns (bool)
    {
        for (uint8 i = 0; i < 8; i++) {
            if (positions[_gameId][i] == _cardId) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Private function to compare the placed card's values against cards found on the board. 
            Captures cards if values are bigger and the card is not yet one of players' cards.
     * @param _gameId Game id
     * @param _cardId Card id
     * @param _position Card position
     * @param _isFinalCard Bool variable to check if the card is last.
     */
    function compareCardValuesAndCapture(
        uint256 _gameId,
        uint256 _cardId,
        uint8 _position,
        bool _isFinalCard
    ) private {
        GameData memory data = gameData[_gameId];

        bool targetIsPlayer;
        bool targetIsOpponent;

        if (data.player != msg.sender) {
            targetIsPlayer = true;
        } else {
            targetIsOpponent = true;
        }

        // A Card needs to be placed on a _position so we can check its adjecent cards
        require(
            positions[_gameId][_position] == _cardId,
            "Triple Triad: Card is not placed at this position!"
        );

        uint8[] memory placedCard = fetchCardValues(_cardId);

        uint256[] memory adjacentCards = getAdjacentCards(_gameId, _position);

        // Check top card
        if (adjacentCards[0] != 0) {
            uint256 topCard = adjacentCards[0];
            uint8 bottomValue = fetchCardValues(topCard)[2];
            if (
                bottomValue < placedCard[0] &&
                ownerOnBoard[_gameId][topCard] != msg.sender
            ) {
                ownerOnBoard[_gameId][topCard] = msg.sender;
                assignScores(targetIsPlayer, targetIsOpponent, _gameId);
                emit CardCaptured(msg.sender, topCard);
            }
        }

        // Check right card
        if (adjacentCards[1] != 0) {
            uint256 rightCard = adjacentCards[1];
            uint8 leftValue = fetchCardValues(rightCard)[3];
            if (
                leftValue < placedCard[1] &&
                ownerOnBoard[_gameId][rightCard] != msg.sender
            ) {
                ownerOnBoard[_gameId][rightCard] = msg.sender;
                assignScores(targetIsPlayer, targetIsOpponent, _gameId);
                emit CardCaptured(msg.sender, rightCard);
            }
        }

        // Check bottom card
        if (adjacentCards[2] != 0) {
            uint256 bottomCard = adjacentCards[2];
            uint8 topValue = fetchCardValues(bottomCard)[0];
            if (
                topValue < placedCard[2] &&
                ownerOnBoard[_gameId][bottomCard] != msg.sender
            ) {
                ownerOnBoard[_gameId][bottomCard] = msg.sender;
                assignScores(targetIsPlayer, targetIsOpponent, _gameId);
                emit CardCaptured(msg.sender, bottomCard);
            }
        }

        // Check left card
        if (adjacentCards[3] != 0) {
            uint256 leftCard = adjacentCards[3];
            uint8 rightValue = fetchCardValues(leftCard)[1];
            if (
                rightValue < placedCard[3] &&
                ownerOnBoard[_gameId][leftCard] != msg.sender
            ) {
                ownerOnBoard[_gameId][leftCard] = msg.sender;
                assignScores(targetIsPlayer, targetIsOpponent, _gameId);
                emit CardCaptured(msg.sender, leftCard);
            }
        }

        // Final card will finish the game
        if (_isFinalCard) {
            finalize(_gameId);
        }
    }

    /**
     * @dev Private function to get the features of card.
     * @param _cardId Card id
     * @return Array of card values (top, right, bottom, left)
     */
    function fetchCardValues(uint256 _cardId)
        private
        view
        returns (uint8[] memory)
    {
        uint8[] memory features = new uint8[](4);
        features[0] = Inventory.allItems(_cardId).feature1;
        features[1] = Inventory.allItems(_cardId).feature2;
        features[2] = Inventory.allItems(_cardId).feature3;
        features[3] = Inventory.allItems(_cardId).feature4;

        return features;
    }

    /**
     * @dev Private function to get the adjacent cards.
            Refernce grid (3x3 board):
            0--1--2
            3--4--5
            6--7--8
     * @param _gameId Game id
     * @param _position Card position
     * @return Array of adjacent cards
     */
    function getAdjacentCards(uint256 _gameId, uint8 _position)
        private
        view
        returns (uint256[] memory)
    {
        uint256[] memory adjacentCards = new uint256[](4);
        uint256 topCard;
        uint256 rightCard;
        uint256 bottomCard;
        uint256 leftCard;

        if (_position == 0) {
            topCard = 0;
            rightCard = positions[_gameId][1];
            bottomCard = positions[_gameId][3];
            leftCard = 0;
        } else if (_position == 1) {
            topCard = 0;
            rightCard = positions[_gameId][2];
            bottomCard = positions[_gameId][4];
            leftCard = positions[_gameId][0];
        } else if (_position == 2) {
            topCard = 0;
            rightCard = 0;
            bottomCard = positions[_gameId][5];
            leftCard = positions[_gameId][1];
        } else if (_position == 3) {
            topCard = positions[_gameId][0];
            rightCard = positions[_gameId][4];
            bottomCard = positions[_gameId][6];
            leftCard = 0;
        } else if (_position == 4) {
            topCard = positions[_gameId][1];
            rightCard = positions[_gameId][5];
            bottomCard = positions[_gameId][7];
            leftCard = positions[_gameId][3];
        } else if (_position == 5) {
            topCard = positions[_gameId][2];
            rightCard = 0;
            bottomCard = positions[_gameId][8];
            leftCard = positions[_gameId][4];
        } else if (_position == 6) {
            topCard = positions[_gameId][3];
            rightCard = positions[_gameId][7];
            bottomCard = 0;
            leftCard = 0;
        } else if (_position == 7) {
            topCard = positions[_gameId][4];
            rightCard = positions[_gameId][8];
            bottomCard = 0;
            leftCard = positions[_gameId][6];
        } else {
            topCard = positions[_gameId][5];
            rightCard = 0;
            bottomCard = 0;
            leftCard = positions[_gameId][7];
        }

        adjacentCards[0] = topCard;
        adjacentCards[1] = rightCard;
        adjacentCards[2] = bottomCard;
        adjacentCards[3] = leftCard;

        return adjacentCards;
    }

    /**
     * @dev Private function to assign scores.
     * @param _targetIsPlayer Bool variable to check the target player
     * @param _targetIsOpponent Bool variable to check the target opponent
     * @param _gameId Game id
     */
    function assignScores(
        bool _targetIsPlayer,
        bool _targetIsOpponent,
        uint256 _gameId
    ) private {
        GameData storage data = gameData[_gameId];
        if (_targetIsPlayer) {
            data.playerScore--;
            data.opponentScore++;
        }
        if (_targetIsOpponent) {
            data.opponentScore--;
            data.playerScore++;
        }

        emit ScoresAssigned(data.playerScore, data.opponentScore);
    }

    /**
     * @dev Private function to finish the game. Assigns the winner of the game based on current scores. If it's a draw, gives winner status to 0x0
     * @param _gameId Game id
     */
    function finalize(uint256 _gameId) private {
        GameData storage data = gameData[_gameId];

        data.gameFinished = true;
        ingame[data.player] = false;
        ingame[data.opponent] = false;

        address winner;

        if (data.playerScore > data.opponentScore) {
            winner = data.player;
        } else if (data.opponentScore > data.playerScore) {
            winner = data.opponent;
        } else {
            winner = address(0);
        }
        data.winner = winner;

        emit GameFinished(_gameId, winner);
    }

    /**
     * @dev External function to finish the game if it is over time to play.
     * @param _gameId Game id
     */
    function endAbandonedGame(uint256 _gameId) external notFinished(_gameId) {
        GameData memory data = gameData[_gameId];
        require(
            block.timestamp - data.endDate >= timeLimit,
            "Triple Triad: This game is still ongoing"
        );
        finalize(_gameId);
    }

    /**
     * @dev External function to claim a card from a finished game.
     * @param _gameId Game id
     * @param _cardId Card id
     */
    function claimCard(uint256 _gameId, uint256 _cardId) external {
        GameData memory data = gameData[_gameId];

        require(
            msg.sender == data.winner,
            "Triple Triad: Caller is not the winner of this game"
        );

        if (msg.sender == data.player) {
            for (uint256 i = 0; i < 5; i++) {
                Inventory.safeTransferFrom(
                    address(this),
                    data.player,
                    playerHands[data.player][i],
                    1,
                    ""
                );
                if (data.opponentHand[i] == _cardId) {
                    Inventory.safeTransferFrom(
                        address(this),
                        data.player,
                        _cardId,
                        1,
                        ""
                    );
                    playerHasBuiltHand[data.opponent] = false;
                } else {
                    Inventory.safeTransferFrom(
                        address(this),
                        data.opponent,
                        playerHands[data.opponent][i],
                        1,
                        ""
                    );
                }
            }
        } else {
            for (uint256 i = 0; i < 5; i++) {
                Inventory.safeTransferFrom(
                    address(this),
                    data.opponent,
                    playerHands[data.opponent][i],
                    1,
                    ""
                );
                if (data.playerHand[i] == _cardId) {
                    Inventory.safeTransferFrom(
                        address(this),
                        data.opponent,
                        _cardId,
                        1,
                        ""
                    );
                    playerHasBuiltHand[data.player] = false;
                } else {
                    Inventory.safeTransferFrom(
                        address(this),
                        data.player,
                        playerHands[data.player][i],
                        1,
                        ""
                    );
                }
            }
        }

        emit CardClaimed(msg.sender, _cardId);
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
        require(_amount <= balance, "Triple Triad: Out of balance");

        payable(msg.sender).transfer(_amount);

        emit EthWithdrew(msg.sender, _amount);
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
        require(_amount <= balance, "Triple Triad: Out of balance");

        token.safeTransfer(msg.sender, _amount);

        emit ERC20TokenWithdrew(msg.sender, _tokenAddr, _amount);
    }

    /**
     * @dev External function to withdraw the nfts. This function can be called only by owner.
     * @param _tokenId NFT token id
     * @param _amount Token amount
     */
    function withdrawNFT(uint256 _tokenId, uint256 _amount) external onlyOwner {
        Inventory.safeTransferFrom(
            address(this),
            msg.sender,
            _tokenId,
            _amount,
            ""
        );

        emit NFTWithdrew(msg.sender, _tokenId, _amount);
    }
}
