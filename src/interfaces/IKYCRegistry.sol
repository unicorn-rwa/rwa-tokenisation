// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IKYCRegistry {
    function isVerified(address wallet) external view returns (bool);
    function isAccredited(address wallet) external view returns (bool);
    function isNonAccreditedUS(address wallet) external view returns (bool);
    function isRegSEligible(address wallet) external view returns (bool);
    function isEligibleInvestor(address wallet) external view returns (bool);
    function getCountry(address wallet) external view returns (bytes2);
    function isCountryRestricted(bytes2 countryCode) external view returns (bool);
}
