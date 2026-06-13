// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PropertyFundingFactory} from "../src/PropertyFundingFactory.sol";

/**
 * @notice Deploys a new property project by calling factory.createProject().
 *         Must be signed by the wallet holding ADMIN_ROLE on the factory
 *         (the platform Gnosis Safe on testnet/mainnet; ANVIL_ADMIN on local).
 *
 * -- Local (Anvil fork, factory already deployed via Deploy.s.sol) -----------
 *
 *   DEPLOY_ENV=local \
 *   FACTORY_ADDRESS=0x<from-deploy-output> \
 *   forge script script/PropertyDeploy.s.sol \
 *     --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
 *     --rpc-url http://localhost:8545 --broadcast -vvvv
 *
 *   (key above is Anvil account[1] = ANVIL_ADMIN, which holds ADMIN_ROLE on the factory)
 *   Alternatively import it once: cast wallet import test_admin \
 *     --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
 *   Then use --account test_admin instead.
 *
 *   All property parameters have sensible local defaults but can be overridden
 *   via the same env vars shown for testnet below.
 *
 * -- Testnet (Base Sepolia) --------------------------------------------------
 *
 *   DEPLOY_ENV=testnet \
 *   FACTORY_ADDRESS=0x<from-deploy-output> \
 *   SPV_ADMIN_ADDRESS=0x<gnosis-safe-admin> \
 *   SPV_TREASURY_ADDRESS=0x<gnosis-safe-treasury> \
 *   TOKEN_NAME="PropToken LA-2024-01" \
 *   TOKEN_SYMBOL="PROP-LA-01" \
 *   FUNDING_GOAL=200000000000 \
 *   DEADLINE=<unix-ts> \
 *   EXPECTED_ROI_BPS=1500 \
 *   EST_START_DATE=<unix-ts> \
 *   EST_END_DATE=<unix-ts> \
 *   MIN_INVESTMENT=2000000000 \
 *   MAX_ACCREDITED_INVESTMENT=25000000000 \
 *   MAX_NON_ACCREDITED_US_INVESTMENT=2500000000 \
 *   OFFERING_DOC_HASH=<ipfs-cid> \
 *   BASESCAN_API_KEY=<key> \
 *   forge script script/PropertyDeploy.s.sol \
 *     --account safe_signer --rpc-url base_sepolia --broadcast \
 *     --verify --etherscan-api-key $BASESCAN_API_KEY \
 *     --verifier-url https://api-sepolia.basescan.org/api -vvvv
 *
 * -- Mainnet (Base) ----------------------------------------------------------
 *
 *   (same vars, DEPLOY_ENV=mainnet, --rpc-url base_mainnet,
 *    --verifier-url https://api.basescan.org/api, --account deployer)
 *
 * Note: --verify on this script should auto-verify PropertyFunding, PropertyToken,
 *       and ROIDistributor because forge tracks all CREATE events in the broadcast.
 *       If it misses any (rate limit, delegatecall path), the script prints the exact
 *       fallback `forge verify-contract` commands with pre-computed constructor args.
 *
 * USDC amounts use 6 decimals: 1 USDC = 1_000_000.
 *   $2,000   =      2_000_000_000 =   2000000000
 *   $25,000  =     25_000_000_000 =  25000000000
 *   $100,000 =    100_000_000_000 = 100000000000
 *   $200,000 =    200_000_000_000 = 200000000000
 */
contract PropertyDeploy is Script {

    // Anvil account[1] — holds ADMIN_ROLE on the factory for local deploys.
    // PUBLIC test key — local development only, never on mainnet.
    address constant ANVIL_ADMIN    = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    // Distinct from ANVIL_ADMIN — required since spvAdmin != spvTreasury.
    // Matches SPV_ADDRESS in fund-wallets.sh (already funded with ETH + USDC).
    address constant ANVIL_TREASURY = 0x903a5AF6fC2B7f5cf1262962d59b4E2FBb48a5e8;

    function run() external {
        string memory env = vm.envOr("DEPLOY_ENV", string("local"));
        bool isLocal   = keccak256(bytes(env)) == keccak256(bytes("local"));
        bool isMainnet = keccak256(bytes(env)) == keccak256(bytes("mainnet"));

        // Factory address is always required — set it from Deploy.s.sol output.
        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        PropertyFundingFactory factory = PropertyFundingFactory(factoryAddr);

        // Read usdc + kycRegistry from the factory — needed for verification args.
        address usdcAddr        = factory.usdc();
        address kycRegistryAddr = factory.kycRegistry();

        // -- Property parameters per environment ------------------------------
        address spvAdmin;
        address spvTreasury;
        string memory tokenName;
        string memory tokenSymbol;
        uint256 fundingGoal;
        uint256 deadline;
        uint256 expectedROIBps;
        uint256 estimatedStartDate;
        uint256 estimatedEndDate;
        uint256 minInvestment;
        uint256 maxAccreditedInvestment;
        uint256 maxNonAccreditedUSInvestment;
        string memory offeringDocHash;

        if (isLocal) {
            spvAdmin    = vm.envOr("SPV_ADMIN_ADDRESS",    ANVIL_ADMIN);
            spvTreasury = vm.envOr("SPV_TREASURY_ADDRESS", ANVIL_TREASURY);
            tokenName   = vm.envOr("TOKEN_NAME",    string("Chicago Skyscraper Tower"));
            tokenSymbol = vm.envOr("TOKEN_SYMBOL",  string("PROP-TOKEN-01"));

            fundingGoal                  = vm.envOr("FUNDING_GOAL",                         uint256(100_000e6));
            deadline                     = vm.envOr("DEADLINE",                              block.timestamp + 30 days);
            expectedROIBps               = vm.envOr("EXPECTED_ROI_BPS",                     uint256(1500));
            estimatedStartDate           = vm.envOr("EST_START_DATE",                       block.timestamp + 30 days);
            estimatedEndDate             = vm.envOr("EST_END_DATE",                         block.timestamp + 365 days);
            minInvestment                = vm.envOr("MIN_INVESTMENT",                       uint256(2_000e6));
            maxAccreditedInvestment      = vm.envOr("MAX_ACCREDITED_INVESTMENT",            uint256(25_000e6));
            maxNonAccreditedUSInvestment = vm.envOr("MAX_NON_ACCREDITED_US_INVESTMENT",     uint256(2_500e6));
            offeringDocHash              = vm.envOr("OFFERING_DOC_HASH",                    string("QmLocalTestDocumentHash"));
        } else {
            // testnet + mainnet: all required — no defaults for production properties
            spvAdmin    = vm.envAddress("SPV_ADMIN_ADDRESS");
            spvTreasury = vm.envAddress("SPV_TREASURY_ADDRESS");
            tokenName   = vm.envString("TOKEN_NAME");
            tokenSymbol = vm.envString("TOKEN_SYMBOL");

            fundingGoal                  = vm.envUint("FUNDING_GOAL");
            deadline                     = vm.envUint("DEADLINE");
            expectedROIBps               = vm.envUint("EXPECTED_ROI_BPS");
            estimatedStartDate           = vm.envUint("EST_START_DATE");
            estimatedEndDate             = vm.envUint("EST_END_DATE");
            minInvestment                = vm.envUint("MIN_INVESTMENT");
            maxAccreditedInvestment      = vm.envUint("MAX_ACCREDITED_INVESTMENT");
            maxNonAccreditedUSInvestment = vm.envUint("MAX_NON_ACCREDITED_US_INVESTMENT");
            offeringDocHash              = vm.envString("OFFERING_DOC_HASH");
        }

        console2.log("=== Property Deploy ===");
        console2.log("Environment  :", env);
        console2.log("Factory      :", factoryAddr);
        console2.log("Caller       :", msg.sender);
        console2.log("USDC         :", usdcAddr);
        console2.log("KYCRegistry  :", kycRegistryAddr);
        console2.log("spvAdmin     :", spvAdmin);
        console2.log("spvTreasury  :", spvTreasury);
        console2.log("Token name   :", tokenName);
        console2.log("Token symbol :", tokenSymbol);
        console2.log("Funding goal :", fundingGoal);
        console2.log("Deadline     :", deadline);
        console2.log("ROI bps      :", expectedROIBps);
        console2.log("Min invest   :", minInvestment);
        console2.log("Max accred.  :", maxAccreditedInvestment);
        console2.log("Max non-acc. :", maxNonAccreditedUSInvestment);
        console2.log("Offering doc :", offeringDocHash);
        console2.log("");

        vm.startBroadcast();

        (address funding, address token, address roi) = factory.createProject(
            tokenName,
            tokenSymbol,
            spvAdmin,
            spvTreasury,
            fundingGoal,
            deadline,
            expectedROIBps,
            estimatedStartDate,
            estimatedEndDate,
            minInvestment,
            maxAccreditedInvestment,
            maxNonAccreditedUSInvestment,
            offeringDocHash
        );

        vm.stopBroadcast();

        console2.log("=== Property deployed ===");
        console2.log("");
        console2.log("  PropertyFunding  :", funding);
        console2.log("  PropertyToken    :", token);
        console2.log("  ROIDistributor   :", roi);
        console2.log("");

        if (isLocal) {
            console2.log("Local setup done. Update KYC_REGISTRY_ADDRESS in the backend .env if needed.");
        } else {
            // -- Verification fallback ----------------------------------------
            // forge script --verify should auto-verify all three contracts via
            // CREATE event tracking. If any fail (rate limit, delegatecall path),
            // run these manually.
            string memory chainId     = isMainnet ? "8453"   : "84532";
            string memory verifierUrl = isMainnet
                ? "https://api.basescan.org/api"
                : "https://api-sepolia.basescan.org/api";

            // Pre-compute ABI-encoded constructor args for each deployed contract.
            // PropertyToken(name, symbol, admin=spvAdmin, minter=factory_at_deploy_time)
            bytes memory tokenArgs = abi.encode(tokenName, tokenSymbol, spvAdmin, factoryAddr);

            // PropertyFunding(...all params...)
            bytes memory fundingArgs = abi.encode(
                usdcAddr,
                token,
                kycRegistryAddr,
                spvTreasury,   // withdrawalRecipient
                spvAdmin,      // admin
                fundingGoal,
                deadline,
                expectedROIBps,
                estimatedStartDate,
                estimatedEndDate,
                minInvestment,
                maxAccreditedInvestment,
                maxNonAccreditedUSInvestment,
                offeringDocHash
            );

            // ROIDistributor(admin=spvTreasury, usdc, project=funding)
            bytes memory roiArgs = abi.encode(spvTreasury, usdcAddr, funding);

            console2.log("=== Verification (auto via --verify flag) ===");
            console2.log("If auto-verify failed for any contract, run these manually:");
            console2.log("");

            console2.log("# PropertyToken");
            console2.log("forge verify-contract \\");
            console2.log("  --chain-id", chainId, "\\");
            console2.log("  --verifier-url", verifierUrl, "\\");
            console2.log("  --etherscan-api-key $BASESCAN_API_KEY \\");
            console2.log("  --constructor-args", vm.toString(tokenArgs), "\\");
            console2.log("  ", token, "src/PropertyToken.sol:PropertyToken");
            console2.log("");

            console2.log("# PropertyFunding");
            console2.log("forge verify-contract \\");
            console2.log("  --chain-id", chainId, "\\");
            console2.log("  --verifier-url", verifierUrl, "\\");
            console2.log("  --etherscan-api-key $BASESCAN_API_KEY \\");
            console2.log("  --constructor-args", vm.toString(fundingArgs), "\\");
            console2.log("  ", funding, "src/PropertyFunding.sol:PropertyFunding");
            console2.log("");

            console2.log("# ROIDistributor");
            console2.log("forge verify-contract \\");
            console2.log("  --chain-id", chainId, "\\");
            console2.log("  --verifier-url", verifierUrl, "\\");
            console2.log("  --etherscan-api-key $BASESCAN_API_KEY \\");
            console2.log("  --constructor-args", vm.toString(roiArgs), "\\");
            console2.log("  ", roi, "src/ROIDistributor.sol:ROIDistributor");
            console2.log("");

            console2.log("=== Next steps ===");
            console2.log("  1. Set KYC_REGISTRY_ADDRESS in backend .env (if not already done)");
            console2.log("  2. spvAdmin Safe: call funding.setActive() once fiat conversion is complete");
            console2.log("  3. spvTreasury Safe: call roi.depositReturns() when property completes");
        }
    }
}
