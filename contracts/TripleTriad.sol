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
    event EthWithdrew(address receiver);

    /// @notice Event emitted when owner withdrew the ERC20 token.
    event ERC20TokenWithdrew(address receiver);

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

    uint8 public deviation = 1;

    // All games ever created
    GameData[] public gameData;

    // Ranks for level 1 cards for use in openStarterPack()
    Card[] public ranks;

    IInventory public Inventory;

    IRandomNumberGenerator RNG;

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
        uint256 _timeLimit,
        uint256 _templateId_START,
        uint256 _templateId_END
    ) {
        Inventory = _Inventory;
        timeLimit = uint32(_timeLimit);
        templateId_START = _templateId_START;
        templateId_END = _templateId_END;
        RNG = _RNG;

        emit TripleTriadDeployed();
    }

    /**
     * @dev External function to add ranks for level 1 cards so openStarterPack() knows the correct item features and templateIds to use. 
            This function can be called only by owner.
     * @param _cards Array of card struct
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
     * @dev External function to get the tempalteIds that users owns.
     * @return An array of templateIds (items that fall within the Triple Triad templates range in Inventory) that _player owns
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
     * @return Array with 5 card ID's (tokenIds from Inventory)
     */
    function buildPlayerHand(uint256[5] memory cardsToAdd)
        external
        returns (uint256[5] memory)
    {
        for (uint256 i = 0; i < 5; i++) {
            uint256 templateId = Inventory.allItems(cardsToAdd[i]).templateId;
            require(
                Inventory.balanceOf(msg.sender, cardsToAdd[i]) > 0,
                "Triple Triad: Player is not the owner of this card"
            );
            require(
                templateId >= templateId_START && templateId <= templateId_END,
                "Triple Triad: Trying to add invalid card"
            );
        }

        return _buildPlayerHand(cardsToAdd, msg.sender);
    }

    /**
     * @dev Private function to build the player hand. This functon can be called after checking passed in buildPlayerHand().
     * @return Array with 5 card ID's (tokenIds from Inventory)
     */
    function _buildPlayerHand(uint256[5] memory _cardsToAdd, address _player)
        private
        returns (uint256[5] memory)
    {
        playerHands[_player] = _cardsToAdd;
        playerHasBuiltHand[_player] = true;

        return _cardsToAdd;
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
            // Note: allows for a set +deviation
            require(
                averageOfTopTwo(playerHands[msg.sender]) <=
                    data.avgOfTopTwo + deviation,
                "Triple Triad: Hand has unfair advantage"
            );
        }

        data.opponent = msg.sender;
        data.opponentHand = playerHands[msg.sender];
        data.gameOpen = false;

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

    /* Place a card on the 3x3 grid 
    
    requirements:
    game must not be finished,
    msg.sender must be part of the game,
    it must be the players' turn,
    the placed card must not be on the board,
    the position on grid must be open,
    the final or 9th card placed must end the game 
    */
    function putCard(
        uint256 _gameId,
        uint256 _cardId,
        uint8 _position
    )
        public
        notFinished(_gameId) // Game must not be finished
    {
        GameData storage data = gameData[_gameId];
        require(!data.gameOpen, "Triple Triad: Game needs to be closed first"); // Make sure both players are in the game
        require(
            playerInGame(_gameId),
            "Triple Triad: Player not part of the game"
        );
        require(
            data.turn == msg.sender,
            "Triple Triad: Not the msg.sender's turn"
        );
        require(
            !_cardIsOnBoard(_gameId, _cardId),
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
        _putCard(_gameId, _cardId, _position);

        //    emit CardPlaced(msg.sender, _gameId, _cardId, _position);

        // Returns its own events on capture
        _compareCardValuesAndCapture(_gameId, _cardId, _position, isFinalCard);
    }

    // Finalize abandoned game that has timeLimit passed and is not yet finished
    function endAbandonedGame(uint256 _gameId) public notFinished(_gameId) {
        require(timeIsUp(_gameId), "Triple Triad: This game is still ongoing");
        _finalize(_gameId);
    }

    // Claim a card from a finished game
    function claimCard(uint256 _gameId, uint256 _cardId) public {
        GameData storage data = gameData[_gameId];

        // Require msg.sender to be the winner of this game
        // So that only the winner can pick a card from the other players' hand
        require(
            msg.sender == data.winner,
            "Triple Triad: msg.sender is not the winner of this game"
        );

        if (msg.sender == data.player) {
            // data.opponent has lost the game...
            for (uint256 i = 0; i < 5; i++) {
                if (data.opponentHand[i] == _cardId) {
                    // transfer the token
                    Inventory.transferFrom(data.opponent, data.player, _cardId);
                    playerHasBuiltHand[data.opponent] = false;
                }
            }
        } else if (msg.sender == data.opponent) {
            // data.player has lost the game...
            for (uint256 i = 0; i < 5; i++) {
                if (data.playerHand[i] == _cardId) {
                    Inventory.transferFrom(data.player, data.opponent, _cardId);
                    playerHasBuiltHand[data.player] = false;
                }
            }
        } else {
            // who the fuck is msg.sender?
            revert();
        }
    }

    function listOpenGames() public view returns (uint256[] memory) {
        return _allOpenGames();
    }

    /* INTERNAL FUNCTIONS */

    // Return an array of all OPEN game IDs
    function _allOpenGames() public view returns (uint256[] memory) {
        uint256[] memory result;
        uint256 index;
        for (uint256 i = 0; i < gameData.length; i++) {
            GameData storage data = gameData[i];
            if (data.gameOpen) {
                result[index] = i;
            }
            index++;
        }
        return result;
    }

    // Checks if game time limit is reached
    function timeIsUp(uint256 _gameId) public view returns (bool) {
        GameData storage data = gameData[_gameId];
        bool status;

        // IS THIS RIGHT?
        if (now - data.endDate >= timeLimit) {
            status = true;
        }
        return status;
    }

    // Write some additional card data for games
    function _putCard(
        uint256 _gameId,
        uint256 _cardId,
        uint8 _position
    ) internal {
        GameData storage data = gameData[_gameId];
        // Add +1 card on the counter
        data.cardsOnBoard++;
        // Add the card to its position
        positions[_gameId][_position] = _cardId;
        // Add the owner on board
        ownerOnBoard[_gameId][_cardId] = msg.sender;
    }

    /*  Function to compare the placed card's values against cards found on the board.
        Captures cards if values are bigger and the card is not yet one of players' cards */
    function _compareCardValuesAndCapture(
        uint256 _gameId,
        uint256 _cardId,
        uint8 _position,
        bool _isFinalCard
    ) public {
        address cardPlacer = msg.sender;

        // Who is the target?
        bool targetIsPlayer;
        bool targetIsOpponent;

        if (_playerRoleInGame(_gameId) != msg.sender) {
            // Player (game starter) is NOT putting the card right now, must be opponent
            targetIsPlayer = true;
        }

        if (_opponentRoleInGame(_gameId) != msg.sender) {
            // Opponent (game joiner) is NOT putting the card right now, must be player
            targetIsOpponent = true;
        }

        // A Card needs to be placed on a _position so we can check its adjecent cards
        require(
            positions[_gameId][_position] == _cardId,
            "Triple Triad: Card is not placed at this position!"
        );

        uint8[] memory placedCard = _fetchCardValues(_cardId);

        /*  ID's of cards adjacent to placedCard: [top, right, bottom, left]
            ID of 0 means there is no card at that position 
            so if _adjacentCards[0][n] = 0 then there is no card! */
        uint256[] memory _adjacentCards = _getAdjacentCards(_gameId, _position);

        /*  Need to check if an actual card (non zero value) is adjacent
        
            Think like this: placedCard is the "center" card to check all adjacent cards against
            If a card is found adjacent to placedCard, compare those values
            
            Reference:
            adjacentCards[0] = topCardID;
            adjacentCards[1] = rightCardID;
            adjacentCards[2] = bottomCardID;
            adjacentCards[3] = leftCardID;
            
            And for values:
            0 - top
            1 - right 
            2 - bottom 
            3 - left 
        */

        // Check top card
        if (_adjacentCards[0] != 0) {
            uint256 topCard = _adjacentCards[0];
            // Get top card's bottom value
            uint8 bottomValue = _fetchCardValues(topCard)[2];
            // If value is smaller & is not the player's card
            if (
                bottomValue < placedCard[0] &&
                ownerOnBoard[_gameId][topCard] != cardPlacer
            ) {
                // Capture the adjacent card
                ownerOnBoard[_gameId][topCard] = cardPlacer;
                _assignScores(targetIsPlayer, targetIsOpponent, _gameId);
                //    emit CardCaptured(cardPlacer, topCard);
            }
        }
        // Check right card
        if (_adjacentCards[1] != 0) {
            uint256 rightCard = _adjacentCards[1];
            // Get right card's left value
            uint8 leftValue = _fetchCardValues(rightCard)[3];
            if (
                leftValue < placedCard[1] &&
                ownerOnBoard[_gameId][rightCard] != cardPlacer
            ) {
                // Capture the adjacent card
                ownerOnBoard[_gameId][rightCard] = cardPlacer;
                _assignScores(targetIsPlayer, targetIsOpponent, _gameId);
                //    emit CardCaptured(cardPlacer, rightCard);
            }
        }
        // Check bottom card
        if (_adjacentCards[2] != 0) {
            uint256 bottomCard = _adjacentCards[2];
            // Get bottom card's top value
            uint8 topValue = _fetchCardValues(bottomCard)[0];
            if (
                topValue < placedCard[2] &&
                ownerOnBoard[_gameId][bottomCard] != cardPlacer
            ) {
                // Capture the adjacent card
                ownerOnBoard[_gameId][bottomCard] = cardPlacer;
                _assignScores(targetIsPlayer, targetIsOpponent, _gameId);
                //   emit CardCaptured(cardPlacer, bottomCard);
            }
        }
        // Check left card
        if (_adjacentCards[3] != 0) {
            uint256 leftCard = _adjacentCards[3];
            // Get left card's right value
            uint8 rightValue = _fetchCardValues(leftCard)[1];
            if (
                rightValue < placedCard[3] &&
                ownerOnBoard[_gameId][leftCard] != cardPlacer
            ) {
                // Capture the adjacent card
                ownerOnBoard[_gameId][leftCard] = cardPlacer;
                _assignScores(targetIsPlayer, targetIsOpponent, _gameId);
                //   emit CardCaptured(cardPlacer, leftCard);
            }
        }

        // Final card will finish the game
        if (_isFinalCard) {
            _finalize(_gameId);
        }
    }

    // Finish the game (declade internal)
    function _finalize(uint256 _gameId) public {
        GameData storage data = gameData[_gameId];
        data.gameFinished = true;
        ingame[data.player] = false;
        ingame[data.opponent] = false;
        determineWinner(_gameId);
    }

    // This must be internal later on!!
    // Assigns the winner of the game based on current scores
    // If it's a draw, gives winner status to 0x0
    function determineWinner(uint256 _gameId) public {
        GameData storage data = gameData[_gameId];
        address winner;
        if (data.playerScore > data.opponentScore) {
            winner = data.player;
        } else if (data.opponentScore > data.playerScore) {
            winner = data.opponent;
        } else {
            winner = address(0);
        }
        data.winner = winner;
        //     emit GameWon(winner, _gameId);
    }

    // Assign scores
    function _assignScores(
        bool targetIsPlayer,
        bool targetIsOpponent,
        uint256 _gameId
    ) internal {
        GameData storage data = gameData[_gameId];
        if (targetIsPlayer) {
            data.playerScore--;
            data.opponentScore++;
        }
        if (targetIsOpponent) {
            data.opponentScore--;
            data.playerScore++;
        }
    }

    //  Function to check whether a given card is already placed on the board or not.
    function _cardIsOnBoard(uint256 _gameId, uint256 _cardId)
        internal
        view
        returns (bool)
    {
        uint256 cardToFind = _cardId;
        for (uint8 i = 0; i < 8; i++) {
            if (positions[_gameId][i] == cardToFind) {
                return true;
            }
        }
    }

    /*  Get adjacent cards for the card placed with function putCard() 
        Returns an array of adjacent cards 
        An ID of 0 means there is no card at that position.
        
        Refernce grid (3x3 board):
        
        0--1--2
        3--4--5
        6--7--8
    */
    function _getAdjacentCards(uint256 _gameId, uint8 _position)
        internal
        view
        returns (uint256[] memory)
    {
        uint256[] memory adjacentCards = new uint256[](4);

        uint256 placedCardPosition = _position;
        uint256 topCard;
        uint256 rightCard;
        uint256 bottomCard;
        uint256 leftCard;

        if (placedCardPosition == 0) {
            topCard = 0;
            rightCard = _cardIdAtPosition(_gameId, 1);
            bottomCard = _cardIdAtPosition(_gameId, 3);
            leftCard = 0;
        } else if (placedCardPosition == 1) {
            topCard = 0;
            rightCard = _cardIdAtPosition(_gameId, 2);
            bottomCard = _cardIdAtPosition(_gameId, 4);
            leftCard = _cardIdAtPosition(_gameId, 0);
        } else if (placedCardPosition == 2) {
            topCard = 0;
            rightCard = 0;
            bottomCard = _cardIdAtPosition(_gameId, 5);
            leftCard = _cardIdAtPosition(_gameId, 1);
        } else if (placedCardPosition == 3) {
            topCard = _cardIdAtPosition(_gameId, 0);
            rightCard = _cardIdAtPosition(_gameId, 4);
            bottomCard = _cardIdAtPosition(_gameId, 6);
            leftCard = 0;
        } else if (placedCardPosition == 4) {
            topCard = _cardIdAtPosition(_gameId, 1);
            rightCard = _cardIdAtPosition(_gameId, 5);
            bottomCard = _cardIdAtPosition(_gameId, 7);
            leftCard = _cardIdAtPosition(_gameId, 3);
        } else if (placedCardPosition == 5) {
            topCard = _cardIdAtPosition(_gameId, 2);
            rightCard = 0;
            bottomCard = _cardIdAtPosition(_gameId, 8);
            leftCard = _cardIdAtPosition(_gameId, 4);
        } else if (placedCardPosition == 6) {
            topCard = _cardIdAtPosition(_gameId, 3);
            rightCard = _cardIdAtPosition(_gameId, 7);
            bottomCard = 0;
            leftCard = 0;
        } else if (placedCardPosition == 7) {
            topCard = _cardIdAtPosition(_gameId, 4);
            rightCard = _cardIdAtPosition(_gameId, 8);
            bottomCard = 0;
            leftCard = _cardIdAtPosition(_gameId, 6);
        } else {
            // Assume card was placed in position 8 when all else fails
            topCard = _cardIdAtPosition(_gameId, 5);
            rightCard = 0;
            bottomCard = 0;
            leftCard = _cardIdAtPosition(_gameId, 7);
        }

        // Add to array
        adjacentCards[0] = topCard;
        adjacentCards[1] = rightCard;
        adjacentCards[2] = bottomCard;
        adjacentCards[3] = leftCard;

        return adjacentCards;
    }

    /*  Function to return the card ID at a given position
        A return of 0 means no card at _position */
    function _cardIdAtPosition(uint256 _gameId, uint8 _position)
        internal
        view
        returns (uint256)
    {
        return positions[_gameId][_position];
    }

    /*  Function to fetch values of a given card
        Returns an array of card values (top, right, bottom, left) */
    function _fetchCardValues(
        uint256 _cardId // change to internal later
    ) public view returns (uint8[] memory) {
        // In the Inventory we have feature1 = top, feature2 = right, feature3 = bottom and feature4 = left
        return Inventory.getFeaturesOfItem(_cardId);
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
        require(_amount <= balance, "Triple Triad: Out of balance");

        token.safeTransfer(msg.sender, _amount);

        emit ERC20TokenWithdrew(msg.sender);
    }
}
