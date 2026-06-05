// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

        // Build Claimant array for commitDistribution
        claimants.push(ROIDistributor.Claimant({wallet: alice, amount: aliceClaim}));
        claimants.push(ROIDistributor.Claimant({wallet: bob,   amount: bobClaim}));

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

    function test_CommitDistribution_StoresClaimants() public view {
        ROIDistributor.Claimant[] memory stored = distributor.getClaimants();
        assertEq(stored.length, 2);
        assertEq(stored[0].wallet, alice);
        assertEq(stored[0].amount, aliceClaim);
        assertEq(stored[1].wallet, bob);
        assertEq(stored[1].amount, bobClaim);
    }

    function test_CommitDistribution_SetsRecoveryUnlocksAt() public view {
        // recoveryUnlocksAt is set at commit time, not at deposit time
        assertEq(distributor.recoveryUnlocksAt(), block.timestamp + distributor.RECOVERY_DELAY());
    }

    function test_CommitDistribution_EmitsEvent() public {
        (PropertyFunding f2,, ROIDistributor dist2) = _createProject();
        _advanceToCompletedFor(f2, 25_000e6, 175_000e6);

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](2);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: aliceClaim});
        c[1] = ROIDistributor.Claimant({wallet: bob,   amount: bobClaim});

        (bytes32 expectedRoot,,) = _buildMerkleTree(alice, aliceClaim, bob, bobClaim);

        vm.expectEmit(true, false, false, true);
        emit ROIDistributor.DistributionCommitted(expectedRoot, totalPayout, 2);

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

        vm.expectRevert(abi.encodeWithSelector(ROIDistributor.DuplicateClaimant.selector, alice));
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

        vm.expectRevert(ROIDistributor.ZeroAddress.selector);
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

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](2);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: aliceClaim});
        c[1] = ROIDistributor.Claimant({wallet: bob,   amount: bobClaim});

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

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](2);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: aliceClaim});
        c[1] = ROIDistributor.Claimant({wallet: bob,   amount: bobClaim});

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

        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](2);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: aliceClaim});
        c[1] = ROIDistributor.Claimant({wallet: bob,   amount: bobClaim});

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
        assertEq(dist2.getClaimants().length, 0);

        // Can recommit with corrected data
        ROIDistributor.Claimant[] memory correct = new ROIDistributor.Claimant[](2);
        correct[0] = ROIDistributor.Claimant({wallet: alice, amount: aliceClaim});
        correct[1] = ROIDistributor.Claimant({wallet: bob,   amount: bobClaim});

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

        // Warp past RECOVERY_DELAY (set at commitDistribution time = block.timestamp at setUp)
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
        ROIDistributor.Claimant[] memory c = new ROIDistributor.Claimant[](2);
        c[0] = ROIDistributor.Claimant({wallet: alice, amount: aliceClaim});
        c[1] = ROIDistributor.Claimant({wallet: bob,   amount: bobClaim});

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
        funding.setCompleted();
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
        f.setCompleted();
        vm.stopPrank();
    }
}
