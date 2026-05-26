// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/// @title TabSubscriptionRouter
/// @notice Recurring stablecoin payments. A creator publishes a Plan; each
///         subscriber pre-approves the router as an ERC-20 spender; an
///         off-chain cron (or anyone, permissionlessly) calls `charge` once
///         per period. Funds flow subscriber → (creator, platform fee).
///
///         Trust model:
///         * Subscribers retain full custody of their tokens. Cancelling
///           the subscription, revoking the allowance, or letting the
///           balance fall below `amount` all halt charges immediately —
///           there is no escrow.
///         * Anyone may call `charge` for any subscription. The contract
///           strictly enforces the period schedule, so duplicate or early
///           calls revert. Custom errors distinguish reasons so off-chain
///           cron jobs can self-diagnose.
///         * Plans, fees, and the platform treasury are owner-controlled.
///           Subscribers can always cancel.
///         * The platform fee is SNAPSHOTTED on each plan at creation, so
///           later admin fee changes don't retroactively affect subscribers
///           who signed up under an earlier rate.
///
///         Pause halts new subscriptions and new charges; cancel always
///         works so users are never locked into being billed.
///
///         Use cases: paid Discord communities, SaaS billing, creator
///         memberships, recurring tips.
contract TabSubscriptionRouter is Ownable, EIP712, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* ----------------------------- constants ----------------------------- */

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 500; // 5% absolute cap
    uint256 public constant MIN_PERIOD = 1 hours;
    uint256 public constant MAX_PERIOD = 365 days;

    /// keccak256("CreatePlan(address creator,string planId,uint256 amount,uint64 period,uint256 nonce,uint256 deadline)")
    bytes32 public constant CREATE_PLAN_TYPEHASH =
        keccak256("CreatePlan(address creator,string planId,uint256 amount,uint64 period,uint256 nonce,uint256 deadline)");

    /// keccak256("Subscribe(address subscriber,bytes32 planKey,uint256 nonce,uint256 deadline)")
    bytes32 public constant SUBSCRIBE_TYPEHASH =
        keccak256("Subscribe(address subscriber,bytes32 planKey,uint256 nonce,uint256 deadline)");

    /* ------------------------------ storage ------------------------------ */

    IERC20 public immutable STABLE;

    address public platformTreasury;
    /// @notice The CURRENT default fee. New plans snapshot this; existing
    ///         plans keep the fee they were created with.
    uint256 public platformFeeBps;

    struct Plan {
        address creator;        // who receives the net (after fee)
        uint256 amount;         // per-period charge in stable's smallest unit
        uint64  period;         // seconds between charges
        uint16  feeBps;         // snapshotted at plan creation (immune to later fee changes)
        bool    active;         // creator can deactivate to halt new charges
    }

    struct Subscription {
        bool    active;
        uint64  startedAt;
        uint64  lastChargedAt;  // 0 until first charge
        uint64  cancelledAt;    // 0 unless cancelled
        uint256 chargesPaid;    // count of successful charges (telemetry)
    }

    // planId is creator-chosen and must be unique per creator. Effective
    // identity is (creator, planId) so two creators can't collide.
    mapping(bytes32 => Plan) public plans;                              // planKey → Plan
    mapping(address => mapping(bytes32 => Subscription)) public subs;   // subscriber → planKey → Sub

    /* ------------------------------- events ------------------------------ */

    event PlanCreated(
        bytes32 indexed planKey,
        address indexed creator,
        string planId,
        uint256 amount,
        uint64 period,
        uint16 feeBps
    );
    event PlanDeactivated(bytes32 indexed planKey, address indexed creator);
    event PlanReactivated(bytes32 indexed planKey, address indexed creator);
    event Subscribed(bytes32 indexed planKey, address indexed subscriber);
    event Cancelled(bytes32 indexed planKey, address indexed subscriber);
    event Charged(
        bytes32 indexed planKey,
        address indexed subscriber,
        address indexed creator,
        uint256 amount,
        uint256 fee,
        uint64  newLastChargedAt
    );
    event PlatformFeeUpdated(uint256 oldBps, uint256 newBps);
    event PlatformTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /* ------------------------------- errors ------------------------------ */

    error FeeTooHigh();
    error ZeroAddress();
    error InvalidPeriod();
    error InvalidAmount();
    error PlanExists();
    error PlanMissing();
    error NotCreator();
    error PlanInactive();
    error PlanAlreadyActive();
    error AlreadySubscribed();
    error NotSubscribed();
    error TooEarly();
    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidSignature();
    error ExpiredDeadline();
    error NonceAlreadyUsed();

    /// @notice Per-user unordered nonces consumed by the gasless `*For`
    ///         entrypoints. Independent of the on-chain plan/subscription
    ///         state so it doesn't pollute the existing flow.
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /* ----------------------------- constructor --------------------------- */

    constructor(IERC20 stable, address treasury, uint256 feeBps)
        EIP712("Tab Subscription", "1")
    {
        if (address(stable) == address(0) || treasury == address(0)) revert ZeroAddress();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        STABLE = stable;
        platformTreasury = treasury;
        platformFeeBps = feeBps;
    }

    /* ------------------------------ creator ----------------------------- */

    /// @notice Create a new plan. `planId` is a creator-scoped string —
    ///         the on-chain identity is `keccak256(creator, planId)`, so
    ///         different creators can use the same id without conflict.
    ///         The current platformFeeBps is SNAPSHOTTED onto the plan at
    ///         this moment; later fee changes don't apply to this plan.
    function createPlan(
        string calldata planId,
        uint256 amount,
        uint64 period
    ) external whenNotPaused returns (bytes32 planKey) {
        planKey = _createPlan(msg.sender, planId, amount, period);
    }

    /// @notice Gasless plan creation. Creator signs an EIP-712
    ///         `CreatePlan` message off-chain; any relayer submits it
    ///         and pays the gas. Plan creation moves no funds, so the
    ///         signature alone is full authorization — no executor
    ///         allowlist needed. Replay-protected via per-creator nonce.
    function createPlanFor(
        address creator,
        string calldata planId,
        uint256 amount,
        uint64 period,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused returns (bytes32 planKey) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_PLAN_TYPEHASH,
                creator,
                keccak256(bytes(planId)),
                amount,
                period,
                nonce,
                deadline
            )
        );
        _verifyAndConsume(creator, nonce, deadline, structHash, signature);
        planKey = _createPlan(creator, planId, amount, period);
    }

    function _createPlan(
        address creator,
        string calldata planId,
        uint256 amount,
        uint64 period
    ) internal returns (bytes32 planKey) {
        if (amount == 0) revert InvalidAmount();
        if (period < MIN_PERIOD || period > MAX_PERIOD) revert InvalidPeriod();
        if (bytes(planId).length == 0) revert PlanMissing();

        planKey = _planKey(creator, planId);
        if (plans[planKey].creator != address(0)) revert PlanExists();

        uint16 snapshotFeeBps = uint16(platformFeeBps);
        plans[planKey] = Plan({
            creator: creator,
            amount: amount,
            period: period,
            feeBps: snapshotFeeBps,
            active: true
        });
        emit PlanCreated(planKey, creator, planId, amount, period, snapshotFeeBps);
    }

    function deactivatePlan(bytes32 planKey) external {
        Plan storage p = plans[planKey];
        if (p.creator == address(0)) revert PlanMissing();
        if (p.creator != msg.sender) revert NotCreator();
        if (!p.active) revert PlanInactive();
        p.active = false;
        emit PlanDeactivated(planKey, msg.sender);
    }

    function reactivatePlan(bytes32 planKey) external {
        Plan storage p = plans[planKey];
        if (p.creator == address(0)) revert PlanMissing();
        if (p.creator != msg.sender) revert NotCreator();
        if (p.active) revert PlanAlreadyActive();
        p.active = true;
        emit PlanReactivated(planKey, msg.sender);
    }

    /* ---------------------------- subscriber ---------------------------- */

    /// @notice Subscribe to a plan. Charges the first period immediately so
    ///         the relationship begins funded (mirrors typical SaaS UX).
    function subscribe(bytes32 planKey) external nonReentrant whenNotPaused {
        _subscribe(msg.sender, planKey);
    }

    /// @notice Gasless subscribe. Subscriber signs an EIP-712 `Subscribe`
    ///         message off-chain; relayer submits it and pays the gas.
    ///         The first-period charge is still pulled from the
    ///         subscriber's USDC allowance — that allowance can be
    ///         established gaslessly via `permit()` on chains where the
    ///         stablecoin supports EIP-2612 (Base USDC, Ink USDT0).
    function subscribeFor(
        address subscriber,
        bytes32 planKey,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        bytes32 structHash = keccak256(
            abi.encode(SUBSCRIBE_TYPEHASH, subscriber, planKey, nonce, deadline)
        );
        _verifyAndConsume(subscriber, nonce, deadline, structHash, signature);
        _subscribe(subscriber, planKey);
    }

    function _subscribe(address subscriber, bytes32 planKey) internal {
        Plan memory p = plans[planKey];
        if (p.creator == address(0)) revert PlanMissing();
        if (!p.active) revert PlanInactive();

        Subscription storage s = subs[subscriber][planKey];
        if (s.active) revert AlreadySubscribed();

        s.active = true;
        s.startedAt = uint64(block.timestamp);
        s.lastChargedAt = uint64(block.timestamp);
        s.cancelledAt = 0;
        s.chargesPaid = s.chargesPaid + 1;

        emit Subscribed(planKey, subscriber);
        _moveFunds(p, subscriber);
        emit Charged(planKey, subscriber, p.creator, p.amount, _planFee(p), s.lastChargedAt);
    }

    /// @notice Shared verification path for the gasless `*For` entrypoints.
    ///         Checks the deadline, recovers the signer, enforces it matches
    ///         the claimed `signer`, and consumes the unordered nonce.
    function _verifyAndConsume(
        address signer,
        uint256 nonce,
        uint256 deadline,
        bytes32 structHash,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert ExpiredDeadline();
        if (usedNonces[signer][nonce]) revert NonceAlreadyUsed();
        bytes32 digest = _hashTypedDataV4(structHash);
        if (ECDSA.recover(digest, signature) != signer) revert InvalidSignature();
        usedNonces[signer][nonce] = true;
    }

    /// @notice Cancel always works — even while paused — so subscribers can
    ///         never be locked into being billed.
    function cancel(bytes32 planKey) external {
        Subscription storage s = subs[msg.sender][planKey];
        if (!s.active) revert NotSubscribed();
        s.active = false;
        s.cancelledAt = uint64(block.timestamp);
        emit Cancelled(planKey, msg.sender);
    }

    /* ------------------------------ charge ------------------------------ */

    /// @notice Permissionless charge. Reverts with a specific error so the
    ///         caller can distinguish "wait" / "user cancelled" / "ran out of
    ///         money" / "approval revoked".
    function charge(bytes32 planKey, address subscriber) external nonReentrant whenNotPaused {
        Plan memory p = plans[planKey];
        if (p.creator == address(0)) revert PlanMissing();
        if (!p.active) revert PlanInactive();

        Subscription storage s = subs[subscriber][planKey];
        if (!s.active) revert NotSubscribed();
        if (block.timestamp < uint256(s.lastChargedAt) + p.period) revert TooEarly();

        // Pre-flight balance + allowance check so the cron knows WHY a charge
        // failed instead of just seeing a SafeERC20 revert.
        if (STABLE.balanceOf(subscriber) < p.amount) revert InsufficientBalance();
        if (STABLE.allowance(subscriber, address(this)) < p.amount) revert InsufficientAllowance();

        // Update bookkeeping before external transfer (CEI).
        s.lastChargedAt = uint64(block.timestamp);
        s.chargesPaid = s.chargesPaid + 1;

        _moveFunds(p, subscriber);
        emit Charged(planKey, subscriber, p.creator, p.amount, _planFee(p), s.lastChargedAt);
    }

    /* ------------------------------ admin ------------------------------ */

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

    /// @notice Emergency pause — blocks new plans, subscriptions, and
    ///         charges. Cancel works regardless so subscribers never feel
    ///         trapped.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ------------------------------ views ------------------------------ */

    function planKeyOf(address creator, string calldata planId) external pure returns (bytes32) {
        return _planKey(creator, planId);
    }

    /// @notice Current default fee on a fresh `amount` (NOT the fee on any
    ///         specific existing plan — use plans[key].feeBps for that).
    function feeOf(uint256 amount) external view returns (uint256) {
        return (amount * platformFeeBps) / BPS_DENOMINATOR;
    }

    /// @notice The actual fee snapshotted on a specific plan.
    function planFeeBps(bytes32 planKey) external view returns (uint16) {
        return plans[planKey].feeBps;
    }

    /// @notice EIP-712 domain separator used by the gasless `*For`
    ///         entrypoints. Off-chain clients can read this to validate
    ///         their typed-data domain before signing.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function isNonceUsed(address user, uint256 nonce) external view returns (bool) {
        return usedNonces[user][nonce];
    }

    /// @notice Whether a subscription is currently chargeable in this block.
    function isChargeable(bytes32 planKey, address subscriber) external view returns (bool) {
        Plan memory p = plans[planKey];
        if (p.creator == address(0) || !p.active) return false;
        Subscription memory s = subs[subscriber][planKey];
        if (!s.active) return false;
        if (block.timestamp < uint256(s.lastChargedAt) + p.period) return false;
        if (STABLE.allowance(subscriber, address(this)) < p.amount) return false;
        if (STABLE.balanceOf(subscriber) < p.amount) return false;
        return true;
    }

    /* ----------------------------- internal ---------------------------- */

    function _planKey(address creator, string calldata planId) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, planId));
    }

    function _planFee(Plan memory p) internal pure returns (uint256) {
        return (p.amount * p.feeBps) / BPS_DENOMINATOR;
    }

    function _moveFunds(Plan memory p, address from) internal {
        uint256 fee = _planFee(p);
        uint256 net = p.amount - fee;
        STABLE.safeTransferFrom(from, p.creator, net);
        if (fee > 0) {
            STABLE.safeTransferFrom(from, platformTreasury, fee);
        }
    }
}
