// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISpinTheWheelGame {
    event AllowedToken(address indexed token);
    event PlayerAddedToken(address indexed player, address indexed token, uint256 amount);
    event SwapFailed(address indexed caller, address indexed token, uint256 indexed attempt);
    event SupraCallback(uint256 indexed randomResult);

    error BettingNotAllowed();
    error TokenNotAllowed();
    error AmountMustBeGreaterThanZero();
    error TransferFailed();
    error NotReadyForSupraCallback();
    error OnlySupraCanCall();
    error RandomNumbersRequired();
    error GameNotEnded();
    error NoBetOnWinningToken();
    error NotInRefundState();
    error ApprovalFailed();
    error MaxSwapRetriesReached();

    enum GamePhase {
        BETTING_ALLOWED, // Automatic transition after 24 hours, for example
        READY_CALL_SUPRA, //  VRF can trigger the next phase
        REFUND_SUPRA_NO_REPLY, // Refund state if 24 hours for eaxmple pass with no reply from supra
        SUPRA_REPLIED_TRY_SWAP, // Now waiting for someone to call trySwapTokens
        REFUND_SWAPS_FAILED, // Refund state
        GAME_ENDED_SUCCESS // Game complete,
    }

    // 1 - BETTING_ALLOWED
    function addToken(address token, uint256 amount) external;

    // 2 - WAITING_FOR_RANDOMNESS
    function requestSupraCallback() external;

    function supraCallback(uint256 requestId, uint256[] memory randomNumbers) external;

    // 3 - SWAP_TOKENS
    function trySwapTokens() external returns (bool);

    // 4A - GAME_ENDED_A
    function collectWinnings() external;

    // 4B - GAME_ENDED_B
    function getRefund(address[] memory tokens) external;

    // Helper function
    function getTokens() external returns (address[] memory);

    // Helper function
    function getPlayerTokenBets(address player) external returns (uint256[] memory bets);

    // Returns the current game phase
    function getGamePhase() external returns (GamePhase);
}
