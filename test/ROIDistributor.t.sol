// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {ROIDistributor} from "../src/ROIDistributor.sol";
import {PropertyFunding} from "../src/PropertyFunding.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ROIDistributorTest is BaseTest {
    PropertyFunding internal funding;
    PropertyToken   internal token;

    // Off-chain Merkle proofs for alice + bob (root verified against on-chain computed root)
    bytes32 internal merkleRoot; // expected root — asserted equal to on-chain computed root
    bytes32[] internal aliceProof;
    bytes32[] internal bobProof;
    uint256 internal aliceClaim;
    uint256 internal bobClaim;
    uint256 internal totalPayout;

    // Claimant list passed to commitDistribution
    ROIDistributor.Claimant[] internal claimants;

    function setUp() public override {
        super.setUp();
        (funding, token, distributor) = _createProject();
        _advanceToCompleted();

        aliceClaim  = 25_000e6 + (25_000e6 * ROI_BPS / 10_000);    //  28_750e6
        bobClaim    = 175_000e6 + (175_000e6 * ROI_BPS / 10_000);   // 201_250e6
        totalPayout = aliceClaim + bobClaim;                          // 230_000e6

        // Off-chain proofs (same sorted-pair algorithm as on-chain _computeMerkleRoot)
        (merkleRoot, aliceProof, bobProof) = _buildMerkleTree(alice, aliceClaim, bob, bobClaim);

        // Build Claimant array (sorted ascending by wallet) for commitDistribution
        ROIDistributor.Claimant[] memory sorted = _claimants2(alice, aliceClaim, bob, bobClaim);
        claimants.push(sorted[0]);
        claimants.push(sorted[1]);

        // Commit and fully fund the distributor
        vm.startPrank(spvTreasury);
        distributor.commitDistribution(claimants);
        usdc.mint(spvTreasury, totalPayout);
        usdc.approve(address(distributor), totalPayout);
        distributor.depositFunds(totalPayout);
        vm.stopPrank();
    }

    // ─── commitDistribution() ─────────────────────────────────────────────────

    function test_CommitDistribution_RootMatchesOffChain() public view {
        // The on-chain computed root must match the off-chain _buildMerkleTree root
        ROIDistributor.Distribution memory d = distributor.getDistribution();
        assertEq(d.merkleRoot, merkleRoot,      "on-chain root != off-chain root");
        assertEq(d.totalRequired, totalPayout,  "totalRequired mismatch");
        assertEq(d.totalDeposited, totalPayout, "totalDeposited mismatch");
        assertEq(d.totalClaimed, 0);
    }

    function test_CommitDistribution_EmitsFullClaimantList() public {
        // The claimant list is no longer stored on-chain — it must be fully recoverable
        // from the DistributionCommitted event (this is what the NestJS backend indexes
        // to display/verify the distribution).
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);
        ROIDistributor.Claimant[] memory c = _claimants2(alice, aliceClaim, bob, bobClaim);

        vm.recordLogs();
        vm.prank(spvTreasury);
        dist2.commitDistribution(c);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("DistributionCommitted(bytes32,uint256,uint256,(address,uint256)[])");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            (uint256 total, uint256 count, ROIDistributor.Claimant[] memory list) =
                abi.decode(logs[i].data, (uint256, uint256, ROIDistributor.Claimant[]));
            assertEq(total, totalPayout);
            assertEq(count, 2);
            assertEq(list.length, 2);
            assertEq(list[0].wallet, c[0].wallet);
            assertEq(list[0].amount, c[0].amount);
            assertEq(list[1].wallet, c[1].wallet);
            assertEq(list[1].amount, c[1].amount);
            found = true;
        }
        assertTrue(found, "DistributionCommitted event not found");
    }

    function test_RecoveryUnlocksAt_SetWhenClaimsEnabled_NotAtCommit() public {
        // H-1: the recovery clock must start when claims OPEN (full deposit), not at
        // commit time — otherwise a delayed deposit shrinks the investor claim window.
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = _claimants2(alice, aliceClaim, bob, bobClaim);

        // Commit only — clock is NOT armed yet.
        vm.prank(spvTreasury);
        dist2.commitDistribution(c);
        assertEq(dist2.recoveryUnlocksAt(), 0, "armed at commit time (H-1 regression)");

        // Partial deposit (still underfunded) — still NOT armed.
        usdc.mint(spvTreasury, totalPayout);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), totalPayout);
        dist2.depositFunds(totalPayout - 1);
        assertEq(dist2.recoveryUnlocksAt(), 0, "armed before claims enabled (H-1 regression)");

        // Final deposit tips it to fully funded → claims enabled → clock armed NOW.
        dist2.depositFunds(1);
        vm.stopPrank();
        assertTrue(dist2.claimsEnabled(), "claims should be enabled");
        assertEq(
            dist2.recoveryUnlocksAt(),
            block.timestamp + dist2.RECOVERY_DELAY(),
            "clock must arm at claims-enabled time"
        );
    }

    function test_RevertWhen_RecoverCommittedButUnderfunded() public {
        // H-1: a committed-but-never-fully-funded distribution can never be recovered —
        // recoveryUnlocksAt stays 0, so recoverFunds() always reverts RecoveryTooEarly,
        // even far in the future. (Use withdrawDeposit() to pull partial funds back.)
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = _claimants2(alice, aliceClaim, bob, bobClaim);
        usdc.mint(spvTreasury, totalPayout);
        vm.startPrank(spvTreasury);
        dist2.commitDistribution(c);
        usdc.approve(address(dist2), totalPayout);
        dist2.depositFunds(totalPayout - 1); // underfunded by 1 — claims never enable
        vm.stopPrank();

        vm.warp(block.timestamp + 10_000 days);

        vm.expectRevert(ROIDistributor.RecoveryTooEarly.selector);
        vm.prank(spvTreasury);
        dist2.recoverFunds();
    }

    function test_CommitDistribution_EmitsEvent() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = _claimants2(alice, aliceClaim, bob, bobClaim);

        (bytes32 expectedRoot,,) = _buildMerkleTree(alice, aliceClaim, bob, bobClaim);

        vm.expectEmit(true, false, false, true);
        emit ROIDistributor.DistributionCommitted(expectedRoot, totalPayout, 2, c);

        vm.prank(spvTreasury);
        dist2.commitDistribution(c);
    }

    function test_RevertWhen_CommitAlreadyCommitted() public {
        vm.expectRevert(ROIDistributor.AlreadyCommitted.selector);
        vm.prank(spvTreasury);
        distributor.commitDistribution(claimants);
    }

    function test_RevertWhen_CommitEmptyClaimants() public {
        (,, ROIDistributor dist2) = _createProject();

        vm.expectRevert(ROIDistributor.EmptyClaimants.selector);
        vm.prank(spvTreasury);
        ROIDistributor.Claimant[] memory empty;
        dist2.commitDistribution(empty);
    }

    function test_RevertWhen_CommitProjectNotCompleted() public {
        (,, ROIDistributor dist2) = _createProject(); // still FUNDRAISING

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](1);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: 1e6});

        vm.expectRevert(ROIDistributor.ProjectNotCompleted.selector);
        vm.prank(spvTreasury);
        dist2.commitDistribution(c);
    }

    function test_RevertWhen_CommitDuplicateWallet() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](2);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: aliceClaim});
        c[1] = ROIDistributor.Claimant({wallet: alice, amount: aliceClaim}); // duplicate

        // A duplicate wallet is not strictly ascending → caught by the sorted invariant
        vm.expectRevert(abi.encodeWithSelector(ROIDistributor.UnsortedClaimants.selector, alice));
        vm.prank(spvTreasury);
        dist2.commitDistribution(c);
    }

    function test_RevertWhen_CommitNonAdmin() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](1);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: 1e6});

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                dist2.ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        dist2.commitDistribution(c);
    }

    function test_RevertWhen_CommitZeroWallet() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](1);
        c[0] = ROIDistributor.Claimant({wallet: address(0), amount: 1e6});

        // zero address can't exceed prev (address(0)) → rejected by the ascending invariant
        vm.expectRevert(abi.encodeWithSelector(ROIDistributor.UnsortedClaimants.selector, address(0)));
        vm.prank(spvTreasury);
        dist2.commitDistribution(c);
    }

    function test_RevertWhen_CommitZeroAmount() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](1);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: 0});

        vm.expectRevert(ROIDistributor.ZeroAmount.selector);
        vm.prank(spvTreasury);
        dist2.commitDistribution(c);
    }

    // ─── depositFunds() ───────────────────────────────────────────────────────

    function test_DepositFunds_MultipleDepositsEnableClaims() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = _claimants2(alice, aliceClaim, bob, bobClaim);

        vm.prank(spvTreasury);
        dist2.commitDistribution(c);

        assertFalse(dist2.claimsEnabled());
        assertEq(dist2.remainingToDeposit(), totalPayout);

        // First partial deposit
        uint256 firstHalf = totalPayout / 2;
        usdc.mint(spvTreasury, totalPayout);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), totalPayout);
        dist2.depositFunds(firstHalf);
        vm.stopPrank();

        assertFalse(dist2.claimsEnabled());
        assertEq(dist2.remainingToDeposit(), totalPayout - firstHalf);

        // Second deposit completes the total
        vm.startPrank(spvTreasury);
        dist2.depositFunds(totalPayout - firstHalf);
        vm.stopPrank();

        assertTrue(dist2.claimsEnabled());
        assertEq(dist2.remainingToDeposit(), 0);
    }

    function test_DepositFunds_EmitsClaimsEnabled() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = _claimants2(alice, aliceClaim, bob, bobClaim);

        usdc.mint(spvTreasury, totalPayout);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), totalPayout);
        dist2.commitDistribution(c);

        vm.expectEmit(false, false, false, true);
        emit ROIDistributor.ClaimsEnabled(totalPayout);
        dist2.depositFunds(totalPayout);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositNoCommitment() public {
        (,, ROIDistributor dist2) = _createProject();

        vm.expectRevert(ROIDistributor.NoCommitment.selector);
        vm.prank(spvTreasury);
        dist2.depositFunds(1e6);
    }

    function test_RevertWhen_DepositZeroAmount() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](1);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: 1e6});

        vm.prank(spvTreasury);
        dist2.commitDistribution(c);

        vm.expectRevert(ROIDistributor.ZeroAmount.selector);
        vm.prank(spvTreasury);
        dist2.depositFunds(0);
    }

    function test_RevertWhen_DepositAlreadyFullyFunded() public {
        // distributor in setUp is already fully funded
        vm.expectRevert(ROIDistributor.AlreadyFullyFunded.selector);
        vm.prank(spvTreasury);
        distributor.depositFunds(1e6);
    }

    // ─── withdrawDeposit() ────────────────────────────────────────────────────

    function test_WithdrawDeposit_ReturnsUSDCToTreasury() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = _claimants2(alice, aliceClaim, bob, bobClaim);

        uint256 halfAmount = totalPayout / 2;
        usdc.mint(spvTreasury, halfAmount);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), halfAmount);
        dist2.commitDistribution(c);
        dist2.depositFunds(halfAmount);
        vm.stopPrank();

        assertFalse(dist2.claimsEnabled());
        uint256 treasuryBefore = usdc.balanceOf(spvTreasury);

        vm.prank(spvTreasury);
        dist2.withdrawDeposit();

        assertEq(usdc.balanceOf(spvTreasury), treasuryBefore + halfAmount);
        assertEq(dist2.getDistribution().totalDeposited, 0);
    }

    function test_RevertWhen_WithdrawDepositNoCommitment() public {
        (,, ROIDistributor dist2) = _createProject();

        vm.expectRevert(ROIDistributor.NoCommitment.selector);
        vm.prank(spvTreasury);
        dist2.withdrawDeposit();
    }

    function test_RevertWhen_WithdrawDepositZeroDeposited() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](1);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: 1e6});

        vm.prank(spvTreasury);
        dist2.commitDistribution(c);

        // Nothing deposited yet
        vm.expectRevert(ROIDistributor.ZeroAmount.selector);
        vm.prank(spvTreasury);
        dist2.withdrawDeposit();
    }

    function test_RevertWhen_WithdrawDepositClaimsEnabled() public {
        // distributor in setUp is fully funded — can't withdraw
        vm.expectRevert(ROIDistributor.ClaimsAlreadyEnabled.selector);
        vm.prank(spvTreasury);
        distributor.withdrawDeposit();
    }

    // ─── cancelCommitment() ───────────────────────────────────────────────────

    function test_CancelCommitment_ResetsStateAndAllowsRecommit() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory wrong = new ROIDistributor.Claimant[](1);
        wrong[0] = ROIDistributor.Claimant({wallet: alice, amount: 1e6}); // wrong amount

        vm.prank(spvTreasury);
        dist2.commitDistribution(wrong);

        // Cancel before any deposit
        vm.prank(spvTreasury);
        dist2.cancelCommitment();

        // State is reset
        ROIDistributor.Distribution memory d = dist2.getDistribution();
        assertEq(d.merkleRoot, bytes32(0));
        assertEq(d.totalRequired, 0);
        assertEq(dist2.recoveryUnlocksAt(), 0);

        // Can recommit with corrected data
        ROIDistributor.Claimant[] memory correct = _claimants2(alice, aliceClaim, bob, bobClaim);

        vm.prank(spvTreasury);
        dist2.commitDistribution(correct);

        assertEq(dist2.getDistribution().totalRequired, totalPayout);
    }

    function test_RevertWhen_CancelNoCommitment() public {
        (,, ROIDistributor dist2) = _createProject();

        vm.expectRevert(ROIDistributor.NoCommitment.selector);
        vm.prank(spvTreasury);
        dist2.cancelCommitment();
    }

    function test_RevertWhen_CancelWithDeposit() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](1);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: 1e6});

        usdc.mint(spvTreasury, 1e6);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), 1e6);
        dist2.commitDistribution(c);
        dist2.depositFunds(1e6);
        vm.stopPrank();

        // Must call withdrawDeposit() first
        vm.expectRevert(ROIDistributor.DepositNotEmpty.selector);
        vm.prank(spvTreasury);
        dist2.cancelCommitment();
    }

    // ─── recoverFunds() ───────────────────────────────────────────────────────

    function test_RecoverFunds_AfterDelay_SendsToTreasury() public {
        // Alice claims, bob does not — bob's share stays in contract
        vm.prank(alice);
        distributor.claim(aliceClaim, aliceProof);

        uint256 treasuryBefore = usdc.balanceOf(spvTreasury);

        // Warp past RECOVERY_DELAY (armed when claims enabled in setUp = block.timestamp)
        vm.warp(distributor.recoveryUnlocksAt() + 1);

        vm.prank(spvTreasury);
        distributor.recoverFunds();

        // Bob's unclaimed share went to treasury
        assertEq(usdc.balanceOf(spvTreasury), treasuryBefore + bobClaim);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function test_RecoverFunds_SendsToWithdrawRecipient_NotArbitrary() public view {
        // Confirm hardcoded — no address parameter, always goes to spvTreasury
        assertEq(distributor.withdrawRecipient(), spvTreasury);
    }

    function test_RevertWhen_RecoverNeverCommitted() public {
        (,, ROIDistributor dist2) = _createProject();

        vm.expectRevert(ROIDistributor.RecoveryTooEarly.selector);
        vm.prank(spvTreasury);
        dist2.recoverFunds();
    }

    function test_RevertWhen_RecoverTooEarly() public {
        // Warp to just before unlock
        vm.warp(distributor.recoveryUnlocksAt() - 1);

        vm.expectRevert(ROIDistributor.RecoveryTooEarly.selector);
        vm.prank(spvTreasury);
        distributor.recoverFunds();
    }

    function test_RevertWhen_RecoverNothingToRecover() public {
        // Both investors claim — nothing left
        vm.prank(alice);
        distributor.claim(aliceClaim, aliceProof);
        vm.prank(bob);
        distributor.claim(bobClaim, bobProof);

        vm.warp(distributor.recoveryUnlocksAt() + 1);

        vm.expectRevert(ROIDistributor.NothingToRecover.selector);
        vm.prank(spvTreasury);
        distributor.recoverFunds();
    }

    // ─── claim() ──────────────────────────────────────────────────────────────

    function test_Claim_Alice_ReceivesUSDC_AndBurnsTokens() public {
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit ROIDistributor.ROIClaimed(alice, aliceClaim);

        vm.prank(alice);
        distributor.claim(aliceClaim, aliceProof);

        assertEq(usdc.balanceOf(alice), usdcBefore + aliceClaim);
        assertEq(token.balanceOf(alice), 0);
        assertTrue(distributor.claimed(alice));
    }

    function test_Claim_Bob_ReceivesUSDC_AndBurnsTokens() public {
        uint256 usdcBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        distributor.claim(bobClaim, bobProof);

        assertEq(usdc.balanceOf(bob), usdcBefore + bobClaim);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_BothInvestorsClaim_TotalClaimedTracked() public {
        vm.prank(alice);
        distributor.claim(aliceClaim, aliceProof);
        vm.prank(bob);
        distributor.claim(bobClaim, bobProof);

        ROIDistributor.Distribution memory d = distributor.getDistribution();
        assertEq(d.totalClaimed, totalPayout);
        assertEq(distributor.remainingFunds(), 0);
    }

    function test_RevertWhen_ClaimNotEnabled() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        // Committed but not fully funded
        ROIDistributor.Claimant[] memory c = _claimants2(alice, aliceClaim, bob, bobClaim);

        usdc.mint(spvTreasury, totalPayout / 2);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), totalPayout / 2);
        dist2.commitDistribution(c);
        dist2.depositFunds(totalPayout / 2);
        vm.stopPrank();

        vm.expectRevert(ROIDistributor.ClaimsNotEnabled.selector);
        vm.prank(alice);
        dist2.claim(aliceClaim, aliceProof);
    }

    function test_RevertWhen_AlreadyClaimed() public {
        vm.prank(alice);
        distributor.claim(aliceClaim, aliceProof);

        vm.expectRevert(ROIDistributor.AlreadyClaimed.selector);
        vm.prank(alice);
        distributor.claim(aliceClaim, aliceProof);
    }

    function test_RevertWhen_InvalidProof() public {
        // Bob uses Alice's proof — should fail
        vm.expectRevert(ROIDistributor.InvalidProof.selector);
        vm.prank(bob);
        distributor.claim(bobClaim, aliceProof);
    }

    function test_RevertWhen_TamperedAmount() public {
        uint256 tamperedAmount = aliceClaim + 1e6;

        vm.expectRevert(ROIDistributor.InvalidProof.selector);
        vm.prank(alice);
        distributor.claim(tamperedAmount, aliceProof);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _advanceToCompleted() internal {
        _fundInvestor(alice, address(funding), 25_000e6);
        _fundInvestor(bob,   address(funding), 175_000e6);
        vm.prank(alice); funding.invest(25_000e6);
        vm.prank(bob);   funding.invest(175_000e6);
        vm.startPrank(multisig);
        funding.withdrawFunds();
        funding.setActive();
        funding.setCompleted(ROI_BPS);
        vm.stopPrank();
    }

    function _advanceToCompletedFor(PropertyFunding f, uint256 aliceAmt, uint256 bobAmt) internal {
        _fundInvestor(alice, address(f), aliceAmt);
        _fundInvestor(bob,   address(f), bobAmt);
        vm.prank(alice); f.invest(aliceAmt);
        vm.prank(bob);   f.invest(bobAmt);
        vm.startPrank(multisig);
        f.withdrawFunds();
        f.setActive();
        f.setCompleted(ROI_BPS);
        vm.stopPrank();
    }

    // ─── H-B: commitDistribution scale ─────────────────────────────────────────

    /// @dev Build n claimants with strictly-ascending wallets (commit ordering invariant).
    function _bigClaimants(uint256 n) internal pure returns (ROIDistributor.Claimant[] memory c) {
        c = new ROIDistributor.Claimant[](n);
        for (uint256 i = 0; i < n; i++) {
            c[i] = ROIDistributor.Claimant({wallet: address(uint160(0x100000 + i)), amount: 1_000e6 + i});
        }
    }

    /// @notice Gas regression: commitDistribution at the MAX_CLAIMANTS cap must stay well
    ///         within a block. Variant C (sorted O(n) dedup + event-only list) measures
    ///         ~6M execution gas at 2000; we assert a generous 10M ceiling so any regression
    ///         (e.g. accidentally re-introducing on-chain claimant storage) trips this.
    function test_Gas_CommitDistribution_AtMaxClaimants() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        uint256 n = dist2.MAX_CLAIMANTS(); // 2000
        ROIDistributor.Claimant[] memory c = _bigClaimants(n);

        vm.prank(spvTreasury);
        uint256 g0 = gasleft();
        dist2.commitDistribution(c);
        uint256 used = g0 - gasleft();
        emit log_named_uint("commitDistribution gas @ MAX_CLAIMANTS", used);
        assertLt(used, 10_000_000, "commitDistribution gas regressed above 10M");
    }

    function test_RevertWhen_CommitExceedsMaxClaimants() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = _bigClaimants(dist2.MAX_CLAIMANTS() + 1);

        vm.expectRevert(ROIDistributor.TooManyClaimants.selector);
        vm.prank(spvTreasury);
        dist2.commitDistribution(c);
    }

    function test_RevertWhen_CommitUnsortedClaimants() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        // Descending wallets — second entry is not > first
        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](2);
        c[0] = ROIDistributor.Claimant({wallet: address(0x20), amount: 1e6});
        c[1] = ROIDistributor.Claimant({wallet: address(0x10), amount: 1e6});

        vm.expectRevert(abi.encodeWithSelector(ROIDistributor.UnsortedClaimants.selector, address(0x10)));
        vm.prank(spvTreasury);
        dist2.commitDistribution(c);
    }

    // ─── I-3: per-claim entitlement cap ─────────────────────────────────────────

    /// @dev A compromised tree-builder commits a VALID tree that massively over-pays a real
    ///      investor. The proof verifies, but the on-chain cap rejects it — the protection
    ///      against an inflated distribution list that the Merkle check alone can't catch.
    function test_RevertWhen_Claim_ExceedsEntitlement_MaliciousTree() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6); // alice principal = 25_000e6, finalROIBps = ROI_BPS

        uint256 inflated = 100_000e6; // ≫ 25k * 1.1525 cap
        uint256 bobAmt   = 175_000e6;
        (, bytes32[] memory aliceP,) = _buildMerkleTree(alice, inflated, bob, bobAmt);
        ROIDistributor.Claimant[] memory c = _claimants2(alice, inflated, bob, bobAmt);

        uint256 total = inflated + bobAmt;
        usdc.mint(spvTreasury, total);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), total);
        dist2.commitDistribution(c);
        dist2.depositFunds(total);
        vm.stopPrank();

        uint256 cap = 25_000e6 * (10_000 + ROI_BPS + dist2.CLAIM_CAP_BUFFER_BPS()) / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(ROIDistributor.ClaimExceedsEntitlement.selector, inflated, cap)
        );
        vm.prank(alice);
        dist2.claim(inflated, aliceP); // valid proof, but over the cap
    }

    /// @dev A wallet that never invested (principal 0 ⇒ cap 0) cannot claim even with a
    ///      valid proof in a fabricated tree.
    function test_RevertWhen_Claim_NonInvestorInTree() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        uint256 bobAmt     = 175_000e6 + (175_000e6 * ROI_BPS / 10_000);
        uint256 charlieAmt = 1e6; // charlie never invested
        (, bytes32[] memory bobP, bytes32[] memory charlieP) =
            _buildMerkleTree(bob, bobAmt, charlie, charlieAmt);
        ROIDistributor.Claimant[] memory c = _claimants2(bob, bobAmt, charlie, charlieAmt);

        uint256 total = bobAmt + charlieAmt;
        usdc.mint(spvTreasury, total);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), total);
        dist2.commitDistribution(c);
        dist2.depositFunds(total);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(ROIDistributor.ClaimExceedsEntitlement.selector, charlieAmt, uint256(0))
        );
        vm.prank(charlie);
        dist2.claim(charlieAmt, charlieP);

        // Sanity: the real investor in the same tree still claims fine.
        vm.prank(bob);
        dist2.claim(bobAmt, bobP);
    }

    /// @dev A claim exactly at the cap (principal * (1 + finalROI + buffer)) is allowed —
    ///      the buffer guarantees honest pro-rata rounding never over-rejects.
    function test_Claim_AtEntitlementCap_Succeeds() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        uint256 cap    = 25_000e6 * (10_000 + ROI_BPS + dist2.CLAIM_CAP_BUFFER_BPS()) / 10_000;
        uint256 bobAmt = 175_000e6;
        (, bytes32[] memory aliceP,) = _buildMerkleTree(alice, cap, bob, bobAmt);
        ROIDistributor.Claimant[] memory c = _claimants2(alice, cap, bob, bobAmt);

        uint256 total = cap + bobAmt;
        usdc.mint(spvTreasury, total);
        vm.startPrank(spvTreasury);
        usdc.approve(address(dist2), total);
        dist2.commitDistribution(c);
        dist2.depositFunds(total);
        vm.stopPrank();

        vm.prank(alice);
        dist2.claim(cap, aliceP); // exactly at the cap → allowed
        assertEq(usdc.balanceOf(alice), cap);
    }
}
