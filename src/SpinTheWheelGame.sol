// SPDX-License-Identifier: MIT

//   ______             __                  ________  __                        __       __  __                            __
//  /      \           |  \                |        \|  \                      |  \  _  |  \|  \                          |  \
// |  $$$$$$\  ______   \$$ _______         \$$$$$$$$| $$____    ______        | $$ / \ | $$| $$____    ______    ______  | $$
// | $$___\$$ /      \ |  \|       \          | $$   | $$    \  /      \       | $$/  $\| $$| $$    \  /      \  /      \ | $$
//  \$$    \ |  $$$$$$\| $$| $$$$$$$\         | $$   | $$$$$$$\|  $$$$$$\      | $$  $$$\ $$| $$$$$$$\|  $$$$$$\|  $$$$$$\| $$
//  _\$$$$$$\| $$  | $$| $$| $$  | $$         | $$   | $$  | $$| $$    $$      | $$ $$\$$\$$| $$  | $$| $$    $$| $$    $$| $$
// |  \__| $$| $$__/ $$| $$| $$  | $$         | $$   | $$  | $$| $$$$$$$$      | $$$$  \$$$$| $$  | $$| $$$$$$$$| $$$$$$$$| $$
//  \$$    $$| $$    $$| $$| $$  | $$         | $$   | $$  | $$ \$$     \      | $$$    \$$$| $$  | $$ \$$     \ \$$     \| $$
//   \$$$$$$ | $$$$$$$  \$$ \$$   \$$          \$$    \$$   \$$  \$$$$$$$       \$$      \$$ \$$   \$$  \$$$$$$$  \$$$$$$$ \$$
//           | $$
//           | $$
//            \$$

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISupraRouter} from "./interfaces/ISupraRouter.sol";
import {ISpinTheWheelGame} from "./interfaces/ISpinTheWheelGame.sol";

/**
 * @title Spin The Wheel Game
 * @notice A game contract that allows players to bet on a token. Loser tokens are swapped for the winner token.
 */
contract SpinTheWheelGame is ISpinTheWheelGame, ReentrancyGuard {
    // Don't call _gamePhase directly, use getGamePhase()
    GamePhase private _gamePhase;

    // Game
    uint256 public immutable supraMaxWaitTime;
    uint256 public immutable bettingEndTimestamp;
    uint256 public immutable maxSwapRetries;

    uint256 public swapRetries;
    uint256 public randomResult;
    uint256 public postSwapAmountWinningToken; // After WETH => Winning token swap
    uint256 public tokenCount;
    uint256 public feeBasisPoints;

    // Supra uints
    uint256 public immutable supraNumOfConfirmations;

    // Uniswap V3 uints
    uint32 public immutable uniswapTwapPeriod;

    // Supra addresses
    address public immutable supraRouter;
    address public immutable supraClient;

    // Uniswap V3
    address public immutable uniswapRouter;
    address public immutable uniswapFactory;

    // WETH address
    address public immutable WETH;

    // Winning token
    address public winningToken;

    // Mappings
    mapping(address player => mapping(address token => uint256 amount)) public playerTokenBets;
    // Allowed ERC-20 tokens
    mapping(address token => bool isAllowed) public allowedTokens;
    // Total bet pool for each token used in the game
    mapping(address token => uint256 betPool) public totalTokenBetPools;
    // Only tokens that actually get used in the game
    mapping(uint256 tokenIndex => address token) public tokenIndexToAddress;

    // Uniswap V3 pool fees
    mapping(address token => uint24 fee) public tokenToWETHPoolFeeTier;

    constructor(
        address[] memory _allowedTokens,
        uint24[] memory _uniswapPoolFeeTiers,
        uint256 _bettingEndTimeStamp,
        uint256 _supraMaxWaitTime,
        uint256 _maxSwapRetries,
        uint256 _supraNumOfConfirmations,
        uint32 _uniswapTwapPeriod,
        address _supraRouter,
        address _supraClient,
        address _uniswapRouter,
        address _uniswapFactory,
        address _WETH
    ) {
        if (_bettingEndTimeStamp <= block.timestamp) revert BettingNotAllowed();
        if (_supraMaxWaitTime <= 0) revert AmountMustBeGreaterThanZero();
        if (_maxSwapRetries <= 0) revert AmountMustBeGreaterThanZero();
        if (_supraNumOfConfirmations <= 0) revert AmountMustBeGreaterThanZero();
        if (_uniswapTwapPeriod <= 0) revert AmountMustBeGreaterThanZero();
        if (_allowedTokens.length == 0) revert TokenNotAllowed();
        if (_uniswapPoolFeeTiers.length != _allowedTokens.length) revert TokenNotAllowed();

        bettingEndTimestamp = _bettingEndTimeStamp;
        supraMaxWaitTime = _supraMaxWaitTime;
        maxSwapRetries = _maxSwapRetries;
        supraNumOfConfirmations = _supraNumOfConfirmations;
        uniswapTwapPeriod = _uniswapTwapPeriod;
        supraRouter = _supraRouter;
        supraClient = _supraClient;
        uniswapRouter = _uniswapRouter;
        uniswapFactory = _uniswapFactory;
        WETH = _WETH;

        for (uint256 i = 0; i < _allowedTokens.length; i++) {
            address token = _allowedTokens[i];
            allowedTokens[token] = true;
            tokenToWETHPoolFeeTier[token] = _uniswapPoolFeeTiers[i];
            emit AllowedToken(token);
        }
    }

    /**
     * @notice Returns the current game phase.
     * @return The current game phase.
     */
    function getGamePhase() public view returns (GamePhase) {
        if (_gamePhase == GamePhase.BETTING_ALLOWED) {
            if (block.timestamp > bettingEndTimestamp + supraMaxWaitTime) {
                return GamePhase.REFUND_SUPRA_NO_REPLY;
            } else if (block.timestamp > bettingEndTimestamp) {
                return GamePhase.READY_CALL_SUPRA;
            }
            return GamePhase.BETTING_ALLOWED;
        } else if (_gamePhase == GamePhase.SUPRA_REPLIED_TRY_SWAP) {
            // Check if max retries reached
            if (swapRetries == maxSwapRetries) {
                return GamePhase.REFUND_SWAPS_FAILED;
            }
            // return GamePhase.TRY_SWAP;
        }
        return _gamePhase;
    }

    /**
     * @notice Allows a player to add tokens to the bet pool.
     * @param token The address of the token to add.
     * @param amount The amount of tokens to add.
     */
    function addToken(address token, uint256 amount) external nonReentrant {
        if (getGamePhase() != GamePhase.BETTING_ALLOWED) revert BettingNotAllowed();
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        // If a token is used for the first time, enumerate it
        if (totalTokenBetPools[token] == 0) {
            tokenIndexToAddress[tokenCount] = token;
            tokenCount++;
        }
        // Update amount of this token added by this player
        playerTokenBets[msg.sender][token] += amount;
        // Update amount of this token added in total
        totalTokenBetPools[token] += amount;
        emit PlayerAddedToken(msg.sender, token, amount);
    }

    /**
     * @notice Requests a callback from the Supra router.
     */
    function requestSupraCallback() external {
        if (getGamePhase() != GamePhase.READY_CALL_SUPRA) revert NotReadyForSupraCallback();
        // _rngCount, _numConfirmations, _clientSeed, _clientWalletAddress
        uint256 nonce = ISupraRouter(supraRouter).generateRequest(
            "supraCallback(uint256,uint256[])",
            1,
            supraNumOfConfirmations,
            supraClient
        );
    }

    /**
     * @notice Callback function called by the Supra router with the random numbers.
     * @param requestId The ID of the request.
     * @param randomNumbers The array of random numbers provided by the Supra router.
     */
    function supraCallback(uint256 requestId, uint256[] memory randomNumbers) external {
        if (msg.sender != supraRouter) revert OnlySupraCanCall();
        if (getGamePhase() != GamePhase.READY_CALL_SUPRA) revert NotReadyForSupraCallback();
        if (randomNumbers.length == 0) revert RandomNumbersRequired();

        randomResult = randomNumbers[0];
        _gamePhase = GamePhase.SUPRA_REPLIED_TRY_SWAP;

        emit SupraCallback(randomResult);
    }

    // TODO fix this because a revert on a single tokens currently does not revet the whole transaction
    /**
     * @notice Attempts to swap tokens.
     * @return A boolean indicating success or failure.
     */
    function trySwapTokens() external returns (bool) {
        if (getGamePhase() != GamePhase.SUPRA_REPLIED_TRY_SWAP) revert NotReadyForSupraCallback();
        if (swapRetries == maxSwapRetries) revert MaxSwapRetriesReached();
        swapRetries++;
        address[] memory tokens = new address[](tokenCount);
        uint256[] memory amounts = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokenIndexToAddress[i];
            uint256 amount = playerTokenBets[msg.sender][token];
            tokens[i] = token;
            amounts[i] = amount;
        }
        uint256[] memory betsInWETH = _getBetsInWETH(tokens, amounts);
        _pickWinner(betsInWETH, randomResult); // Implicitly sets winningToken
        address[] memory loserTokens = new address[](tokenCount - 1);
        uint256 loserTokenCount = 0;
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokenIndexToAddress[i];
            if (token != winningToken) {
                loserTokens[loserTokenCount] = token;
                loserTokenCount++;
            }
        }

        if (!_swapLoserTokensForWETH(loserTokens)) {
            return false;
        }

        // Implicitly sets postSwapAmountWinningToken
        if (!_swapWETHForWinnerToken(winningToken)) {
            return false;
        }

        _gamePhase = GamePhase.GAME_ENDED_SUCCESS;
        return true;
    }

    /**
     * @notice Collects winnings for the player.
     */
    function collectWinnings() external {
        if (getGamePhase() != GamePhase.GAME_ENDED_SUCCESS) revert GameNotEnded();
        uint256 playerBet = playerTokenBets[msg.sender][winningToken];
        if (playerBet == 0) revert NoBetOnWinningToken();
        uint256 totalBets = totalTokenBetPools[winningToken];

        // Calculate the winnings
        uint256 winnings = (playerBet * postSwapAmountWinningToken) / totalBets;
        if (!IERC20(winningToken).transfer(msg.sender, winnings)) revert TransferFailed();
    }

    /**
     * @notice Refunds tokens to the player.
     * @param tokens The array of token addresses to refund.
     */
    function getRefund(address[] memory tokens) external {
        GamePhase phase = getGamePhase();
        if (phase != GamePhase.REFUND_SUPRA_NO_REPLY && phase != GamePhase.REFUND_SWAPS_FAILED)
            revert NotInRefundState();

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = playerTokenBets[msg.sender][token];
            if (amount > 0) {
                if (!IERC20(token).transfer(msg.sender, amount)) revert TransferFailed();
                playerTokenBets[msg.sender][token] = 0;
                totalTokenBetPools[token] -= amount;
            }
        }
    }

    /**
     * @notice Returns all tokens used in the game.
     * @return An array of token addresses.
     */
    function getTokens() external view returns (address[] memory) {
        address[] memory tokens = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokens[i] = tokenIndexToAddress[i];
        }
        return tokens;
    }

    /**
     * @notice Returns the token bets of a player.
     * @param player The address of the player.
     * @return An array of bet amounts for each token.
     */
    function getPlayerTokenBets(address player) external view returns (uint256[] memory) {
        uint256[] memory bets = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokenIndexToAddress[i];
            bets[i] = playerTokenBets[player][token];
        }
        return bets;
    }

    // ========================= INTERNAL FUNCTIONS =========================

    /**
     * @notice Gets the bets in WETH for each token.
     * @param tokens An array of token addresses.
     * @param amounts An array of bet amounts.
     * @return An array of bet amounts in WETH.
     */
    function _getBetsInWETH(
        address[] memory tokens,
        uint256[] memory amounts
    ) internal view returns (uint256[] memory) {
        uint256[] memory betsInWETH = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            uint24 poolFeeTier = tokenToWETHPoolFeeTier[token];
            uint256 betInWETH = _getAmountInWETH(token, amount, poolFeeTier);
            betsInWETH[i] = betInWETH;
        }
        return betsInWETH;
    }

    // TODO check if this is correct
    function _getAmountInWETH(address token, uint256 amount, uint24 poolFeeTier) internal view returns (uint256) {
        if (token == WETH) {
            return amount;
        }
        address poolAddress = IUniswapV3Factory(uniswapFactory).getPool(token, WETH, poolFeeTier);
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtPriceX96WETH = 2 ** 96;
        uint256 amountInWETH = (amount * sqrtPriceX96) / sqrtPriceX96WETH;
        return amountInWETH;
    }

    /**
     * @notice Picks the winner based on the random result.
     * @param betsInWETH An array of bet amounts in WETH.
     * @param _randomResult The random result used to pick the winner.
     */
    function _pickWinner(uint256[] memory betsInWETH, uint256 _randomResult) internal {
        uint256 totalPool = 0;
        for (uint256 i = 0; i < betsInWETH.length; i++) {
            totalPool += betsInWETH[i];
        }

        uint256 scaledResult = _randomResult % totalPool;

        uint256 currentBetSum = 0;
        for (uint256 i = 0; i < betsInWETH.length; i++) {
            currentBetSum += betsInWETH[i];
            if (currentBetSum >= scaledResult) {
                winningToken = tokenIndexToAddress[i];
            }
        }
    }

    /**
     * @notice Swaps loser tokens for WETH.
     * @param loserTokens An array of loser token addresses.
     * @return A boolean indicating success or failure.
     */
    function _swapLoserTokensForWETH(address[] memory loserTokens) internal returns (bool) {
        for (uint256 i = 0; i < loserTokens.length; i++) {
            address loserToken = loserTokens[i];
            (bool success, uint256 amountOut) = _trySwapExactInputSingle(
                loserToken,
                WETH,
                tokenToWETHPoolFeeTier[loserToken],
                IERC20(loserToken).balanceOf(address(this)),
                15 seconds, // 15 seconds deadline
                uniswapTwapPeriod
            );
            if (!success) {
                emit SwapFailed(address(this), loserToken, swapRetries);
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Swaps WETH for the winning token.
     * @param winnerToken The address of the winning token.
     * @return A boolean indicating success or failure.
     */
    function _swapWETHForWinnerToken(address winnerToken) internal returns (bool) {
        (bool success, uint256 amountOut) = _trySwapExactInputSingle(
            WETH,
            winnerToken,
            tokenToWETHPoolFeeTier[winnerToken],
            IERC20(WETH).balanceOf(address(this)),
            15 seconds, // 15 seconds deadline
            uniswapTwapPeriod
        );
        if (success) {
            postSwapAmountWinningToken = amountOut;
            return true;
        }
        return false;
    }

    /**
     * @notice Attempts to swap a single input token for an output token using Uniswap V3.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     * @param poolFee The fee tier of the Uniswap V3 pool.
     * @param amountIn The amount of input tokens.
     * @param deadlineFromNow The deadline for the swap.
     * @param twapPeriod The TWAP period in seconds.
     * @return success A boolean indicating success or failure.
     * @return amountOut The amount of output tokens received.
     */
    function _trySwapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 amountIn,
        uint256 deadlineFromNow,
        uint32 twapPeriod // TWAP period in seconds
    ) internal returns (bool success, uint256 amountOut) {
        // Approve the Uniswap V3 Router to spend the tokenIn
        if (!IERC20(tokenIn).approve(uniswapRouter, amountIn)) revert ApprovalFailed();

        // Get the pool address
        address poolAddress = IUniswapV3Factory(uniswapFactory).getPool(tokenIn, tokenOut, poolFee);

        // Get the TWAP tick
        (int24 arithmeticMeanTick, ) = OracleLibrary.consult(poolAddress, twapPeriod);

        // Calculate the minimum amount out using the TWAP
        uint256 amountOutMinimum = OracleLibrary.getQuoteAtTick(
            arithmeticMeanTick,
            uint128(amountIn),
            tokenIn,
            tokenOut
        );
        uint256 scaledAmountOutMinimum = (amountOutMinimum * 90) / 100; // 90% of the arithmetic twap, for example

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp + deadlineFromNow,
            amountIn: amountIn,
            amountOutMinimum: scaledAmountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        // The call to `exactInputSingle` executes the swap.
        try ISwapRouter(uniswapRouter).exactInputSingle(params) returns (uint256 amountOut) {
            return (true, amountOut);
        } catch {
            return (false, 0);
        }
    }
}
