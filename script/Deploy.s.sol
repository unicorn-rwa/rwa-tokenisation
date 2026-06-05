// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KYCRegistry} from "../src/KYCRegistry.sol";
import {PropertyFundingFactory} from "../src/PropertyFundingFactory.sol";

/**
 * @notice Deploys the RWA platform infrastructure.
 *         ROIDistributor is no longer deployed globally -- the factory creates one
 *         per property, each controlled by its own SPV multisig.
 *
 * Switch environments via DEPLOY_ENV -- no code changes needed:
 *
 *   local   -- Anvil fork; uses well-known test addresses
 *   testnet -- Base Sepolia; requires ADMIN_ADDRESS + ATTESTER_ADDRESS env vars
 *   mainnet -- Base mainnet; requires ADMIN_ADDRESS + ATTESTER_ADDRESS env vars
 *
 * -- Local (Anvil fork running on localhost:8545) ----------------------------
 *   DEPLOY_ENV=local \
 *   forge script script/Deploy.s.sol \
 *     --account deployer --rpc-url http://localhost:8545 --broadcast -vvvv
 *
 * -- Testnet ----------------------------------------------------------------
 *   DEPLOY_ENV=testnet \
 *   ADMIN_ADDRESS=0x<gnosis-safe> \
 *   ATTESTER_ADDRESS=0x<nestjs-hot-wallet> \
 *   forge script script/Deploy.s.sol \
 *     --account deployer --rpc-url base_sepolia --broadcast --verify -vvvv
 *
 * -- Mainnet ----------------------------------------------------------------
 *   DEPLOY_ENV=mainnet \
 *   ADMIN_ADDRESS=0x<gnosis-safe> \
 *   ATTESTER_ADDRESS=0x<nestjs-hot-wallet> \
 *   forge script script/Deploy.s.sol \
 *     --account deployer --rpc-url base_mainnet --broadcast --verify -vvvv
 *
 * Note: deployer wallet is resolved from --account flag (encrypted keystore).
 *       Private keys are never stored in env vars or code.
 *
 * After deploy, each new property is launched by the platform Safe calling:
 *   factory.createProject(..., spvAdmin, spvTreasury, ...)
 * where:
 *   spvAdmin    = per-property operational Gnosis Safe (state transitions, pause, metadata)
 *   spvTreasury = per-property financial Gnosis Safe (receives USDC, deposits ROI returns)
 */
contract Deploy is Script {

    // -- Well-known Anvil test addresses (mnemonic: "test test ... junk") ----
    // These are PUBLIC -- local development only.
    address constant ANVIL_DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // [0]
    address constant ANVIL_ADMIN    = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // [1]
    address constant ANVIL_ATTESTER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // [2]

    address constant USDC_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant USDC_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        // -- Environment detection -----------------------------------------
        string memory env = vm.envOr("DEPLOY_ENV", string("local"));
        bool isLocal   = keccak256(bytes(env)) == keccak256(bytes("local"));
        bool isMainnet = keccak256(bytes(env)) == keccak256(bytes("mainnet"));

        // -- Resolve addresses per environment ------------------------------
        address usdc;
        address admin;
        address attester;

        if (isLocal) {
            usdc     = USDC_SEPOLIA;
            admin    = ANVIL_ADMIN;
            attester = ANVIL_ATTESTER;
        } else if (isMainnet) {
            usdc     = USDC_MAINNET;
            admin    = vm.envAddress("ADMIN_ADDRESS");
            attester = vm.envAddress("ATTESTER_ADDRESS");
        } else {
            // testnet (default for non-local, non-mainnet)
            usdc     = USDC_SEPOLIA;
            admin    = vm.envAddress("ADMIN_ADDRESS");
            attester = vm.envAddress("ATTESTER_ADDRESS");
        }

        console2.log("=== RWA Platform Deploy ===");
        console2.log("Environment :", env);
        console2.log("Deployer    :", msg.sender);
        console2.log("Admin       :", admin);
        console2.log("Attester    :", attester);
        console2.log("USDC        :", usdc);
        console2.log("");

        // -- Deploy contracts (signed by deployer via --account flag) -------
        vm.startBroadcast();

        KYCRegistry registry = new KYCRegistry(admin, attester);
        console2.log("KYCRegistry :", address(registry));

        PropertyFundingFactory factory = new PropertyFundingFactory(
            admin,
            usdc,
            address(registry)
        );
        console2.log("Factory     :", address(factory));

        vm.stopBroadcast();

        // -- Save addresses to JSON ----------------------------------------
        string memory obj = "deploy";
        vm.serializeAddress(obj, "usdc",        usdc);
        vm.serializeAddress(obj, "admin",       admin);
        vm.serializeAddress(obj, "attester",    attester);
        vm.serializeAddress(obj, "kycRegistry", address(registry));
        string memory json = vm.serializeAddress(obj, "factory", address(factory));

        string memory outFile = string.concat("state/addresses-", env, ".json");
        vm.writeJson(json, outFile);

        // -- Summary -------------------------------------------------------
        console2.log("");
        console2.log("=== Deployment complete ===");
        console2.log("");
        console2.log("  KYCRegistry :", address(registry));
        console2.log("  Factory     :", address(factory));
        console2.log("");
        console2.log("Addresses saved to:", outFile);
        console2.log("");
        console2.log("Load in shell:");
        console2.log("  source <(jq -r 'to_entries[]|\"export \\(.key|ascii_upcase)=\\(.value)\"'", outFile, ")");
        console2.log("");

        if (isLocal) {
            console2.log("Local setup done.");
            console2.log("Next: ./script/fund-wallets.sh");
        } else {
            console2.log("Next steps:");
            console2.log("  1. Safe: call registry.allowCountry() for each allowed country");
            console2.log("  2. Set attester address in NestJS .env as OPERATOR_PRIVATE_KEY");
            console2.log("  3. For each property: deploy two SPV Gnosis Safes (admin + treasury), then call factory.createProject(..., spvAdmin, spvTreasury, ...)");
        }
    }
}
