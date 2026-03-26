// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IKYCRegistry} from "./interfaces/IKYCRegistry.sol";

/**
 * @title PropertyToken
 * @notice ERC-20 security token representing fractional ownership of one property.
 *         Implements the ERC-3643 compliance pattern: every token transfer checks
 *         that the recipient holds a valid KYC attestation.
 *
 *         Token lifecycle:
 *           1. Minted to investor when they call PropertyFunding.invest()
 *           2. Locked during construction (transfersEnabled = false)
 *           3. Burned by ROIDistributor when investor claims principal + ROI
 *           4. Burned by PropertyFunding when investor claims a refund
 *
 *         1 USDC (1e6 units) = 1 PropertyToken (1e18 units)
 *         The 1e12 scaling is handled in PropertyFunding.
 *
 * Roles:
 *   DEFAULT_ADMIN_ROLE — Gnosis Safe; manages roles, enables transfers
 *   MINTER_ROLE        — PropertyFunding + ROIDistributor; mint/burn
 *   PAUSER_ROLE        — Gnosis Safe; emergency stop
 */
contract PropertyToken is ERC20, AccessControl, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IKYCRegistry public immutable kycRegistry;

    /// @notice False during construction — prevents secondary market until v2
    bool public transfersEnabled;

    // ─── Events ────────────────────────────────────────────────────────────────
    event TransfersEnabled();

    // ─── Errors ────────────────────────────────────────────────────────────────
    error TransfersLocked();
    error RecipientNotVerified(address recipient);
    error ZeroAddress();

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(
        string memory name,
        string memory symbol,
        address admin,
        address minter,
        address kycRegistry_
    ) ERC20(name, symbol) {
        if (admin == address(0) || minter == address(0) || kycRegistry_ == address(0))
            revert ZeroAddress();

        kycRegistry = IKYCRegistry(kycRegistry_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Also grant DEFAULT_ADMIN_ROLE to minter (the factory) so it can wire up
        // MINTER_ROLE to PropertyFunding + ROIDistributor after deployment.
        // Factory revokes its own DEFAULT_ADMIN_ROLE once setup is complete.
        _grantRole(DEFAULT_ADMIN_ROLE, minter);
        _grantRole(MINTER_ROLE, minter);
        _grantRole(PAUSER_ROLE, admin);
    }

    // ─── Minter actions ────────────────────────────────────────────────────────

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    // ─── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Unlock secondary-market transfers between KYC'd investors (v2 feature)
    function enableTransfers() external onlyRole(DEFAULT_ADMIN_ROLE) {
        transfersEnabled = true;
        emit TransfersEnabled();
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ─── ERC-3643 compliance hook ───────────────────────────────────────────────
    //
    // _update() is called on every mint, burn, and transfer.
    // We only apply compliance rules for wallet-to-wallet transfers
    // (mint: from == 0, burn: to == 0 — both bypass the KYC check).

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            // Wallet-to-wallet transfer
            if (paused()) revert EnforcedPause();
            if (!transfersEnabled) revert TransfersLocked();
            if (!kycRegistry.isVerified(to)) revert RecipientNotVerified(to);
        }
        super._update(from, to, amount);
    }
}
