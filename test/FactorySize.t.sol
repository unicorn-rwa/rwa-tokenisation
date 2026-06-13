// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PropertyFundingFactory} from "../src/PropertyFundingFactory.sol";

/**
 * @notice Regression guard for the EIP-170 contract size limit.
 *         PropertyFundingFactory previously exceeded 24,576 bytes because it
 *         embedded PropertyFunding's creation bytecode. PropertyFunding is now
 *         deployed via the PropertyFundingDeployer external library. This test
 *         fails if a future change pushes the factory back over the limit.
 *
 *         We deploy the factory (forge auto-deploys + links the library) and
 *         measure the real on-chain runtime size — this also proves linking works.
 */
contract FactorySizeTest is Test {
    /// @dev EIP-170 maximum runtime code size.
    uint256 internal constant EIP170_LIMIT = 24_576;

    function test_FactoryUnderEip170() public {
        // Dummy non-zero addresses satisfy the constructor's zero-address checks.
        PropertyFundingFactory factory = new PropertyFundingFactory(
            address(0xA11CE), // admin
            address(0x021C),  // usdc
            address(0x4EC)    // kycRegistry
        );

        uint256 size = address(factory).code.length;
        assertLt(size, EIP170_LIMIT, "PropertyFundingFactory exceeds EIP-170 limit");
        emit log_named_uint("PropertyFundingFactory runtime size", size);
    }
}
