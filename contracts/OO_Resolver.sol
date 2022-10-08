// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/oracle/interfaces/OptimisticOracleV2Interface.sol";

contract OO_Resolver {

    // Create an Optimistic oracle instance at the deployed address on Görli.
    OptimisticOracleV2Interface oo = OptimisticOracleV2Interface(0xA5B9d8a0B0Fa04Ba71BDD68069661ED5C0848884);

    uint256 requestTime = 0; // Store the request time so we can re-use it later.
    bytes32 identifier = bytes32("YES_OR_NO_QUERY"); // Use the yes no idetifier to ask arbitary questions, such as the weather on a particular day.

    function requestData(string memory _question, address _bondCurrency, uint256 _reward, uint256 _liveness) public {
        bytes memory ancillaryData = createQuestion(_question); // Question to ask the UMA Oracle.

        requestTime = block.timestamp; // Set the request time to the current block time.
        IERC20 bondCurrency = IERC20(_bondCurrency); // Use preferred token as the bond currency.
        uint256 reward = _reward; // Set the reward amount for UMA Oracle.

        // Set liveness for request disputes measured in seconds. Recommended time is at least 7200 (2 hours).
        // Users should increase liveness time depending on various factors such as amount of funds being handled
        // and risk of malicious acts.
        uint256 liveness = _liveness;

        // Now, make the price request to the Optimistic oracle with preferred inputs.
        oo.requestPrice(identifier, requestTime, ancillaryData, bondCurrency, reward);
        oo.setCustomLiveness(identifier, requestTime, ancillaryData, liveness);
    }

    //******* VIEW FUNCTIONS ***********
        function createQuestion(string memory _question) public pure returns (bytes memory) {
        bytes memory question = bytes(string.concat("Q: ", _question, "? A:1 for yes. 0 for no."));
        return question;
    }
}