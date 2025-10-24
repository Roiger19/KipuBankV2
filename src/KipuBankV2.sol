// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin Imports for Security and Token Standards
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Chainlink Import for Price Feeds
// Interfaz de Chainlink pegada manualmente para evitar errores de ruta
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @title KipuBankV2
 * @author Juan Pablo Soto Roig (Version 2)
 * @notice A multi-asset deposit vault (ETH and ERC20) with USD-based limits
 * controlled by Chainlink oracles and administrative management.
 * @dev Uses Ownable for access control and ReentrancyGuard for security.
 */
contract KipuBankV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice We use address(0) to represent ETH in the internal accounting
    address public constant ETH_ADDRESS = address(0);

    /// @notice Maximum age for an oracle price feed (e.g., 1 hour)
    uint256 public constant MAX_PRICE_STALE_PERIOD = 3600; // 1 hour in seconds

    /// @notice USD prices are handled with 8 decimals
    uint256 internal constant USD_DECIMALS = 8;

    // ============================================
    // STATE VARIABLES
    // ============================================

    // --- Limits and Accounting ---
    uint256 private s_bankCapUsd;
    uint256 private s_totalUsdBalance;
    uint256 private s_maxWithdrawUsdPerTx;

    // --- Fund Mapping ---
    // token => user => amount
    mapping(address => mapping(address => uint256)) private s_clientFunds;

    // --- Whitelist and Oracle Mapping ---
    // token => priceFeedAddress
    mapping(address => address) private s_tokenPriceFeeds;
    mapping(address => bool) private s_isTokenWhitelisted;

    // --- Counters ---
    uint256 public depositCount;
    uint256 public totalTransactionsOut;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a user deposits funds (ETH or ERC20)
    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUsd
    );

    /// @notice Emitted when a user withdraws funds (ETH or ERC20)
    event Withdrawal(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUsd
    );

    /// @notice Emitted when the admin updates the bank's deposit cap
    event BankCapUpdated(uint256 newCapUsd);

    /// @notice Emitted when the admin updates the per-tx withdrawal limit
    event WithdrawalLimitUpdated(uint256 newLimitUsd);

    /// @notice Emitted when a new token is approved for deposit
    event TokenWhitelisted(address indexed token, address indexed priceFeed);

    /// @notice Emitted when a token is removed from the system
    event TokenDelisted(address indexed token);

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    error ZeroAmount();
    error TransferFailed();
    error TokenNotWhitelisted(address token);
    error InvalidPriceFeed(address token);
    error StalePriceFeed(address token, uint256 lastUpdated);
    error BankCapExceeded(
        uint256 currentUsd,
        uint256 depositUsd,
        uint256 capUsd
    );
    error InsufficientBalance(uint256 requested, uint256 available);
    error WithdrawalLimitExceeded(uint256 requestedUsd, uint256 limitUsd);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initializes the contract with the USD-based limits
     * @param _initialBankCapUsd Maximum deposit limit in USD (with 8 decimals)
     * @param _initialMaxWithdrawUsd Per-tx withdrawal limit in USD (with 8 decimals)
     */
    constructor(uint256 _initialBankCapUsd, uint256 _initialMaxWithdrawUsd)
        Ownable(msg.sender)
    {
        s_bankCapUsd = _initialBankCapUsd;
        s_maxWithdrawUsdPerTx = _initialMaxWithdrawUsd;
        emit BankCapUpdated(_initialBankCapUsd);
        emit WithdrawalLimitUpdated(_initialMaxWithdrawUsd);
    }

    // ============================================
    // ADMIN FUNCTIONS (onlyOwner)
    // ============================================

    /**
     * @notice Adds a token to the whitelist or updates its price feed
     * @param _token The ERC20 contract address (or address(0) for ETH)
     * @param _priceFeed The Chainlink oracle address (e.g., ETH/USD)
     */
    function whitelistToken(address _token, address _priceFeed)
        external
        onlyOwner
    {
        if (_priceFeed == address(0)) revert InvalidPriceFeed(_token);
        s_tokenPriceFeeds[_token] = _priceFeed;
        s_isTokenWhitelisted[_token] = true;
        emit TokenWhitelisted(_token, _priceFeed);
    }

    /**
     * @notice Removes a token from the whitelist
     * @dev Users can still withdraw funds, but cannot deposit more
     * @param _token The address of the token to remove
     */
    function delistToken(address _token) external onlyOwner {
        s_isTokenWhitelisted[_token] = false;
        emit TokenDelisted(_token);
    }

    /**
     * @notice Updates the maximum deposit limit (in USD)
     * @param _newCapUsd The new limit (with 8 decimals)
     */
    function updateBankCap(uint256 _newCapUsd) external onlyOwner {
        s_bankCapUsd = _newCapUsd;
        emit BankCapUpdated(_newCapUsd);
    }

    /**
     * @notice Updates the per-transaction withdrawal limit (in USD)
     * @param _newLimitUsd The new limit (with 8 decimals)
     */
    function updateWithdrawalLimit(uint256 _newLimitUsd) external onlyOwner {
        s_maxWithdrawUsdPerTx = _newLimitUsd;
        emit WithdrawalLimitUpdated(_newLimitUsd);
    }

    // ============================================
    // EXTERNAL DEPOSIT FUNCTIONS
    // ============================================

    /**
     * @notice Allows users to deposit ETH
     * @dev ETH (msg.value) must be sent in the transaction
     */
    function depositEth() external payable nonReentrant {
        _deposit(ETH_ADDRESS, msg.sender, msg.value);
    }

    /**
     * @notice Allows users to deposit ERC20 tokens
     * @dev The user must first approve the contract to spend their tokens
     * @param _token The address of the ERC20 token to deposit
     * @param _amount The amount of tokens to deposit (in their native decimals)
     */
    function depositErc20(address _token, uint256 _amount) external nonReentrant {
        if (_token == ETH_ADDRESS) revert("Use depositEth() for ETH");
        _deposit(_token, msg.sender, _amount);
        // Transfer the token from the user to the contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    }

    // ============================================
    // EXTERNAL WITHDRAW FUNCTIONS
    // ============================================

    /**
     * @notice Allows users to withdraw ETH from their vault
     * @param _amount The amount of ETH to withdraw (in wei)
     */
    function withdrawEth(uint256 _amount) external nonReentrant {
        _withdraw(ETH_ADDRESS, msg.sender, _amount);
        // Safely transfer ETH to the user
        (bool success, ) = msg.sender.call{value: _amount}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Allows users to withdraw ERC20 tokens from their vault
     * @param _token The address of the ERC20 token to withdraw
     * @param _amount The amount of tokens to withdraw (in their native decimals)
     */
    function withdrawErc20(address _token, uint256 _amount)
        external
        nonReentrant
    {
        if (_token == ETH_ADDRESS) revert("Use withdrawEth() for ETH");
        _withdraw(_token, msg.sender, _amount);
        // Safely transfer the token to the user
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    // ============================================
    // INTERNAL LOGIC
    // ============================================

    /**
     * @dev Shared internal logic for deposits
     */
    function _deposit(address _token, address _user, uint256 _amount) internal {
        // --- Checks ---
        if (_amount == 0) revert ZeroAmount();
        if (!s_isTokenWhitelisted[_token]) revert TokenNotWhitelisted(_token);

        uint256 valueUsd = getUsdValue(_token, _amount);
        uint256 newTotalUsdBalance;

        unchecked {
            newTotalUsdBalance = s_totalUsdBalance + valueUsd;
        }

        if (newTotalUsdBalance > s_bankCapUsd) {
            revert BankCapExceeded(
                s_totalUsdBalance,
                valueUsd,
                s_bankCapUsd
            );
        }

        // --- Effects ---
        s_totalUsdBalance = newTotalUsdBalance;
        s_clientFunds[_token][_user] += _amount;
        depositCount++;

        // --- Interactions ---
        emit Deposit(_user, _token, _amount, valueUsd);
    }

    /**
     * @dev Shared internal logic for withdrawals
     */
    function _withdraw(address _token, address _user, uint256 _amount) internal {
        // --- Checks ---
        if (_amount == 0) revert ZeroAmount();

        uint256 userBalance = s_clientFunds[_token][_user];
        if (_amount > userBalance) {
            revert InsufficientBalance(_amount, userBalance);
        }

        uint256 valueUsd = getUsdValue(_token, _amount);
        if (valueUsd > s_maxWithdrawUsdPerTx) {
            revert WithdrawalLimitExceeded(valueUsd, s_maxWithdrawUsdPerTx);
        }

        // --- Effects ---
        unchecked {
            s_totalUsdBalance -= valueUsd;
            s_clientFunds[_token][_user] = userBalance - _amount;
        }
        totalTransactionsOut++;

        // --- Interactions ---
        emit Withdrawal(_user, _token, _amount, valueUsd);
    }

    // ============================================
    // ORACLE & VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Gets the USD value of a token amount
     * @param _token The token address (address(0) for ETH)
     * @param _amount The amount of the token (in its native decimals)
     * @return valueUsd The value in USD (with 8 decimals)
     */
    function getUsdValue(address _token, uint256 _amount)
        public
        view
        returns (uint256 valueUsd)
    {
        address priceFeedAddress = s_tokenPriceFeeds[_token];
        if (priceFeedAddress == address(0)) revert InvalidPriceFeed(_token);

        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            priceFeedAddress
        );

        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        if (price <= 0) revert InvalidPriceFeed(_token);
        if (block.timestamp - updatedAt > MAX_PRICE_STALE_PERIOD) {
            revert StalePriceFeed(_token, updatedAt);
        }

        uint8 tokenDecimals = (_token == ETH_ADDRESS)
            ? 18
            : IERC20Metadata(_token).decimals();
        
        // The price has 8 decimals. We multiply the amount by the price
        // and adjust for the token's decimals.
        // (amount * price) / 10**tokenDecimals
        // (e.g., 1e18 * 3000e8) / 1e18 = 3000e8
        valueUsd = (_amount * uint256(price)) / (10**tokenDecimals);
    }

    /**
     * @notice Gets a user's balance for a specific token
     */
    function getClientBalance(address _token, address _user)
        external
        view
        returns (uint256)
    {
        return s_clientFunds[_token][_user];
    }

    /**
     * @notice Returns the total deposit cap in USD (with 8 decimals)
     */
    function getBankCapUsd() external view returns (uint256) {
        return s_bankCapUsd;
    }

    /**
     * @notice Returns the total USD balance deposited in the contract (with 8 decimals)
     */
    function getTotalUsdBalance() external view returns (uint256) {
        return s_totalUsdBalance;
    }

    /**
     * @notice Returns the per-transaction withdrawal limit in USD (with 8 decimals)
     */
    function getMaxWithdrawUsdPerTx() external view returns (uint256) {
        return s_maxWithdrawUsdPerTx;
    }

    /**
     * @notice Returns the price feed oracle address for a token
     */
    function getTokenPriceFeed(address _token) external view returns (address) {
        return s_tokenPriceFeeds[_token];
    }

}