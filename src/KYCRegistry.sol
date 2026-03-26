// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IKYCRegistry} from "./interfaces/IKYCRegistry.sol";

/**
 * @title KYCRegistry
 * @notice On-chain registry of KYC/AML attestations issued by the backend after
 *         off-chain verification (Synaps + Parallel Markets).
 *
 *         Two investor tracks:
 *           - Reg D 506(c): US accredited investors  → accreditedInvestor = true
 *           - Reg S:        non-US investors          → regSEligible = true
 *
 *         In production this reads EAS (Ethereum Attestation Service) on Base.
 *         Here we implement a standalone registry so contracts are self-contained
 *         and testable without an external EAS deployment.
 *
 * Roles:
 *   DEFAULT_ADMIN_ROLE — Gnosis Safe; manages roles
 *   ATTESTER_ROLE      — NestJS hot wallet; issues/revokes attestations
 *   PAUSER_ROLE        — Gnosis Safe; emergency stop
 */
contract KYCRegistry is IKYCRegistry, AccessControl, Pausable {
    // ─── Errors ────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error AlreadyRevoked();
    error AttestationNotFound();

    // ─── Events ────────────────────────────────────────────────────────────────
    event AttestationIssued(
        address indexed wallet,
        bool accredited,
        bool regS,
        bytes2 country,
        uint64 expiresAt
    );

    // ─── storage slots (yes, vars on same time:))  ────────────────────────────────────────────────────────────────
    event AttestationRevoked(address indexed wallet);
    event AttestationUpdated(address indexed wallet, uint64 newExpiry);


    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    struct Attestation {
        bool    kycPassed;
        bool    accreditedInvestor; // Reg D 506(c) — US accredited
        bool    regSEligible;       // Reg S — non-US investor
        bytes2  countryCode;        // ISO 3166-1 alpha-2, e.g. "US", "UA"
        uint64  expiresAt;          // unix timestamp — attestations expire (max 1 yr)
        bool    revoked;
    }

    mapping(address => Attestation) private _attestations;

    // PM webhook reverse-lookup: keccak256(pmInvestorId) → wallet
    // Written on OAuth callback, read on webhook to find which wallet to revoke
    mapping(bytes32 => address) private _pmIdHashToWallet;

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(address admin, address attester) {
        if (admin == address(0) || attester == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ATTESTER_ROLE, attester);
        _grantRole(PAUSER_ROLE, admin);
    }

    // ─── Attester actions ──────────────────────────────────────────────────────

    /**
     * @notice Issue or overwrite an attestation for a wallet.
     * @param pmIdHash  keccak256(pmInvestorId) for webhook reverse-lookup.
     *                  Pass bytes32(0) for non-US (Synaps-only) investors.
     */
    function issueAttestation(
        address wallet,
        bool accreditedInvestor,
        bool regSEligible,
        bytes2 countryCode,
        uint64 expiresAt,
        bytes32 pmIdHash
    ) external onlyRole(ATTESTER_ROLE) whenNotPaused {
        if (wallet == address(0)) revert ZeroAddress();

        _attestations[wallet] = Attestation({
            kycPassed:          true,
            accreditedInvestor: accreditedInvestor,
            regSEligible:       regSEligible,
            countryCode:        countryCode,
            expiresAt:          expiresAt,
            revoked:            false
        });

        if (pmIdHash != bytes32(0)) {
            _pmIdHashToWallet[pmIdHash] = wallet;
        }

        emit AttestationIssued(wallet, accreditedInvestor, regSEligible, countryCode, expiresAt);
    }

    /// @notice Revoke attestation — called on PM webhook (accreditation.expired/revoked)
    function revokeAttestation(address wallet) external onlyRole(ATTESTER_ROLE) {
        if (_attestations[wallet].revoked) revert AlreadyRevoked();
        _attestations[wallet].revoked = true;
        emit AttestationRevoked(wallet);
    }

    /// @notice Extend expiry — called on PM webhook (accreditation.updated/renewed)
    function updateExpiry(address wallet, uint64 newExpiry) external onlyRole(ATTESTER_ROLE) {
        if (!_attestations[wallet].kycPassed) revert AttestationNotFound();
        _attestations[wallet].expiresAt = newExpiry;
        _attestations[wallet].revoked   = false; // re-activate if previously expired
        emit AttestationUpdated(wallet, newExpiry);
    }

    // ─── IKYCRegistry ──────────────────────────────────────────────────────────

    function isVerified(address wallet) public view returns (bool) {
        Attestation storage a = _attestations[wallet];
        return a.kycPassed && !a.revoked && block.timestamp < a.expiresAt;
    }

    function isAccredited(address wallet) public view returns (bool) {
        Attestation storage a = _attestations[wallet];
        return a.kycPassed && a.accreditedInvestor && !a.revoked && block.timestamp < a.expiresAt;
    }

    function isRegSEligible(address wallet) public view returns (bool) {
        Attestation storage a = _attestations[wallet];
        return a.kycPassed && a.regSEligible && !a.revoked && block.timestamp < a.expiresAt;
    }

    /// @notice True if investor is eligible under either Reg D (US) or Reg S (non-US)
    function isEligibleInvestor(address wallet) public view returns (bool) {
        return isAccredited(wallet) || isRegSEligible(wallet);
    }

    // ─── View helpers ──────────────────────────────────────────────────────────

    function getAttestation(address wallet) external view returns (Attestation memory) {
        return _attestations[wallet];
    }

    /// @notice Reverse-lookup for Parallel Markets webhook handling.
    ///         Only callable by attester to protect investor privacy.
    function getWalletByPmIdHash(bytes32 pmIdHash)
        external
        view
        onlyRole(ATTESTER_ROLE)
        returns (address)
    {
        return _pmIdHashToWallet[pmIdHash];
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
