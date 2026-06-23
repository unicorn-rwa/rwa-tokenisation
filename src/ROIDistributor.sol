// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {PropertyFunding} from "./PropertyFunding.sol";
import {PropertyToken} from "./PropertyToken.sol";

/**
 * @title ROIDistributor
 * @notice Handles principal + ROI payouts to investors after project completion.
 *         One instance is deployed per property by the factory — each SPV has
 *         its own isolated distributor, controlled by its own spvTreasury Safe.
 *
 *         Two-step distribution flow:
 *           1. spvTreasury calls commitDistribution() with the full claimants list,
 *              sorted strictly ascending by wallet. The Merkle root is computed
 *              ON-CHAIN from that exact calldata, so claim() can never disagree with
 *              what was committed. The list is NOT stored on-chain (H-B gas) — it is
 *              emitted in full in the DistributionCommitted event, which (together with
 *              the tx calldata) is the permanent, authoritative record. Off-chain
 *              consumers read the event to display / verify the distribution.
 *           2. spvTreasury calls depositFunds() one or more times until the full
 *              required amount is deposited. Claims auto-unlock when totalDeposited
 *              reaches totalRequired.
 *           3. Each investor calls claim() with their Merkle proof.
 *
 *         Error recovery (before claims are enabled):
 *           withdrawDeposit() — pulls partial USDC back to spvTreasury so the
 *                               commitment can be cancelled and recommitted.
 *           cancelCommitment() — clears the tree (only when totalDeposited == 0).
 *
 *         Unclaimed funds recovery:
 *           recoverFunds() — sweeps remaining USDC to spvTreasury after RECOVERY_DELAY
 *                            (180 days from when claims are enabled — see H-1).
 *
 * Roles:
 *   DEFAULT_ADMIN_ROLE — per-property financial Gnosis Safe (spvTreasury)
 *   ADMIN_ROLE         — per-property financial Gnosis Safe; drives distribution
 */
contract ROIDistributor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IERC20  public immutable usdc;
    address public immutable project;            // PropertyFunding this distributor serves
    address public immutable withdrawRecipient;  // spvTreasury: destination for withdrawDeposit() and recoverFunds()

    /// @notice 180 days from when claims are enabled (full deposit received) before
    ///         unclaimed funds can be recovered.
    uint256 public constant RECOVERY_DELAY = 180 days;

    /// @notice Hard cap on committed claimants — mirrors PropertyFunding.MAX_INVESTORS
    ///         (the claimant set is the investor set). Guarantees commitDistribution()
    ///         always fits in a block regardless of input (H-B). Keep in sync.
    uint256 public constant MAX_CLAIMANTS = 2000;

    /// @notice Basis-point denominator (100% = 10_000).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Slack added over finalROIBps when capping a claim (I-3), to absorb the
    ///         operator's pro-rata rounding / dust. Small enough that it can't meaningfully
    ///         inflate a payout — a claim may exceed principal*(1+finalROI) by at most 0.25%.
    uint256 public constant CLAIM_CAP_BUFFER_BPS = 25;

    // ─── Data structures ──────────────────────────────────────────────────────

    struct Claimant {
        address wallet;
        uint256 amount;
    }

    struct Distribution {
        bytes32 merkleRoot;     // computed on-chain from the committed calldata — never set manually
        uint256 totalRequired;  // sum of all claimant amounts
        uint256 totalDeposited; // USDC actually transferred into this contract
        uint256 totalClaimed;   // USDC paid out to investors
    }

    Distribution public distribution;
    // NOTE: the claimant list is intentionally NOT stored on-chain (H-B gas). It lives in
    // the DistributionCommitted event + tx calldata, and the Merkle root is derived from it.
    mapping(address => bool) public claimed;

    /// @notice Timestamp after which recoverFunds() may be called.
    ///         Set when claims are enabled (totalDeposited first reaches totalRequired),
    ///         NOT at commit time — this guarantees investors always get the full
    ///         RECOVERY_DELAY window to claim after claims open (H-1). A delay between
    ///         commitDistribution() and depositFunds() can no longer compress that window.
    ///         0 = claims not yet enabled (never committed, or committed but underfunded).
    uint256 public recoveryUnlocksAt;

    // ─── Events ────────────────────────────────────────────────────────────────
    // claimants carries the FULL committed list (event is the on-chain record of the tree)
    event DistributionCommitted(bytes32 indexed merkleRoot, uint256 totalRequired, uint256 claimantCount, Claimant[] claimants);
    event FundsDeposited(uint256 amount, uint256 totalDeposited);
    event ClaimsEnabled(uint256 totalDeposited);
    event CommitmentCancelled();
    event DepositWithdrawn(uint256 amount);
    event FundsRecovered(uint256 amount);
    event ROIClaimed(address indexed investor, uint256 usdcAmount);

    // ─── Errors ────────────────────────────────────────────────────────────────
    error AlreadyClaimed();
    error ClaimExceedsEntitlement(uint256 requested, uint256 maxAllowed);
    error AlreadyCommitted();
    error AlreadyFullyFunded();
    error ClaimsAlreadyEnabled();
    error ClaimsNotEnabled();
    error DepositNotEmpty();
    error UnsortedClaimants(address wallet);
    error TooManyClaimants();
    error EmptyClaimants();
    error InvalidProof();
    error NoCommitment();
    error NothingToRecover();
    error ProjectNotCompleted();
    error RecoveryTooEarly();
    error ZeroAddress();
    error ZeroAmount();

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param admin_   Per-property financial Gnosis Safe (spvTreasury).
     *                 Holds ADMIN_ROLE and is the only valid destination for
     *                 withdrawDeposit() and recoverFunds().
     * @param usdc_    USDC token address.
     * @param project_ PropertyFunding contract address this distributor serves.
     */
    constructor(address admin_, address usdc_, address project_) {
        if (admin_ == address(0) || usdc_ == address(0) || project_ == address(0))
            revert ZeroAddress();
        usdc              = IERC20(usdc_);
        project           = project_;
        withdrawRecipient = admin_; // spvTreasury is both the admin and the only valid recovery destination
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ─── Admin: commit ─────────────────────────────────────────────────────────

    /**
     * @notice Commit the distribution tree. The Merkle root is computed on-chain from
     *         `claimants_`, guaranteeing claim() can never disagree with what was
     *         committed. No USDC is transferred at this step.
     *
     *         `claimants_` MUST be sorted strictly ascending by wallet. Ascending order
     *         is verified in a single O(n) pass that simultaneously enforces:
     *           - no duplicate wallets (each must be > the previous), and
     *           - no zero address (the first must be > address(0)).
     *         This replaces the old O(n²) storage-read dedup (H-B). The claimant list is
     *         NOT persisted on-chain — it is emitted in full in DistributionCommitted, so
     *         commitDistribution scales linearly and stays well within a block even at the
     *         MAX_CLAIMANTS cap.
     *
     *         Call cancelCommitment() + recommit to fix errors — only possible before any
     *         USDC has been deposited via depositFunds().
     *
     * @param claimants_ Full list of (wallet, amount) pairs, sorted ascending by wallet.
     *                   No duplicates, zero addresses, or zero amounts allowed.
     */
    function commitDistribution(Claimant[] calldata claimants_)
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        if (distribution.totalRequired != 0) revert AlreadyCommitted();
        if (claimants_.length == 0) revert EmptyClaimants();
        if (claimants_.length > MAX_CLAIMANTS) revert TooManyClaimants();
        if (PropertyFunding(project).state() != PropertyFunding.State.COMPLETED)
            revert ProjectNotCompleted();

        // Single O(n) pass over calldata. Strictly-ascending wallets ⇒ no dupes, no zero
        // address. prev starts at address(0) so the first wallet must be strictly greater.
        uint256 total = 0;
        address prev = address(0);
        for (uint256 i = 0; i < claimants_.length; i++) {
            address wallet = claimants_[i].wallet;
            uint256 amount = claimants_[i].amount;
            if (wallet <= prev) revert UnsortedClaimants(wallet);
            if (amount == 0) revert ZeroAmount();
            prev = wallet;
            total += amount;
        }

        bytes32 root = _computeMerkleRoot(claimants_);

        distribution.merkleRoot    = root;
        distribution.totalRequired = total;
        // recoveryUnlocksAt is intentionally NOT set here (H-1). The recovery clock starts
        // only when claims actually open (depositFunds reaches totalRequired), so an
        // arbitrary gap between commit and deposit can't shrink the investor claim window.

        emit DistributionCommitted(root, total, claimants_.length, claimants_);
    }

    // ─── Admin: deposit ────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC toward the committed distribution total.
     *         May be called multiple times. Claims auto-unlock when
     *         totalDeposited >= totalRequired.
     */
    function depositFunds(uint256 amount)
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        if (distribution.totalRequired == 0) revert NoCommitment();
        if (amount == 0) revert ZeroAmount();
        if (distribution.totalDeposited >= distribution.totalRequired) revert AlreadyFullyFunded();
        if (PropertyFunding(project).state() != PropertyFunding.State.COMPLETED)
            revert ProjectNotCompleted();

        distribution.totalDeposited += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit FundsDeposited(amount, distribution.totalDeposited);

        if (distribution.totalDeposited >= distribution.totalRequired) {
            // Claims just opened — start the recovery clock now (H-1). This branch runs
            // exactly once: any subsequent depositFunds reverts AlreadyFullyFunded above.
            recoveryUnlocksAt = block.timestamp + RECOVERY_DELAY;
            emit ClaimsEnabled(distribution.totalDeposited);
        }
    }

    // ─── Admin: error recovery ─────────────────────────────────────────────────

    /**
     * @notice Pull back partially deposited USDC to spvTreasury.
     *         Only callable before claims are enabled (totalDeposited < totalRequired).
     *         After this call, cancelCommitment() can be used to recommit.
     */
    function withdrawDeposit()
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        if (distribution.totalRequired == 0) revert NoCommitment();
        if (claimsEnabled()) revert ClaimsAlreadyEnabled();
        uint256 amount = distribution.totalDeposited;
        if (amount == 0) revert ZeroAmount();

        distribution.totalDeposited = 0;
        usdc.safeTransfer(withdrawRecipient, amount);

        emit DepositWithdrawn(amount);
    }

    /**
     * @notice Cancel the committed distribution tree and reset all state.
     *         Only callable when no USDC has been deposited — call
     *         withdrawDeposit() first if needed.
     *         After cancellation a new commitDistribution() call is allowed.
     */
    function cancelCommitment()
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        if (distribution.totalRequired == 0) revert NoCommitment();
        if (distribution.totalDeposited > 0) revert DepositNotEmpty();

        delete distribution;
        recoveryUnlocksAt = 0;
        // No _claimants array to clear — the cancelled tree's list remains only in its
        // (now superseded) DistributionCommitted event; a fresh commit emits a new one.

        emit CommitmentCancelled();
    }

    // ─── Admin: recovery ───────────────────────────────────────────────────────

    /**
     * @notice Sweep remaining USDC to spvTreasury after RECOVERY_DELAY.
     *         Intended for permanently unclaimed funds (e.g. investors lost wallet access).
     *         Recovery window opens 180 days after claims were enabled (full deposit),
     *         guaranteeing investors a full RECOVERY_DELAY to claim once claims open (H-1).
     */
    function recoverFunds()
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        if (recoveryUnlocksAt == 0) revert RecoveryTooEarly();             // claims never enabled
        if (block.timestamp < recoveryUnlocksAt) revert RecoveryTooEarly();
        uint256 amount = usdc.balanceOf(address(this));
        if (amount == 0) revert NothingToRecover();

        usdc.safeTransfer(withdrawRecipient, amount);
        emit FundsRecovered(amount);
    }

    // ─── Investor actions ──────────────────────────────────────────────────────

    /**
     * @notice Claim principal + ROI. Burns the caller's PropertyTokens.
     *         Only callable once claims are enabled (full deposit received).
     *
     * @param claimableAmount Total USDC claimable (principal + ROI), as in the committed tree
     * @param proof           Merkle proof; obtain from NestJS /api/projects/{id}/proof/{wallet}
     */
    function claim(
        uint256 claimableAmount,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (!claimsEnabled()) revert ClaimsNotEnabled();
        if (claimed[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, claimableAmount));
        if (!MerkleProof.verify(proof, distribution.merkleRoot, leaf))
            revert InvalidProof();

        // Defense-in-depth (I-3): cap the payout by the claimant's actual on-chain principal
        // and the admin-set finalROIBps (+ a small rounding buffer). Even if a compromised
        // tree-builder commits an inflated amount for a real investor — or any amount for a
        // wallet that never invested (principal 0 ⇒ cap 0) — the claim can't exceed
        // principal * (1 + finalROIBps). finalROIBps is set by the spvAdmin Safe at
        // setCompleted(), a DIFFERENT Safe than the spvTreasury that commits the tree, so
        // inflating a payout would require BOTH Safes to be compromised.
        PropertyFunding fundingProject = PropertyFunding(project);
        uint256 principal = fundingProject.investments(msg.sender);
        uint256 maxClaim = principal
            * (BPS_DENOMINATOR + fundingProject.finalROIBps() + CLAIM_CAP_BUFFER_BPS)
            / BPS_DENOMINATOR;
        if (claimableAmount > maxClaim) revert ClaimExceedsEntitlement(claimableAmount, maxClaim);

        // Effects
        claimed[msg.sender] = true;
        distribution.totalClaimed += claimableAmount;

        // Burn caller's PropertyTokens (receipt tokens have served their purpose)
        PropertyToken token = fundingProject.propertyToken();
        uint256 tokenBalance = token.balanceOf(msg.sender);
        if (tokenBalance > 0) {
            token.burn(msg.sender, tokenBalance);
        }

        // Transfer USDC to investor
        usdc.safeTransfer(msg.sender, claimableAmount);

        emit ROIClaimed(msg.sender, claimableAmount);
    }

    // ─── View helpers ──────────────────────────────────────────────────────────

    /// @notice True when the full required amount has been deposited and claims are open.
    function claimsEnabled() public view returns (bool) {
        return distribution.totalRequired > 0 &&
               distribution.totalDeposited >= distribution.totalRequired;
    }

    // NOTE: getClaimants() was removed with the on-chain _claimants array (H-B). The full
    // committed list is available from the DistributionCommitted event (and the original tx
    // calldata) — index it off-chain (e.g. the NestJS backend) to display/verify the tree.

    function getDistribution() external view returns (Distribution memory) {
        return distribution;
    }

    function remainingFunds() external view returns (uint256) {
        return distribution.totalDeposited - distribution.totalClaimed;
    }

    /// @notice USDC still needed to fully fund the distribution (0 once claims are enabled).
    function remainingToDeposit() external view returns (uint256) {
        if (distribution.totalDeposited >= distribution.totalRequired) return 0;
        return distribution.totalRequired - distribution.totalDeposited;
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    /**
     * @dev Compute the Merkle root from a claimants array in-place, using the
     *      same sorted-pair algorithm as OZ MerkleProof.verify:
     *
     *        leaf hash:           keccak256(abi.encodePacked(wallet, amount))
     *        internal node hash:  keccak256(abi.encodePacked(min(a,b), max(a,b)))
     *        odd-length levels:   last node is paired with itself
     *
     *      This guarantees that any proof produced by the NestJS backend from
     *      the same claimants list will verify correctly against the stored root.
     */
    function _computeMerkleRoot(Claimant[] calldata claimants_) internal pure returns (bytes32) {
        uint256 n = claimants_.length;

        // Compute leaf hashes
        bytes32[] memory nodes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            nodes[i] = keccak256(abi.encodePacked(claimants_[i].wallet, claimants_[i].amount));
        }

        // Reduce layer-by-layer until only the root remains.
        // In-place: writes to positions 0..ceil(n/2)-1 while reading from 0..n-1.
        // Safe because write index i is always <= read indices 2i and 2i+1.
        while (n > 1) {
            uint256 half = n / 2;
            for (uint256 i = 0; i < half; i++) {
                nodes[i] = _hashPair(nodes[2 * i], nodes[2 * i + 1]);
            }
            if (n % 2 == 1) {
                // Odd node: pair with itself, place at position ceil(n/2) - 1
                nodes[half] = _hashPair(nodes[n - 1], nodes[n - 1]);
            }
            n = (n + 1) / 2;
        }

        return nodes[0];
    }

    /// @dev Sorted pair hash — mirrors OZ MerkleProof._hashPair / _efficientHash.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }
}
