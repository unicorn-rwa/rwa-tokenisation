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
 *     --account test_deployer --rpc-url http://localhost:8545 --broadcast -vvvv
 *
 * -- Testnet ----------------------------------------------------------------
 *   DEPLOY_ENV=testnet \
 *   ADMIN_ADDRESS=0x<gnosis-safe> \
 *   ATTESTER_ADDRESS=0x<nestjs-hot-wallet> \
 *   BASESCAN_API_KEY=<key> \
 *   forge script script/Deploy.s.sol \
 *     --account test_deployer --rpc-url base_sepolia --broadcast \
 *     --verify --etherscan-api-key $BASESCAN_API_KEY \
 *     --verifier-url https://api-sepolia.basescan.org/api -vvvv
 *
 * -- Mainnet ----------------------------------------------------------------
 *   DEPLOY_ENV=mainnet \
 *   ADMIN_ADDRESS=0x<gnosis-safe> \
 *   ATTESTER_ADDRESS=0x<nestjs-hot-wallet> \
 *   BASESCAN_API_KEY=<key> \
 *   forge script script/Deploy.s.sol \
 *     --account deployer --rpc-url base_mainnet --broadcast \
 *     --verify --etherscan-api-key $BASESCAN_API_KEY \
 *     --verifier-url https://api.basescan.org/api -vvvv
 *
 * Note: deployer wallet is resolved from --account flag (encrypted keystore).
 *       Private keys are never stored in env vars or code.
 *       If --verify fails (rate limit / network), the script prints the exact
 *       fallback `forge verify-contract` commands with pre-computed constructor args.
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
        console2.log("ContractDeployer    :", msg.sender);
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

        // PropertyFundingFactory deploys PropertyFunding via the external library
        // PropertyFundingDeployer (extracted to stay under the EIP-170 size limit).
        // The linked library address isn't readable from Solidity, so for a
        // production deploy you deploy the library explicitly (forge create,
        // plain CREATE), pin it in foundry.toml, and pass it here via
        // PROPERTY_FUNDING_DEPLOYER_LIB so it lands in the deployment record.
        // For local auto-deploy, the address is shown in forge's trace
        // (the "Create2Deployer" line). See reviews/production.md.
        address fundingDeployerLib = vm.envOr("PROPERTY_FUNDING_DEPLOYER_LIB", address(0));
        if (fundingDeployerLib != address(0)) {
            console2.log("Library     :", fundingDeployerLib);
        } else {
            console2.log("Library     : auto-deployed by forge (see Create2Deployer trace; pin for prod)");
        }

        // -- Summary -------------------------------------------------------
        console2.log("");
        console2.log("=== Deployment complete ===");
        console2.log("");
        console2.log("  KYCRegistry :", address(registry));
        console2.log("  Factory     :", address(factory));
        if (fundingDeployerLib != address(0)) {
            console2.log("  Library     :", fundingDeployerLib);
        }

        if (isLocal) {
            console2.log("");
            console2.log("Local setup done.");
            console2.log("Next: ./script/fund-wallets.sh");
        } else {
            // -- Verification fallback commands --------------------------------
            // These are printed so you can re-run verification manually if
            // --verify times out or hits a rate limit during broadcast.
            string memory chainId      = isMainnet ? "8453"   : "84532";
            string memory verifierUrl  = isMainnet
                ? "https://api.basescan.org/api"
                : "https://api-sepolia.basescan.org/api";

            // Pre-compute ABI-encoded constructor args for each contract.
            // Pass these verbatim to --constructor-args when verifying manually.
            bytes memory registryArgs = abi.encode(admin, attester);
            bytes memory factoryArgs  = abi.encode(admin, usdc, address(registry));

            console2.log("");
            console2.log("=== Verification (auto via --verify flag) ===");
            console2.log("If auto-verify failed, run these manually:");
            console2.log("");

            console2.log("# KYCRegistry");
            console2.log("forge verify-contract \\");
            console2.log("  --chain-id", chainId, "\\");
            console2.log("  --verifier-url", verifierUrl, "\\");
            console2.log("  --etherscan-api-key $BASESCAN_API_KEY \\");
            console2.log("  --constructor-args", vm.toString(registryArgs), "\\");
            console2.log("  ", address(registry), "src/KYCRegistry.sol:KYCRegistry");
            console2.log("");

            console2.log("# PropertyFundingFactory");
            console2.log("forge verify-contract \\");
            console2.log("  --chain-id", chainId, "\\");
            console2.log("  --verifier-url", verifierUrl, "\\");
            console2.log("  --etherscan-api-key $BASESCAN_API_KEY \\");
            console2.log("  --constructor-args", vm.toString(factoryArgs), "\\");
            console2.log("  ", address(factory), "src/PropertyFundingFactory.sol:PropertyFundingFactory");

            if (fundingDeployerLib != address(0)) {
                console2.log("");
                console2.log("# PropertyFundingDeployer library (no constructor args)");
                console2.log("forge verify-contract \\");
                console2.log("  --chain-id", chainId, "\\");
                console2.log("  --verifier-url", verifierUrl, "\\");
                console2.log("  --etherscan-api-key $BASESCAN_API_KEY \\");
                console2.log("  ", fundingDeployerLib, "src/PropertyFundingDeployer.sol:PropertyFundingDeployer");
            }

            console2.log("");
            console2.log("=== Next steps ===");
            console2.log("  1. Safe: call registry.allowCountry() for each allowed country");
            console2.log("  2. Set attester address in NestJS .env as OPERATOR_PRIVATE_KEY");
            console2.log("  3. For each property: deploy two SPV Gnosis Safes (admin + treasury),");
            console2.log("     then call factory.createProject(..., spvAdmin, spvTreasury, ...)");
        }
    }
}
