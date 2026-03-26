// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PropertyFunding} from "../../src/PropertyFunding.sol";

/**
 * @dev Malicious ERC-20 that attempts a reentrancy attack during transfer().
 *      Simulates an attacker who tricks the contract into using a "poisoned" token
 *      that calls back into the funding contract mid-execution.
 *
 *      Attack vector: when PropertyFunding calls usdc.safeTransfer(attacker, amount)
 *      inside claimRefund(), this token's transfer() tries to immediately call
 *      claimRefund() again before the first call completes.
 *
 *      The attack is blocked by TWO independent defenses in PropertyFunding:
 *        1. nonReentrant modifier  — catches the reentrant call at the lock level
 *        2. CEI pattern            — investments[attacker] = 0 *before* transfer,
 *                                    so even without nonReentrant the second call
 *                                    would fail with NothingToRefund
 */
contract MaliciousUSDC is ERC20 {
    PropertyFunding public target;

    // Guard prevents infinite recursion inside this mock itself
    bool private _reentering;

    // Audit trail — lets tests inspect what happened
    bool public reentrancyAttempted;
    bool public reentrancyReverted; // true = nonReentrant blocked it (expected)

    constructor() ERC20("Malicious USD Coin", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTarget(address _target) external {
        target = PropertyFunding(_target);
    }

    /**
     * @dev During every transfer, attempt to reenter the target contract.
     *      Uses try/catch so the outer transfer succeeds — this lets the test
     *      verify the *reentrant* call was blocked, not the original one.
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!_reentering && address(target) != address(0)) {
            _reentering = true;
            reentrancyAttempted = true;

            try target.claimRefund() {
                // If this branch is hit, the contract is vulnerable — test must fail
                reentrancyReverted = false;
            } catch {
                // Expected: nonReentrant (or CEI) blocked the second call
                reentrancyReverted = true;
            }

            _reentering = false;
        }
        return super.transfer(to, amount);
    }
}
