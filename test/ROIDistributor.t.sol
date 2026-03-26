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

    // Pre-built distribution for alice + bob
    bytes32 internal merkleRoot;
    bytes32[] internal aliceProof;
    bytes32[] internal bobProof;
    uint256 internal aliceClaim; // principal + ROI
    uint256 internal bobClaim;
    uint256 internal totalPayout;

    function setUp() public override {
        super.setUp();
        (funding, token) = _createProject();

        // Fund project to COMPLETED state
        _advanceToCompleted();

        // Build Merkle tree off-chain (here: inline in test)
        // Alice invested 120k, Bob invested 80k, 15% ROI
        aliceClaim = 120_000e6 + (120_000e6 * ROI_BPS / 10_000); // 138_000e6
        bobClaim   =  80_000e6 + ( 80_000e6 * ROI_BPS / 10_000); //  92_000e6
        totalPayout = aliceClaim + bobClaim; // 230_000e6

        (merkleRoot, aliceProof, bobProof) = _buildMerkleTree(alice, aliceClaim, bob, bobClaim);

        // Admin approves and deposits USDC into distributor
        usdc.mint(admin, totalPayout);
        vm.startPrank(admin);
        usdc.approve(address(distributor), totalPayout);
        distributor.depositReturns(address(funding), merkleRoot, totalPayout);
        vm.stopPrank();
    }

    // ─── depositReturns() ─────────────────────────────────────────────────────

    function test_DepositReturns_StoresMerkleRoot() public view {
        ROIDistributor.Distribution memory d = distributor.getDistribution(address(funding));
        assertEq(d.merkleRoot, merkleRoot);
        assertEq(d.totalDeposited, totalPayout);
        assertEq(d.totalClaimed, 0);
    }

    function test_DepositReturns_EmitsEvent() public {
        // Create a second project to test fresh deposit event
        (PropertyFunding f2,) = _createProject();
        // Must sum to FUNDING_GOAL (200_000e6) to reach FUNDED state
        _advanceToCompletedFor(f2, 100_000e6, 100_000e6);

        uint256 payout = 50_000e6 + (50_000e6 * ROI_BPS / 10_000) +
                         50_000e6 + (50_000e6 * ROI_BPS / 10_000);
        bytes32 newRoot = keccak256("testroot");

        usdc.mint(admin, payout);
        vm.startPrank(admin);
        usdc.approve(address(distributor), payout);

        vm.expectEmit(true, false, false, true);
        emit ROIDistributor.DistributionDeposited(address(f2), newRoot, payout);

        distributor.depositReturns(address(f2), newRoot, payout);
        vm.stopPrank();
    }

    function test_RevertWhen_ProjectNotCompleted() public {
        (PropertyFunding f2,) = _createProject(); // still FUNDRAISING

        usdc.mint(admin, 1e6);
        vm.startPrank(admin);
        usdc.approve(address(distributor), 1e6);

        vm.expectRevert(ROIDistributor.ProjectNotCompleted.selector);
        distributor.depositReturns(address(f2), bytes32("x"), 1e6);
        vm.stopPrank();
    }

    function test_RevertWhen_NonAdminDeposits() public {
        (PropertyFunding f2,) = _createProject();
        _advanceToCompletedFor(f2, FUNDING_GOAL / 2, FUNDING_GOAL / 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                distributor.ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        distributor.depositReturns(address(f2), bytes32("x"), 1e6);
    }

    // ─── claim() ──────────────────────────────────────────────────────────────

    function test_Claim_Alice_ReceivesUSDC_AndBurnsTokens() public {
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, true, false, true);
        emit ROIDistributor.ROIClaimed(address(funding), alice, aliceClaim);

        vm.prank(alice);
        distributor.claim(address(funding), aliceClaim, aliceProof);

        assertEq(usdc.balanceOf(alice), usdcBefore + aliceClaim);
        assertEq(token.balanceOf(alice), 0); // tokens burned on claim
        assertTrue(distributor.claimed(address(funding), alice));
    }

    function test_Claim_Bob_ReceivesUSDC_AndBurnsTokens() public {
        uint256 usdcBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        distributor.claim(address(funding), bobClaim, bobProof);

        assertEq(usdc.balanceOf(bob), usdcBefore + bobClaim);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_BothInvestorsClaim_TotalClaimedTracked() public {
        vm.prank(alice);
        distributor.claim(address(funding), aliceClaim, aliceProof);

        vm.prank(bob);
        distributor.claim(address(funding), bobClaim, bobProof);

        ROIDistributor.Distribution memory d = distributor.getDistribution(address(funding));
        assertEq(d.totalClaimed, totalPayout);
        assertEq(distributor.remainingFunds(address(funding)), 0);
    }

    function test_RevertWhen_AlreadyClaimed() public {
        vm.prank(alice);
        distributor.claim(address(funding), aliceClaim, aliceProof);

        vm.expectRevert(ROIDistributor.AlreadyClaimed.selector);
        vm.prank(alice);
        distributor.claim(address(funding), aliceClaim, aliceProof);
    }

    function test_RevertWhen_InvalidProof() public {
        // Bob uses Alice's proof — should fail
        vm.expectRevert(ROIDistributor.InvalidProof.selector);
        vm.prank(bob);
        distributor.claim(address(funding), bobClaim, aliceProof); // wrong proof
    }

    function test_RevertWhen_TamperedAmount() public {
        uint256 tamperedAmount = aliceClaim + 1e6; // inflated claim

        vm.expectRevert(ROIDistributor.InvalidProof.selector);
        vm.prank(alice);
        distributor.claim(address(funding), tamperedAmount, aliceProof);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Advance the default project to COMPLETED with alice=120k, bob=80k
    function _advanceToCompleted() internal {
        uint256 aliceAmount = 120_000e6;
        uint256 bobAmount   =  80_000e6;

        _fundInvestor(alice, address(funding), aliceAmount);
        _fundInvestor(bob,   address(funding), bobAmount);

        vm.prank(alice); funding.invest(aliceAmount);
        vm.prank(bob);   funding.invest(bobAmount);

        vm.startPrank(admin);
        funding.withdrawFunds();
        funding.setActive();
        funding.setCompleted();
        vm.stopPrank();
    }

    /// @dev Generic version — advance any funding contract to COMPLETED
    function _advanceToCompletedFor(
        PropertyFunding f,
        uint256 aliceAmount,
        uint256 bobAmount
    ) internal {
        _fundInvestor(alice, address(f), aliceAmount);
        _fundInvestor(bob,   address(f), bobAmount);

        vm.prank(alice); f.invest(aliceAmount);
        vm.prank(bob);   f.invest(bobAmount);

        vm.startPrank(admin);
        f.withdrawFunds();
        f.setActive();
        f.setCompleted();
        vm.stopPrank();
    }
}
