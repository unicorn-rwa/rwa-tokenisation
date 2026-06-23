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
 *        admin       -- platform Gnosis Safe / factory owner
 *        attester    -- NestJS hot wallet that issues KYC attestations
 *        multisig    -- per-property OPERATIONAL Safe (spvAdmin):
 *                       ADMIN_ROLE + PAUSER_ROLE on PropertyFunding,
 *                       DEFAULT_ADMIN_ROLE on PropertyToken
 *                       drives state machine: withdrawFunds, setActive, setCompleted, pause
 *        spvTreasury -- per-property FINANCIAL Safe:
 *                       withdrawal recipient in PropertyFunding (receives raised USDC),
 *                       ADMIN_ROLE on ROIDistributor (calls depositReturns)
 *        alice       -- US accredited investor (Reg D)
 *        bob         -- Ukrainian investor (Reg S)
 *        charlie     -- non-KYC'd user (all invest calls must revert for charlie)
 *        dave        -- US non-accredited investor (Reg D 506b)
 */
abstract contract BaseTest is Test {
    // ─── Actors ────────────────────────────────────────────────────────────────
    address internal admin       = makeAddr("admin");
    address internal attester    = makeAddr("attester");
    address internal multisig    = makeAddr("multisig");    // spvAdmin: operational Safe
    address internal spvTreasury = makeAddr("spvTreasury"); // spvTreasury: financial Safe
    address internal alice    = makeAddr("alice");   // US accredited     (Reg D 506c, cap $25k)
    address internal bob      = makeAddr("bob");     // UA Reg S           (no cap)
    address internal charlie  = makeAddr("charlie"); // no KYC
    address internal dave     = makeAddr("dave");    // US non-accredited  (Reg D 506b, cap $2.5k)

    // ─── Contracts ─────────────────────────────────────────────────────────────
    MockUSDC               internal usdc;
    KYCRegistry            internal registry;
    ROIDistributor         internal distributor; // populated per-project in each test's setUp
    PropertyFundingFactory internal factory;

    // Default project params -- override in individual tests as needed
    uint256 internal constant FUNDING_GOAL                = 200_000e6; // $200k USDC
    uint256 internal constant MIN_INVESTMENT              =   2_000e6; // $2k USDC
    uint256 internal constant MAX_ACCREDITED_INVESTMENT   =  25_000e6; // $25k -- Reg D 506(c) cap
    uint256 internal constant MAX_NON_ACCREDITED_INVESTMENT =  2_500e6; // $2.5k -- Reg D 506(b) cap
    uint256 internal constant ROI_BPS                     = 1_500;     // 15%
    uint256 internal constant DEADLINE_OFFSET             = 30 days;

    // ─── setUp ─────────────────────────────────────────────────────────────────
    function setUp() public virtual {
        // Deploy platform infrastructure
        vm.startPrank(admin);
        usdc     = new MockUSDC();
        registry = new KYCRegistry(admin, attester);
        factory  = new PropertyFundingFactory(
            admin,
            address(usdc),
            address(registry)
        );
        vm.stopPrank();

        // Issue KYC attestations via the attester wallet
        vm.startPrank(attester);

        // Alice -- US accredited investor (Reg D 506c, cap $25k/project)
        registry.issueAttestation(
            alice,
            true,  // accreditedInvestor
            false, // nonAccreditedUS
            false, // regSEligible
            "US",
            uint64(block.timestamp + 365 days),
            bytes32(0)
        );

        // Bob -- Ukrainian investor (Reg S, no cap)
        registry.issueAttestation(
            bob,
            false, // accreditedInvestor
            false, // nonAccreditedUS
            true,  // regSEligible
            "UA",
            uint64(block.timestamp + 365 days),
            bytes32(0)
        );

        // Dave -- US non-accredited investor (Reg D 506b, cap $2.5k/project)
        registry.issueAttestation(
            dave,
            false, // accreditedInvestor
            true,  // nonAccreditedUS
            false, // regSEligible
            "US",
            uint64(block.timestamp + 365 days),
            bytes32(0)
        );

        // Charlie gets no attestation -- all invest calls should revert
        vm.stopPrank();

        // US is restricted by default in KYCRegistry constructor (V1: non-US only).
        // Allow it here so general tests using alice/dave can exercise invest() paths.
        // Dedicated country-restriction tests call restrictCountry("US") themselves.
        vm.prank(admin);
        registry.allowCountry("US");
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Deploy a default project via the factory.
    ///      Returns (funding, token, roi).
    ///      multisig    = spvAdmin    (state machine, pause, metadata)
    ///      spvTreasury = spvTreasury (withdrawal recipient, depositReturns)
    function _createProject()
        internal
        returns (PropertyFunding funding, PropertyToken token, ROIDistributor roi)
    {
        vm.prank(admin);
        (address f, address t, address r) = factory.createProject(
            "PropToken LA-2024-01",
            "PROP-LA-01",
            multisig,     // spvAdmin    -- operational Safe
            spvTreasury,  // spvTreasury -- financial Safe
            FUNDING_GOAL,
            block.timestamp + DEADLINE_OFFSET,
            ROI_BPS,
            block.timestamp + 60 days,
            block.timestamp + 540 days,
            MIN_INVESTMENT,
            MAX_ACCREDITED_INVESTMENT,
            MAX_NON_ACCREDITED_INVESTMENT,
            "ipfs://QmTestHash"
        );
        funding = PropertyFunding(f);
        token   = PropertyToken(t);
        roi     = ROIDistributor(r);
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

    /// @dev Build a 2-claimant array sorted ascending by wallet — the ordering
    ///      commitDistribution() now requires. For a 2-leaf sorted-pair tree the Merkle
    ///      root and proofs are order-independent, so callers may pass either order.
    function _claimants2(address w1, uint256 a1, address w2, uint256 a2)
        internal
        pure
        returns (ROIDistributor.Claimant[] memory c)
    {
        c = new ROIDistributor.Claimant[](2);
        if (w1 < w2) {
            c[0] = ROIDistributor.Claimant({wallet: w1, amount: a1});
            c[1] = ROIDistributor.Claimant({wallet: w2, amount: a2});
        } else {
            c[0] = ROIDistributor.Claimant({wallet: w2, amount: a2});
            c[1] = ROIDistributor.Claimant({wallet: w1, amount: a1});
        }
    }
}
