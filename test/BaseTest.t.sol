// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {KYCRegistry} from "../src/KYCRegistry.sol";
import {PropertyToken} from "../src/PropertyToken.sol";
import {PropertyFunding} from "../src/PropertyFunding.sol";
import {PropertyFundingFactory} from "../src/PropertyFundingFactory.sol";
import {ROIDistributor} from "../src/ROIDistributor.sol";

/**
 * @dev Shared test scaffold.
 *      All test contracts inherit from this to avoid boilerplate.
 *
 *      Actors:
 *        admin    — Gnosis Safe / platform owner
 *        attester — NestJS hot wallet that issues KYC attestations
 *        multisig — withdrawal recipient (simulates Gnosis Safe holding raised funds)
 *        alice    — US accredited investor (Reg D)
 *        bob      — Ukrainian investor (Reg S)
 *        charlie  — non-KYC'd user (all invest calls must revert for charlie)
 */
abstract contract BaseTest is Test {
    // ─── Actors ────────────────────────────────────────────────────────────────
    address internal admin    = makeAddr("admin");
    address internal attester = makeAddr("attester");
    address internal multisig = makeAddr("multisig");
    address internal alice    = makeAddr("alice");   // US accredited
    address internal bob      = makeAddr("bob");     // UA Reg S
    address internal charlie  = makeAddr("charlie"); // no KYC

    // ─── Contracts ─────────────────────────────────────────────────────────────
    MockUSDC              internal usdc;
    KYCRegistry           internal registry;
    ROIDistributor        internal distributor;
    PropertyFundingFactory internal factory;

    // Default project params — override in individual tests as needed
    uint256 internal constant FUNDING_GOAL   = 200_000e6; // $200k USDC
    uint256 internal constant MIN_INVESTMENT =   2_000e6; // $2k USDC
    uint256 internal constant ROI_BPS        = 1_500;     // 15%
    uint256 internal constant DEADLINE_OFFSET = 30 days;

    // ─── setUp ─────────────────────────────────────────────────────────────────
    function setUp() public virtual {
        // Deploy infrastructure
        vm.startPrank(admin);
        usdc        = new MockUSDC();
        registry    = new KYCRegistry(admin, attester);
        distributor = new ROIDistributor(admin, address(usdc));
        factory     = new PropertyFundingFactory(
            admin,
            address(usdc),
            address(registry),
            address(distributor)
        );
        vm.stopPrank();

        // Issue KYC attestations via the attester wallet
        vm.startPrank(attester);

        // Alice — US accredited investor (Reg D 506c)
        registry.issueAttestation(
            alice,
            true,  // accreditedInvestor
            false, // regSEligible
            "US",
            uint64(block.timestamp + 365 days),
            bytes32(0)
        );

        // Bob — Ukrainian investor (Reg S)
        registry.issueAttestation(
            bob,
            false, // accreditedInvestor
            true,  // regSEligible
            "UA",
            uint64(block.timestamp + 365 days),
            bytes32(0)
        );
        // Charlie gets no attestation — all invest calls should revert

        vm.stopPrank();
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Deploy a default project via the factory. Returns (funding, token).
    function _createProject()
        internal
        returns (PropertyFunding funding, PropertyToken token)
    {
        vm.prank(admin);
        (address f, address t) = factory.createProject(
            "PropToken LA-2024-01",
            "PROP-LA-01",
            multisig,
            FUNDING_GOAL,
            block.timestamp + DEADLINE_OFFSET,
            ROI_BPS,
            block.timestamp + 60 days,
            block.timestamp + 540 days,
            MIN_INVESTMENT,
            "ipfs://QmTestHash"
        );
        funding = PropertyFunding(f);
        token   = PropertyToken(t);
    }

    /// @dev Give an investor USDC and pre-approve the funding contract.
    function _fundInvestor(address investor, address fundingContract, uint256 usdcAmount) internal {
        usdc.mint(investor, usdcAmount);
        vm.prank(investor);
        usdc.approve(fundingContract, usdcAmount);
    }

    /**
     * @dev Build a 2-leaf Merkle tree compatible with OZ MerkleProof.
     *      Leaf format: keccak256(abi.encodePacked(wallet, amount))
     *      OZ uses sorted (commutative) pair hashing.
     */
    function _buildMerkleTree(
        address investor1, uint256 amount1,
        address investor2, uint256 amount2
    )
        internal
        pure
        returns (
            bytes32 root,
            bytes32[] memory proof1,
            bytes32[] memory proof2
        )
    {
        bytes32 leaf1 = keccak256(abi.encodePacked(investor1, amount1));
        bytes32 leaf2 = keccak256(abi.encodePacked(investor2, amount2));

        // OZ MerkleProof.verify uses _hashPair which sorts leaves before hashing
        (bytes32 lo, bytes32 hi) = leaf1 < leaf2 ? (leaf1, leaf2) : (leaf2, leaf1);
        root = keccak256(abi.encodePacked(lo, hi));

        // Proof for leaf1 is [leaf2] (the sibling)
        proof1 = new bytes32[](1);
        proof1[0] = leaf2;

        // Proof for leaf2 is [leaf1]
        proof2 = new bytes32[](1);
        proof2[0] = leaf1;
    }
}
