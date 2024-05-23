// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// TOKENS

// base HIGHER token
// 0x0578d8a44db98b23bf096a382e016e29a5ce0ffe
// HIGHER-WETH univ3 pool (1%)
// 0xcc28456d4ff980cee3457ca809a257e52cd9cdb0

// base DEGEN
// 0x4ed4e862860bed51a9570b96d89af5e1b0efefed
// DEGEN-WETH univ3 pool (0.3%)
// 0xc9034c3e7f58003e6ae0c8438e7c8f4598d5acaa

// base TN100X
// 0x5b5dee44552546ecea05edea01dcd7be7aa6144a
// TN100X-WETH univ3 pool (0.3%)
// 0x6B93950a9B589Bc32B82a5df4e5148f98A7FAe27

// base BRETT
// 0x532f27101965dd16442e59d40670faf5ebb142e4
// BRETT-WETH univ3 pool (1%)
// 0x532f27101965dd16442e59d40670faf5ebb142e4

// base TYBG
// 0x0d97f261b1e88845184f678e2d1e7a98d9fd38de
// TYBG-WETH univ3 pool (1%)
// 0xe745a591970e0fa981204cf525e170a2b9e4fb93
interface ISupraRouterContract {
    function generateRequest(
        string memory _functionSig,
        uint8 _rngCount,
        uint256 _numConfirmations,
        uint256 _clientSeed,
        address _clientWalletAddress
    ) external returns (uint256);

    function generateRequest(
        string memory _functionSig,
        uint8 _rngCount,
        uint256 _numConfirmations,
        address _clientWalletAddress
    ) external returns (uint256);
}

// uint256 nonce =  ISupraRouter(supraAddr).generateRequest("finishLootBox(uint256,uint256[])", 1, 1, 123, supraClientAddress);

interface IGame {
    event AllowedToken(address indexed token);
    event PlayerAddedToken(address indexed player, address indexed token, uint256 amount);
    event SwapFailed(address indexed caller, address indexed token, uint256 indexed attempt);
    event SupraCallback(uint256 indexed randomResult);
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
    function getRefund() external;

    function getPlayerTokenBets(address player) external returns (uint256[] memory bets);

    // Returns the current game phase
    function getGamePhase() external returns (uint256);
}

contract Game is IGame, ReentrancyGuard {
    uint256 public bettingEndTimestamp;
    uint256 public supraMaxWaitTime; // Cannot be 0
    uint256 public maxSwapRetries = 3; // Cannot be 0
    uint256 public swapRetries; // current retries of trySwapTokens
    uint256 public randomResult; // Random number from Supra

    // Count of tokens used in the game
    uint256 public tokenCount;

    uint256 public feeBasisPoints; // 100 basis points = 1 percent
    
    // Period used when computing TWAP
    uint256 public constant twapPeriod = 3 hours; // TODO check gas costs and time period safety
    // uint256 public immutable supraSeed;
    uint256 public immutable supraNumOfConfirmations;
    address public immutable clientWalletAddress; // Used by Supra
    address public immutable supraRouter;
    address public immutable WETH;

    // Each player can bet on multiple tokens
    mapping(address player => mapping(address token => uint256 amount)) public playerTokenBets;
    // Allowed ERC-20 tokens
    mapping(address token => bool isAllowed) public allowedTokens;
    // Total bet pool for each token used in the game
    mapping(address token => uint256 betPool) public totalTokenBetPools;
    // Only tokens that actually get used in the game
    mapping(uint256 tokenIndex => address token) public tokenIndexToAddress;

    // Current game phase
    GamePhase _gamePhase;
    enum GamePhase {
        BETTING_ALLOWED, // Automatic transition after 24 hours, for example
        READY_CALL_SUPRA, //  VRF can trigger the next phase
        REFUND_SUPRA_NO_REPLY, // Refund state if 24 hours for eaxmple pass with no reply from supra
        SUPRA_REPLIED_TRY_SWAP, // Now waiting for someone to call trySwapTokens
        REFUND_SWAPS_FAILED, // Refund state
        GAME_ENDED_SUCCESS, // Game complete,
    }

    constructor(
        // uint256 _supraSeed,
        uint256 _supraNumOfConfirmations,
        address _supraRouter,
        address _clientWalletAddress,
        address _WETH, 
        address[] memory _allowedTokens,
        uint256 _bettingEndTimeStamp,
        uint256 _supraMaxWaitTime,
        uint256 _feeBasisPoints) 
        {

            require (_bettingEndTimeStamp > block.timestamp);
            require (_supraMaxWaitTime > 0);
            require(_allowedTokens.length > 0);

            // supraSeed = _supraSeed;
            supraNumOfConfirmations = _supraNumOfConfirmations;

            supraRouter = _supraRouter;
            clientWalletAddress = _clientWalletAddress;
            WETH = _WETH;
            bettingEndTimestamp = _bettingEndTimeStamp;
            supraMaxWaitTime = _supraMaxWaitTime;
            feeBasisPoints = _feeBasisPoints;
            for (uint256 i = 0; i < _allowedTokens.length; i++) {
                allowedTokens[_allowedTokens[i]] = true;
                emit AllowedToken(_allowedTokens[i]);
            }
        }


    function getGamePhase() public returns (GamePhase) {
        if (_gamePhase == GamePhase.BETTING_ALLOWED) {
            if (block.timestamp > bettingEndTimestamp + supraMaxWaitTime) {
                return GamePhase.REFUND_SUPRA_NO_REPLY;
            }
            else if (block.timestamp > bettingEndTimestamp) {
                return GamePhase.READY_CALL_SUPRA;
            }
            return GamePhase.BETTING_ALLOWED;
        }
        else if (_gamePhase == GamePhase.SUPRA_REPLIED_TRY_SWAP) {
            // Check if max retries reached
            if (swapRetries == maxSwapRetries) {
                return GamePhase.REFUND_SWAPS_FAILED;
            }
            // return GamePhase.TRY_SWAP;
        }
        return _gamePhase;
    }

    function addToken(address token, uint256 amount) external nonReentrant {
        require(getGamePhase() == GamePhase.BETTING_ALLOWED, "Betting is not allowed");
        require(allowedTokens[token], "Token is not allowed");
        require(amount > 0, "Amount must be greater than 0");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");

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


    function requestSupraCallback() external {
        require(getGamePhase() == GamePhase.READY_CALL_SUPRA, "Not ready for Supra callback");
        // _rngCount, _numConfirmations, _clientSeed, _clientWalletAddress
        uint256 nonce =  ISupraRouter(supraAddr).generateRequest("supraCallback(uint256,uint256[])", 1, supraNumOfConfirmations, clientWalletAddress);

    }

    function supraCallback(uint256 requestId, uint256[] memory randomNumbers) external {
        require(msg.sender == supraRouter, "Only Supra can call this function");
        require(getGamePhase() == GamePhase.READY_CALL_SUPRA, "Not ready for Supra callback");
        require(randomNumbers.length > 0, "Random numbers must be provided");
        randomResult = randomNumbers[0];
        _gamePhase = GamePhase.SUPRA_REPLIED_TRY_SWAP;

        emit SupraCallback(randomResult);
    }

    function trySwapTokens() external returns (bool) {
        require(getGamePhase() == GamePhase.SUPRA_REPLIED_TRY_SWAP, "Not ready for swap");
        require(swapRetries < maxSwapRetries, "Max swap retries reached");
        swapRetries++;

        // 1 - Fetch WETH value of balance of each token
        // 2 - Pick winning token
        // 3 - Swap all other tokens for WETH

        // _swapOthersForWETH();
        uint256 winnerTokenIndex = pickWinner(betsInWETH, randomResult);
        address winnerToken = tokenIndexToAddress[winnerTokenIndex];
        // uint256 totalPool = totalTokenBetPools[winnerToken];

        // swap all other tokens for WETH
        try {
            for (uint256 i; i < tokenCount; i++) {
                address token = tokenIndexToAddress[i];
                if (token == winnerToken) {
                    continue;
                }
                _swapForWETH(token, totalTokenBetPools[token]);
            }
            uint256 WETHBalance = IERC20(WETH).balanceOf(address(this));
            _swapWETHForWinningToken(winnerToken, WETHBalance);
            _gamePhase = GamePhase.GAME_ENDED_SUCCESS;
            return true;
        } catch {
            emit SwapFailed(msg.sender, token, swapRetries);
            return false;
        }

    }

    function getTokens() external returns (address[] memory) {
        // Return all tokens used in the game
        address[] memory tokens = new address[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            tokens[i] = tokenIndexToAddress[i];
        }
        return tokens;
    }

    function getPlayerTokenBets(address player) external returns (uint256[] memory) {
        // Iterate over all tokens in the game and return the amount bet by the player
        uint256[] memory bets = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokenIndexToAddress[i];
            bets[i] = playerTokenBets[player][token];
        }
        return bets;
    }


    function getRefund() external {
        GamePhase phase = getGamePhase();
        require(phase == GamePhase.REFUND_SUPRA_NO_REPLY || phase() == GamePhase.REFUND_SWAPS_FAILED, "Not in refund state");
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = playerTokenBets[msg.sender][token];
            if (amount > 0) {
                require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");
                playerTokenBets[msg.sender][token] = 0;
                totalTokenBetPools[token] -= amount;
            }
        }
    }

    /**
    * @notice Select the winning token
    * @dev 
    */
    function pickWinner( uint256[] memory bets, uint256 _randomResult) public view returns (uint256) {
        // uint256[] memory bets = new uint256[](tokenCount);
        // for (uint256 i = 0; i < tokenCount; i++) {
        //     address token = tokenIndexToAddress[i];
        //     bets[i] = totalTokenBetPools[token];
        // }

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

    // ========= INTERNAL FUNCTIONS =========
    function _swapForWETH(address token, uint256 amount) internal {
        // Swap token for WETH
        uint256 poolAddress = IUniswapV3Factory(token, WETH); // TODO check if token order matters
        uint256 fee = IUniswapV3Pool(poolAddress).fee();
        _swapExactInputSingle(token, amount, twapPeriod, poolAddress, )
    }

    function _swapWETHForWinningToken(address winnerToken, amount) internal {
        // Swap WETH for winner token
        uint256 poolAddress = IUniswapV3Factory(WETH, winnerToken); // TODO check if token order matters
        uint256 fee = IUniswapV3Pool(poolAddress).fee();
        _swapExactInputSingle(WETH, amount, twapPeriod, poolAddress, )
    }

}