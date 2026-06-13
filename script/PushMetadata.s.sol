// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PropertyFunding} from "../src/PropertyFunding.sol";

/**
 * @notice Append a new IPFS CID to a PropertyFunding contract's update log
 *         (construction photos, progress reports, etc.).
 *
 *         Calls PropertyFunding.pushMetadataUpdate(cid). The log is append-only —
 *         existing records can never be edited or removed, and the original
 *         offeringDocHash is always preserved separately. UIs read the timeline via
 *         getMetadataHistory(); latestMetadata() returns the newest CID (or the
 *         offeringDocHash if none have been pushed yet).
 *
 *         Must be signed by the wallet holding ADMIN_ROLE on that PropertyFunding —
 *         the per-property spvAdmin (operational Safe) on testnet/mainnet, or the
 *         spvAdmin EOA used locally.
 *
 * -- Local (Anvil fork) ------------------------------------------------------
 *
 *   FUNDING_ADDRESS=0x<propertyFunding> \
 *   CID="ipfs://bafy...progress-2026-06" \
 *   forge script script/PushMetadata.s.sol \
 *     --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
 *     --rpc-url http://localhost:8545 --broadcast -vvvv
 *
 *   (key above is Anvil account[1] = ANVIL_ADMIN, the default local spvAdmin.
 *    Use the key/keystore of whatever address you passed as SPV_ADMIN_ADDRESS
 *    when you ran PropertyDeploy.s.sol.)
 *
 * -- Testnet / Mainnet (spvAdmin is a Gnosis Safe) ---------------------------
 *
 *   A Safe cannot sign a raw forge transaction. Two options:
 *
 *   (a) Propose via the Safe UI (Transaction Builder):
 *         to:    <PropertyFunding address>
 *         value: 0
 *         data:  output of `cast calldata "pushMetadataUpdate(string)" "<cid>"`
 *
 *   (b) If a single signer / EOA temporarily holds ADMIN_ROLE, run this script
 *       with --account <keystore> --rpc-url base_sepolia (or base_mainnet).
 *
 * Note: the CID is stored verbatim as a string — pass the full URI you want on-chain
 *       (e.g. "ipfs://bafy..." or a bare "bafy..." CID). No format validation is done
 *       on-chain, so double-check it before broadcasting.
 */
contract PushMetadata is Script {
    function run() external {
        address fundingAddr = vm.envAddress("FUNDING_ADDRESS");
        string memory cid   = vm.envString("CID");
        require(bytes(cid).length > 0, "CID is empty");

        PropertyFunding funding = PropertyFunding(fundingAddr);

        // -- Pre-flight: show current state ----------------------------------
        string[] memory before = funding.getMetadataHistory();
        console2.log("=== Push Metadata Update ===");
        console2.log("PropertyFunding :", fundingAddr);
        console2.log("Caller          :", msg.sender);
        console2.log("New CID         :", cid);
        console2.log("Updates so far  :", before.length);
        console2.log("Current latest  :", funding.latestMetadata());
        console2.log("");

        // -- Broadcast the append --------------------------------------------
        vm.startBroadcast();
        funding.pushMetadataUpdate(cid);
        vm.stopBroadcast();

        // -- Confirm ---------------------------------------------------------
        string[] memory after_ = funding.getMetadataHistory();
        console2.log("=== Pushed ===");
        console2.log("New index       :", after_.length - 1);
        console2.log("Total updates   :", after_.length);
        console2.log("latestMetadata():", funding.latestMetadata());
    }
}
