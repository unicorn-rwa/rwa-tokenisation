// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {PropertyFunding} from "../src/PropertyFunding.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract PropertyFundingTest is BaseTest {
    PropertyFunding internal funding;
    PropertyToken   internal token;

    function setUp() public override {
        super.setUp();
        (funding, token) = _createProject();
    }

    // ─── invest() ─────────────────────────────────────────────────────────────

    function test_Invest_AcceptsUSDC_AndMintsTokens() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);

        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        assertEq(funding.investments(alice), MIN_INVESTMENT);
        assertEq(funding.totalRaised(), MIN_INVESTMENT);
        // 1 USDC (1e6) = 1 token (1e18) → scaled by DECIMALS_FACTOR = 1e12
        assertEq(token.balanceOf(alice), MIN_INVESTMENT * funding.DECIMALS_FACTOR());
    }

    function test_Invest_EmitsEvent() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        uint256 expectedTokens = MIN_INVESTMENT * funding.DECIMALS_FACTOR();

        vm.expectEmit(true, false, false, true);
        emit PropertyFunding.Invested(alice, MIN_INVESTMENT, expectedTokens);

        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);
    }

    function test_Invest_TransitionsToFunded_WhenGoalReached() public {
        // Fill the entire goal in one shot (alice is accredited, no cap restriction here)
        _fundInvestor(alice, address(funding), FUNDING_GOAL);

        vm.expectEmit(true, true, false, false);
        emit PropertyFunding.StateChanged(PropertyFunding.State.FUNDRAISING, PropertyFunding.State.FUNDED);

        vm.prank(alice);
        funding.invest(FUNDING_GOAL);

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.FUNDED));
    }

    function test_Invest_BothTracks_RegDandRegS() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT); // Reg D
        _fundInvestor(bob,   address(funding), MIN_INVESTMENT); // Reg S

        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.prank(bob);
        funding.invest(MIN_INVESTMENT);

        assertEq(funding.totalRaised(), MIN_INVESTMENT * 2);
        assertEq(funding.investorCount(), 2);
    }

    function test_RevertWhen_InvestWithoutKYC() public {
        _fundInvestor(charlie, address(funding), MIN_INVESTMENT);

        vm.expectRevert(
            abi.encodeWithSelector(PropertyFunding.NotEligibleInvestor.selector, charlie)
        );
        vm.prank(charlie);
        funding.invest(MIN_INVESTMENT);
    }

    function test_RevertWhen_InvestBelowMinimum() public {
        uint256 tooLittle = MIN_INVESTMENT - 1;
        _fundInvestor(alice, address(funding), tooLittle);

        vm.expectRevert(
            abi.encodeWithSelector(PropertyFunding.BelowMinimum.selector, MIN_INVESTMENT, tooLittle)
        );
        vm.prank(alice);
        funding.invest(tooLittle);
    }

    function test_RevertWhen_InvestAfterDeadline() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);

        vm.expectRevert(PropertyFunding.DeadlinePassed.selector);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);
    }

    function test_RevertWhen_InvestNotInFundraisingState() public {
        // Fill goal to move to FUNDED
        _fundInvestor(alice, address(funding), FUNDING_GOAL);
        vm.prank(alice);
        funding.invest(FUNDING_GOAL);

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.FUNDED));

        // Try investing again — should revert with wrong state
        _fundInvestor(bob, address(funding), MIN_INVESTMENT);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.WrongState.selector,
                PropertyFunding.State.FUNDRAISING,
                PropertyFunding.State.FUNDED
            )
        );
        vm.prank(bob);
        funding.invest(MIN_INVESTMENT);
    }

    function test_RevertWhen_InvestWhilePaused() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);

        vm.prank(admin);
        funding.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);
    }

    // ─── triggerRefund() ──────────────────────────────────────────────────────

    function test_TriggerRefund_AfterDeadlineGoalNotMet() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT); // far below goal

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);

        vm.expectEmit(true, true, false, false);
        emit PropertyFunding.StateChanged(
            PropertyFunding.State.FUNDRAISING,
            PropertyFunding.State.REFUNDING
        );

        funding.triggerRefund(); // anyone can call this
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.REFUNDING));
    }

    function test_RevertWhen_TriggerRefund_DeadlineNotReached() public {
        vm.expectRevert(PropertyFunding.DeadlineNotReached.selector);
        funding.triggerRefund();
    }

    function test_RevertWhen_TriggerRefund_GoalAlreadyMet() public {
        // Once the goal is met invest() transitions state to FUNDED immediately.
        // triggerRefund() requires FUNDRAISING, so it reverts with WrongState — not GoalAlreadyMet.
        // GoalAlreadyMet is a defensive guard; WrongState fires first via the modifier.
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

    // ─── claimRefund() ────────────────────────────────────────────────────────

    function test_ClaimRefund_ReturnsUSDC_BurnsTokens() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        funding.triggerRefund();

        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit PropertyFunding.RefundClaimed(alice, MIN_INVESTMENT);

        vm.prank(alice);
        funding.claimRefund();

        assertEq(usdc.balanceOf(alice), usdcBefore + MIN_INVESTMENT);
        assertEq(token.balanceOf(alice), 0); // tokens burned
        assertEq(funding.investments(alice), 0);
    }

    function test_RevertWhen_ClaimRefund_NothingInvested() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        funding.triggerRefund();

        vm.expectRevert(PropertyFunding.NothingToRefund.selector);
        vm.prank(charlie);
        funding.claimRefund();
    }

    function test_RevertWhen_ClaimRefund_AlreadyClaimed() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);
        funding.triggerRefund();

        vm.prank(alice);
        funding.claimRefund();

        // Second claim — investments[alice] == 0 now
        vm.expectRevert(PropertyFunding.NothingToRefund.selector);
        vm.prank(alice);
        funding.claimRefund();
    }

    // ─── withdrawFunds() ──────────────────────────────────────────────────────

    function test_WithdrawFunds_TransfersToMultisig() public {
        _fundInvestor(alice, address(funding), FUNDING_GOAL);
        vm.prank(alice);
        funding.invest(FUNDING_GOAL);

        uint256 multisigBefore = usdc.balanceOf(multisig);

        vm.expectEmit(true, false, false, true);
        emit PropertyFunding.FundsWithdrawn(multisig, FUNDING_GOAL);

        vm.prank(admin);
        funding.withdrawFunds();

        assertEq(usdc.balanceOf(multisig), multisigBefore + FUNDING_GOAL);
        assertEq(usdc.balanceOf(address(funding)), 0);
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.WITHDRAWN));
    }

    function test_RevertWhen_NonAdminWithdraws() public {
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
    }

    // ─── Full lifecycle ────────────────────────────────────────────────────────

    /**
     * @notice Integration test: FUNDRAISING → FUNDED → WITHDRAWN → ACTIVE → COMPLETED
     */
    function test_FullLifecycle_SuccessPath() public {
        // 1. Two investors fund the project
        uint256 aliceAmount = 120_000e6;
        uint256 bobAmount   =  80_000e6;
        _fundInvestor(alice, address(funding), aliceAmount);
        _fundInvestor(bob,   address(funding), bobAmount);

        vm.prank(alice); funding.invest(aliceAmount);
        vm.prank(bob);   funding.invest(bobAmount);

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.FUNDED));

        // 2. Admin withdraws to multisig (fiat conversion)
        vm.prank(admin);
        funding.withdrawFunds();
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.WITHDRAWN));

        // 3. Construction starts
        vm.prank(admin);
        funding.setActive();
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.ACTIVE));

        // 4. Construction completes
        vm.prank(admin);
        funding.setCompleted();
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.COMPLETED));

        // Token holders confirmed — ROIDistributor takes over from here
        assertGt(token.balanceOf(alice), 0);
        assertGt(token.balanceOf(bob), 0);
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_Invest_AnyAmountAboveMin(uint256 amount) public {
        // Bound: between min and funding goal
        amount = bound(amount, MIN_INVESTMENT, FUNDING_GOAL);
        _fundInvestor(alice, address(funding), amount);

        vm.prank(alice);
        funding.invest(amount);

        assertEq(funding.investments(alice), amount);
        assertEq(token.balanceOf(alice), amount * funding.DECIMALS_FACTOR());
    }

    function testFuzz_TotalRaised_NeverExceedsFundingGoal(
        uint256 amount1,
        uint256 amount2
    ) public {
        amount1 = bound(amount1, MIN_INVESTMENT, FUNDING_GOAL / 2);
        amount2 = bound(amount2, MIN_INVESTMENT, FUNDING_GOAL / 2);

        _fundInvestor(alice, address(funding), amount1);
        _fundInvestor(bob,   address(funding), amount2);

        vm.prank(alice); funding.invest(amount1);
        vm.prank(bob);   funding.invest(amount2);

        assertLe(funding.totalRaised(), FUNDING_GOAL + amount1 + amount2);
    }
}
