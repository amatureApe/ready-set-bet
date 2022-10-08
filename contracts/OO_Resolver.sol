// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/oracle/interfaces/OptimisticOracleV2Interface.sol";

contract OO_BetHandler {
    // Create an Optimistic oracle instance at the deployed address on Görli.
    OptimisticOracleV2Interface oo =
        OptimisticOracleV2Interface(0xA5B9d8a0B0Fa04Ba71BDD68069661ED5C0848884);

    uint256 requestTime = 0; // Store the request time so we can re-use it later.
    bytes32 identifier = bytes32("YES_OR_NO_QUERY"); // Use the yes no idetifier to ask arbitary questions, such as the weather on a particular day.
    address constant ZERO_ADDRESS = address(0);

    struct Bet {
        bytes question;
        IERC20 bondCurrency;
        uint256 reward;
        uint256 liveness;
        address creator; // Creator of the bet contract.
        address affirmation; // Address of the side of the bet that affirms the question.
        uint256 affirmationAmount; // Amount deposited into the bet by the affrimation.
        address negation; // Address of the side of the bet that negates the question.
        uint256 negationAmount; // Amount deposited into the bet by the negation.
        uint256 betId; // The bet's global id number.
        BetStatus betStatus;
    }

    enum BetStatus {
        OPEN,
        PENDING,
        ACTIVE,
        SETTLED
    }

    mapping(address => Bet[]) public userBets; // All of the user's active bets.
    mapping(address => uint256) public numOfBets; // Number of bets a user has active.
    mapping(uint256 => Bet) public bets; // All bets mapped by their betId
    uint256 betId = 0; // latest global betId for all managed bets.

    function setBet(
        string calldata _question,
        address _bondCurrency,
        uint256 _reward,
        uint256 _liveness,
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

        Bet memory bet = Bet(
            ancillaryData,
            bondCurrency,
            _reward,
            _liveness,
            msg.sender,
            affirmation,
            affirmationAmount,
            negation,
            negationAmount,
            betId + 1,
            BetStatus.OPEN
        );

        bondCurrency.approve(address(this), _betAmount + _reward);
        bondCurrency.transferFrom(
            msg.sender,
            address(this),
            _betAmount + _reward
        );
        bondCurrency.approve(address(this), 0);

        userBets[msg.sender].push(bet);
        betId += 1;
    }

    function takeBet(uint256 _betId) public {
        Bet storage bet = bets[_betId];
        require(
            bet.affirmation == ZERO_ADDRESS || bet.negation == ZERO_ADDRESS
        );

        if (bet.affirmation == ZERO_ADDRESS) {
            bet.bondCurrency.approve(address(this), bet.affirmationAmount);
            bet.bondCurrency.transferFrom(
                msg.sender,
                address(this),
                bet.affirmationAmount
            );
            bet.affirmation = msg.sender;
        } else {
            bet.bondCurrency.approve(address(this), bet.negationAmount);
            bet.bondCurrency.transferFrom(
                msg.sender,
                address(this),
                bet.negationAmount
            );
            bet.negation = msg.sender;
        }
    }

    function requestData(uint256 _betId) public {
        Bet storage bet = bets[_betId];
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
            identifier,
            requestTime,
            ancillaryData,
            bondCurrency,
            reward
        );
        oo.setCustomLiveness(identifier, requestTime, ancillaryData, liveness);
    }

    // Settle the request once it's gone through the liveness period of 30 seconds. This acts the finalize the voted on price.
    // In a real world use of the Optimistic Oracle this should be longer to give time to disputers to catch bat price proposals.
    function settleRequest(uint256 _betId) public {
        Bet storage bet = bets[_betId];
        require(bet.affirmation == msg.sender || bet.negation == msg.sender);

        bytes memory ancillaryData = bet.question;

        oo.settle(address(this), identifier, requestTime, ancillaryData);
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
                    identifier,
                    requestTime,
                    ancillaryData
                )
                .resolvedPrice;
    }
}
