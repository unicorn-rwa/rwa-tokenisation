// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {PropertyFunding} from "../src/PropertyFunding.sol";
import {PropertyFundingFactory} from "../src/PropertyFundingFactory.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract PropertyFundingTest is BaseTest {
    PropertyFunding internal funding;
    PropertyToken   internal token;

    function setUp() public override {
        super.setUp();
        (funding, token,) = _createProject();
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

        vm.prank(multisig);
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

    function test_RevertWhen_TriggerRefund_GoalAlreadyMet_BeforeTimeout() public {
        // Once the goal is met, state is FUNDED. triggerRefund() now accepts FUNDED
        // state but only after WITHDRAWAL_TIMEOUT. Before the timeout it reverts.
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
        funding.invest(FUNDING_GOAL);

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.FUNDED));
        assertEq(funding.fundedAt(), block.timestamp);

        // Warp to just before the 30-day timeout
        vm.warp(block.timestamp + funding.WITHDRAWAL_TIMEOUT() - 1);

        vm.expectRevert(PropertyFunding.WithdrawalTimeoutNotReached.selector);
        vm.prank(bob);
        funding.triggerRefund();
    }

    // ─── H-1 escape hatch (FUNDED timeout) ────────────────────────────────────

    function test_TriggerRefund_FromFunded_AfterTimeout() public {
        // Admin goes dark — never calls withdrawFunds(). After 30 days any
        // investor can force REFUNDING and recover their USDC.
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
        funding.invest(FUNDING_GOAL); // state → FUNDED, fundedAt recorded

        vm.warp(block.timestamp + funding.WITHDRAWAL_TIMEOUT() + 1);

        vm.prank(bob);
        funding.triggerRefund();

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.REFUNDING));
    }

    function test_WithdrawFunds_DisarmsTimeout() public {
        // Admin acts on day 25 — well within the 30-day window.
        // After withdrawal state is WITHDRAWN; triggerRefund() from WITHDRAWN
        // reverts with WrongState — the escape hatch is disarmed.
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
        funding.invest(FUNDING_GOAL);

        vm.warp(block.timestamp + 25 days);
        vm.prank(multisig);
        funding.withdrawFunds(); // state → WITHDRAWN

        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.WITHDRAWN));

        // Warp past the original timeout — doesn't matter, state is WITHDRAWN
        vm.warp(block.timestamp + funding.WITHDRAWAL_TIMEOUT() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyFunding.WrongState.selector,
                PropertyFunding.State.FUNDRAISING,
                PropertyFunding.State.WITHDRAWN
            )
        );
        vm.prank(bob);
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

        uint256 treasuryBefore = usdc.balanceOf(spvTreasury);

        vm.expectEmit(true, false, false, true);
        emit PropertyFunding.FundsWithdrawn(spvTreasury, FUNDING_GOAL);

        vm.prank(multisig); // spvAdmin drives state transition
        funding.withdrawFunds();

        assertEq(usdc.balanceOf(spvTreasury), treasuryBefore + FUNDING_GOAL);
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

        // 2. SPV multisig withdraws to itself (fiat conversion)
        vm.prank(multisig);
        funding.withdrawFunds();
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.WITHDRAWN));

        // 3. Construction starts
        vm.prank(multisig);
        funding.setActive();
        assertEq(uint8(funding.state()), uint8(PropertyFunding.State.ACTIVE));

        // 4. Construction completes
        vm.prank(multisig);
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
        vm.prank(multisig);
        funding.pushMetadataUpdate("ipfs://QmUpdate1");

        string[] memory history = funding.getMetadataHistory();
        assertEq(history.length, 1);
        assertEq(history[0], "ipfs://QmUpdate1");
        assertEq(funding.latestMetadata(), "ipfs://QmUpdate1");
    }

    function test_GetMetadataHistory_MultipleUpdates() public {
        vm.startPrank(multisig);
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

    // ─── Deadline cap (C-2 fix) ────────────────────────────────────────────────

    function test_RevertWhen_DeadlineExceeds180Days() public {
        uint256 tooFar = block.timestamp + funding.MAX_FUNDRAISING_DURATION() + 1;

        vm.expectRevert(PropertyFunding.DeadlineTooFar.selector);
        vm.prank(admin);
        factory.createProject(
            "PropToken Test",
            "PROP-TEST",
            multisig,
            spvTreasury,
            FUNDING_GOAL,
            tooFar,          // deadline > 180 days from now
            ROI_BPS,
            block.timestamp + 60 days,
            block.timestamp + 540 days,
            MIN_INVESTMENT,
            MAX_ACCREDITED_INVESTMENT,
            MAX_NON_ACCREDITED_INVESTMENT,
            "ipfs://QmTestHash"
        );
    }

    function test_AllowsDeadlineAtExactly180Days() public {
        uint256 exactMax = block.timestamp + funding.MAX_FUNDRAISING_DURATION();

        vm.prank(admin);
        (address f,,) = factory.createProject(
            "PropToken Test",
            "PROP-TEST",
            multisig,
            spvTreasury,
            FUNDING_GOAL,
            exactMax,        // deadline == 180 days from now — must succeed
            ROI_BPS,
            block.timestamp + 60 days,
            block.timestamp + 540 days,
            MIN_INVESTMENT,
            MAX_ACCREDITED_INVESTMENT,
            MAX_NON_ACCREDITED_INVESTMENT,
            "ipfs://QmTestHash"
        );
        assertEq(PropertyFunding(f).deadline(), exactMax);
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

    // ─── M-2: spvAdmin == spvTreasury rejected by factory ─────────────────────

    function test_RevertWhen_SpvAdminEqualsSpvTreasury() public {
        vm.expectRevert(PropertyFundingFactory.RoleConflict.selector);
        vm.prank(admin);
        factory.createProject(
            "PropToken Test", "PROP-TEST",
            multisig,  // spvAdmin == spvTreasury — must revert
            multisig,
            FUNDING_GOAL, block.timestamp + DEADLINE_OFFSET,
            ROI_BPS, block.timestamp + 60 days, block.timestamp + 540 days,
            MIN_INVESTMENT, MAX_ACCREDITED_INVESTMENT, MAX_NON_ACCREDITED_INVESTMENT,
            "ipfs://QmTestHash"
        );
    }

    // ─── M-3: relational investment param validation ───────────────────────────

    function test_RevertWhen_MinInvestment_ExceedsAccreditedCap() public {
        uint256 bigMin = MAX_ACCREDITED_INVESTMENT + 1;
        vm.expectRevert(PropertyFundingFactory.InvalidParam.selector);
        vm.prank(admin);
        factory.createProject(
            "PropToken Test", "PROP-TEST",
            multisig, spvTreasury,
            FUNDING_GOAL, block.timestamp + DEADLINE_OFFSET,
            ROI_BPS, block.timestamp + 60 days, block.timestamp + 540 days,
            bigMin,                    // minInvestment > maxAccreditedInvestment
            MAX_ACCREDITED_INVESTMENT,
            MAX_NON_ACCREDITED_INVESTMENT,
            "ipfs://QmTestHash"
        );
    }

    function test_RevertWhen_MinInvestment_ExceedsNonAccreditedCap() public {
        uint256 bigMin = MAX_NON_ACCREDITED_INVESTMENT + 1;
        vm.expectRevert(PropertyFundingFactory.InvalidParam.selector);
        vm.prank(admin);
        factory.createProject(
            "PropToken Test", "PROP-TEST",
            multisig, spvTreasury,
            FUNDING_GOAL, block.timestamp + DEADLINE_OFFSET,
            ROI_BPS, block.timestamp + 60 days, block.timestamp + 540 days,
            bigMin,                       // minInvestment > maxNonAccreditedUSInvestment
            MAX_ACCREDITED_INVESTMENT,
            MAX_NON_ACCREDITED_INVESTMENT,
            "ipfs://QmTestHash"
        );
    }

    // ─── M-4: withdrawFunds uses totalRaised, not balanceOf ───────────────────

    function test_WithdrawFunds_UsesTotalRaised_NotAccidentalUSDC() public {
        _fundInvestor(bob, address(funding), FUNDING_GOAL);
        vm.prank(bob);
        funding.invest(FUNDING_GOAL);

        // Accidentally send extra USDC directly to the contract
        uint256 accidental = 1_000e6;
        usdc.mint(address(funding), accidental);
        assertEq(usdc.balanceOf(address(funding)), FUNDING_GOAL + accidental);

        uint256 treasuryBefore = usdc.balanceOf(spvTreasury);
        vm.prank(multisig);
        funding.withdrawFunds();

        // Only totalRaised (FUNDING_GOAL) is transferred — accidental USDC stays in contract
        assertEq(usdc.balanceOf(spvTreasury), treasuryBefore + FUNDING_GOAL);
        assertEq(usdc.balanceOf(address(funding)), accidental);
    }

    // ─── H-4: MINTER_ROLE locked after deploy ─────────────────────────────────

    function test_PropertyToken_MinterRole_LockedAfterDeploy() public {
        // spvAdmin (multisig) should no longer have DEFAULT_ADMIN_ROLE on the token
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), multisig));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));

        // Cannot grant MINTER_ROLE — no admin exists on the token
        bytes32 minterRole = keccak256("MINTER_ROLE");
        address attacker = makeAddr("attacker");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                multisig,
                token.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(multisig);
        token.grantRole(minterRole, attacker);
    }

    // ─── L-5: MINTER/BURNER least-privilege split ─────────────────────────────

    function test_PropertyToken_RoleSplit_LeastPrivilege() public {
        // Fresh project so we can inspect all three contracts' roles
        (PropertyFunding f, PropertyToken t,) = _createProject();
        address roi = factory.projectDistributor(address(f));

        bytes32 minterRole = t.MINTER_ROLE();
        bytes32 burnerRole = t.BURNER_ROLE();

        // Funding can both mint (invest) and burn (refund)
        assertTrue(t.hasRole(minterRole, address(f)), "funding missing MINTER_ROLE");
        assertTrue(t.hasRole(burnerRole, address(f)), "funding missing BURNER_ROLE");

        // Distributor can burn (ROI claim) but must NOT be able to mint
        assertTrue(t.hasRole(burnerRole, roi),  "distributor missing BURNER_ROLE");
        assertFalse(t.hasRole(minterRole, roi), "distributor must not hold MINTER_ROLE");

        // Factory retains nothing after wiring
        assertFalse(t.hasRole(minterRole, address(factory)), "factory still has MINTER_ROLE");
        assertFalse(t.hasRole(burnerRole, address(factory)), "factory still has BURNER_ROLE");
    }

    function test_RevertWhen_DistributorAttemptsMint() public {
        (PropertyFunding f, PropertyToken t,) = _createProject();
        address roi = factory.projectDistributor(address(f));

        // Even the distributor — which legitimately burns — cannot mint unbacked tokens
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                roi,
                t.MINTER_ROLE()
            )
        );
        vm.prank(roi);
        t.mint(roi, 1_000e18);
    }

    // ─── L-3: MAX_INVESTORS cap ────────────────────────────────────────────────

    function test_RevertWhen_InvestorCountExceedsMax() public {
        // Create a project with a tiny funding goal so we can fill it with many investors
        // Use a fresh project to avoid polluting setUp's funding
        vm.prank(admin);
        (address f,,) = factory.createProject(
            "PropToken Cap", "PROP-CAP",
            multisig, spvTreasury,
            type(uint256).max,               // effectively unlimited goal
            block.timestamp + DEADLINE_OFFSET,
            ROI_BPS, block.timestamp + 60 days, block.timestamp + 540 days,
            MIN_INVESTMENT, MAX_ACCREDITED_INVESTMENT, MAX_NON_ACCREDITED_INVESTMENT,
            "ipfs://QmTestHash"
        );
        PropertyFunding capFunding = PropertyFunding(f);
        uint256 cap = capFunding.MAX_INVESTORS();

        // Register and invest for exactly MAX_INVESTORS unique Reg S wallets
        for (uint256 i = 0; i < cap; i++) {
            address inv = makeAddr(string(abi.encodePacked("regSInvestor", i)));
            vm.prank(attester);
            registry.issueAttestation(inv, false, false, true, "UA", uint64(block.timestamp + 365 days), bytes32(0));
            _fundInvestor(inv, f, MIN_INVESTMENT);
            vm.prank(inv);
            capFunding.invest(MIN_INVESTMENT);
        }
        assertEq(capFunding.investorCount(), cap);

        // One more unique investor should revert
        address overflow = makeAddr("overflowInvestor");
        vm.prank(attester);
        registry.issueAttestation(overflow, false, false, true, "UA", uint64(block.timestamp + 365 days), bytes32(0));
        _fundInvestor(overflow, f, MIN_INVESTMENT);

        vm.expectRevert(PropertyFunding.TooManyInvestors.selector);
        vm.prank(overflow);
        capFunding.invest(MIN_INVESTMENT);
    }
}
