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

        vm.expectEmit(true, false, false, true);
        emit KYCRegistry.AttestationIssued(newInvestor, true, false, false, "US", uint64(block.timestamp + 365 days));

        vm.prank(attester);
        registry.issueAttestation(
            newInvestor,
            true,  // accreditedInvestor
            false, // nonAccreditedUS
            false, // regSEligible
            "US",
            uint64(block.timestamp + 365 days),
            bytes32(0)
        );
    }

    function test_IssueAttestation_StoresPmIdHash() public {
        bytes32 pmHash = keccak256("pm_investor_12345");
        address investor = makeAddr("investor");

        vm.prank(attester);
        registry.issueAttestation(investor, true, false, false, "US", uint64(block.timestamp + 365 days), pmHash);

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
        registry.issueAttestation(alice, true, false, false, "US", uint64(block.timestamp + 1), bytes32(0));
    }

    function test_RevertWhen_ZeroAddressIssued() public {
        vm.expectRevert(KYCRegistry.ZeroAddress.selector);
        vm.prank(attester);
        registry.issueAttestation(address(0), true, false, false, "US", uint64(block.timestamp + 1), bytes32(0));
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

    function test_RevertWhen_UpdateExpiry_OnRevokedAttestation() public {
        // Alice is sanctioned — manually revoked by attester (e.g. OFAC hit)
        vm.prank(attester);
        registry.revokeAttestation(alice);

        assertFalse(registry.isVerified(alice));

        // Compromised attester (or buggy PM webhook) tries to restore her via updateExpiry
        vm.expectRevert(KYCRegistry.AlreadyRevoked.selector);
        vm.prank(attester);
        registry.updateExpiry(alice, uint64(block.timestamp + 365 days));

        // Revocation must still be in effect
        assertFalse(registry.isVerified(alice));
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
        registry.issueAttestation(charlie, true, false, false, "US", uint64(block.timestamp + 1), bytes32(0));
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
            false, false, true, // regSEligible
            "UA",
            uint64(block.timestamp + offsetDays),
            bytes32(0)
        );

        assertTrue(registry.isVerified(wallet));
        assertTrue(registry.isRegSEligible(wallet));
    }

    // ─── nonAccreditedUS ───────────────────────────────────────────────────────

    function test_NonAccreditedUS_IsVerifiedAndEligible() public {
        // dave is set up in BaseTest as US non-accredited
        assertTrue(registry.isVerified(dave));
        assertTrue(registry.isNonAccreditedUS(dave));
        assertTrue(registry.isEligibleInvestor(dave));
        assertFalse(registry.isAccredited(dave));
        assertFalse(registry.isRegSEligible(dave));
    }

    function test_NonAccreditedUS_False_ForAccredited() public {
        assertFalse(registry.isNonAccreditedUS(alice));
    }

    function test_NonAccreditedUS_False_ForRegS() public {
        assertFalse(registry.isNonAccreditedUS(bob));
    }

    // ─── ConflictingInvestorTypes ──────────────────────────────────────────────

    function test_RevertWhen_TwoTypesSet() public {
        address wallet = makeAddr("dual");
        vm.expectRevert(KYCRegistry.ConflictingInvestorTypes.selector);
        vm.prank(attester);
        // accredited + regS both true → conflict
        registry.issueAttestation(wallet, true, false, true, "US", uint64(block.timestamp + 365 days), bytes32(0));
    }

    function test_RevertWhen_NoTypeSet() public {
        address wallet = makeAddr("none");
        vm.expectRevert(KYCRegistry.ConflictingInvestorTypes.selector);
        vm.prank(attester);
        // all false → typeCount = 0 → conflict
        registry.issueAttestation(wallet, false, false, false, "UA", uint64(block.timestamp + 365 days), bytes32(0));
    }

    function test_RevertWhen_AllThreeTypesSet() public {
        address wallet = makeAddr("all");
        vm.expectRevert(KYCRegistry.ConflictingInvestorTypes.selector);
        vm.prank(attester);
        registry.issueAttestation(wallet, true, true, true, "US", uint64(block.timestamp + 365 days), bytes32(0));
    }

    // ─── Country restrictions ──────────────────────────────────────────────────

    function test_US_RestrictedByDefault() public {
        // Deploy a fresh registry — US restriction comes from constructor, before setUp's allowCountry
        KYCRegistry freshRegistry = new KYCRegistry(admin, attester);
        assertTrue(freshRegistry.isCountryRestricted(bytes2("US")));
    }

    function test_AllowCountry_RemovesRestriction() public {
        // BaseTest setUp already called allowCountry("US"), so US should be unrestricted
        assertFalse(registry.isCountryRestricted(bytes2("US")));
    }

    function test_RestrictCountry_AddsRestriction() public {
        assertFalse(registry.isCountryRestricted(bytes2("CN")));
        vm.prank(admin);
        registry.restrictCountry(bytes2("CN"));
        assertTrue(registry.isCountryRestricted(bytes2("CN")));
    }

    function test_RestrictCountry_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit KYCRegistry.CountryRestricted(bytes2("CN"));
        vm.prank(admin);
        registry.restrictCountry(bytes2("CN"));
    }

    function test_AllowCountry_EmitsEvent() public {
        vm.prank(admin);
        registry.restrictCountry(bytes2("CN"));

        vm.expectEmit(true, false, false, false);
        emit KYCRegistry.CountryAllowed(bytes2("CN"));
        vm.prank(admin);
        registry.allowCountry(bytes2("CN"));
    }

    function test_GetCountry_ReturnsCorrectCode() public view {
        assertEq(registry.getCountry(alice), bytes2("US"));
        assertEq(registry.getCountry(bob),   bytes2("UA"));
        assertEq(registry.getCountry(dave),  bytes2("US"));
        assertEq(registry.getCountry(charlie), bytes2(0)); // no attestation
    }

    function test_RestrictCountry_OnlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(charlie);
        registry.restrictCountry(bytes2("UA"));
    }

    function test_AllowCountry_OnlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                charlie,
                registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(charlie);
        registry.allowCountry(bytes2("US"));
    }

    // ─── M-1: no silent overwrite of active attestation ────────────────────────

    function test_RevertWhen_IssueAttestation_OverActiveAttestation() public {
        // alice already has an active attestation — re-issuing must revert
        vm.expectRevert(KYCRegistry.AttestationAlreadyActive.selector);
        vm.prank(attester);
        registry.issueAttestation(alice, true, false, false, "US", uint64(block.timestamp + 365 days), bytes32(0));
    }

    function test_IssueAttestation_AllowsReissueAfterExpiry() public {
        // warp past alice's attestation expiry — re-issue should succeed
        vm.warp(block.timestamp + 366 days);
        assertFalse(registry.isVerified(alice));

        vm.prank(attester);
        registry.issueAttestation(alice, true, false, false, "US", uint64(block.timestamp + 365 days), bytes32(0));

        assertTrue(registry.isVerified(alice));
    }

    function test_IssueAttestation_AllowsReissueAfterRevoke() public {
        vm.startPrank(attester);
        registry.revokeAttestation(alice);
        // revoked attestation is not active — re-issue should succeed
        registry.issueAttestation(alice, true, false, false, "US", uint64(block.timestamp + 365 days), bytes32(0));
        vm.stopPrank();

        assertTrue(registry.isVerified(alice));
    }

    function test_RevertWhen_IssueAttestation_PastExpiry() public {
        // expiresAt in the past — would silently issue an already-expired attestation
        vm.expectRevert(KYCRegistry.InvalidExpiry.selector);
        vm.prank(attester);
        registry.issueAttestation(charlie, true, false, false, "US", uint64(block.timestamp - 1), bytes32(0));
    }

    function test_RevertWhen_IssueAttestation_ExpiryAtCurrentTimestamp() public {
        vm.expectRevert(KYCRegistry.InvalidExpiry.selector);
        vm.prank(attester);
        registry.issueAttestation(charlie, true, false, false, "US", uint64(block.timestamp), bytes32(0));
    }

    // ─── L-2: revert revokeAttestation on non-existent wallet ─────────────────

    function test_RevertWhen_RevokeNonExistentAttestation() public {
        // charlie has no attestation — must revert with AttestationNotFound
        vm.expectRevert(KYCRegistry.AttestationNotFound.selector);
        vm.prank(attester);
        registry.revokeAttestation(charlie);
    }
}
