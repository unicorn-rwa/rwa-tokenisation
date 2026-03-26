// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KYCRegistry} from "../src/KYCRegistry.sol";
import {ROIDistributor} from "../src/ROIDistributor.sol";
import {PropertyFundingFactory} from "../src/PropertyFundingFactory.sol";

/**
 * @notice Deploys the full RWA platform to Base Sepolia (or any EVM chain).
 *
 * Required env vars:
 *   DEPLOYER_KEY       — private key of the deployer (funds gas)
 *   ADMIN_ADDRESS      — Gnosis Safe address (receives all admin roles)
 *   ATTESTER_ADDRESS   — NestJS hot wallet (ATTESTER_ROLE on KYCRegistry)
 *   USDC_ADDRESS       — USDC token on target chain
 *                        Base Sepolia: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
 *                        Base mainnet: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 *
 * Run:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url base_sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerKey    = vm.envUint("DEPLOYER_KEY");
        address admin          = vm.envAddress("ADMIN_ADDRESS");
        address attester       = vm.envAddress("ATTESTER_ADDRESS");
        address usdc           = vm.envAddress("USDC_ADDRESS");

        address deployer = vm.addr(deployerKey);
        console2.log("Deployer :", deployer);
        console2.log("Admin    :", admin);
        console2.log("Attester :", attester);
        console2.log("USDC     :", usdc);

        vm.startBroadcast(deployerKey);

        // ── 1. KYCRegistry ────────────────────────────────────────────────────
        KYCRegistry registry = new KYCRegistry(admin, attester);
        console2.log("KYCRegistry      :", address(registry));

        // ── 2. ROIDistributor ─────────────────────────────────────────────────
        ROIDistributor distributor = new ROIDistributor(admin, usdc);
        console2.log("ROIDistributor   :", address(distributor));

        // ── 3. PropertyFundingFactory ─────────────────────────────────────────
        PropertyFundingFactory factory = new PropertyFundingFactory(
            admin,
            usdc,
            address(registry),
            address(distributor)
        );
        console2.log("Factory          :", address(factory));

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────
        console2.log("\n=== Deployment complete ===");
        console2.log("Next steps:");
        console2.log("  1. Transfer DEFAULT_ADMIN_ROLE to Gnosis Safe if deployer != admin");
        console2.log("  2. Set ATTESTER_ADDRESS in NestJS .env");
        console2.log("  3. Call factory.createProject() to launch first property");
        console2.log("  4. Register EAS schema on Base (see docs.attest.org)");
    }
}
