// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PropertyToken} from "./PropertyToken.sol";
import {PropertyFunding} from "./PropertyFunding.sol";

/**
 * @title PropertyFundingFactory
 * @notice Deploys a PropertyToken + PropertyFunding pair for each new project.
 *         Wires up MINTER_ROLE so PropertyFunding and ROIDistributor can mint/burn.
 *
 *         Deployment order per project:
 *           1. Deploy PropertyToken (factory holds temp MINTER_ROLE)
 *           2. Deploy PropertyFunding
 *           3. Grant MINTER_ROLE to PropertyFunding (invest/refund)
 *           4. Grant MINTER_ROLE to ROIDistributor  (ROI claim burns)
 *           5. Revoke factory's own MINTER_ROLE
 *
 * Roles:
 *   DEFAULT_ADMIN_ROLE — Gnosis Safe
 *   ADMIN_ROLE         — Gnosis Safe; can create projects
 */
contract PropertyFundingFactory is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public immutable usdc;
    address public immutable kycRegistry;
    address public immutable roiDistributor;

    address[] public projects; // list of all deployed PropertyFunding addresses

    // ─── Events ────────────────────────────────────────────────────────────────
    event ProjectCreated(
        address indexed fundingContract,
        address indexed tokenContract,
        string  tokenSymbol,
        uint256 fundingGoal,
        uint256 deadline
    );

    // ─── Errors ────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidParam();

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(
        address admin_,
        address usdc_,
        address kycRegistry_,
        address roiDistributor_
    ) {
        if (
            admin_ == address(0) ||
            usdc_ == address(0) ||
            kycRegistry_ == address(0) ||
            roiDistributor_ == address(0)
        ) revert ZeroAddress();

        usdc           = usdc_;
        kycRegistry    = kycRegistry_;
        roiDistributor = roiDistributor_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ─── Factory ───────────────────────────────────────────────────────────────

    /**
     * @notice Create a new property investment project.
     * @param tokenName            ERC-20 name, e.g. "PropToken LA-2024-01"
     * @param tokenSymbol          ERC-20 symbol, e.g. "PROP-LA-01"
     * @param withdrawalRecipient  Gnosis Safe that receives raised USDC
     * @param fundingGoal          Target in USDC (6 decimals), e.g. 200_000e6
     * @param deadline             Unix timestamp — fundraising deadline
     * @param expectedROIBps       Expected return in basis points, e.g. 1500 = 15%
     * @param estimatedStartDate   Expected construction start (unix)
     * @param estimatedEndDate     Expected construction end (unix)
     * @param minInvestment        Minimum USDC per investment tx, e.g. 2_000e6
     * @param metadataURI          IPFS CID with property details, images, legal docs
     * @return fundingContract     Deployed PropertyFunding address
     * @return tokenContract       Deployed PropertyToken address
     */
    function createProject(
        string  calldata tokenName,
        string  calldata tokenSymbol,
        address          withdrawalRecipient,
        uint256          fundingGoal,
        uint256          deadline,
        uint256          expectedROIBps,
        uint256          estimatedStartDate,
        uint256          estimatedEndDate,
        uint256          minInvestment,
        string  calldata metadataURI
    ) external onlyRole(ADMIN_ROLE) returns (address fundingContract, address tokenContract) {
        if (withdrawalRecipient == address(0)) revert ZeroAddress();
        if (fundingGoal == 0 || minInvestment == 0 || deadline <= block.timestamp)
            revert InvalidParam();

        // 1. Deploy PropertyToken — factory holds temp MINTER_ROLE (address(this))
        PropertyToken token = new PropertyToken(
            tokenName,
            tokenSymbol,
            msg.sender,   // admin = caller (Gnosis Safe)
            address(this), // temp minter, revoked below
            kycRegistry
        );

        // 2. Deploy PropertyFunding
        PropertyFunding funding = new PropertyFunding(
            usdc,
            address(token),
            kycRegistry,
            withdrawalRecipient,
            msg.sender, // admin = caller (Gnosis Safe)
            fundingGoal,
            deadline,
            expectedROIBps,
            estimatedStartDate,
            estimatedEndDate,
            minInvestment,
            metadataURI
        );

        // 3+4. Wire up MINTER_ROLE — funding contract mints on invest(), burns on refund()
        //      ROI distributor burns tokens when investor claims ROI
        bytes32 minterRole = keccak256("MINTER_ROLE");
        token.grantRole(minterRole, address(funding));
        token.grantRole(minterRole, roiDistributor);

        // 5. Revoke factory's temp roles — principle of least privilege.
        //    Factory no longer needs MINTER_ROLE or DEFAULT_ADMIN_ROLE on this token.
        token.revokeRole(minterRole, address(this));
        token.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        projects.push(address(funding));
        fundingContract = address(funding);
        tokenContract   = address(token);

        emit ProjectCreated(address(funding), address(token), tokenSymbol, fundingGoal, deadline);
    }

    // ─── View helpers ──────────────────────────────────────────────────────────

    function projectCount() external view returns (uint256) {
        return projects.length;
    }

    function getProjects() external view returns (address[] memory) {
        return projects;
    }
}
