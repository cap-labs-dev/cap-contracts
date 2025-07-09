// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IRegistry {
    function isEndorsed(address _vault) external view returns (bool);
}
