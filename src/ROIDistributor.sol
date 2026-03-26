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
 *
 *         Uses a Merkle tree for gas-efficient distribution:
 *           1. NestJS backend reads all investors and amounts from the chain
 *           2. Computes each investor's claimable USDC: principal + (principal * roiBps / 10_000)
 *           3. Builds a Merkle tree: leaves = keccak256(abi.encodePacked(wallet, amount))
 *           4. Admin calls depositReturns() with the root and total USDC
 *           5. Each investor calls claim() with their amount + proof — gets USDC, tokens burned
 *
 *         Pull pattern: investors call claim() themselves — no gas-heavy push loops.
 *
 * Roles:
 *   DEFAULT_ADMIN_ROLE — Gnosis Safe
 *   ADMIN_ROLE         — Gnosis Safe; calls depositReturns()
 */
contract ROIDistributor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IERC20 public immutable usdc;

    struct Distribution {
        bytes32 merkleRoot;
        uint256 totalDeposited;
        uint256 totalClaimed;
    }

    // PropertyFunding address → Distribution
    mapping(address => Distribution) public distributions;

    // project → investor → claimed flag (prevents double-claims)
    mapping(address => mapping(address => bool)) public claimed;

    // ─── Events ────────────────────────────────────────────────────────────────
    event DistributionDeposited(address indexed project, bytes32 merkleRoot, uint256 totalAmount);
    event ROIClaimed(address indexed project, address indexed investor, uint256 usdcAmount);

    // ─── Errors ────────────────────────────────────────────────────────────────
    error AlreadyClaimed();
    error InvalidProof();
    error ProjectNotCompleted();
    error ZeroAddress();
    error ZeroAmount();

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(address admin_, address usdc_) {
        if (admin_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /**
     * @notice Deposit USDC returns and record the Merkle root for investor claims.
     * @param project      PropertyFunding contract address
     * @param merkleRoot   Root of Merkle tree (leaves: keccak256(wallet, claimableUsdc))
     * @param totalAmount  Total USDC to distribute (principal + ROI for all investors)
     */
    function depositReturns(
        address project,
        bytes32 merkleRoot,
        uint256 totalAmount
    ) external nonReentrant onlyRole(ADMIN_ROLE) {
        if (project == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();

        // Verify the project is in COMPLETED state before accepting funds
        if (PropertyFunding(project).state() != PropertyFunding.State.COMPLETED)
            revert ProjectNotCompleted();

        distributions[project] = Distribution({
            merkleRoot:     merkleRoot,
            totalDeposited: totalAmount,
            totalClaimed:   0
        });

        usdc.safeTransferFrom(msg.sender, address(this), totalAmount);

        emit DistributionDeposited(project, merkleRoot, totalAmount);
    }

    // ─── Investor actions ──────────────────────────────────────────────────────

    /**
     * @notice Claim principal + ROI. Burns the caller's PropertyTokens.
     * @param project         PropertyFunding contract address
     * @param claimableAmount Total USDC claimable (principal + ROI), as computed by backend
     * @param proof           Merkle proof; obtain from NestJS /api/projects/{id}/proof/{wallet}
     */
    function claim(
        address project,
        uint256 claimableAmount,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (claimed[project][msg.sender]) revert AlreadyClaimed();

        // Verify the caller's leaf against the stored Merkle root
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, claimableAmount));
        if (!MerkleProof.verify(proof, distributions[project].merkleRoot, leaf))
            revert InvalidProof();

        // Effects
        claimed[project][msg.sender] = true;
        distributions[project].totalClaimed += claimableAmount;

        // Burn caller's PropertyTokens (receipt tokens have served their purpose)
        PropertyToken token = PropertyFunding(project).propertyToken();
        uint256 tokenBalance = token.balanceOf(msg.sender);
        if (tokenBalance > 0) {
            token.burn(msg.sender, tokenBalance);
        }

        // Transfer USDC to investor
        usdc.safeTransfer(msg.sender, claimableAmount);

        emit ROIClaimed(project, msg.sender, claimableAmount);
    }

    // ─── View helpers ──────────────────────────────────────────────────────────

    function getDistribution(address project) external view returns (Distribution memory) {
        return distributions[project];
    }

    function remainingFunds(address project) external view returns (uint256) {
        Distribution storage d = distributions[project];
        return d.totalDeposited - d.totalClaimed;
    }
}
