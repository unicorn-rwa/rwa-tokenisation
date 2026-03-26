// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {MaliciousUSDC} from "./mocks/MaliciousUSDC.sol";
import {KYCRegistry} from "../src/KYCRegistry.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {PropertyFunding} from "../src/PropertyFunding.sol";
import {ROIDistributor} from "../src/ROIDistributor.sol";
import {PropertyFundingFactory} from "../src/PropertyFundingFactory.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title AttackerTest
 * @notice Adversarial test suite. Every test here represents a realistic attack
 *         attempt. All tests are expected to PASS — meaning the contract correctly
 *         rejects the attack.
 *
 * Categories:
 *   1. KYC Bypass       — invest or access without valid attestation
 *   2. Role Escalation  — grant yourself privileged roles
 *   3. State Machine    — call functions out of order or skip states
 *   4. Double Spend     — claim refund / ROI more than once
 *   5. Merkle Forgery   — manipulate or steal Merkle proofs
 *   6. Reentrancy       — reenter via malicious token callback
 *   7. Edge Cases       — zero amounts, boundary conditions
 */
contract AttackerTest is BaseTest {
    PropertyFunding internal funding;
    PropertyToken   internal token;

    // attacker = charlie — has no KYC throughout most tests
    // For tests where attacker needs some KYC, a fresh address is used

    function setUp() public override {
        super.setUp();
        (funding, token) = _createProject();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 1. KYC BYPASS ATTACKS
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Attacker with no attestation tries to invest directly
    function test_Attack_InvestWithNoKYC() public {
        _fundInvestor(charlie, address(funding), MIN_INVESTMENT);

        vm.expectRevert(
            abi.encodeWithSelector(PropertyFunding.NotEligibleInvestor.selector, charlie)
        );
        vm.prank(charlie);
        funding.invest(MIN_INVESTMENT);

        // Funds never left charlie's wallet
        assertEq(usdc.balanceOf(charlie), MIN_INVESTMENT);
        assertEq(funding.totalRaised(), 0);
    }

    /// @dev Attacker waits for alice's KYC to expire, then tries to front-run
    ///      an investment on her behalf — but alice herself can no longer invest.
    ///      Uses a project with a 2-year deadline so the KYC check (not deadline)
    ///      is what fires. The default 30-day project would fail with DeadlinePassed
    ///      instead because the deadline fires before the KYC check in invest().
    function test_Attack_InvestWithExpiredKYC() public {
        // Create a project with deadline > attestation expiry (2 years > 1 year)
        vm.prank(admin);
        (address longF,) = factory.createProject(
            "LongProject", "LONG", multisig,
            FUNDING_GOAL, block.timestamp + 730 days,
            ROI_BPS, block.timestamp + 800 days, block.timestamp + 1000 days,
            MIN_INVESTMENT, "ipfs://long"
        );
        PropertyFunding longFunding = PropertyFunding(longF);

        // Warp past KYC expiry (365 days) but NOT past the 730-day project deadline
        vm.warp(block.timestamp + 366 days);

        assertFalse(registry.isEligibleInvestor(alice));
        assertTrue(block.timestamp < longFunding.deadline()); // deadline still open

        _fundInvestor(alice, address(longFunding), MIN_INVESTMENT);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyFunding.NotEligibleInvestor.selector, alice)
        );
        vm.prank(alice);
        longFunding.invest(MIN_INVESTMENT);
    }

    /// @dev Attacker's KYC is revoked mid-lifecycle (PM webhook fired)
    ///      then attacker tries to invest — must be rejected
    function test_Attack_InvestWithRevokedKYC() public {
        // Admin revokes attacker's attestation (simulates PM webhook)
        vm.prank(attester);
        registry.revokeAttestation(alice);

        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.expectRevert(
            abi.encodeWithSelector(PropertyFunding.NotEligibleInvestor.selector, alice)
        );
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);
    }

    /// @dev Attacker tries to forge their own attestation by calling issueAttestation
    ///      directly — must fail because they don't have ATTESTER_ROLE
    function test_Attack_SelfIssueKYCAttestation() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                registry.ATTESTER_ROLE()
            )
        );
        vm.prank(charlie);
        registry.issueAttestation(
            charlie, true, false, "US",
            uint64(block.timestamp + 365 days),
            bytes32(0)
        );

        // charlie is still unverified
        assertFalse(registry.isVerified(charlie));
    }

    /// @dev Attacker impersonates a legitimate investor by passing their wallet address
    ///      to issueAttestation — still blocked, no ATTESTER_ROLE
    function test_Attack_IssueAttestationForArbitraryWallet() public {
        address victim = makeAddr("victim");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                registry.ATTESTER_ROLE()
            )
        );
        vm.prank(charlie);
        registry.issueAttestation(victim, true, false, "US", uint64(block.timestamp + 1), bytes32(0));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 2. ROLE ESCALATION ATTACKS
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Attacker tries to grant themselves ATTESTER_ROLE on KYCRegistry
    function test_Attack_GrantSelfAttesterRole() public {
        bytes32 attesterRole = registry.ATTESTER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(charlie);
        registry.grantRole(attesterRole, charlie);

        assertFalse(registry.hasRole(attesterRole, charlie));
    }

    /// @dev Attacker tries to grant themselves DEFAULT_ADMIN_ROLE on KYCRegistry
    function test_Attack_GrantSelfAdminRole() public {
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                adminRole // admin of DEFAULT_ADMIN_ROLE is itself
            )
        );
        vm.prank(charlie);
        registry.grantRole(adminRole, charlie);
    }

    /// @dev Attacker tries to mint PropertyTokens directly without MINTER_ROLE
    function test_Attack_MintTokensWithoutRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                token.MINTER_ROLE()
            )
        );
        vm.prank(charlie);
        token.mint(charlie, 1_000e18);

        assertEq(token.balanceOf(charlie), 0);
    }

    /// @dev Attacker tries to burn alice's tokens (theft of position)
    function test_Attack_BurnVictimsTokens() public {
        // Alice legitimately invests first
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        // Pre-store balance BEFORE setting up prank.
        // vm.prank() is consumed by the NEXT external call — including view calls like
        // balanceOf(). If we wrote token.burn(alice, token.balanceOf(alice)) with
        // vm.prank active, balanceOf() would consume the prank and burn() would run
        // as the test contract (no role) giving the wrong error. Classic Foundry gotcha.
        uint256 aliceBalance = token.balanceOf(alice);
        assertGt(aliceBalance, 0);

        // Attacker tries to burn alice's tokens
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                token.MINTER_ROLE()
            )
        );
        vm.prank(charlie);
        token.burn(alice, aliceBalance);

        // Alice's position is intact
        assertEq(token.balanceOf(alice), aliceBalance);
    }

    /// @dev Attacker tries to enable secondary-market transfers without admin role
    function test_Attack_EnableTransfersWithoutRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                token.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(charlie);
        token.enableTransfers();

        assertFalse(token.transfersEnabled());
    }

    /// @dev Attacker tries to pause the funding contract (denial of service)
    function test_Attack_PauseFundingWithoutRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                funding.PAUSER_ROLE()
            )
        );
        vm.prank(charlie);
        funding.pause();

        assertFalse(funding.paused());
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 3. STATE MACHINE ATTACKS
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Attacker (or investor) tries to withdraw funds — admin only
    function test_Attack_WithdrawFundsAsInvestor() public {
        _fundInvestor(alice, address(funding), FUNDING_GOAL);
        vm.prank(alice);
        funding.invest(FUNDING_GOAL);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                funding.ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        funding.withdrawFunds();

        // Funds still in contract
        assertEq(usdc.balanceOf(address(funding)), FUNDING_GOAL);
    }

    /// @dev Attacker tries to skip FUNDRAISING and call withdrawFunds directly
    function test_Attack_WithdrawFundsBeforeGoalMet() public {
        // Invest partially — state is still FUNDRAISING
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.WrongState.selector,
                PropertyFunding.State.FUNDED,
                PropertyFunding.State.FUNDRAISING
            )
        );
        vm.prank(admin);
        funding.withdrawFunds();
    }

    /// @dev Attacker tries to call setActive() on a fresh FUNDRAISING project
    function test_Attack_SetActiveFromFundraising() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.WrongState.selector,
                PropertyFunding.State.WITHDRAWN,
                PropertyFunding.State.FUNDRAISING
            )
        );
        vm.prank(admin);
        funding.setActive();
    }

    /// @dev Attacker tries to jump straight to setCompleted() from FUNDRAISING
    function test_Attack_SetCompletedFromFundraising() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.WrongState.selector,
                PropertyFunding.State.ACTIVE,
                PropertyFunding.State.FUNDRAISING
            )
        );
        vm.prank(admin);
        funding.setCompleted();
    }

    /// @dev Attacker tries to trigger a refund before the deadline — too early
    function test_Attack_TriggerRefundBeforeDeadline() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.expectRevert(PropertyFunding.DeadlineNotReached.selector);
        funding.triggerRefund(); // deadline is 30 days away
    }

    /// @dev Attacker tries to invest after the deadline has passed
    function test_Attack_InvestAfterDeadline() public {
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);

        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.expectRevert(PropertyFunding.DeadlinePassed.selector);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        assertEq(funding.totalRaised(), 0);
    }

    /// @dev Attacker tries to claim refund during FUNDRAISING — too early
    function test_Attack_ClaimRefundDuringFundraising() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.WrongState.selector,
                PropertyFunding.State.REFUNDING,
                PropertyFunding.State.FUNDRAISING
            )
        );
        vm.prank(alice);
        funding.claimRefund();
    }

    /// @dev Attacker tries to run triggerRefund on a successfully FUNDED project
    ///      (goal was met → state moved to FUNDED → triggerRefund requires FUNDRAISING)
    function test_Attack_TriggerRefundAfterGoalMet() public {
        _fundInvestor(alice, address(funding), FUNDING_GOAL);
        vm.prank(alice);
        funding.invest(FUNDING_GOAL);

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.FUNDED));
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.WrongState.selector,
                PropertyFunding.State.FUNDRAISING,
                PropertyFunding.State.FUNDED
            )
        );
        funding.triggerRefund();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4. DOUBLE SPEND / DOUBLE CLAIM ATTACKS
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Attacker claims refund twice — second claim must revert
    function test_Attack_DoubleRefund() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        funding.triggerRefund();

        vm.prank(alice);
        funding.claimRefund(); // legitimate first claim

        // Second attempt — investments[alice] is now 0
        vm.expectRevert(PropertyFunding.NothingToRefund.selector);
        vm.prank(alice);
        funding.claimRefund();

        // Alice got exactly her investment back, no more
        assertEq(usdc.balanceOf(alice), MIN_INVESTMENT);
    }

    /// @dev Attacker tries to claim ROI distribution twice
    function test_Attack_DoubleROIClaim() public {
        // Full lifecycle → COMPLETED
        _fundInvestor(alice, address(funding), FUNDING_GOAL);
        vm.prank(alice);
        funding.invest(FUNDING_GOAL);
        vm.startPrank(admin);
        funding.withdrawFunds();
        funding.setActive();
        funding.setCompleted();
        vm.stopPrank();

        uint256 aliceClaim = FUNDING_GOAL + (FUNDING_GOAL * ROI_BPS / 10_000);
        (bytes32 root, bytes32[] memory proof,) = _buildMerkleTree(
            alice, aliceClaim,
            bob, 1e6 // dummy second leaf to build valid tree
        );
        usdc.mint(admin, aliceClaim + 1e6);
        vm.startPrank(admin);
        usdc.approve(address(distributor), aliceClaim + 1e6);
        distributor.depositReturns(address(funding), root, aliceClaim + 1e6);
        vm.stopPrank();

        vm.prank(alice);
        distributor.claim(address(funding), aliceClaim, proof); // legitimate

        // Second attempt
        vm.expectRevert(ROIDistributor.AlreadyClaimed.selector);
        vm.prank(alice);
        distributor.claim(address(funding), aliceClaim, proof);

        // Alice got exactly principal + ROI, nothing extra
        assertEq(usdc.balanceOf(alice), aliceClaim);
    }

    /// @dev Attacker who has no investment tries to claim ROI
    function test_Attack_ClaimROIWithNoInvestment() public {
        _fundInvestor(alice, address(funding), FUNDING_GOAL);
        vm.prank(alice);
        funding.invest(FUNDING_GOAL);
        vm.startPrank(admin);
        funding.withdrawFunds();
        funding.setActive();
        funding.setCompleted();
        vm.stopPrank();

        uint256 aliceClaim = FUNDING_GOAL + (FUNDING_GOAL * ROI_BPS / 10_000);
        (bytes32 root, bytes32[] memory aliceProof,) = _buildMerkleTree(alice, aliceClaim, bob, 1e6);

        usdc.mint(admin, aliceClaim + 1e6);
        vm.startPrank(admin);
        usdc.approve(address(distributor), aliceClaim + 1e6);
        distributor.depositReturns(address(funding), root, aliceClaim + 1e6);
        vm.stopPrank();

        // charlie has no investment — no leaf in the tree → invalid proof
        vm.expectRevert(ROIDistributor.InvalidProof.selector);
        vm.prank(charlie);
        distributor.claim(address(funding), aliceClaim, aliceProof);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 5. MERKLE PROOF FORGERY ATTACKS
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Attacker inflates their claim amount — leaf doesn't match tree → invalid proof
    function test_Attack_InflatedMerkleClaim() public {
        _advanceToCompletedWithAliceAndBob();
        (bytes32 root, bytes32[] memory aliceProof, bytes32[] memory bobProof) = _buildPayoutTree();
        _depositDistribution(root);

        uint256 aliceReal  = 120_000e6 + (120_000e6 * ROI_BPS / 10_000);
        uint256 aliceFaked = aliceReal + 50_000e6; // attacker tries to steal extra

        vm.expectRevert(ROIDistributor.InvalidProof.selector);
        vm.prank(alice);
        distributor.claim(address(funding), aliceFaked, aliceProof);

        // Nothing paid out
        assertEq(distributor.getDistribution(address(funding)).totalClaimed, 0);
    }

    /// @dev Attacker steals bob's proof and tries to claim bob's funds as themselves
    function test_Attack_StealOthersProof() public {
        _advanceToCompletedWithAliceAndBob();
        (bytes32 root,, bytes32[] memory bobProof) = _buildPayoutTree();
        _depositDistribution(root);

        uint256 bobClaim = 80_000e6 + (80_000e6 * ROI_BPS / 10_000);

        // charlie uses bob's proof + bob's amount — leaf = keccak256(charlie, bobClaim)
        // which doesn't match the tree leaf keccak256(bob, bobClaim) → invalid
        vm.expectRevert(ROIDistributor.InvalidProof.selector);
        vm.prank(charlie);
        distributor.claim(address(funding), bobClaim, bobProof);
    }

    /// @dev Attacker submits an empty proof array — invalid against any real tree
    function test_Attack_EmptyMerkleProof() public {
        _advanceToCompletedWithAliceAndBob();
        (bytes32 root,,) = _buildPayoutTree();
        _depositDistribution(root);

        uint256 aliceClaim = 120_000e6 + (120_000e6 * ROI_BPS / 10_000);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.expectRevert(ROIDistributor.InvalidProof.selector);
        vm.prank(alice);
        distributor.claim(address(funding), aliceClaim, emptyProof);
    }

    /// @dev Attacker deposits returns for a non-completed project to poison the distributor
    function test_Attack_DepositReturnForActiveProject() public {
        _fundInvestor(alice, address(funding), FUNDING_GOAL);
        vm.prank(alice);
        funding.invest(FUNDING_GOAL);
        vm.startPrank(admin);
        funding.withdrawFunds();
        funding.setActive(); // ACTIVE — not yet COMPLETED
        vm.stopPrank();

        usdc.mint(admin, 1e6);
        vm.startPrank(admin);
        usdc.approve(address(distributor), 1e6);
        vm.expectRevert(ROIDistributor.ProjectNotCompleted.selector);
        distributor.depositReturns(address(funding), bytes32("root"), 1e6);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 6. REENTRANCY ATTACKS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Reentrancy attack on claimRefund():
     *      - Deploy PropertyFunding backed by MaliciousUSDC
     *      - MaliciousUSDC.transfer() calls claimRefund() again mid-execution
     *
     *      Defense layer 1 — nonReentrant:    blocks at the lock
     *      Defense layer 2 — CEI pattern:     investments[attacker] = 0 before transfer,
     *                                          so even without nonReentrant the inner call
     *                                          would get NothingToRefund
     *
     *      The test confirms: attacker receives their refund ONCE (legitimate use still works),
     *      and the reentrant call was rejected.
     */
    function test_Attack_ReentrancyOnClaimRefund() public {
        // Deploy a separate project backed by MaliciousUSDC
        MaliciousUSDC malUsdc = new MaliciousUSDC();

        // Need a new factory/funding that uses malUsdc
        vm.startPrank(admin);
        ROIDistributor dist2 = new ROIDistributor(admin, address(malUsdc));
        PropertyFundingFactory factory2 = new PropertyFundingFactory(
            admin, address(malUsdc), address(registry), address(dist2)
        );
        (address f2Addr,) = factory2.createProject(
            "ReentrancyProp", "REENT",
            multisig,
            FUNDING_GOAL,
            block.timestamp + DEADLINE_OFFSET,
            ROI_BPS,
            block.timestamp + 60 days,
            block.timestamp + 540 days,
            MIN_INVESTMENT,
            "ipfs://test"
        );
        vm.stopPrank();

        PropertyFunding f2 = PropertyFunding(f2Addr);

        // Alice (KYC'd) invests via malicious token
        malUsdc.mint(alice, MIN_INVESTMENT);
        vm.prank(alice);
        malUsdc.approve(address(f2), MIN_INVESTMENT);
        vm.prank(alice);
        f2.invest(MIN_INVESTMENT);

        // Trigger refund
        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        f2.triggerRefund();

        // Arm the reentrancy attack — MaliciousUSDC will call f2.claimRefund() inside transfer
        malUsdc.setTarget(address(f2));

        // Attacker claims refund — the token will attempt reentrancy during transfer
        vm.prank(alice);
        f2.claimRefund(); // should succeed: alice gets her refund once

        // ── Assertions ──────────────────────────────────────────────────────
        // The reentrancy attempt was made
        assertTrue(malUsdc.reentrancyAttempted(), "Reentrancy was never attempted - test is invalid");

        // The reentrancy was rejected (nonReentrant blocked inner claimRefund call)
        assertTrue(malUsdc.reentrancyReverted(), "Reentrancy SUCCEEDED - contract is vulnerable!");

        // Alice received exactly her investment back (not double)
        assertEq(malUsdc.balanceOf(alice), MIN_INVESTMENT);

        // Contract holds no residual funds
        assertEq(malUsdc.balanceOf(address(f2)), 0);
    }

    /**
     * @dev Demonstrates CEI (Checks-Effects-Interactions) protection independently.
     *      Even if nonReentrant didn't exist, the second claimRefund() call
     *      would fail because investments[alice] was set to 0 *before* the transfer.
     *
     *      We simulate this by checking state AFTER the legitimate claim.
     */
    function test_Attack_CEIGuaranteesZeroBalanceBeforeTransfer() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        funding.triggerRefund();

        vm.prank(alice);
        funding.claimRefund();

        // investments mapping is zero — a reentrant call would get NothingToRefund
        // regardless of nonReentrant, because state was cleared before transfer
        assertEq(funding.investments(alice), 0);

        // Confirm a second call reverts with NothingToRefund (CEI defense confirmed)
        vm.expectRevert(PropertyFunding.NothingToRefund.selector);
        vm.prank(alice);
        funding.claimRefund();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 7. EDGE CASE / BOUNDARY ATTACKS
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Attacker invests 0 — below minimum, should revert
    function test_Attack_InvestZeroAmount() public {
        // Approve 0 (no-op) and attempt 0 investment
        vm.prank(alice);
        usdc.approve(address(funding), 0);

        vm.expectRevert(
            abi.encodeWithSelector(PropertyFunding.BelowMinimum.selector, MIN_INVESTMENT, 0)
        );
        vm.prank(alice);
        funding.invest(0);
    }

    /// @dev Attacker invests 1 wei below minimum
    function test_Attack_InvestOneBelow_Minimum() public {
        uint256 almostMin = MIN_INVESTMENT - 1;
        _fundInvestor(alice, address(funding), almostMin);

        vm.expectRevert(
            abi.encodeWithSelector(PropertyFunding.BelowMinimum.selector, MIN_INVESTMENT, almostMin)
        );
        vm.prank(alice);
        funding.invest(almostMin);
    }

    /// @dev Attacker tries to invest more than they approved — transferFrom reverts
    function test_Attack_InvestMoreThanApproved() public {
        usdc.mint(alice, FUNDING_GOAL);
        vm.prank(alice);
        usdc.approve(address(funding), MIN_INVESTMENT); // approve less than invest amount

        // safeTransferFrom will revert — insufficient allowance
        vm.expectRevert();
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT * 2);

        // No state change — totalRaised must remain 0
        assertEq(funding.totalRaised(), 0);
    }

    /// @dev Attacker tries to invest more USDC than they hold
    function test_Attack_InvestMoreThanBalance() public {
        uint256 balance = MIN_INVESTMENT;
        usdc.mint(alice, balance);
        vm.prank(alice);
        usdc.approve(address(funding), FUNDING_GOAL); // approve plenty, but no balance

        vm.expectRevert();
        vm.prank(alice);
        funding.invest(FUNDING_GOAL); // more than alice's balance

        assertEq(funding.totalRaised(), 0);
    }

    /// @dev Attacker tries to update expiry on a wallet that was never attested
    function test_Attack_UpdateExpiryForUnknownWallet() public {
        address ghost = makeAddr("ghost");
        assertFalse(registry.isVerified(ghost));

        vm.expectRevert(KYCRegistry.AttestationNotFound.selector);
        vm.prank(attester);
        registry.updateExpiry(ghost, uint64(block.timestamp + 365 days));
    }

    /// @dev Attacker deploys a contract, issues itself KYC via the attester,
    ///      transfers tokens to a non-KYC wallet when transfers are locked.
    ///      Even if transfers were enabled, non-KYC recipients are rejected.
    function test_Attack_TransferTokensToNonKYCWallet() public {
        vm.prank(admin);
        token.enableTransfers();

        // Mint to alice
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        // Pre-store balance before setting up prank — same vm.prank/balanceOf gotcha
        // as in test_Attack_BurnVictimsTokens: view calls consume the prank.
        uint256 aliceBalance = token.balanceOf(alice);
        assertGt(aliceBalance, 0);

        // Alice tries to send to charlie (no KYC) — blocked by _update() compliance hook
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.RecipientNotVerified.selector, charlie)
        );
        vm.prank(alice);
        token.transfer(charlie, aliceBalance);
    }

    /// @dev Boundary test: triggerRefund() at deadline - 1 second must revert.
    ///
    ///      The invest/refund boundary works like this:
    ///        block.timestamp >= deadline  → investing BLOCKED  (DeadlinePassed)
    ///        block.timestamp <  deadline  → triggerRefund BLOCKED (DeadlineNotReached)
    ///        block.timestamp == deadline  → investing blocked, refund ALLOWED
    ///
    ///      So at exactly deadline the refund CAN be triggered — the contract is correct.
    ///      This test proves the second before deadline still blocks trigger.
    function test_Attack_TriggerRefundOneSecondBeforeDeadline() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        // One second before deadline — refund trigger still blocked
        vm.warp(funding.deadline() - 1);

        vm.expectRevert(PropertyFunding.DeadlineNotReached.selector);
        funding.triggerRefund();
    }

    /// @dev At exactly the deadline block, triggerRefund() IS allowed.
    ///      This is intentional: deadline is the moment fundraising ends.
    ///      Investing is blocked (>= deadline), refund opens (== deadline).
    function test_Boundary_TriggerRefundAtExactDeadlineSucceeds() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.warp(funding.deadline()); // at exactly deadline

        funding.triggerRefund(); // no revert expected — this is correct behaviour
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.REFUNDING));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════════

    function _advanceToCompletedWithAliceAndBob() internal {
        uint256 aliceAmt = 120_000e6;
        uint256 bobAmt   =  80_000e6;
        _fundInvestor(alice, address(funding), aliceAmt);
        _fundInvestor(bob,   address(funding), bobAmt);
        vm.prank(alice); funding.invest(aliceAmt);
        vm.prank(bob);   funding.invest(bobAmt);
        vm.startPrank(admin);
        funding.withdrawFunds();
        funding.setActive();
        funding.setCompleted();
        vm.stopPrank();
    }

    function _buildPayoutTree()
        internal
        view
        returns (bytes32 root, bytes32[] memory aliceProof, bytes32[] memory bobProof)
    {
        uint256 aliceClaim = 120_000e6 + (120_000e6 * ROI_BPS / 10_000);
        uint256 bobClaim   =  80_000e6 + ( 80_000e6 * ROI_BPS / 10_000);
        (root, aliceProof, bobProof) = _buildMerkleTree(alice, aliceClaim, bob, bobClaim);
    }

    function _depositDistribution(bytes32 root) internal {
        uint256 aliceClaim = 120_000e6 + (120_000e6 * ROI_BPS / 10_000);
        uint256 bobClaim   =  80_000e6 + ( 80_000e6 * ROI_BPS / 10_000);
        uint256 total      = aliceClaim + bobClaim;
        usdc.mint(admin, total);
        vm.startPrank(admin);
        usdc.approve(address(distributor), total);
        distributor.depositReturns(address(funding), root, total);
        vm.stopPrank();
    }
}
