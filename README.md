# 🛡️ KipuBankV2 - Production-Ready Multi-Asset Vault

## 1. High-Level Explanation & Improvements

KipuBankV2 is a significant upgrade to the original KipuBank contract, transitioning it from a simple ETH-only vault to a production-ready, multi-asset (ETH & ERC20) banking contract.

The core motivation was to enhance **security, flexibility, and real-world applicability**.

### Key Improvements Implemented:

* **Access Control (`Ownable`):** The contract is now managed by an `owner`. This is crucial for security, as only the owner can whitelist new tokens for deposit or update critical parameters (like the bank cap), preventing users from depositing malicious or unknown assets.
* **Multi-Token Support (ETH & ERC20):** The vault now supports both native ETH and any whitelisted ERC20 token.
* **Internal Accounting (using `address(0)`):** A nested mapping (`token => user => balance`) now tracks all funds. We use the `address(0)` convention to represent ETH within this mapping, allowing us to reuse the same internal logic for all assets.
* **Chainlink Oracles (USD-Based Limits):** The `BANK_CAP` and `MAX_WITHDRAW_AMOUNT` are now defined in **USD**, not in a specific token amount. When a user deposits any asset, the contract fetches its real-time price from a Chainlink oracle, converts the amount to its USD value, and checks it against the cap. This creates a unified and far more stable security policy across all assets.
* **Enhanced Security (`ReentrancyGuard` & `SafeERC20`):** The contract inherits from OpenZeppelin's `ReentrancyGuard` to protect all deposit/withdraw functions. It also uses `SafeERC20` for all token transfers, preventing issues with non-standard ERC20s.
* **Advanced Error Handling:** The contract implements a full suite of custom errors (e.g., `TokenNotWhitelisted`, `StalePriceFeed`) to provide clear reasons for transaction failures.

---

## 2. Deployment & Interaction Instructions

This project is built with Hardhat.

### Deployment

1.  **Set up your Environment**: You need a `.env` file (add this to `.gitignore`) with your `SEPOLIA_RPC_URL` (from Alchemy/Infura) and your `PRIVATE_KEY`.
2.  **Configure Hardhat**: Update the `hardhat.config.ts` to include the Sepolia network.
3.  **Run the Deploy Script**: This project uses Hardhat Ignition. You can deploy to a testnet (e.g., Sepolia) by running:
    ```bash
    npx hardhat ignition deploy ignition/modules/KipuBankV2.ts --network sepolia
    ```
4.  **Copy the Address**: The script will output the contract address upon successful deployment.

### Interaction Flow

#### As the Admin (Owner)

Your first step after deployment *must* be to whitelist assets.

1.  **Whitelist ETH**:
    * Call `whitelistToken(address _token, address _priceFeed)`
    * `_token`: `0x0000000000000000000000000000000000000000` (the `ETH_ADDRESS`)
    * `_priceFeed`: `0x694AA1769357215DE4FAC081bf1f309aDC325306` (Sepolia ETH/USD feed)
2.  **Whitelist an ERC20 (e.g., LINK)**:
    * Call `whitelistToken(address _token, address _priceFeed)`
    * `_token`: `0x779877A7B0D9E8603169DdbD7836e478b4624789` (Sepolia LINK address)
    * `_priceFeed`: `0xc59E3633BAAC79493d908e63626716e204A45EdF` (Sepolia LINK/USD feed)

#### As a User

1.  **Deposit ETH**:
    * Call the `depositEth()` function while sending ETH (setting the `value` in the transaction).
2.  **Deposit ERC20**:
    * **Step A (Approve):** Call the `approve()` function on the ERC20 token contract, giving the KipuBankV2 contract address permission to spend your tokens.
    * **Step B (Deposit):** Call `depositErc20(address _token, uint256 _amount)` with the token's address and the amount you wish to deposit.
3.  **Withdraw Funds**:
    * Call `withdrawEth(uint256 _amount)` or `withdrawErc20(address _token, uint256 _amount)`.
4.  **Check Balances**:
    * Call `getClientBalance(address _token, address _user)` to see the balance for a specific asset.
    * Call `getTotalUsdBalance()` to see the bank's total assets in USD.

---

## 3. Design Decisions & Trade-offs

* **Decision: USD-Based Limits vs. Token-Based Limits**
    * **Reasoning**: A USD-based cap is more robust. A cap of "100 ETH" becomes extremely high (in value) if ETH moons, increasing the contract's risk profile. A cap of "$10,000 USD" remains consistent regardless of market volatility.
    * **Trade-off**: This creates a **hard dependency on the Chainlink oracle**. If the oracle is stale (older than `MAX_PRICE_STALE_PERIOD`) or fails, all deposits and withdrawals for that asset are blocked until the oracle recovers. This is a trade-off of liveness for security.

* **Decision: Admin Whitelist vs. Open Deposits**
    * **Reasoning**: Allowing anyone to deposit any ERC20 token is a massive security risk (e.g., "phishing" tokens, valueless tokens). An `onlyOwner` whitelist ensures that only legitimate assets with valid price feeds are accepted.
    * **Trade-off**: This introduces **centralization**. The `owner` is a single point of failure. A future, more decentralized version of this contract would replace the `owner` with a multi-signature wallet or a governance (DAO) contract.
