pragma solidity ^0.5.12;

/*  Tested functions that seem to work
    ---------------------
    constructor() 
    addRanks() 
    openStarterPack() mints cards and should emit event for UIs just fine
    deckOf() seems to be working, but please look at the loop comments and confirm 
    
    
    
    Functions being tested 
    ---------------------
    buildPlayerHand() - haven't even started. 
*/

/*  General gameplay flow
    ---------------------
    1. Players call setApprovalForAll() on the inventory contract to unlock the game
    2. Players add 5 cards from their inventory into their play "hand" with buildPlayerHand()
        Afaik the player cannot add cards into hand they don't own... or add cards in hand that have templateIds outside 
        of the predefined triple triad range. 
    3. Player A creates a new game by calling startNewGame()
        The following requirements must be met:
        Player A must not be in any other game 
        Player A must have given approval with setApprovalForAll()
        Player A must have built a hand with buildPlayerHand()
        The following state changes happen:
        Player A's ingame status is set to true 
        The game gets added to gameData array along with the GameData struct which holds default settings for Player A 
        Depending on Player A's choice, the game is started either without (default) no mercy mode or with no mercy mode 
        No mercy mode simply enables/disables the "fair hand" checks in joinGame(). 
        No mercy = true means player B can join even when holding all level 10 cards in any game 
        whereas no mercy = false blocks player B from joining if their hand is too powerful 
    4. Each new game gets a unique ID, emits a NewGame event and is listed on the UI for other players to join
        allGames array is public so can easily be called with web3, listOpenGames() fetches a list of open games. Should be ok? 
    5. Player B chooses which open game to join and calls joinGame() passing the game ID as argument 
        The following requirements must be met:
        Player B must not be in any other game 
        The game Player B is joining must be open (must only have Player A ready and waiting)
        Player B must have given approval with setApprovalForAll()
        Player B must have built a hand with buildPlayerHand()
        The following state changes happen:
        Player B's ingame status is set to true 
        Player B's game data is set 
        The game status becomes "closed" meaning nobody else can join 
        Note: By default Player B cannot join a game where Player A's hand is too weak compared to Player B's hand
    6. Both players are now ready and playing the game 
    7. The first card will always be placed by the Player A (the game creator)
    8. Players take turns placing cards on a 3x3 board 
        putCard() requires that the msg.sender is actually playing this game 
    9. When a card is placed the game will look at its adjacent cards and will compare the cards values against each other 
        Think of it like Domino. Each card has a top, right, bottom and a left value [0,1,2,3] representing the corresponding side.
        When a card is placed and its adjacent card's touching side's value is lower, that card is "captured" and its ownerOnBoard 
        is changed to the player who placed that card. 
        For more in depth explanation:
        https://finalfantasy.fandom.com/wiki/Triple_Triad_(Final_Fantasy_VIII)
    10. Each time a card is captured, the card placer gets +1 added to their score 
    11. When all 9 spots on the board are used up the game is concluded. 
    12. The 9th and final card placed will trigger a finalization event which will determine the winner of the game. 
        The winner of the game can either be Player A or Player B. The burn address (address 0) is assigned as the winner in gameData 
        when the game comes out as a draw. 
    13. The winner can claim 1 card from the losers hand after the game has finished by calling claimCard() 
        The UI will call gameData[_gameID] on a finished game
        If the authenticated user on the UI is the winner a list of 5 opponent cards will be shown from which the player can choose 1 card 
        Note that opponent cards will be listed from the gameData, not the current playerHands[opponent] since the latter can be different 
        by the time winner decides to claim a card. 
        The claimCard() function requires the msg.sender to be the winner of that game and the default winner is address 0x0.
        After the card is claimed, the losers' playerHasBuiltHand becomes false meaning they need to build a new hand for the next game. 
        
    Additional functionality
    ---------------------
    openStarterPack() is allowed to be called by all new players and it will give the caller 7 cards from level 1 cards deck in the 
    Inventory. For testing purposes this uses a pseudo random number, but in a live release will use chainlink. 
    
    There is a time limit set in constructor() which dictates how long a game can last. 
    Once this time has passed, anyone can call endAbandonedGame() to trigger the finalize. 
    It is required that the _gameID is not yet set to "finished" and that the timer is indeed ran out. 
    This is to avoid players who realize they are losing to just abandon the game leaving the other player stuck and with no card. 
        
Issues:
13. How can we be sure the loser doesn't call setApprovalForAll() and set approval to false BEFORE the winner can call claimCard()?
    The loser can even front run the winner's claim transaction revoking approval and when winner's claim tx goes through, it will 
    fail because this contract no longer is allowed to transfer losers cards.
    
    We COULD transfer all cards in player hand to this game contract... but that will take a lot of gas. 5x transferFrom + 
    the user would want to take at least 4 of them back even if they lose so a total of 9x transfers? Oh no no no.

Ideas:
Ability to replay any game on the UI by fetching all events and things so the moves would replay in front of your eyes. 
*/


// Inventory contract Interface. Mainnet address: 0x9680223f7069203e361f55fefc89b7c1a952cdcc
contract iInventory {
	function getIndividualCount(uint256 _templateId) public view returns(uint256);
    function getIndividualOwnedCount(uint256 _templateId, address _owner) public view returns(uint256);
    function getTemplateIDsByTokenIDs(uint[] memory _tokenIds) public view returns(uint[] memory);
    function createFromTemplate(uint256 _templateId, uint8 _feature1, uint8 _feature2, uint8 _feature3, uint8 _feature4, uint8 _equipmentPosition) public returns(uint256);
    function burn(uint256 _tokenId) public returns(bool);
    function ownerOf(uint256 tokenId) public view returns (address owner);
    function getFeaturesOfItem(uint256 _tokenId) public view returns(uint8[] memory);

    function transferFrom(address from, address to, uint256 tokenId) public;
    function isApprovedForAll(address owner, address operator) public view returns (bool);
}

contract Game {
    event NewGame(address, uint256);
    event JoinedGame(address, uint256);
    event CardPlaced(address, uint256, uint256, uint8);
    event CardCaptured(address, uint256);
	event GameWon(address winner, uint256 gameID);
	event PackOpened(address player, uint256[] tokenIds, uint32 timestamp);
    
    modifier onlyAdmin() {
      require(msg.sender == admin, "Triple Triad: msg.sender is not admin");
      _;
    }
    
    modifier starterPackNotOpened() {
        require(!starterPackOpened[msg.sender], "Triple Triad: Starter pack already claimed");
        _;
    }
    
    // Require that the player has given approval for Triple Triad to handle their items 
    modifier hasGivenApproval() {
        require(inv.isApprovedForAll(msg.sender, address(this)), "Triple Triad: Player has not given approval for NFTs");
        _;
    }
    
    // Require game to be open when opponent wants to join it 
    modifier gameIsOpen(uint256 _gameID) {
        GameData storage data = gameData[_gameID];
        require(data.gameOpen, "Triple Triad: This game is not open");
        _;
    }
    
    // Require the player to not be in any game (you can only play 1 game at a time)
    modifier notInAnyGame() {
        require(!ingame[msg.sender], "Triple Triad: Only one game at a time");
        _;
    }
    
    // Require that the game is not finished 
    modifier notFinished(uint256 _gameID) {
        GameData storage data = gameData[_gameID];
        require(!data.gameFinished, "Triple Triad: Game finished");
        _;
    }
    
    // Require a _position to be open in a _gameID 
    modifier positionOpen(uint256 _gameID, uint8 _position) {
        require(positions[_gameID][_position] == 0, "Triple Triad: Position occupied");
        _;
    }
    
    // Require the card to not be on the board 
    modifier cardNotOnBoard(uint256 _gameID, uint256 _cardID) {
        require(!_cardIsOnBoard(_gameID, _cardID), "Triple Triad: Card already on board");
        _;
    }
    
    // Make sure its the players' turn 
    modifier playersTurn(uint256 _gameID) {
        GameData storage data = gameData[_gameID];
        require(data.turn == msg.sender, "Triple Triad: Not the msg.sender's turn");
        _;
    }
    
    // Make sure the player is in fact playing _gameID 
    modifier playingGame(uint256 _gameID) {
        require(playerInGame(_gameID), "Triple Triad: Player not part of the game");
        _;
    }
    
    // Make sure the allocated time for games to last has passed for endAbandonedGame() 
    modifier timeLimitHasPassed(uint256 _gameID) {
        require(timeIsUp(_gameID), "Triple Triad: This game is still ongoing");
        _;
    }
    
    // Require msg.sender to have 5 cards in hand (tokenIds)
    modifier hasBuiltHand() {
        require(playerHasBuiltHand[msg.sender], "Triple Triad: Player has not built hand");
        _;
    }

    using SafeMath for uint256;
    
    // The range of Triple Triad card NFTs in Inventory 
    uint256 constant templateId_START = 40;
    uint256 constant templateId_END   = 150;
    
    // Unix timestamp for how long a game is allowed to stay open 
    uint32 public timeLimit;
    
    uint8 public deviation = 1;

    // GameID => (CardID => Card owner on the board) 
    // Note: this is not the same as inv.ownerOf()
    mapping(uint256 => mapping(uint256 => address)) public ownerOnBoard;
    
    // Player hand status
    // For player to be able to open a new game or join an existing game, they need to have 5 owned cards in hand 
    mapping(address => bool) public playerHasBuiltHand;
    
    // Player address to PlayerHand struct 
    mapping(address => PlayerHand) public playerHands;
    
    // Card positions on the grid in any given game 
    // gameID => Grid(position => cardID)
    mapping(uint256 => mapping(uint8 => uint256)) public positions;
    
    // Has player opened a starter pack? 
    mapping(address => bool) public starterPackOpened;
    
    // Is the player currently in any game?
    mapping(address => bool) public ingame;
    
    // All games ever created 
    GameData[] public gameData;
    
    // Ranks for level 1 cards for use in openStarterPack()  
    Card[] public ranks;
    
    // Game data 
    struct GameData {
        address player; // game opener 
        address opponent; // game joiner 
        address turn; // whose turn it currently is?
        address winner; // who won this game? 0x0 can either mean a draw or ongoing game 
        uint256[5] playerHand; // tokenIds from the player hand 
        uint256[5] opponentHand; // tokenIds from the opponent hand 
        uint32 startDate; // game creation date 
        uint32 endDate; // time at which the game ends 
        uint8 playerScore; // player score 
        uint8 opponentScore; // opponent score 
        uint8 cardsOnBoard; // counts how many cards on board 
        uint8 avgOfTopTwo; // This is used to determine the average weight of a player's hand. It's this game's "difficulty level", set by Player A upon creation 
        bool gameOpen; // is the game open to join? 
        bool gameFinished; // has the game concluded? 
        bool noMercy; // if set to true in startNewGame() the joinGame() doesn't check for fair hand 
    }

    // The player hand 
    // These are 5 tokenIds (cards) from the Inventory
    struct PlayerHand {
        uint256 card1;
        uint256 card2;
        uint256 card3;
        uint256 card4;
        uint256 card5;
    }
    
    // A basic card struct 
    struct Card {
        uint256 templateId; // same as in Inventory 
        uint8 top;
        uint8 right;
        uint8 bottom;
        uint8 left;
    }

    address public admin;
    address public inventory = address(0x9680223F7069203E361f55fEFC89B7c1A952CDcc);
    
    iInventory inv = iInventory(inventory);

    constructor(uint256 _timeLimit) public {
        admin = msg.sender;
        timeLimit = uint32(_timeLimit);
        addRanks();
    }
    
    // Adds ranks for level 1 cards so openStarterPack() knows the correct item features and templateIds to use 
    function addRanks() internal {
        ranks.push(Card(40,1,4,1,5)); // Geezard 
        ranks.push(Card(41,5,1,1,3)); // Funguar
        ranks.push(Card(42,1,3,3,5)); // Bite Bug 
        ranks.push(Card(43,6,1,1,2)); // Red Bat 
        ranks.push(Card(44,2,3,1,5)); // Blobra
        ranks.push(Card(45,2,1,4,4)); // Gayla 
        ranks.push(Card(46,1,5,4,1)); // Gesper 
        ranks.push(Card(47,3,5,2,1)); // Fastitocalon-F
        ranks.push(Card(48,2,1,6,1)); // Blood Soul 
        ranks.push(Card(49,4,2,4,3)); // Caterchipillar
        ranks.push(Card(50,2,1,2,6)); // Cockatrice
    }
    
    /*  Give the user 7 random level 1 cards from ranks[] 
        by calling inv.createFromTemplate() using these values */
    function openStarterPack() public starterPackNotOpened() {
        require(ranks.length > 0, "Triple Triad: Admin has not added ranks yet");
        starterPackOpened[msg.sender] = true;
        
        uint256 rand;
		uint256[] memory tokenIds = new uint256[](7);

		for (uint i = 0; i < 7; i++) {
            // Chainlink RNG here!!! 
            // Pick a random number between 0 - 10 (the entries in ranks[])
		    rand = _rand(0,10);
		    uint256 tokenId = inv.createFromTemplate(
		        ranks[rand].templateId, 
		        ranks[rand].top, 
		        ranks[rand].right, 
		        ranks[rand].bottom, 
		        ranks[rand].left,
		        1 // equipmentPosition for Triple Triad cards is their level 
		    );
		    tokenIds[i] = tokenId;
		}
		
		emit PackOpened(msg.sender, tokenIds, uint32(now));
    }
    
    /*  Returns an array of templateIds (items that fall within the Triple Triad templates range in Inventory) that _player owns 
        Returns another array with the total counts for each of these templateIds the _player owns 
        Note: In the UI ignore everything with a value of 0 */
    function deckOf(address _player) public view returns(uint256[] memory, uint256[] memory) {
        // Fixed arrays of 110 because Triple Triad has 110 cards total 
        uint256[] memory playerDeck = new uint256[](110);
        uint256[] memory cardCount = new uint256[](110);
        uint256 index;
        uint256 count;
        
        // Start from templateId_START and end at templateId_END (included)
        // blast, I tested this in a simple js script, and <= seemed to have ran 111 times while interating through ids 40,...,150 so it's ok?
        for(uint i = templateId_START; i <= templateId_END; i++) {
            count = inv.getIndividualOwnedCount(i, _player);
            if(count > 0) {
                // _player owns this card!
                playerDeck[index] = i;
                cardCount[index] = count;
                index++;
            }
        }
        
        return (playerDeck, cardCount);
    }

    /* Function to add user selected cards from the Inventory contract into the playerHand array that the user can play with. 
    Returns an array with 5 card ID's (tokenIds from Inventory) */
    function buildPlayerHand(uint256[] calldata cardsToAdd) external hasGivenApproval() returns (uint256[] memory) {
        // Declare the player 
        address _player = msg.sender;
        // Fetch templateIds 
        uint256[] memory templateIds = inv.getTemplateIDsByTokenIDs(cardsToAdd);
        // check if the _player actually owns these cards
        // also check if the templateIds are within our Triple Triad card template range to avoid santa hats in game 
        for(uint i = 0; i < 5; i++) {
            require(inv.ownerOf(cardsToAdd[i]) == _player, "Triple Triad: Player is not the owner of this card");
            require(templateIds[i] >= templateId_START && templateIds[i] <= templateId_END, "Triple Triad: Trying to add invalid card");
        }
        
        // Execute
        return _buildPlayerHand(cardsToAdd, _player);
    }
    
    

    /* Start a new game that another player can then join 
    
    msg.sender requirements:
    must not be in any other game, 
    must have given approval for all items to this contract, 
    must have built a hand */
    function startNewGame(bool _noMercy) public notInAnyGame() hasGivenApproval() hasBuiltHand() {
        // set ingame status 
        ingame[msg.sender] = true;
        
        // Declare the player hand
        // Note to self: this might not work, I remember having trouble with this approach in the past 
        // Think you need to = new uint256[](5); etc. 
        uint256[5] memory playerHand;
        playerHand[0] = playerHands[msg.sender].card1;
        playerHand[1] = playerHands[msg.sender].card2;
        playerHand[2] = playerHands[msg.sender].card3;
        playerHand[3] = playerHands[msg.sender].card4;
        playerHand[4] = playerHands[msg.sender].card5;
        
        /*  GameData: 
            address player, 
            address opponent, 
            address turn, 
            address winner, 
            uint256[] playerHand, 
            uint256[] opponentHand, 
            uint32 startDate, 
            uint32 endDate, 
            uint8 playerScore, 
            uint8 opponentScore, 
            uint8 cardsOnBoard, 
            uint8 avgOfTopTwo, 
            bool gameOpen, 
            bool gameFinished,
            bool noMercy */
        uint256 id = gameData.push(GameData(
            msg.sender, 
            address(0),
            msg.sender, 
            address(0), 
            playerHand,
            [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)],
            uint32(now), 
            uint32(now + timeLimit), 
            5, 
            5, 
            0,
            _averageOfTopTwo(playerHand),
            true, 
            false,
            _noMercy)) -1;
            
        emit NewGame(msg.sender, id);
    }
    
    
    
    /* Join a game that another player has opened 
    
    msg.sender requirements:
    must not be in any other game, 
    must have given approval for all items to this contract, 
    must have built a hand 
    must have the average of two best cards from hand to be <= from the game's avgOfTopTwo (for fair play)
    
    additionally:
    _gameID must be open to joins */
    function joinGame(
        uint256 _gameID
    ) 
        public 
        notInAnyGame()
        gameIsOpen(_gameID) 
        hasGivenApproval() 
        hasBuiltHand() 
        returns (uint256)
    {
        // set ingame status 
        ingame[msg.sender] = true;
        
        uint256[5] memory playerHand;
        playerHand[0] = playerHands[msg.sender].card1;
        playerHand[1] = playerHands[msg.sender].card2;
        playerHand[2] = playerHands[msg.sender].card3;
        playerHand[3] = playerHands[msg.sender].card4;
        playerHand[4] = playerHands[msg.sender].card5;
        
        GameData storage data = gameData[_gameID];
        
        if(data.noMercy) {
            // Require opponent hand to be fair 
            // Note: allows for a set +deviation 
            require(_averageOfTopTwo(playerHand) <= data.avgOfTopTwo + deviation, "Triple Triad: Hand has unfair advantage");
        }
        
        // set opponent data 
        data.opponent = msg.sender;
        data.opponentHand = playerHand;
        data.gameOpen = false;
        emit JoinedGame(msg.sender, _gameID);
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
        uint256 _gameID, 
        uint256 _cardID, 
        uint8 _position
    )
        notFinished(_gameID) // Game must not be finished 
        playingGame(_gameID) // The player is playing this game (is either player or opponent)
        playersTurn(_gameID) // It is the players' turn
        cardNotOnBoard(_gameID, _cardID) // Card has not been placed in this game 
        positionOpen(_gameID, _position) // Position for card is unoccupied 
        public
    {
        GameData storage data = gameData[_gameID];
        require(!data.gameOpen, "Triple Triad: Game needs to be closed first"); // Make sure both players are in the game
        
        // Check if this was the final or 9th card
        bool isFinalCard;
        if(data.cardsOnBoard > 8) {
            isFinalCard = true;
        }
        
        // Relinquish turn to the other player 
        if(msg.sender == data.player) {
            data.turn = data.opponent;
        } else {
            data.turn = data.player;
        }
        
        // +1 to card count on board, add card at position in game, set the owner on board (can change in _compareCardValuesAndCapture() if captured )
        _putCard(_gameID, _cardID, _position);
        
        emit CardPlaced(msg.sender, _gameID, _cardID, _position);
        
        // Returns its own events on capture
        _compareCardValuesAndCapture(_gameID, _cardID, _position, isFinalCard);
    }
    
    
    
    // Finalize abandoned game that has timeLimit passed and is not yet finished 
    function endAbandonedGame(uint256 _gameID) public timeLimitHasPassed(_gameID) notFinished(_gameID) {
        _finalize(_gameID);
    }
    
    
    
    // Claim a card from a finished game
    function claimCard(uint256 _gameID, uint256 _cardID) public {
        GameData storage data = gameData[_gameID];
        
        // Require msg.sender to be the winner of this game
        // So that only the winner can pick a card from the other players' hand 
        require(msg.sender == data.winner, "Triple Triad: msg.sender is not the winner of this game");

        if(msg.sender == data.player) {
            // data.opponent has lost the game...
            for(uint i = 0; i < 5; i++) {
                if(data.opponentHand[i] == _cardID) {
                    // transfer the token 
                    inv.transferFrom(data.opponent, data.player, _cardID);
                    playerHasBuiltHand[data.opponent] = false;
                }
            }
        }
        else if (msg.sender == data.opponent) {
            // data.player has lost the game...
            for(uint i = 0; i < 5; i++) {
                if(data.playerHand[i] == _cardID) {
                    inv.transferFrom(data.player, data.opponent, _cardID);
                    playerHasBuiltHand[data.player] = false;
                }
            }
        }
        else {
            // who the fuck is msg.sender?
            revert();
        }
    }
    
    
    
    function listOpenGames() public view returns(uint256[] memory) {
        return _allOpenGames();
    }
    
    
    
    /* INTERNAL FUNCTIONS */
    
    // Return an array of all OPEN game IDs 
    function _allOpenGames() public view returns(uint256[] memory) {
        uint256[] memory result;
        uint256 index;
        for(uint i = 0; i < gameData.length; i++) {
            GameData storage data = gameData[i];
            if(data.gameOpen) {
                result[index] = i;
            }
            index++;
        }
        return result;
    }
    
    // We need to find 2 of the largest values from a set of 5, then return their average value 
    function _averageOfTopTwo(uint256[5] memory _playerHand) public pure returns(uint8) {
        uint256 largest1;
        uint256 largest2;
        for(uint i = 0; i < _playerHand.length; i++) {
            if(_playerHand[i] > largest1) {
                largest2 = largest1;
                largest1 = _playerHand[i];
            }
            else if(_playerHand[i] > largest2) {
                largest2 = _playerHand[i];
            }
        }
        return uint8(SafeMath.div(SafeMath.add(largest1, largest2), 2));
    }

	//  Generate a pseudo random number between min and max
	//  Only works as expected if min is 0
	function _rand(
	    uint256 _min, 
	    uint256 _max
	) 
	    public  
	    view   
	    returns (uint256) 
	{

		// Add 1 to the provided _max (idk why... blast?)
		uint256 max = _max.add(1);
		
		// Return it
		return uint256(keccak256(abi.encodePacked(now, msg.sender, gasleft()))) % (_min.add(max));
	}
	
	
	
	// Checks if game time limit is reached 
	function timeIsUp(uint256 _gameID) public view returns (bool) {
	    GameData storage data = gameData[_gameID];
	    bool status;
	    
	    // IS THIS RIGHT? 
	    if(now - data.endDate >= timeLimit) {
	        status = true;
	    }
	    return status;
	}
	
	
	
	// Write some additional card data for games 
    function _putCard(uint256 _gameID, uint256 _cardID, uint8 _position) internal {
        GameData storage data = gameData[_gameID];
        // Add +1 card on the counter
        data.cardsOnBoard++;
        // Add the card to its position 
        positions[_gameID][_position] = _cardID;
        // Add the owner on board 
        ownerOnBoard[_gameID][_cardID] = msg.sender;
    }



    /*  Function to compare the placed card's values against cards found on the board.
        Captures cards if values are bigger and the card is not yet one of players' cards */
    function _compareCardValuesAndCapture(
        uint256 _gameID, 
        uint256 _cardID, 
        uint8 _position,
        bool _isFinalCard
    ) 
        public
    {
        address cardPlacer = msg.sender;
        
        // Who is the target?
        bool targetIsPlayer;
        bool targetIsOpponent;
        
        if(_playerRoleInGame(_gameID) != msg.sender) {
            // Player (game starter) is NOT putting the card right now, must be opponent 
            targetIsPlayer = true;

        }
        
        if(_opponentRoleInGame(_gameID) != msg.sender) {
            // Opponent (game joiner) is NOT putting the card right now, must be player 
            targetIsOpponent = true;
        }
        
        // A Card needs to be placed on a _position so we can check its adjecent cards 
        require(positions[_gameID][_position] == _cardID, "Triple Triad: Card is not placed at this position!");

        uint8[] memory placedCard = _fetchCardValues(_cardID);
        
        /*  ID's of cards adjacent to placedCard: [top, right, bottom, left]
            ID of 0 means there is no card at that position 
            so if _adjacentCards[0][n] = 0 then there is no card! */
        uint256[] memory _adjacentCards = _getAdjacentCards(_gameID, _position);
        
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
        if(_adjacentCards[0] != 0) {
            uint256 topCard = _adjacentCards[0];
            // Get top card's bottom value
            uint8 bottomValue = _fetchCardValues(topCard)[2];
            // If value is smaller & is not the player's card 
            if(bottomValue < placedCard[0] && ownerOnBoard[_gameID][topCard] != cardPlacer) {
                // Capture the adjacent card 
                ownerOnBoard[_gameID][topCard] = cardPlacer;
                _assignScores(targetIsPlayer, targetIsOpponent, _gameID);
                emit CardCaptured(cardPlacer, topCard);
            }
        }
        // Check right card 
        if(_adjacentCards[1] != 0) {
            uint256 rightCard = _adjacentCards[1];
            // Get right card's left value 
            uint8 leftValue = _fetchCardValues(rightCard)[3];
            if(leftValue < placedCard[1] && ownerOnBoard[_gameID][rightCard] != cardPlacer) {
                // Capture the adjacent card 
                ownerOnBoard[_gameID][rightCard] = cardPlacer;
                _assignScores(targetIsPlayer, targetIsOpponent, _gameID);
                emit CardCaptured(cardPlacer, rightCard);
            }
        }
        // Check bottom card 
        if(_adjacentCards[2] != 0) {
            uint256 bottomCard = _adjacentCards[2];
            // Get bottom card's top value 
            uint8 topValue = _fetchCardValues(bottomCard)[0];
            if(topValue < placedCard[2] && ownerOnBoard[_gameID][bottomCard] != cardPlacer) {
                // Capture the adjacent card 
                ownerOnBoard[_gameID][bottomCard] = cardPlacer;
                _assignScores(targetIsPlayer, targetIsOpponent, _gameID);
                emit CardCaptured(cardPlacer, bottomCard);
            }
        }
        // Check left card 
        if(_adjacentCards[3] != 0) {
            uint256 leftCard = _adjacentCards[3];
            // Get left card's right value 
            uint8 rightValue = _fetchCardValues(leftCard)[1];
            if(rightValue < placedCard[3] && ownerOnBoard[_gameID][leftCard] != cardPlacer) {
                // Capture the adjacent card 
                ownerOnBoard[_gameID][leftCard] = cardPlacer;
                _assignScores(targetIsPlayer, targetIsOpponent, _gameID);
                emit CardCaptured(cardPlacer, leftCard);
            }
        }
        
        // Final card will finish the game
        if(_isFinalCard) {
            _finalize(_gameID);
        }
    }
    
    
    
    // Finish the game (declade internal)
    function _finalize(uint256 _gameID) public {
        GameData storage data = gameData[_gameID];
        data.gameFinished = true;
        ingame[data.player] = false;
        ingame[data.opponent] = false;
        determineWinner(_gameID);
    }
    
    
    
    // This must be internal later on!!
    // Assigns the winner of the game based on current scores 
    // If it's a draw, gives winner status to 0x0
    function determineWinner(uint256 _gameID) public {
        GameData storage data = gameData[_gameID];
        address winner;
        if(data.playerScore > data.opponentScore) {
            winner = data.player;
        }
        else if(data.opponentScore > data.playerScore) {
            winner = data.opponent;
        }
        else {
            winner = address(0);
        }
        data.winner = winner;
        emit GameWon(winner, _gameID);
    }
    
    
    
    // Assign scores 
    function _assignScores(
        bool targetIsPlayer, 
        bool targetIsOpponent, 
        uint256 _gameID
    ) 
        internal 
    {
        GameData storage data = gameData[_gameID];
        if(targetIsPlayer) {
            data.playerScore--;
            data.opponentScore++;
        }
        if(targetIsOpponent) {
            data.opponentScore--;
            data.playerScore++;
        }
    }
    
    
    
    //  Function to check whether a given card is already placed on the board or not.
    function _cardIsOnBoard(
        uint256 _gameID, 
        uint256 _cardID
    )
        internal  
        view 
        returns (bool) 
    {
        uint256 cardToFind = _cardID;
        for(uint8 i = 0; i < 8; i++) {
            if(positions[_gameID][i] == cardToFind) {
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
    function _getAdjacentCards(
        uint256 _gameID, 
        uint8 _position
    )
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
        
        if(placedCardPosition == 0) {
            topCard = 0;
            rightCard = _cardIdAtPosition(_gameID, 1);
            bottomCard = _cardIdAtPosition(_gameID, 3);
            leftCard = 0;
        }
        else if (placedCardPosition == 1) {
            topCard = 0;
            rightCard = _cardIdAtPosition(_gameID, 2);
            bottomCard = _cardIdAtPosition(_gameID, 4);
            leftCard = _cardIdAtPosition(_gameID, 0);
        }
        else if (placedCardPosition == 2) {
            topCard = 0;
            rightCard = 0;
            bottomCard = _cardIdAtPosition(_gameID, 5);
            leftCard = _cardIdAtPosition(_gameID, 1);
        }
        else if (placedCardPosition == 3) {
            topCard = _cardIdAtPosition(_gameID, 0);
            rightCard = _cardIdAtPosition(_gameID, 4);
            bottomCard = _cardIdAtPosition(_gameID, 6);
            leftCard = 0;
        }
        else if (placedCardPosition == 4) {
            topCard = _cardIdAtPosition(_gameID, 1);
            rightCard = _cardIdAtPosition(_gameID, 5);
            bottomCard = _cardIdAtPosition(_gameID, 7);
            leftCard = _cardIdAtPosition(_gameID, 3);
        }
        else if (placedCardPosition == 5) {
            topCard = _cardIdAtPosition(_gameID, 2);
            rightCard = 0;
            bottomCard = _cardIdAtPosition(_gameID, 8);
            leftCard = _cardIdAtPosition(_gameID, 4);
        }
        else if (placedCardPosition == 6) {
            topCard = _cardIdAtPosition(_gameID, 3);
            rightCard = _cardIdAtPosition(_gameID, 7);
            bottomCard = 0;
            leftCard = 0;
        }
        else if (placedCardPosition == 7) {
            topCard = _cardIdAtPosition(_gameID, 4);
            rightCard = _cardIdAtPosition(_gameID, 8);
            bottomCard = 0;
            leftCard = _cardIdAtPosition(_gameID, 6);
        }
        else {
            // Assume card was placed in position 8 when all else fails 
            topCard = _cardIdAtPosition(_gameID, 5);
            rightCard = 0;
            bottomCard = 0;
            leftCard = _cardIdAtPosition(_gameID, 7);
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
    function _cardIdAtPosition(
        uint256 _gameID, 
        uint8 _position
    ) 
        internal 
        view
        returns (uint256) 
    {
        return positions[_gameID][_position];
    }
    
    
    
    /*  Function to fetch values of a given card
        Returns an array of card values (top, right, bottom, left) */
    function _fetchCardValues(
        uint256 _cardID
    )
        public // change to internal later 
        view
        returns (uint8[] memory)
    {
        // In the Inventory we have feature1 = top, feature2 = right, feature3 = bottom and feature4 = left
        return inv.getFeaturesOfItem(_cardID);
    }
    
    
    
    // Internal function to build the player hand.
    // Called after all checks passed in buildPlayerHand();
    function _buildPlayerHand(
        uint256[] memory _cardsToAdd,
        address _player
    )
        internal 
        returns (uint256[] memory)
    {
        playerHands[_player] = PlayerHand(
            _cardsToAdd[0],
            _cardsToAdd[1],
            _cardsToAdd[2],
            _cardsToAdd[3],
            _cardsToAdd[4]
        );
        
        playerHasBuiltHand[_player] = true;
        return _cardsToAdd;
    }
    
    
    
    function _playerRoleInGame(uint256 _gameID) public view returns (address) {
        GameData storage data = gameData[_gameID];
        return data.player;
    }
    
    function _opponentRoleInGame(uint256 _gameID) public view returns (address) {
        GameData storage data = gameData[_gameID];
        return data.opponent;
    }
    
    function _playerScore(uint256 _gameID) public view returns (uint8) {
        GameData storage data = gameData[_gameID];
        return data.playerScore;
    }
    
    function _opponentScore(uint256 _gameID) public view returns (uint8) {
        GameData storage data = gameData[_gameID];
        return data.opponentScore;
    }

    function playerInGame(uint256 _gameID) public view returns (bool) {
        bool status;
        GameData storage data = gameData[_gameID];
        if(data.player == msg.sender || data.opponent == msg.sender) {
            status = true;
        }
        return status;
    }

}



library SafeMath {
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
          return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a / b;
        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }
}
