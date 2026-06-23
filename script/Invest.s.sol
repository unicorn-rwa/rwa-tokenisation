// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Seeds a PropertyFunding round with investments from the funded Anvil
 *         test wallets, so the Investors / Transactions tables have data.
 *
 *         For each wallet it:
 *           0. attests it Reg S (non-US) from a valid country — if not already
 *              verified — signed by the local ATTESTER (Anvil account [2]).
 *           1. acts as the wallet (broadcasts with its key),
 *           2. approves USDC for the funding contract,
 *           3. invests one of: 2000, 2500, 3000, 3300, 4100, 5000 USDC.
 *
 * Run (Anvil fork on 127.0.0.1:8545):
 *   FUNDING=0x<propertyFunding> \
 *   forge script script/Invest.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvv
 *
 * Optional: set MM_WALLET_PK=0x<key> to also invest from your MetaMask wallet.
 */

// FUNDING=0x073448E20C51D7319F9C386D1Dd12E0EFa7C4e5a forge script script/Invest.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvv

 
interface IKYC {
    function isVerified(address wallet) external view returns (bool);
    function issueAttestation(
        address wallet,
        bool accreditedInvestor,
        bool nonAccreditedUS,
        bool regSEligible,
        bytes2 countryCode,
        uint64 expiresAt,
        bytes32 pmIdHash
    ) external;
}

interface IFunding {
    function invest(uint256 usdcAmount) external;
    function usdc() external view returns (address);
    function kycRegistry() external view returns (address);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Invest is Script {
    function run() external {
        address funding = vm.envAddress("FUNDING");
        IFunding f = IFunding(funding);
        IKYC kyc = IKYC(f.kycRegistry());
        IERC20 usdc = IERC20(f.usdc());

        // ATTESTER_ROLE holder for the local deploy = Anvil account [2].
        // Overridable for non-local registries via ATTESTER_PK.
        uint256 attesterPk = vm.envOr(
            "ATTESTER_PK",
            uint256(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a)
        );

        // ── Funded test wallets: private key, country, amount (whole USDC) ──────
        uint256[6] memory pks;
        bytes2[6] memory countries;
        uint256[6] memory amounts;

        // alice — Anvil [4]
        pks[0] = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
        countries[0] = bytes2("UA");
        amounts[0] = 2000;
        // bob — Anvil [5]
        pks[1] = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
        countries[1] = bytes2("GB");
        amounts[1] = 2500;
        // dave — Anvil [6]
        pks[2] = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
        countries[2] = bytes2("DE");
        amounts[2] = 3000;
        // investor5 — Anvil [8]
        pks[3] = 0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97;
        countries[3] = bytes2("FR");
        amounts[3] = 3300;
        // investor6 — Anvil [9]
        pks[4] = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
        countries[4] = bytes2("CA");
        amounts[4] = 4100;
        // mm_wallet_1 — your MetaMask wallet (optional, needs MM_WALLET_PK)
        pks[5] = vm.envOr("MM_WALLET_PK", uint256(0));
        countries[5] = bytes2("AU");
        amounts[5] = 5000;

        uint64 expiry = uint64(block.timestamp + 365 days);

        for (uint256 i = 0; i < pks.length; i++) {
            if (pks[i] == 0) continue; // wallet not provided (e.g. MM_WALLET_PK unset)
            address user = vm.addr(pks[i]);
            uint256 amount = amounts[i] * 1e6; // USDC has 6 decimals

            // 0. Verify as Reg S (non-US) from a valid country, if not already.
            if (!kyc.isVerified(user)) {
                vm.startBroadcast(attesterPk);
                kyc.issueAttestation(user, false, false, true, countries[i], expiry, bytes32(0));
                vm.stopBroadcast();
                console2.log("attested ", user, string(abi.encodePacked(countries[i])));
            }

            // 1-3. As the user: approve USDC, then invest.
            vm.startBroadcast(pks[i]);
            usdc.approve(funding, amount);
            f.invest(amount);
            vm.stopBroadcast();
            console2.log("invested ", user, amounts[i]);
        }
    }
}
