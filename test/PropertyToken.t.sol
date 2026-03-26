// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract PropertyTokenTest is BaseTest {
    PropertyToken internal token;
    address internal minter = makeAddr("minter");

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        token = new PropertyToken(
            "PropToken LA-01",
            "PROP-LA-01",
            admin,
            minter,
            address(registry)
        );
    }

    // ─── Mint / Burn ───────────────────────────────────────────────────────────

    function test_Mint_IncreasesBalance() public {
        vm.prank(minter);
        token.mint(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    function test_Burn_DecreasesBalance() public {
        vm.startPrank(minter);
        token.mint(alice, 1_000e18);
        token.burn(alice, 400e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 600e18);
    }

    function test_MintBurn_DoNotRequireKYCOnRecipient() public {
        // Mint to charlie (non-KYC) — allowed because from == 0 (mint bypasses _update check)
        vm.prank(minter);
        token.mint(charlie, 500e18);
        assertEq(token.balanceOf(charlie), 500e18);

        // Burn from charlie — allowed because to == 0 (burn bypasses _update check)
        vm.prank(minter);
        token.burn(charlie, 500e18);
        assertEq(token.balanceOf(charlie), 0);
    }

    function test_RevertWhen_NonMinterMints() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                alice,
                token.MINTER_ROLE()
            )
        );
        vm.prank(alice);
        token.mint(alice, 1e18);
    }

    // ─── ERC-3643 Transfer compliance ─────────────────────────────────────────

    function test_Transfer_RevertWhen_TransfersNotEnabled() public {
        vm.prank(minter);
        token.mint(alice, 1_000e18);

        vm.expectRevert(PropertyToken.TransfersLocked.selector);
        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_Transfer_RevertWhen_RecipientNotKYC() public {
        // Enable transfers first
        vm.prank(admin);
        token.enableTransfers();

        vm.prank(minter);
        token.mint(alice, 1_000e18);

        // charlie has no KYC — transfer should revert
        vm.expectRevert(
            abi.encodeWithSelector(PropertyToken.RecipientNotVerified.selector, charlie)
        );
        vm.prank(alice);
        token.transfer(charlie, 100e18);
    }

    function test_Transfer_SucceedsWhen_EnabledAndRecipientKYC() public {
        vm.prank(admin);
        token.enableTransfers();

        vm.prank(minter);
        token.mint(alice, 1_000e18);

        // alice → bob (both KYC'd)
        vm.prank(alice);
        token.transfer(bob, 300e18);

        assertEq(token.balanceOf(alice), 700e18);
        assertEq(token.balanceOf(bob),   300e18);
    }

    function test_EnableTransfers_EmitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit PropertyToken.TransfersEnabled();

        vm.prank(admin);
        token.enableTransfers();
    }

    // ─── Pause ────────────────────────────────────────────────────────────────

    function test_Pause_BlocksTransferBetweenKYCWallets() public {
        vm.prank(admin);
        token.enableTransfers();

        vm.prank(minter);
        token.mint(alice, 1_000e18);

        vm.prank(admin);
        token.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_Pause_DoesNotBlockMintBurn() public {
        vm.prank(admin);
        token.pause();

        // Mint still works (mint bypasses the pause check in _update)
        vm.prank(minter);
        token.mint(alice, 500e18);
        assertEq(token.balanceOf(alice), 500e18);
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_MintBurn_BalanceConsistency(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        burnAmount = bound(burnAmount, 0, mintAmount);

        vm.startPrank(minter);
        token.mint(alice, mintAmount);
        token.burn(alice, burnAmount);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
    }
}
