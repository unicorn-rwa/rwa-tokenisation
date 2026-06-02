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
            minter
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

    // ─── Non-transferable ─────────────────────────────────────────────────────

    /// @dev Any wallet-to-wallet transfer is permanently disabled, regardless of recipient KYC
    function test_Transfer_AlwaysReverts() public {
        vm.prank(minter);
        token.mint(alice, 1_000e18);

        vm.expectRevert(PropertyToken.TransfersDisabled.selector);
        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    /// @dev transferFrom is also permanently blocked
    function test_TransferFrom_AlwaysReverts() public {
        vm.prank(minter);
        token.mint(alice, 1_000e18);

        vm.prank(alice);
        token.approve(charlie, 100e18);

        vm.expectRevert(PropertyToken.TransfersDisabled.selector);
        vm.prank(charlie);
        token.transferFrom(alice, bob, 100e18);
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
