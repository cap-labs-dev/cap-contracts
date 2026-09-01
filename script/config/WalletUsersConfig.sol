// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { UsersConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { WalletUtils } from "../../contracts/deploy/utils/WalletUtils.sol";
import { Vm } from "forge-std/Vm.sol";

contract WalletUsersConfig is WalletUtils {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _getUsersConfig() internal view returns (UsersConfig memory users) {
        address wallet = getWalletAddress();
        users = UsersConfig({
            deployer: wallet,
            governor: wallet,
            keeper: wallet,
            guardian: wallet,
            admin: wallet,
            liquidator: wallet,
            stablecoinUnderlying: VM.envOr("STABLECOIN_UNDERLYING", address(0)),
            stakedStablecoin: VM.envOr("STAKED_STABLECOIN", wallet)
        });
    }
}
