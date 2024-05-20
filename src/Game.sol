// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract Game {
    event AllowedToken(address indexed token);
    event BetPlaced(address indexed player, address indexed token, uint256 amount);
    event NextPhase(GamePhase indexed phase);
    enum GamePhase {
        BETTING_ALLOWED, // Anyone can trigger the next phase after 24 hours
        WAITING_FOR_RANDOMNESS, // Only Chainlink VRF can trigger the next phase
        SWAP_TOKENS, // Anyone can trigger the next phase after the random number is received
        GAME_ENDED
    }
    // The first phase lasts for 24 hours
    // The second phase is a call and just waiting for the random number.
    // The third phase is the end of the game.

    GamePhase public gamePhase; // Default is BETTING_ALLOWED
    uint256 public immutable bettingEndTimestamp;
    uint256 public randomResult;

    // Each player can bet on multiple tokens
    mapping(address player => mapping(address token => uint256 amount)) public playerTokenBets;

    mapping(address token => bool isAllowed) public allowedTokens;

    // Total bet pool for each token used in the game
    mapping(address token => uint256 betPool) public totalTokenBetPools;
    // Only tokens that actually get used in the game
    mapping(uint256 tokenIndex => address token) public tokenIndexToAddress;

    // Uniswap V3 SwapRouter
    ISwapRouter public immutable swapRouter;

    // Maximum number of swap retries. If all fail, allow refund to all players
    uint256 public maxSwapRetries = 3;
    uint256 public swapRetries;

    // Count of tokens used in the game
    uint256 public tokenCount;

    constructor(address[] memory _allowedTokens) {
        bettingEndTimestamp = block.timestamp + 24 hours;
        for (uint256 i = 0; i < _allowedTokens.length; i++) {
            allowedTokens[_allowedTokens[i]] = true;
            emit AllowedToken(_allowedTokens[i]);
        }
        emit NextPhase(gamePhase);
    }

    function addBet(address token, uint256 amount) public {
        require(gamePhase == GamePhase.BETTING_ALLOWED, "Betting is not allowed");
        require(allowedTokens[token], "Token is not allowed");
        require(amount > 0, "Amount must be greater than 0");
        // require(token.balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // If a token is used for the first time, enumerate it
        if (totalTokenBetPools[token] == 0) {
            tokenIndexToAddress[tokenCount] = token;
            tokenCount++;
        }
        playerTokenBets[msg.sender][token] += amount;
        totalTokenBetPools[token] += amount;
        emit BetPlaced(msg.sender, token, amount);
    }

    function nextPhase() public {
        if (gamePhase == GamePhase.BETTING_ALLOWED) {
            require(block.timestamp >= bettingEndTimestamp, "Betting phase is not over yet");
            _callRandomness();
            gamePhase = GamePhase.WAITING_FOR_RANDOMNESS;
        } else if (gamePhase == GamePhase.SWAP_TOKENS) {
            _swapAll();
            gamePhase = GamePhase.GAME_ENDED;
        } else {
            revert("Game has already ended");
        }
        emit NextPhase(gamePhase);
    }

    function _callRandomness() internal {
        // Call VRF
    }

    function _swapForUSDC(address token, uint256 amount) internal {
        // Swap token for USDC
    }

    function _swapUSDCForWinnerToken(address winnerToken, uint256 amount) internal {
        // Swap USDC for winner token
    }

    function _swapAll() internal {
        uint256 winnerTokenIndex = pickWinner(randomResult);
        address winnerToken = tokenIndexToAddress[winnerTokenIndex];
        // uint256 totalPool = totalTokenBetPools[winnerToken];

        // swap all other tokens for USDC
        for (uint256 i; i < tokenCount; i++) {
            address token = tokenIndexToAddress[i];
            if (token == winnerToken) {
                continue;
            }
            _swapForUSDC(token, totalTokenBetPools[token]);
        }

        // then swap USDC for winner token
        _swapUSDCForWinnerToken(winnerToken, totalTokenBetPools[winnerToken]);

        nextPhase();
    }


    function callback(uint256 _randomResult) external {
        require(gamePhase == GamePhase.WAITING_FOR_RANDOMNESS, "Not waiting for randomness");
        // require the caller is the vrf
        randomResult = _randomResult;
        nextPhase();
    }

    // token bet pools
    function pickWinner(uint256 _randomResult) public view returns (uint256) {
        uint256[] memory bets = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokenIndexToAddress[i];
            bets[i] = totalTokenBetPools[token];
        }

        uint256 totalPool = 0;
        for (uint256 i = 0; i < bets.length; i++) {
            totalPool += bets[i];
        }

        uint256 scaledResult = _randomResult % totalPool;

        uint256 currentBetSum = 0;
        for (uint256 i = 0; i < bets.length; i++) {
            currentBetSum += bets[i];
            if (currentBetSum >= scaledResult) {
                return i;
            }
        }

        // Fallback, should not reach here if logic is correct
        return bets.length - 1;
    }
}
