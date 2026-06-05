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
    error ConflictingInvestorTypes();
    error AttestationAlreadyActive();
    error InvalidExpiry();

    // ─── Events ────────────────────────────────────────────────────────────────
    event AttestationIssued(
        address indexed wallet,
        bool accredited,
        bool nonAccreditedUS,
        bool regS,
        bytes2 country,
        uint64 expiresAt
    );
    event AttestationRevoked(address indexed wallet);
    event AttestationUpdated(address indexed wallet, uint64 newExpiry);
    event CountryRestricted(bytes2 indexed country);
    event CountryAllowed(bytes2 indexed country);


    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    struct Attestation {
        bool    kycPassed;
        bool    accreditedInvestor; // Reg D 506(c) — US accredited       (max $25k/project)
        bool    nonAccreditedUS;    // Reg D 506(b) — US non-accredited   (max $2.5k/project)
        bool    regSEligible;       // Reg S        — non-US investor      (country-level limits)
        bytes2  countryCode;        // ISO 3166-1 alpha-2, e.g. "US", "UA"
        uint64  expiresAt;          // unix timestamp — attestations expire (max 1 yr)
        bool    revoked;
    }

    mapping(address => Attestation) private _attestations;

    // PM webhook reverse-lookup: keccak256(pmInvestorId) → wallet
    // Written on OAuth callback, read on webhook to find which wallet to revoke
    mapping(bytes32 => address) private _pmIdHashToWallet;

    // Countries blocked from investing (ISO 3166-1 alpha-2).
    // KYC attestation can still be issued — restriction applies at invest() time only.
    mapping(bytes2 => bool) private _restrictedCountries;

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(address admin, address attester) {
        if (admin == address(0) || attester == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ATTESTER_ROLE, attester);
        _grantRole(PAUSER_ROLE, admin);

        // V1: US investors not yet supported — restrict at investment level.
        // Remove via allowCountry("US") when US investor flow is ready.
        _restrictedCountries[bytes2("US")] = true;
        emit CountryRestricted(bytes2("US"));
    }

    // ─── Attester actions ──────────────────────────────────────────────────────

    /**
     * @notice Issue or overwrite an attestation for a wallet.
     *         Exactly one of accreditedInvestor / nonAccreditedUS / regSEligible must be true.
     * @param pmIdHash  keccak256(pmInvestorId) for webhook reverse-lookup.
     *                  Pass bytes32(0) for non-US (Synaps-only) investors.
     */
    function issueAttestation(
        address wallet,
        bool accreditedInvestor,
        bool nonAccreditedUS,
        bool regSEligible,
        bytes2 countryCode,
        uint64 expiresAt,
        bytes32 pmIdHash
    ) external onlyRole(ATTESTER_ROLE) whenNotPaused {
        if (wallet == address(0)) revert ZeroAddress();
        // M-1: prevent silent overwrite of an active attestation — revoke first
        if (isVerified(wallet)) revert AttestationAlreadyActive();
        // M-1: prevent past-dated issuance that silently "issues" an already-expired attestation
        if (expiresAt <= block.timestamp) revert InvalidExpiry();

        // Investor types are mutually exclusive — exactly one must be set
        uint8 typeCount = (accreditedInvestor ? 1 : 0)
                        + (nonAccreditedUS    ? 1 : 0)
                        + (regSEligible       ? 1 : 0);
        if (typeCount != 1) revert ConflictingInvestorTypes();

        _attestations[wallet] = Attestation({
            kycPassed:          true,
            accreditedInvestor: accreditedInvestor,
            nonAccreditedUS:    nonAccreditedUS,
            regSEligible:       regSEligible,
            countryCode:        countryCode,
            expiresAt:          expiresAt,
            revoked:            false
        });

        if (pmIdHash != bytes32(0)) {
            _pmIdHashToWallet[pmIdHash] = wallet;
        }

        emit AttestationIssued(wallet, accreditedInvestor, nonAccreditedUS, regSEligible, countryCode, expiresAt);
    }

    /// @notice Revoke attestation — called on PM webhook (accreditation.expired/revoked)
    function revokeAttestation(address wallet) external onlyRole(ATTESTER_ROLE) {
        // L-2: reject calls on wallets with no attestation — prevents silent storage pollution
        if (!_attestations[wallet].kycPassed) revert AttestationNotFound();
        if (_attestations[wallet].revoked) revert AlreadyRevoked();
        _attestations[wallet].revoked = true;
        emit AttestationRevoked(wallet);
    }

    /// @notice Extend expiry — called on PM webhook (accreditation.updated/renewed).
    ///         Cannot be used to re-activate a manually revoked attestation — use
    ///         issueAttestation() (requires admin Safe) for that instead.
    function updateExpiry(address wallet, uint64 newExpiry) external onlyRole(ATTESTER_ROLE) {
        if (!_attestations[wallet].kycPassed) revert AttestationNotFound();
        if (_attestations[wallet].revoked) revert AlreadyRevoked();
        _attestations[wallet].expiresAt = newExpiry;
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

    function isNonAccreditedUS(address wallet) public view returns (bool) {
        Attestation storage a = _attestations[wallet];
        return a.kycPassed && a.nonAccreditedUS && !a.revoked && block.timestamp < a.expiresAt;
    }

    function isRegSEligible(address wallet) public view returns (bool) {
        Attestation storage a = _attestations[wallet];
        return a.kycPassed && a.regSEligible && !a.revoked && block.timestamp < a.expiresAt;
    }

    /// @notice True if investor is eligible under Reg D 506(c), Reg D 506(b), or Reg S
    function isEligibleInvestor(address wallet) public view returns (bool) {
        return isAccredited(wallet) || isNonAccreditedUS(wallet) || isRegSEligible(wallet);
    }

    // ─── View helpers ──────────────────────────────────────────────────────────

    function getAttestation(address wallet) external view returns (Attestation memory) {
        return _attestations[wallet];
    }

    /// @notice Returns the country code stored for a wallet (bytes2(0) if no attestation).
    function getCountry(address wallet) external view returns (bytes2) {
        return _attestations[wallet].countryCode;
    }

    /// @notice True if the country is on the investment restriction list.
    function isCountryRestricted(bytes2 countryCode) external view returns (bool) {
        return _restrictedCountries[countryCode];
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

    /// @notice Add a country to the investment restriction list.
    ///         Only the multisig (DEFAULT_ADMIN_ROLE) can call this.
    function restrictCountry(bytes2 countryCode) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _restrictedCountries[countryCode] = true;
        emit CountryRestricted(countryCode);
    }

    /// @notice Remove a country from the investment restriction list.
    ///         Only the multisig (DEFAULT_ADMIN_ROLE) can call this.
    function allowCountry(bytes2 countryCode) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _restrictedCountries[countryCode] = false;
        emit CountryAllowed(countryCode);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
