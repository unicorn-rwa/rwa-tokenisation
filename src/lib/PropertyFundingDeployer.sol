// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PropertyFunding} from "../PropertyFunding.sol";

/**
 * @title PropertyFundingDeployer
 * @notice External library that deploys PropertyFunding. Extracted from
 *         PropertyFundingFactory PURELY to keep the factory under the EIP-170
 *         24,576-byte runtime limit — PropertyFunding's ~10.3 KB creation
 *         bytecode lives in this library instead of being embedded in the
 *         factory.
 *
 *         This is a `public`/`external` library, so it is deployed as its own
 *         contract and invoked by the factory via `delegatecall`. Because of
 *         delegatecall, the `new PropertyFunding(...)` runs in the FACTORY's
 *         context: the factory is the deployer (CREATE), so the child's address
 *         derives from the factory address + nonce — identical to deploying it
 *         inline. The factory keeps all role wiring, registry bookkeeping, and
 *         event emission.
 *
 * ─── SECURITY INVARIANTS (must hold forever — see threat model) ──────────────
 *   1. NO `selfdestruct` anywhere in this library. Prevents metamorphic
 *      redeployment of malicious code at the same linked address.
 *   2. NO state variables. This code runs in the factory's storage context via
 *      delegatecall; any storage slot used here would collide with the
 *      factory's `projects` / `isProject` / `projectDistributor` / AccessControl
 *      `_roles`. The `library` keyword already forbids state variables — do not
 *      work around it (e.g. by delegating to a stateful helper).
 *   3. PURE DEPLOYMENT HELPER. No role logic, no token approvals, no registry
 *      writes. All privileged wiring (grant/revoke MINTER_ROLE, the H-4 admin
 *      lock) stays in the factory.
 *   4. The factory's linked address to this library must be PINNED in
 *      foundry.toml and VERIFIED on-chain alongside the factory (it is part of
 *      the trusted contract set).
 */
library PropertyFundingDeployer {
    /// @dev Mirrors PropertyFunding's constructor args. Passed as a struct to
    ///      avoid a 14-argument signature and stack-too-deep.
    struct Params {
        address usdc;
        address propertyToken;
        address kycRegistry;
        address withdrawalRecipient;
        address admin;
        uint256 fundingGoal;
        uint256 deadline;
        uint256 expectedROIBps;
        uint256 estimatedStartDate;
        uint256 estimatedEndDate;
        uint256 minInvestment;
        uint256 maxAccreditedInvestment;
        uint256 maxNonAccreditedUSInvestment;
        string  offeringDocHash;
    }

    /// @notice Deploy a PropertyFunding contract and return its address.
    /// @dev External so the creation bytecode lives here, not in the factory.
    function deploy(Params calldata p) external returns (address funding) {
        funding = address(
            new PropertyFunding(
                p.usdc,
                p.propertyToken,
                p.kycRegistry,
                p.withdrawalRecipient,
                p.admin,
                p.fundingGoal,
                p.deadline,
                p.expectedROIBps,
                p.estimatedStartDate,
                p.estimatedEndDate,
                p.minInvestment,
                p.maxAccreditedInvestment,
                p.maxNonAccreditedUSInvestment,
                p.offeringDocHash
            )
        );
    }
}
