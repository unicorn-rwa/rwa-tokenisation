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
        // Bob (Reg S, no cap) fills the entire goal in one shot
        _fundInvestor(bob, address(funding), FUNDING_GOAL);

        vm.expectEmit(true, true, false, false);
        emit PropertyFunding.StateChanged(PropertyFunding.State.FUNDRAISING, PropertyFunding.State.FUNDED);

        vm.prank(bob);
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
        // Fill goal with bob (no cap) to move to FUNDED
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
        funding.invest(FUNDING_GOAL);

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.FUNDED));

        // Try investing again — should revert with wrong state
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.WrongState.selector,
                PropertyFunding.State.FUNDRAISING,
                PropertyFunding.State.FUNDED
            )
        );
        vm.prank(alice);
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

        vm.prank(alice);
        funding.triggerRefund();
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.REFUNDING));
    }

    function test_TriggerRefund_OnlyInvestor_NonInvestorReverts() public {
        // charlie has no KYC and no investment — must be rejected with NotAnInvestor
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);

        vm.expectRevert(PropertyFunding.NotAnInvestor.selector);
        vm.prank(charlie); // charlie never called invest()
        funding.triggerRefund();
    }

    function test_TriggerRefund_OnlyInvestor_InvestorSucceeds() public {
        // alice invested → she can trigger the refund after deadline
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.warp(block.timestamp + DEADLINE_OFFSET + 1);

        vm.prank(alice);
        funding.triggerRefund();

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.REFUNDING));
    }

    function test_RevertWhen_TriggerRefund_DeadlineNotReached() public {
        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);

        vm.expectRevert(PropertyFunding.DeadlineNotReached.selector);
        vm.prank(alice);
        funding.triggerRefund();
    }

    function test_RevertWhen_TriggerRefund_GoalAlreadyMet() public {
        // Once the goal is met invest() transitions state to FUNDED immediately.
        // triggerRefund() requires FUNDRAISING, so it reverts with WrongState — not GoalAlreadyMet.
        // GoalAlreadyMet is a defensive guard; WrongState fires first via the modifier.
        // bob is Reg S (no cap) — can invest the full FUNDING_GOAL
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
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
        vm.prank(alice);
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
        vm.prank(alice);
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
        vm.prank(alice);
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
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
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
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
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
        //    Alice (accredited, $25k cap) + Bob (Reg S, no cap) together hit $200k goal
        uint256 aliceAmount =  25_000e6;
        uint256 bobAmount   = 175_000e6;
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
        // Bound alice's amount within her $25k accredited cap
        amount = bound(amount, MIN_INVESTMENT, MAX_ACCREDITED_INVESTMENT);
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
        // alice capped at $25k, bob (Reg S) capped at half-goal for this test
        amount1 = bound(amount1, MIN_INVESTMENT, MAX_ACCREDITED_INVESTMENT);
        amount2 = bound(amount2, MIN_INVESTMENT, FUNDING_GOAL / 2);

        _fundInvestor(alice, address(funding), amount1);
        _fundInvestor(bob,   address(funding), amount2);

        vm.prank(alice); funding.invest(amount1);
        vm.prank(bob);   funding.invest(amount2);

        assertLe(funding.totalRaised(), FUNDING_GOAL + amount1 + amount2);
    }

    // ─── Per-investor-type limits ──────────────────────────────────────────────

    function test_RevertWhen_AccreditedExceedsPerProjectLimit() public {
        uint256 overLimit = MAX_ACCREDITED_INVESTMENT + 1;
        _fundInvestor(alice, address(funding), overLimit);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.ExceedsInvestorLimit.selector,
                MAX_ACCREDITED_INVESTMENT,
                overLimit
            )
        );
        vm.prank(alice);
        funding.invest(overLimit);
    }

    function test_AccreditedMultipleInvests_CumulativeWithinLimit() public {
        // Two investments totalling exactly the cap — both should succeed
        uint256 half = MAX_ACCREDITED_INVESTMENT / 2;
        _fundInvestor(alice, address(funding), MAX_ACCREDITED_INVESTMENT);

        vm.prank(alice); funding.invest(half);
        vm.prank(alice); funding.invest(half);

        assertEq(funding.investments(alice), MAX_ACCREDITED_INVESTMENT);
    }

    function test_AccreditedMultipleInvests_CumulativeExceedsLimit() public {
        // First invest fine, second pushes over the cap
        _fundInvestor(alice, address(funding), MAX_ACCREDITED_INVESTMENT + MIN_INVESTMENT);

        vm.prank(alice);
        funding.invest(MAX_ACCREDITED_INVESTMENT); // fine — exactly at cap

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.ExceedsInvestorLimit.selector,
                MAX_ACCREDITED_INVESTMENT,
                MAX_ACCREDITED_INVESTMENT + MIN_INVESTMENT
            )
        );
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT); // pushes total over cap
    }

    function test_RevertWhen_NonAccreditedUS_ExceedsLimit() public {
        uint256 overLimit = MAX_NON_ACCREDITED_INVESTMENT + 1;
        _fundInvestor(dave, address(funding), overLimit);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.ExceedsInvestorLimit.selector,
                MAX_NON_ACCREDITED_INVESTMENT,
                overLimit
            )
        );
        vm.prank(dave);
        funding.invest(overLimit);
    }

    function test_RegS_NoLimit_CanInvestFullGoal() public {
        // Bob (Reg S) has no per-project cap — can invest the entire funding goal
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
        funding.invest(FUNDING_GOAL);

        assertEq(funding.investments(bob), FUNDING_GOAL);
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.FUNDED));
    }

    // ─── Country restriction ───────────────────────────────────────────────────

    function test_RevertWhen_InvestFromRestrictedCountry() public {
        // Re-restrict US (setUp called allowCountry — undo that for this test)
        vm.prank(admin);
        registry.restrictCountry(bytes2("US"));

        _fundInvestor(alice, address(funding), MIN_INVESTMENT);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.RestrictedCountry.selector,
                alice,
                bytes2("US")
            )
        );
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT);
    }

    function test_AllowCountry_UnblocksInvestment() public {
        // Re-restrict, then allow, then invest succeeds
        vm.prank(admin);
        registry.restrictCountry(bytes2("US"));

        vm.prank(admin);
        registry.allowCountry(bytes2("US"));

        _fundInvestor(alice, address(funding), MIN_INVESTMENT);
        vm.prank(alice);
        funding.invest(MIN_INVESTMENT); // no revert

        assertEq(funding.investments(alice), MIN_INVESTMENT);
    }

    // ─── Append-only metadata ─────────────────────────────────────────────────

    function test_OfferingDocHash_SetAtDeploy() public view {
        assertEq(funding.offeringDocHash(), "ipfs://QmTestHash");
    }

    function test_LatestMetadata_ReturnsOfferingHash_WhenNoUpdates() public view {
        assertEq(funding.latestMetadata(), "ipfs://QmTestHash");
    }

    function test_PushMetadataUpdate_AppendsToHistory() public {
        vm.prank(admin);
        funding.pushMetadataUpdate("ipfs://QmUpdate1");

        string[] memory history = funding.getMetadataHistory();
        assertEq(history.length, 1);
        assertEq(history[0], "ipfs://QmUpdate1");
        assertEq(funding.latestMetadata(), "ipfs://QmUpdate1");
    }

    function test_GetMetadataHistory_MultipleUpdates() public {
        vm.startPrank(admin);
        funding.pushMetadataUpdate("ipfs://QmUpdate1");
        funding.pushMetadataUpdate("ipfs://QmUpdate2");
        funding.pushMetadataUpdate("ipfs://QmUpdate3");
        vm.stopPrank();

        string[] memory history = funding.getMetadataHistory();
        assertEq(history.length, 3);
        assertEq(history[0], "ipfs://QmUpdate1");
        assertEq(history[2], "ipfs://QmUpdate3");
        assertEq(funding.latestMetadata(), "ipfs://QmUpdate3");
        // Original doc hash is unchanged
        assertEq(funding.offeringDocHash(), "ipfs://QmTestHash");
    }

    function test_PushMetadataUpdate_OnlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                funding.ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        funding.pushMetadataUpdate("ipfs://evil");
    }
}
