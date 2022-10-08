// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/oracle/interfaces/OptimisticOracleV2Interface.sol";

contract OO_BetHandler {
    // Create an Optimistic oracle instance at the deployed address on Görli.
    OptimisticOracleV2Interface oo =
        OptimisticOracleV2Interface(0xA5B9d8a0B0Fa04Ba71BDD68069661ED5C0848884);

    uint256 requestTime = 0; // Store the request time so we can re-use it later.
    bytes32 constant IDENTIFIER = bytes32("YES_OR_NO_QUERY"); // Use the yes no idetifier to ask arbitary questions, such as the weather on a particular day.
    address constant ZERO_ADDRESS = address(0);
    // 0x0000000000000000000000000000000000000000

    struct Bet {
        bytes question;
        IERC20 bondCurrency;
        uint256 reward;
        uint256 liveness;
        address creator; // Creator of the bet contract.
        bool privateBet; // Is the bet meant for a specific person or open to everyone?
        address affirmation; // Address of the side of the bet that affirms the question.
        uint256 affirmationAmount; // Amount deposited into the bet by the affrimation.
        address negation; // Address of the side of the bet that negates the question.
        uint256 negationAmount; // Amount deposited into the bet by the negation.
        uint256 betId; // The bet's global id number.
        BetStatus betStatus;
    }

    enum BetStatus {
        OPEN,
        ACTIVE,
        SETTLING,
        SETTLED,
        CLAIMED
    }

    mapping(address => Bet[]) public userCreatedBets; // All bets created by the user.
    mapping(address => Bet[]) public userOpenBets; // All of the user's bets pending uptake.
    mapping(address => Bet[]) public userActiveBets; // All of the user's active bets.
    mapping(address => Bet[]) public userSettledBets; // All of the user's settled bets.
    mapping(address => Bet[]) public userWonBets; // All bets the user has won.
    mapping(address => Bet[]) public userLostBets; // All bets the user has lost.
    mapping(address => Bet[]) public userAllBets; // All bets the user is and has participated in.
    mapping(uint256 => Bet) public bets; // All bets mapped by their betId
    uint256 betId = 0; // latest global betId for all managed bets.

    function setBet(
        string calldata _question,
        address _bondCurrency,
        uint256 _reward,
        uint256 _liveness,
        bool _privateBet,
        // If _privateBet is false, _privateBetRecipient should be 0x0000000000000000000000000000000000000000
        address _privateBetRecipient,
        bool _affirmation,
        uint256 _betAmount,
        uint256 _counterBetAmount
    ) public {
        bytes memory ancillaryData = createQuestion(_question); // Question to ask the UMA Oracle.
        IERC20 bondCurrency = IERC20(_bondCurrency); // Use preferred token as the bond currency.

        address affirmation;
        uint256 affirmationAmount;
        address negation;
        uint256 negationAmount;

        if (_affirmation == true) {
            affirmation = msg.sender;
            affirmationAmount = _betAmount;
            negationAmount = _counterBetAmount;
        } else {
            negation = msg.sender;
            negationAmount = _betAmount;
            affirmationAmount = _counterBetAmount;
        }

        if (_privateBet == true) {
            affirmation == msg.sender
                ? negation = _privateBetRecipient
                : affirmation = _privateBetRecipient;
        }

        Bet memory bet = Bet(
            ancillaryData,
            bondCurrency,
            _reward,
            _liveness,
            msg.sender,
            _privateBet,
            affirmation,
            affirmationAmount,
            negation,
            negationAmount,
            betId,
            BetStatus.OPEN
        );

        // Make sure to approve this contract to spend your ERC20 externally first
        bondCurrency.transferFrom(msg.sender, address(this), _betAmount);

        userAllBets[msg.sender].push(bet);
        userCreatedBets[msg.sender].push(bet);
        userOpenBets[msg.sender].push(bet);
        bets[betId] = bet;
        betId += 1;
    }

    function takeBet(uint256 _betId) public {
        Bet storage bet = bets[_betId];
        require(msg.sender != bet.creator, "Can't take your own bet");
        if (bet.privateBet == false) {
            require(
                bet.affirmation == ZERO_ADDRESS || bet.negation == ZERO_ADDRESS,
                "Bet already taken"
            );
        } else {
            require(
                msg.sender == bet.affirmation || msg.sender == bet.negation,
                "Not bet recipient"
            );
        }
        require(bet.betStatus == BetStatus.OPEN, "Bet not Open");

        if (bet.affirmation == ZERO_ADDRESS) {
            // Make sure to approve this contract to spend your ERC20 externally first
            bet.bondCurrency.transferFrom(
                msg.sender,
                address(this),
                bet.affirmationAmount
            );
            bet.affirmation = msg.sender;
            userActiveBets[bet.affirmation].push(bet);
        } else {
            // Make sure to approve this contract to spend your ERC20 externally first
            bet.bondCurrency.transferFrom(
                msg.sender,
                address(this),
                bet.negationAmount
            );
            bet.negation = msg.sender;
            userActiveBets[bet.negation].push(bet);
        }

        bet.betStatus = BetStatus.ACTIVE;
        userAllBets[msg.sender].push(bet);

        delete userOpenBets[bet.creator];
    }

    function requestData(uint256 _betId) public {
        Bet storage bet = bets[_betId];
        require(
            bet.betStatus == BetStatus.ACTIVE,
            "Bet not ready to be settled"
        );
        require(bet.affirmation == msg.sender || bet.negation == msg.sender);

        bytes memory ancillaryData = bet.question; // Question to ask the UMA Oracle.

        requestTime = block.timestamp; // Set the request time to the current block time.
        IERC20 bondCurrency = IERC20(bet.bondCurrency); // Use preferred token as the bond currency.
        uint256 reward = bet.reward; // Set the reward amount for UMA Oracle.

        // Set liveness for request disputes measured in seconds. Recommended time is at least 7200 (2 hours).
        // Users should increase liveness time depending on various factors such as amount of funds being handled
        // and risk of malicious acts.
        uint256 liveness = bet.liveness;

        // Now, make the price request to the Optimistic oracle with preferred inputs.
        oo.requestPrice(
            IDENTIFIER,
            requestTime,
            ancillaryData,
            bondCurrency,
            reward
        );
        oo.setCustomLiveness(IDENTIFIER, requestTime, ancillaryData, liveness);

        bet.betStatus = BetStatus.SETTLING;
    }

    // Settle the request once it's gone through the liveness period of 30 seconds. This acts the finalize the voted on price.
    // In a real world use of the Optimistic Oracle this should be longer to give time to disputers to catch bat price proposals.
    function settleRequest(uint256 _betId) public {
        Bet storage bet = bets[_betId];
        require(bet.betStatus == BetStatus.SETTLING, "Bet not settling");
        require(bet.affirmation == msg.sender || bet.negation == msg.sender);

        bytes memory ancillaryData = bet.question;

        oo.settle(address(this), IDENTIFIER, requestTime, ancillaryData);
        bet.betStatus = BetStatus.SETTLED;

        userSettledBets[bet.affirmation].push(bet);
        userSettledBets[bet.negation].push(bet);
    }

    function claimWinnings(uint256 _betId) public {
        Bet storage bet = bets[_betId];
        uint256 totalWinnings = bet.affirmationAmount + bet.negationAmount;
        int256 settlementData = getSettledData(_betId);
        require(bet.betStatus == BetStatus.SETTLED, "Bet not yet settled");
        require(
            settlementData == 1e18 || settlementData == 0,
            "Invalid settlement"
        );
        if (settlementData == 1e18) {
            require(msg.sender == bet.affirmation, "Negation did not win bet");
            bet.bondCurrency.transfer(bet.affirmation, totalWinnings);
            userWonBets[bet.affirmation].push(bet);
            userLostBets[bet.negation].push(bet);
        } else {
            require(msg.sender == bet.negation, "Affirmation did not win bet");
            bet.bondCurrency.transfer(bet.negation, totalWinnings);
            userWonBets[bet.negation].push(bet);
            userLostBets[bet.affirmation].push(bet);
        }

        bet.betStatus = BetStatus.CLAIMED;
        delete userActiveBets[bet.affirmation];
        delete userActiveBets[bet.negation];
    }

    //******* VIEW FUNCTIONS ***********
    function createQuestion(string memory _question)
        public
        pure
        returns (bytes memory)
    {
        bytes memory question = bytes(
            string.concat("Q: ", _question, "? A:1 for yes. 0 for no.")
        );
        return question;
    }

    // Fetch the resolved price from the Optimistic Oracle that was settled.
    function getSettledData(uint256 _betId) public view returns (int256) {
        Bet storage bet = bets[_betId];
        require(bet.affirmation == msg.sender || bet.negation == msg.sender);

        bytes memory ancillaryData = bet.question;

        return
            oo
                .getRequest(
                    address(this),
                    IDENTIFIER,
                    requestTime,
                    ancillaryData
                )
                .resolvedPrice;
    }
}
