// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {KYCRegistry} from "../src/KYCRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract KYCRegistryTest is BaseTest {
    // ─── issueAttestation ──────────────────────────────────────────────────────

    function test_IssueAttestation_SetsVerified() public {
        assertTrue(registry.isVerified(alice));
        assertTrue(registry.isVerified(bob));
        assertFalse(registry.isVerified(charlie));
    }

    function test_IssueAttestation_SetsAccredited() public {
        assertTrue(registry.isAccredited(alice));
        assertFalse(registry.isAccredited(bob));    // bob is Reg S, not accredited
        assertFalse(registry.isAccredited(charlie));
    }

    function test_IssueAttestation_SetsRegS() public {
        assertFalse(registry.isRegSEligible(alice)); // alice is US accredited
        assertTrue(registry.isRegSEligible(bob));
        assertFalse(registry.isRegSEligible(charlie));
    }

    function test_IssueAttestation_EmitsEvent() public {
        address newInvestor = makeAddr("newInvestor");

        // vm.expectEmit(checkTopic1, checkTopic2, checkTopic3, checkData)
        vm.expectEmit(true, false, false, true);
        emit KYCRegistry.AttestationIssued(newInvestor, true, false, "US", uint64(block.timestamp + 365 days));

        vm.prank(attester);
        registry.issueAttestation(
            newInvestor,
            true, false, "US",
            uint64(block.timestamp + 365 days),
            bytes32(0)
        );
    }

    function test_IssueAttestation_StoresPmIdHash() public {
        bytes32 pmHash = keccak256("pm_investor_12345");
        address investor = makeAddr("investor");

        vm.prank(attester);
        registry.issueAttestation(investor, true, false, "US", uint64(block.timestamp + 365 days), pmHash);

        vm.prank(attester);
        assertEq(registry.getWalletByPmIdHash(pmHash), investor);
    }

    function test_RevertWhen_NonAttesterIssues() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                registry.ATTESTER_ROLE()
            )
        );
        vm.prank(charlie);
        registry.issueAttestation(alice, true, false, "US", uint64(block.timestamp + 1), bytes32(0));
    }

    function test_RevertWhen_ZeroAddressIssued() public {
        vm.expectRevert(KYCRegistry.ZeroAddress.selector);
        vm.prank(attester);
        registry.issueAttestation(address(0), true, false, "US", uint64(block.timestamp + 1), bytes32(0));
    }

    // ─── Expiry ────────────────────────────────────────────────────────────────

    function test_IsVerified_ReturnsFalse_AfterExpiry() public {
        // Alice's attestation expires in 365 days
        assertTrue(registry.isVerified(alice));

        // Warp past expiry
        vm.warp(block.timestamp + 366 days);

        assertFalse(registry.isVerified(alice));
        assertFalse(registry.isAccredited(alice));
        assertFalse(registry.isEligibleInvestor(alice));
    }

    function test_UpdateExpiry_ReactivatesAttestation() public {
        vm.warp(block.timestamp + 366 days);
        assertFalse(registry.isVerified(alice));

        // Attester renews (PM sent accreditation.updated webhook)
        vm.prank(attester);
        registry.updateExpiry(alice, uint64(block.timestamp + 365 days));

        assertTrue(registry.isVerified(alice));
    }

    // ─── Revocation ────────────────────────────────────────────────────────────

    function test_RevokeAttestation_BlocksVerification() public {
        assertTrue(registry.isVerified(alice));

        vm.prank(attester);
        registry.revokeAttestation(alice);

        assertFalse(registry.isVerified(alice));
        assertFalse(registry.isAccredited(alice));
        assertFalse(registry.isEligibleInvestor(alice));
    }

    function test_RevokeAttestation_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit KYCRegistry.AttestationRevoked(alice);

        vm.prank(attester);
        registry.revokeAttestation(alice);
    }

    function test_RevertWhen_RevokeAlreadyRevoked() public {
        vm.startPrank(attester);
        registry.revokeAttestation(alice);

        vm.expectRevert(KYCRegistry.AlreadyRevoked.selector);
        registry.revokeAttestation(alice);
        vm.stopPrank();
    }

    // ─── isEligibleInvestor ────────────────────────────────────────────────────

    function test_IsEligibleInvestor_TrueForBothTracks() public {
        assertTrue(registry.isEligibleInvestor(alice)); // Reg D
        assertTrue(registry.isEligibleInvestor(bob));   // Reg S
        assertFalse(registry.isEligibleInvestor(charlie));
    }

    // ─── Pause ────────────────────────────────────────────────────────────────

    function test_Pause_BlocksIssuance() public {
        vm.prank(admin);
        registry.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(attester);
        registry.issueAttestation(charlie, true, false, "US", uint64(block.timestamp + 1), bytes32(0));
    }

    // ─── Fuzz ──────────────────────────────────────────────────────────────────

    /// @dev Any non-zero wallet with valid expiry should be verifiable
    function testFuzz_IssueAndVerify(address wallet, uint64 offsetDays) public {
        vm.assume(wallet != address(0));
        // Keep offset in a reasonable range: 1 day to 2 years
        offsetDays = uint64(bound(offsetDays, 1 days, 730 days));

        vm.prank(attester);
        registry.issueAttestation(
            wallet,
            false, true, "UA",
            uint64(block.timestamp + offsetDays),
            bytes32(0)
        );

        assertTrue(registry.isVerified(wallet));
        assertTrue(registry.isRegSEligible(wallet));
    }
}
