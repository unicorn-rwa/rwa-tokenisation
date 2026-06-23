// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {ROIDistributor} from "../src/ROIDistributor.sol";
import {PropertyFunding} from "../src/PropertyFunding.sol";

/// @dev Emits the on-chain Merkle root for fixed claimant vectors (n = 1,2,3,5).
///      These roots are the golden values the offline operator tool (rwa-operator)
///      must reproduce byte-for-byte. Commit → read root → cancel → recommit on a
///      single completed distributor.
contract MerkleVectorTest is BaseTest {
    PropertyFunding internal funding;
    ROIDistributor  internal dist;

    function setUp() public override {
        super.setUp();
        (funding,, dist) = _createProject();
        _fundInvestor(alice, address(funding), 25_000e6);
        _fundInvestor(bob,   address(funding), 175_000e6);
        vm.prank(alice); funding.invest(25_000e6);
        vm.prank(bob);   funding.invest(175_000e6);
        vm.startPrank(multisig);
        funding.withdrawFunds();
        funding.setActive();
        funding.setCompleted(ROI_BPS);
        vm.stopPrank();
    }

    function _vec(uint256 n) internal pure returns (ROIDistributor.Claimant[] memory c) {
        c = new ROIDistributor.Claimant[](n);
        for (uint256 i = 0; i < n; i++) {
            c[i] = ROIDistributor.Claimant({
                wallet: address(uint160(i + 1)), // 0x..01, 0x..02, ... ascending
                amount: (i + 1) * 100            // 100, 200, 300, ...
            });
        }
    }

    /// @dev These MUST equal the GOLDEN roots embedded in rwa-operator/index.html and
    ///      rwa-operator/test/merkle-golden.mjs. If this assertion ever fails, the
    ///      on-chain tree changed and the offline operator tool must be updated in lockstep.
    function test_GoldenRootsMatchOperatorTool() public {
        uint256[4] memory sizes = [uint256(1), 2, 3, 5];
        bytes32[4] memory expected = [
            bytes32(0xeaf4f17819af3a9b14bda1f6c91bd1ccc63dc24933ec6966756a9a01d04c5170),
            bytes32(0xd0c386ab2cfa17ac05dfb1fa0991800a6d838917d7520fce68dd13cfc9ac0cb9),
            bytes32(0x1644881ff990f0ce81db8094076cc7d727b6553c057c7b6892d5a862378496e2),
            bytes32(0x04b2dd0fbef01b2515bcacd7650e1bb5de3fd944c9e6ba6d8d9f6f148734fc02)
        ];
        for (uint256 k = 0; k < sizes.length; k++) {
            ROIDistributor.Claimant[] memory c = _vec(sizes[k]);
            vm.prank(spvTreasury);
            dist.commitDistribution(c);
            (bytes32 root,,,) = dist.distribution();
            assertEq(root, expected[k], "on-chain root != operator-tool golden vector");
            vm.prank(spvTreasury);
            dist.cancelCommitment(); // reset so we can recommit the next vector
        }
    }
}
