// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title PropertyToken
 * @notice Non-transferable ERC-20 token representing an investor's position in one property.
 *
 *         Token lifecycle:
 *           1. Minted to investor when they call PropertyFunding.invest()
 *           2. Burned by ROIDistributor when investor claims principal + ROI
 *           3. Burned by PropertyFunding when investor claims a refund
 *
 *         Wallet-to-wallet transfers are permanently disabled. The token exists
 *         solely as an on-chain proof of position — it cannot be sold or moved.
 *
 *         1 USDC (1e6 units) = 1 PropertyToken (1e18 units)
 *         The 1e12 scaling is handled in PropertyFunding.
 *
 * Roles:
 *   DEFAULT_ADMIN_ROLE — Gnosis Safe; manages roles
 *   MINTER_ROLE        — PropertyFunding + ROIDistributor; mint/burn
 */
contract PropertyToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ─── Errors ────────────────────────────────────────────────────────────────
    error TransfersDisabled();
    error ZeroAddress();

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(
        string memory name,
        string memory symbol,
        address admin,
        address minter
    ) ERC20(name, symbol) {
        if (admin == address(0) || minter == address(0))
            revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Also grant DEFAULT_ADMIN_ROLE to minter (the factory) so it can wire up
        // MINTER_ROLE to PropertyFunding + ROIDistributor after deployment.
        // Factory revokes its own DEFAULT_ADMIN_ROLE once setup is complete.
        _grantRole(DEFAULT_ADMIN_ROLE, minter);
        _grantRole(MINTER_ROLE, minter);
    }

    // ─── Minter actions ────────────────────────────────────────────────────────

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    // ─── Non-transferable hook ─────────────────────────────────────────────────
    //
    // _update() is called on every mint, burn, and transfer.
    // Mint (from == 0) and burn (to == 0) are allowed.
    // Any wallet-to-wallet transfer is permanently rejected.

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) revert TransfersDisabled();
        super._update(from, to, amount);
    }
}
