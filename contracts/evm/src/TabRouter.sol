// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/// @title TabRouter
/// @notice Non-custodial, gasless stablecoin payment router. A user signs an
///         EIP-712 `Payment` message authorizing exactly one transfer; any
///         relayer can then submit it on-chain and pay the gas. The router
///         pulls `amount + fee` from the sender via `transferFrom`, forwards
///         `amount` to the recipient and `fee` to the treasury.
///
///         Modeled on Monipay's MoniPayRouter (verified on Base and BSC).
///         Hardened by enforcing `fee == calculateFee(amount)` so a malicious
///         relayer cannot trick a user into signing an inflated fee.
///
///         Fee is configurable (owner-only, capped at 500 BPS = 5%) so we
///         don't need a contract redeploy to adjust pricing across chains.
///
///         Pause halts new `relayPayment` calls; pre-signed messages just
///         queue until the contract is unpaused.
contract TabRouter is Ownable, EIP712, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* ----------------------------- constants ----------------------------- */

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 500;            // 5% hard cap

    /// keccak256("Payment(address from,address to,uint256 amount,uint256 fee,uint256 nonce,uint256 deadline)")
    bytes32 public constant PAYMENT_TYPEHASH =
        keccak256("Payment(address from,address to,uint256 amount,uint256 fee,uint256 nonce,uint256 deadline)");

    /* ------------------------------ storage ------------------------------ */

    /// @notice The single stablecoin this router settles in (e.g. USDC on Base, USDT on BSC).
    IERC20 public immutable STABLE;

    /// @notice Receiver of the protocol fee.
    address public platformTreasury;

    /// @notice Configurable platform fee in basis points (0..MAX_FEE_BPS).
    ///         Public so off-chain clients can read it before signing.
    uint256 public platformFeeBps;

    /// @notice Per-user unordered nonce set. nonces[user][nonce] = true means consumed.
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /// @notice Lifetime totals for off-chain analytics.
    uint256 public totalVolume;
    uint256 public totalFeesCollected;

    /* ------------------------------- events ------------------------------ */

    event PaymentRelayed(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        uint256 nonce,
        bytes32 indexed digest
    );

    event PlatformFeeUpdated(uint256 oldBps, uint256 newBps);
    event PlatformTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /* ------------------------------- errors ------------------------------ */

    error InvalidAmount();
    error InvalidFee();
    error ZeroAddress();
    error ExpiredDeadline();
    error NonceAlreadyUsed();
    error InvalidSignature();
    error FeeTooHigh();

    /* ---------------------------- constructor --------------------------- */

    constructor(address stable, address treasury, uint256 feeBps) EIP712("Tab Router", "1") {
        if (stable == address(0) || treasury == address(0)) revert ZeroAddress();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        STABLE = IERC20(stable);
        platformTreasury = treasury;
        platformFeeBps = feeBps;
    }

    /* ------------------------------ payment ------------------------------ */

    /// @notice Settle a payment authorized by `from` via an EIP-712 signature.
    /// @dev Permissionless: the signature is the authorization. Any address
    ///      may submit. Replay protection is the per-user `usedNonces` set.
    function relayPayment(
        address from,
        address to,
        uint256 amount,
        uint256 fee,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (to == address(0) || from == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (fee != calculateFee(amount)) revert InvalidFee();
        if (block.timestamp > deadline) revert ExpiredDeadline();
        if (usedNonces[from][nonce]) revert NonceAlreadyUsed();

        bytes32 structHash = keccak256(
            abi.encode(PAYMENT_TYPEHASH, from, to, amount, fee, nonce, deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(digest, signature);
        if (signer != from) revert InvalidSignature();

        usedNonces[from][nonce] = true;
        totalVolume += amount;
        totalFeesCollected += fee;

        STABLE.safeTransferFrom(from, to, amount);
        if (fee > 0) {
            STABLE.safeTransferFrom(from, platformTreasury, fee);
        }

        emit PaymentRelayed(from, to, amount, fee, nonce, digest);
    }

    /* ------------------------------ helpers ----------------------------- */

    function calculateFee(uint256 amount) public view returns (uint256) {
        return (amount * platformFeeBps) / BPS_DENOMINATOR;
    }

    function isNonceUsed(address user, uint256 nonce) external view returns (bool) {
        return usedNonces[user][nonce];
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashPayment(
        address from,
        address to,
        uint256 amount,
        uint256 fee,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(PAYMENT_TYPEHASH, from, to, amount, fee, nonce, deadline))
        );
    }

    /* ------------------------------ admin ------------------------------- */

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

    /// @notice Emergency pause — blocks new relays. Pre-signed payments stay
    ///         valid until their deadline and can be submitted once unpaused.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
