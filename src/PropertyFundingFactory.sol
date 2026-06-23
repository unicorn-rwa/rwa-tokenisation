// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PropertyToken} from "./PropertyToken.sol";
import {PropertyFunding} from "./PropertyFunding.sol";
import {ROIDistributor} from "./ROIDistributor.sol";
import {PropertyFundingDeployer} from "./lib/PropertyFundingDeployer.sol";

/**
 * @title PropertyFundingFactory
 * @notice Deploys a PropertyToken + PropertyFunding + ROIDistributor triple for each
 *         new property project. Each property is an independent SPV — it gets its own
 *         Gnosis Safe (spvMultisig) that controls all three contracts.
 *
 *         Deployment order per project:
 *           1. Deploy PropertyToken (factory holds temp MINTER_ROLE)
 *           2. Deploy PropertyFunding (admin = spvMultisig)
 *           3. Deploy ROIDistributor (admin = spvMultisig, project = PropertyFunding)
 *           4. Grant MINTER_ROLE + BURNER_ROLE to PropertyFunding (invest mints, refund burns)
 *           5. Grant BURNER_ROLE only to ROIDistributor  (ROI claim burns; never mints)
 *           6. Revoke factory's own MINTER_ROLE + BURNER_ROLE + DEFAULT_ADMIN_ROLE on token
 *
 * Roles (factory-level only):
 *   DEFAULT_ADMIN_ROLE — platform Gnosis Safe
 *   ADMIN_ROLE         — platform Gnosis Safe; can create projects
 */
contract PropertyFundingFactory is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public immutable usdc;
    address public immutable kycRegistry;

    address[] public projects; // list of all deployed PropertyFunding addresses
    mapping(address => bool)    public isProject;         // factory-deployed projects only
    mapping(address => address) public projectDistributor; // funding → roiDistributor

    // ─── Events ────────────────────────────────────────────────────────────────
    event ProjectCreated(
        address indexed fundingContract,
        address indexed tokenContract,
        address         roiDistributor,
        address         spvAdmin,
        address         spvTreasury,
        string  tokenSymbol,
        uint256 fundingGoal,
        uint256 deadline
    );

    // Maximum allowed fundraising window — mirrors PropertyFunding.MAX_FUNDRAISING_DURATION
    uint256 public constant MAX_FUNDRAISING_DURATION = 180 days;

    // Maximum investor count — mirrors PropertyFunding.MAX_INVESTORS (keep in sync)
    uint256 public constant MAX_INVESTORS = 2000;

    // ─── Errors ────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error InvalidParam();
    error DeadlineTooFar();
    error RoleConflict();
    error GoalExceedsCapacity();

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(
        address admin_,
        address usdc_,
        address kycRegistry_
    ) {
        if (
            admin_ == address(0) ||
            usdc_ == address(0) ||
            kycRegistry_ == address(0)
        ) revert ZeroAddress();

        usdc        = usdc_;
        kycRegistry = kycRegistry_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ─── Factory ───────────────────────────────────────────────────────────────

    /**
     * @notice Create a new property investment project.
     *         Deploys PropertyToken + PropertyFunding + ROIDistributor.
     *         All three are administered exclusively by spvMultisig — no shared admin.
     *
     * @param tokenName                    ERC-20 name, e.g. "PropToken LA-2024-01"
     * @param tokenSymbol                  ERC-20 symbol, e.g. "PROP-LA-01"
     * @param spvAdmin                     Per-property operational Gnosis Safe — drives state machine,
     *                                     holds ADMIN_ROLE + PAUSER_ROLE on PropertyFunding,
     *                                     DEFAULT_ADMIN_ROLE on PropertyToken
     * @param spvTreasury                  Per-property financial Gnosis Safe — receives raised USDC,
     *                                     holds ADMIN_ROLE on ROIDistributor and calls depositReturns()
     * @param fundingGoal                  Target in USDC (6 decimals), e.g. 200_000e6
     * @param deadline                     Unix timestamp — fundraising deadline
     * @param expectedROIBps               Expected return in basis points, e.g. 1500 = 15%
     * @param estimatedStartDate           Expected construction start (unix)
     * @param estimatedEndDate             Expected construction end (unix)
     * @param minInvestment                Minimum USDC per investment tx, e.g. 2_000e6
     * @param maxAccreditedInvestment      Reg D 506(c) cumulative cap per investor, e.g. 25_000e6
     * @param maxNonAccreditedUSInvestment Reg D 506(b) cumulative cap per investor, e.g. 2_500e6
     * @param offeringDocHash              IPFS CID of the legal offering documents — permanent, never changes
     * @return fundingContract             Deployed PropertyFunding address
     * @return tokenContract               Deployed PropertyToken address
     * @return roiDistributor              Deployed ROIDistributor address
     */
    function createProject(
        string  calldata tokenName,
        string  calldata tokenSymbol,
        address          spvAdmin,
        address          spvTreasury,
        uint256          fundingGoal,
        uint256          deadline,
        uint256          expectedROIBps,
        uint256          estimatedStartDate,
        uint256          estimatedEndDate,
        uint256          minInvestment,
        uint256          maxAccreditedInvestment,
        uint256          maxNonAccreditedUSInvestment,
        string  calldata offeringDocHash
    ) external onlyRole(ADMIN_ROLE) returns (address fundingContract, address tokenContract, address roiDistributor) {
        if (spvAdmin == address(0) || spvTreasury == address(0)) revert ZeroAddress();
        // M-2: spvAdmin and spvTreasury must be different Safes — same address defeats role split
        if (spvAdmin == spvTreasury) revert RoleConflict();
        if (
            fundingGoal == 0 ||
            minInvestment == 0 ||
            maxAccreditedInvestment == 0 ||
            maxNonAccreditedUSInvestment == 0 ||
            deadline <= block.timestamp
        ) revert InvalidParam();
        if (deadline > block.timestamp + MAX_FUNDRAISING_DURATION) revert DeadlineTooFar();
        // M-3: relational validation — min must not exceed per-investor caps
        if (minInvestment > maxAccreditedInvestment) revert InvalidParam();
        if (minInvestment > maxNonAccreditedUSInvestment) revert InvalidParam();
        // M-B: goal must be reachable within MAX_INVESTORS at the min ticket (mirrors
        //      PropertyFunding's constructor check) — prevents Sybil slot-exhaustion DoS.
        if (fundingGoal > minInvestment * MAX_INVESTORS) revert GoalExceedsCapacity();

        // 1. Deploy PropertyToken — factory holds temp MINTER_ROLE + DEFAULT_ADMIN_ROLE
        PropertyToken token = new PropertyToken(
            tokenName,
            tokenSymbol,
            spvAdmin,     // admin = operational SPV Safe
            address(this) // temp minter, revoked below
        );

        // 2. Deploy PropertyFunding
        //    spvAdmin    → ADMIN_ROLE + PAUSER_ROLE (state transitions)
        //    spvTreasury → withdrawalRecipient (receives raised USDC)
        //    Deployed via PropertyFundingDeployer (external library, delegatecall)
        //    purely so PropertyFunding's creation bytecode lives in the library,
        //    not the factory — keeps the factory under the EIP-170 size limit.
        //    delegatecall runs in this factory's context, so the factory is still
        //    the deployer and the child address is identical to an inline deploy.
        PropertyFunding funding = PropertyFunding(
            PropertyFundingDeployer.deploy(
                PropertyFundingDeployer.Params({
                    usdc:                         usdc,
                    propertyToken:                address(token),
                    kycRegistry:                  kycRegistry,
                    withdrawalRecipient:          spvTreasury, // financial SPV Safe
                    admin:                        spvAdmin,    // operational SPV Safe
                    fundingGoal:                  fundingGoal,
                    deadline:                     deadline,
                    expectedROIBps:               expectedROIBps,
                    estimatedStartDate:           estimatedStartDate,
                    estimatedEndDate:             estimatedEndDate,
                    minInvestment:                minInvestment,
                    maxAccreditedInvestment:      maxAccreditedInvestment,
                    maxNonAccreditedUSInvestment: maxNonAccreditedUSInvestment,
                    offeringDocHash:              offeringDocHash
                })
            )
        );

        // 3. Deploy ROIDistributor — tied to this property
        //    spvTreasury → ADMIN_ROLE (holds USDC, calls depositReturns)
        ROIDistributor roi = new ROIDistributor(
            spvTreasury,     // admin = financial SPV Safe
            usdc,            // USDC address
            address(funding) // project this distributor serves
        );

        // 4+5. Wire up roles with least privilege (L-5):
        //      funding mints on invest() and burns on refund()  → MINTER_ROLE + BURNER_ROLE
        //      roi only burns when an investor claims ROI        → BURNER_ROLE only
        bytes32 minterRole = keccak256("MINTER_ROLE");
        bytes32 burnerRole = keccak256("BURNER_ROLE");
        token.grantRole(minterRole, address(funding));
        token.grantRole(burnerRole, address(funding));
        token.grantRole(burnerRole, address(roi)); // distributor never mints — burn only

        // 6. Revoke all admin roles from PropertyToken — the role set is frozen forever.
        //    H-4: revoke spvAdmin's DEFAULT_ADMIN_ROLE so no one can grant extra
        //         minter/burner addresses post-deploy. Do this before revoking factory's own
        //         DEFAULT_ADMIN_ROLE (factory must still have it to call revokeRole).
        token.revokeRole(minterRole, address(this));
        token.revokeRole(burnerRole, address(this));
        token.revokeRole(DEFAULT_ADMIN_ROLE, spvAdmin);   // H-4: lock the role set permanently
        token.revokeRole(DEFAULT_ADMIN_ROLE, address(this)); // factory self-revokes last

        projects.push(address(funding));
        isProject[address(funding)]            = true;
        projectDistributor[address(funding)]   = address(roi);

        fundingContract = address(funding);
        tokenContract   = address(token);
        roiDistributor  = address(roi);

        emit ProjectCreated(
            address(funding),
            address(token),
            address(roi),
            spvAdmin,
            spvTreasury,
            tokenSymbol,
            fundingGoal,
            deadline
        );
    }

    // ─── View helpers ──────────────────────────────────────────────────────────

    function projectCount() external view returns (uint256) {
        return projects.length;
    }

    function getProjects() external view returns (address[] memory) {
        return projects;
    }
}
