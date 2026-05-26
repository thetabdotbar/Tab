// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/// @title TabEscrowRouter
/// @notice Non-custodial open-tab escrow. Two flows:
///
///         1. HANDLE escrow — sender locks funds against a Tab handle. An
///            off-chain executor releases the funds to the recipient's wallet
///            once they sign up + claim the handle. Used when sender + recipient
///            have coordinated which handle the recipient will pick.
///
///         2. CODE escrow — sender locks funds against a secret. Anyone who
///            knows the secret (typically embedded in a share link) can claim
///            them to their own wallet, no handle required. This is the
///            "send to any wallet" / "magic claim link" path — used when the
///            recipient hasn't joined Tab yet and the sender can't coordinate
///            a handle in advance.
///
///         Sender can refund either type after the deadline if nobody claimed.
///
///         Fee is snapshotted at creation time so retroactive fee changes
///         don't hit users with an already-locked escrow.
///
///         Pause halts NEW escrow creation only; existing claims + refunds
///         always work so user funds can never be trapped by an emergency pause.
contract TabEscrowRouter is Ownable, EIP712, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* ----------------------------- constants ----------------------------- */

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 500;             // 5% hard cap
    uint256 public constant MIN_DEADLINE_WINDOW = 1 hours; // sender can't lock funds for <1h
    uint256 public constant MAX_DEADLINE_WINDOW = 90 days; // ... or >90d

    /// keccak256("CreateEscrowHandle(address sender,string handleSlug,uint256 amount,uint256 deadline,uint256 senderNonce)")
    bytes32 public constant CREATE_ESCROW_HANDLE_TYPEHASH =
        keccak256("CreateEscrowHandle(address sender,string handleSlug,uint256 amount,uint256 deadline,uint256 senderNonce)");

    /// keccak256("CreateEscrowCode(address sender,bytes32 codeHash,uint256 amount,uint256 deadline,uint256 senderNonce)")
    bytes32 public constant CREATE_ESCROW_CODE_TYPEHASH =
        keccak256("CreateEscrowCode(address sender,bytes32 codeHash,uint256 amount,uint256 deadline,uint256 senderNonce)");

    /* ------------------------------ storage ------------------------------ */

    IERC20 public immutable STABLE;

    address public platformTreasury;
    uint256 public platformFeeBps;

    enum Status { None, Pending, Claimed, Refunded }
    enum ClaimType { Handle, Code }

    struct Escrow {
        address sender;
        bytes32 commitment;     // Handle: keccak256(bytes(handleSlug)). Code: keccak256(bytes(secret)).
        uint256 amount;         // amount locked, before fee
        uint256 deadline;       // unix seconds, sender can refund after this
        uint16  feeBps;         // snapshotted at creation — fee changes after don't affect this escrow
        ClaimType claimType;
        Status status;
    }

    mapping(bytes32 => Escrow) public escrows; // id => Escrow

    mapping(address => bool) public executors;

    /* ------------------------------- events ------------------------------ */

    event EscrowCreated(
        bytes32 indexed id,
        address indexed sender,
        bytes32 indexed commitment,
        ClaimType claimType,
        string handleSlug,       // empty string for Code claims
        uint256 amount,
        uint256 deadline,
        uint16 feeBps
    );

    event EscrowClaimed(
        bytes32 indexed id,
        address indexed recipient,
        uint256 net,
        uint256 fee
    );

    event EscrowRefunded(bytes32 indexed id, address indexed sender, uint256 amount);

    event ExecutorAdded(address indexed executor);
    event ExecutorRemoved(address indexed executor);
    event PlatformFeeUpdated(uint256 oldBps, uint256 newBps);
    event PlatformTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /* ------------------------------- errors ------------------------------ */

    error NotExecutor();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidDeadline();
    error EmptyHandle();
    error EmptyCommitment();
    error EscrowAlreadyExists();
    error EscrowNotPending();
    error EscrowNotExpired();
    error EscrowExpired();
    error FeeTooHigh();
    error HandleMismatch();
    error CodeMismatch();
    error WrongClaimType();
    error InvalidSignature();

    /* ----------------------------- modifiers ---------------------------- */

    modifier onlyExecutor() {
        if (!executors[msg.sender]) revert NotExecutor();
        _;
    }

    /* ---------------------------- constructor --------------------------- */

    constructor(address stable, address treasury, uint256 feeBps, address initialExecutor)
        EIP712("Tab Escrow", "1")
    {
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

    /* --------------------------- create: handle ------------------------- */

    /// @notice Lock `amount` of STABLE against `handleSlug` — recipient must
    ///         own that handle when they claim. Returns a stable id derived
    ///         from sender + handleHash + nonce so multiple parallel escrows
    ///         to the same handle don't collide.
    function createEscrow(
        string calldata handleSlug,
        uint256 amount,
        uint256 deadline,
        uint256 senderNonce
    ) external nonReentrant whenNotPaused returns (bytes32 id) {
        if (bytes(handleSlug).length == 0) revert EmptyHandle();
        bytes32 commitment = keccak256(bytes(handleSlug));
        id = _create(msg.sender, commitment, amount, deadline, senderNonce, ClaimType.Handle, handleSlug);
    }

    /* --------------------------- create: code --------------------------- */

    /// @notice Lock `amount` of STABLE against a secret. The sender hands the
    ///         secret to the recipient (typically embedded in a share URL).
    ///         Anyone who reveals the secret to `claimByCode` gets the funds.
    /// @param  codeHash    keccak256(bytes(secret)). The recipient reveals
    ///                     `secret` and the contract re-hashes to verify.
    /// @param  senderNonce Caller-supplied id namespace so the same sender can
    ///                     have multiple code escrows in flight at once.
    function createEscrowByCode(
        bytes32 codeHash,
        uint256 amount,
        uint256 deadline,
        uint256 senderNonce
    ) external nonReentrant whenNotPaused returns (bytes32 id) {
        if (codeHash == bytes32(0)) revert EmptyCommitment();
        id = _create(msg.sender, codeHash, amount, deadline, senderNonce, ClaimType.Code, "");
    }

    /* ----------------------- create: gasless (handle) ------------------- */

    /// @notice Gasless handle-escrow creation. The sender signs an EIP-712
    ///         `CreateEscrowHandle` message off-chain; an executor submits
    ///         it on-chain and pays the gas. USDC for the escrow itself is
    ///         pulled from `sender`'s allowance via `safeTransferFrom` —
    ///         sender must have approved the router beforehand (either via
    ///         a separate permit() in the same submitted batch, or any
    ///         existing allowance).
    ///
    ///         Replay protection: the resulting escrow `id` is keyed on
    ///         (sender, commitment, senderNonce, claimType). A second
    ///         submission of the same signature reverts with
    ///         `EscrowAlreadyExists` because the storage slot is occupied.
    function createEscrowForHandle(
        address sender,
        string calldata handleSlug,
        uint256 amount,
        uint256 deadline,
        uint256 senderNonce,
        bytes calldata signature
    ) external onlyExecutor nonReentrant whenNotPaused returns (bytes32 id) {
        if (bytes(handleSlug).length == 0) revert EmptyHandle();
        bytes32 commitment = keccak256(bytes(handleSlug));

        // Block-scope the digest so it leaves the stack before the
        // 7-arg _create call below (avoids stack-too-deep in 0.8.20).
        {
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        CREATE_ESCROW_HANDLE_TYPEHASH,
                        sender,
                        commitment,
                        amount,
                        deadline,
                        senderNonce
                    )
                )
            );
            if (ECDSA.recover(digest, signature) != sender) revert InvalidSignature();
        }

        id = _create(sender, commitment, amount, deadline, senderNonce, ClaimType.Handle, handleSlug);
    }

    /* ----------------------- create: gasless (code) --------------------- */

    /// @notice Gasless code-escrow creation. Same pattern as
    ///         `createEscrowForHandle` but commits a raw `codeHash` instead
    ///         of a handle string.
    function createEscrowForCode(
        address sender,
        bytes32 codeHash,
        uint256 amount,
        uint256 deadline,
        uint256 senderNonce,
        bytes calldata signature
    ) external onlyExecutor nonReentrant whenNotPaused returns (bytes32 id) {
        if (codeHash == bytes32(0)) revert EmptyCommitment();

        // See createEscrowForHandle for the rationale on block-scoping.
        {
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        CREATE_ESCROW_CODE_TYPEHASH,
                        sender,
                        codeHash,
                        amount,
                        deadline,
                        senderNonce
                    )
                )
            );
            if (ECDSA.recover(digest, signature) != sender) revert InvalidSignature();
        }

        id = _create(sender, codeHash, amount, deadline, senderNonce, ClaimType.Code, "");
    }

    function _create(
        address sender,
        bytes32 commitment,
        uint256 amount,
        uint256 deadline,
        uint256 senderNonce,
        ClaimType claimType,
        string memory handleSlug
    ) internal returns (bytes32 id) {
        if (amount == 0) revert InvalidAmount();
        if (
            deadline < block.timestamp + MIN_DEADLINE_WINDOW ||
            deadline > block.timestamp + MAX_DEADLINE_WINDOW
        ) revert InvalidDeadline();

        // ID derivation: include claimType so a handle and code escrow with
        // the same commitment+nonce don't collide on `id`.
        id = keccak256(abi.encode(sender, commitment, senderNonce, claimType));
        if (escrows[id].status != Status.None) revert EscrowAlreadyExists();

        uint16 snapshotFeeBps = uint16(platformFeeBps);
        escrows[id] = Escrow({
            sender: sender,
            commitment: commitment,
            amount: amount,
            deadline: deadline,
            feeBps: snapshotFeeBps,
            claimType: claimType,
            status: Status.Pending
        });

        STABLE.safeTransferFrom(sender, address(this), amount);

        emit EscrowCreated(id, sender, commitment, claimType, handleSlug, amount, deadline, snapshotFeeBps);
    }

    /* ----------------------------- claim: handle ----------------------- */

    /// @notice Release a HANDLE escrow to `recipient` (minus fee). The executor
    ///         MUST verify off-chain that `recipient` owns the handle this
    ///         escrow was opened against — this contract only enforces that an
    ///         executor signed off + that the handle slug hashes correctly.
    function claim(
        bytes32 id,
        string calldata handleSlug,
        address recipient
    ) external onlyExecutor nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        Escrow memory e = escrows[id];
        if (e.status != Status.Pending) revert EscrowNotPending();
        if (e.claimType != ClaimType.Handle) revert WrongClaimType();
        if (block.timestamp > e.deadline) revert EscrowExpired();
        if (keccak256(bytes(handleSlug)) != e.commitment) revert HandleMismatch();

        _settle(id, e, recipient);
    }

    /* ----------------------------- claim: code ------------------------- */

    /// @notice Release a CODE escrow to the caller (minus fee). Anyone who
    ///         reveals the secret can claim — single-use, the escrow flips to
    ///         Claimed on the first successful reveal. Caller pays gas to
    ///         their own wallet; for sponsored / gasless claims use
    ///         `claimByCodeFor` (executor calls on behalf of a recipient).
    /// @param  secret The preimage of the codeHash committed at creation.
    function claimByCode(
        bytes32 id,
        bytes calldata secret
    ) external nonReentrant {
        Escrow memory e = escrows[id];
        if (e.status != Status.Pending) revert EscrowNotPending();
        if (e.claimType != ClaimType.Code) revert WrongClaimType();
        if (block.timestamp > e.deadline) revert EscrowExpired();
        if (keccak256(secret) != e.commitment) revert CodeMismatch();

        _settle(id, e, msg.sender);
    }

    /// @notice Sponsored variant of `claimByCode`. An executor calls on
    ///         behalf of `recipient`, paying gas. Used for "click link →
    ///         instant funds" flows where the recipient has no native gas
    ///         token in their wallet yet (giveaway / airdrop / tipbot UX).
    ///         The executor presenting a valid secret IS the authorization
    ///         — secrets are short-lived and embedded in the recipient's
    ///         share link, so possessing the secret + knowing where to send
    ///         is itself the consent.
    /// @param  recipient The wallet that should actually receive the funds.
    /// @param  secret    The preimage of the codeHash committed at creation.
    function claimByCodeFor(
        bytes32 id,
        address recipient,
        bytes calldata secret
    ) external onlyExecutor nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        Escrow memory e = escrows[id];
        if (e.status != Status.Pending) revert EscrowNotPending();
        if (e.claimType != ClaimType.Code) revert WrongClaimType();
        if (block.timestamp > e.deadline) revert EscrowExpired();
        if (keccak256(secret) != e.commitment) revert CodeMismatch();

        _settle(id, e, recipient);
    }

    function _settle(bytes32 id, Escrow memory e, address recipient) internal {
        escrows[id].status = Status.Claimed;

        // Use the SNAPSHOTTED feeBps from the escrow, not the live platformFeeBps,
        // so post-creation fee changes don't retroactively hit this user.
        uint256 fee = (e.amount * e.feeBps) / BPS_DENOMINATOR;
        uint256 net = e.amount - fee;

        if (fee > 0) STABLE.safeTransfer(platformTreasury, fee);
        STABLE.safeTransfer(recipient, net);

        emit EscrowClaimed(id, recipient, net, fee);
    }

    /* ------------------------------ refund ------------------------------ */

    /// @notice After the deadline, anyone can refund the sender. Pull pattern
    ///         keeps the executor key out of the refund path. Refund works
    ///         even when the contract is paused — funds are never trapped.
    function refund(bytes32 id) external nonReentrant {
        Escrow memory e = escrows[id];
        if (e.status != Status.Pending) revert EscrowNotPending();
        if (block.timestamp <= e.deadline) revert EscrowNotExpired();

        escrows[id].status = Status.Refunded;
        STABLE.safeTransfer(e.sender, e.amount);

        emit EscrowRefunded(id, e.sender, e.amount);
    }

    /* ------------------------------ helpers ----------------------------- */

    function calculateFee(uint256 amount) public view returns (uint256 fee, uint256 net) {
        fee = (amount * platformFeeBps) / BPS_DENOMINATOR;
        net = amount - fee;
    }

    /// @notice Fee on a specific escrow, using the snapshotted feeBps. Useful
    ///         for UI to display the exact fee that will be deducted on claim.
    function escrowFee(bytes32 id) external view returns (uint256 fee, uint256 net) {
        Escrow memory e = escrows[id];
        fee = (e.amount * e.feeBps) / BPS_DENOMINATOR;
        net = e.amount - fee;
    }

    function escrowExists(bytes32 id) external view returns (bool) {
        return escrows[id].status != Status.None;
    }

    function computeHandleId(
        address sender,
        string calldata handleSlug,
        uint256 senderNonce
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(sender, keccak256(bytes(handleSlug)), senderNonce, ClaimType.Handle));
    }

    function computeCodeId(
        address sender,
        bytes32 codeHash,
        uint256 senderNonce
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(sender, codeHash, senderNonce, ClaimType.Code));
    }

    /// @notice Domain separator for EIP-712 signatures consumed by the
    ///         gasless `createEscrowFor*` entrypoints. Off-chain clients
    ///         can read this to verify their typed-data domain before
    ///         signing.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /* ------------------------------- admin ------------------------------ */

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

    /// @notice Emergency pause — blocks NEW escrow creation only. Existing
    ///         escrows can still be claimed and refunded. Funds are never
    ///         trapped by this pause.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
