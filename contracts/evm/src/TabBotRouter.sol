// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/// @title TabBotRouter
/// @notice Companion router for bot-driven flows: peer-to-peer transfers
///         triggered by social commands (e.g. Twitter / Telegram / Discord),
///         and campaign grant distributions from a sponsor treasury.
///
///         Trust model: users pre-approve this router as an ERC-20 spender
///         once, then off-chain `executors` push transfers. Anti-replay is
///         a per-user nonce counter + tweetId/grantId deduplication.
///
///         Pause halts new P2P + grants; existing approvals stay live so
///         user funds are never trapped (users can always revoke approval
///         from their wallet).
///
///         Modeled on Monipay's MoniBotRouter (verified on BSC).
contract TabBotRouter is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* ----------------------------- constants ----------------------------- */

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 500; // 5% hard cap

    /* ------------------------------ storage ------------------------------ */

    IERC20 public immutable STABLE;

    address public platformTreasury;
    uint256 public platformFeeBps;

    mapping(address => bool) public executors;
    mapping(address => uint256) public nonces;            // per-user counter
    mapping(bytes32 => bool) public usedGrants;           // keccak(abi.encode(campaignId, recipient))
    mapping(bytes32 => bool) public usedTweetIds;         // keccak(tweetId)

    /* ------------------------------- events ------------------------------ */

    event P2PExecuted(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        uint256 nonce,
        string tweetId
    );

    event GrantExecuted(
        address indexed sponsor,
        address indexed to,
        uint256 amount,
        uint256 fee,
        string campaignId
    );

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event PlatformFeeUpdated(uint256 oldBps, uint256 newBps);
    event PlatformTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /* ------------------------------- errors ------------------------------ */

    error NotExecutor();
    error FeeTooHigh();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidNonce();
    error TweetIdAlreadyUsed();
    error GrantAlreadyIssued();
    error EmptyId();

    /* ----------------------------- modifiers ---------------------------- */

    modifier onlyExecutor() {
        if (!executors[msg.sender]) revert NotExecutor();
        _;
    }

    /* ---------------------------- constructor --------------------------- */

    constructor(address stable, address treasury, uint256 feeBps, address initialExecutor) {
        if (stable == address(0) || treasury == address(0) || initialExecutor == address(0)) {
            revert ZeroAddress();
        }
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        STABLE = IERC20(stable);
        platformTreasury = treasury;
        platformFeeBps = feeBps;

        executors[initialExecutor] = true;
        emit ExecutorAdded(initialExecutor);
    }

    /* -------------------------------- p2p -------------------------------- */

    /// @notice Move `amount` of stablecoin from `from` to `to` on behalf of an
    ///         off-chain social command. `from` must have approved this router
    ///         for at least `amount + fee`.
    /// @param  nonce   Must equal `nonces[from]` (strict ordering).
    /// @param  tweetId Off-chain dedup key (e.g. Twitter status id, Telegram
    ///                 message id, Discord interaction id). Reused tweetIds
    ///                 revert — protects against a malicious executor
    ///                 replaying the same social command twice.
    function executeP2P(
        address from,
        address to,
        uint256 amount,
        uint256 nonce,
        string calldata tweetId
    ) external onlyExecutor nonReentrant whenNotPaused {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (bytes(tweetId).length == 0) revert EmptyId();
        if (nonces[from] != nonce) revert InvalidNonce();

        bytes32 tweetKey = keccak256(bytes(tweetId));
        if (usedTweetIds[tweetKey]) revert TweetIdAlreadyUsed();
        usedTweetIds[tweetKey] = true;
        nonces[from] = nonce + 1;

        (uint256 fee, uint256 net) = calculateFee(amount);

        STABLE.safeTransferFrom(from, to, net);
        if (fee > 0) {
            STABLE.safeTransferFrom(from, platformTreasury, fee);
        }

        emit P2PExecuted(from, to, net, fee, nonce, tweetId);
    }

    /* ------------------------------ grants ------------------------------ */

    /// @notice Distribute a grant from `sponsor` (the campaign treasury) to
    ///         `to`. `sponsor` must have approved this router for at least
    ///         `amount`. One grant per (campaignId, recipient).
    /// @dev    Dedup key uses `abi.encode` (not `abi.encodePacked`) to avoid
    ///         the theoretical collision where two distinct `(campaignId, to)`
    ///         pairs hash to the same value because their concatenation is
    ///         ambiguous under packed encoding.
    function executeGrant(
        address sponsor,
        address to,
        uint256 amount,
        string calldata campaignId
    ) external onlyExecutor nonReentrant whenNotPaused {
        if (sponsor == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (bytes(campaignId).length == 0) revert EmptyId();

        bytes32 grantKey = keccak256(abi.encode(campaignId, to));
        if (usedGrants[grantKey]) revert GrantAlreadyIssued();
        usedGrants[grantKey] = true;

        (uint256 fee, uint256 net) = calculateFee(amount);

        STABLE.safeTransferFrom(sponsor, to, net);
        if (fee > 0) {
            STABLE.safeTransferFrom(sponsor, platformTreasury, fee);
        }

        emit GrantExecuted(sponsor, to, net, fee, campaignId);
    }

    /* ------------------------------ helpers ----------------------------- */

    function calculateFee(uint256 amount) public view returns (uint256 fee, uint256 net) {
        fee = (amount * platformFeeBps) / BPS_DENOMINATOR;
        net = amount - fee;
    }

    function isGrantIssued(string calldata campaignId, address recipient) external view returns (bool) {
        return usedGrants[keccak256(abi.encode(campaignId, recipient))];
    }

    function isTweetUsed(string calldata tweetId) external view returns (bool) {
        return usedTweetIds[keccak256(bytes(tweetId))];
    }

    /* ------------------------------ admin ------------------------------- */

    function addExecutor(address executor) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        executors[executor] = true;
        emit ExecutorAdded(executor);
    }

    function removeExecutor(address executor) external onlyOwner {
        executors[executor] = false;
        emit ExecutorRemoved(executor);
    }

    function setPlatformFee(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 old = platformFeeBps;
        platformFeeBps = newBps;
        emit PlatformFeeUpdated(old, newBps);
    }

    function setPlatformTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = platformTreasury;
        platformTreasury = newTreasury;
        emit PlatformTreasuryUpdated(old, newTreasury);
    }

    /// @notice Emergency pause — blocks new P2P + grant executions. Existing
    ///         user approvals stay live; users can revoke them from any
    ///         wallet (`approve(this, 0)`).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
