// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract Errors {
    error NotOperator();
    error NotVault();
    error OperatorNotOptedIn();
    error OperatorNotRegistred();
    error OperarorGracePeriodNotPassed();
    error OperatorAlreadyRegistred();
    error VaultAlreadyRegistred();
    error VaultEpochTooShort();
    error VaultGracePeriodNotPassed();
    error InvalidSubnetworksCnt();
    error TooOldEpoch();
    error InvalidEpoch();
    error SlashingWindowTooShort();
    error TooBigSlashAmount();
    error UnknownSlasherType();
}