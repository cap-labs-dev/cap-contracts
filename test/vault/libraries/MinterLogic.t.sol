// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVaultUpgradeable } from "../../../contracts/interfaces/IVaultUpgradeable.sol";
import { MinterLogic } from "../../../contracts/vault/libraries/MinterLogic.sol";

import { MinterStorage } from "../../../contracts/vault/libraries/MinterStorage.sol";
import { DataTypes } from "../../../contracts/vault/libraries/types/DataTypes.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract MockVault is MockERC20 {
    mapping(address => uint256) public _totalSupplies;

    constructor() MockERC20("Mock Cap Token", "MCT", 18) { }

    function mockRedeemFee(uint256 _redeemFee) external {
        DataTypes.MinterStorage storage $ = MinterStorage.get();
        $.redeemFee = _redeemFee;
    }

    function mockOracle(address _oracle) external {
        DataTypes.MinterStorage storage $ = MinterStorage.get();
        $.oracle = _oracle;
    }

    function mockFees(address _asset, DataTypes.FeeData memory _feeData) external {
        DataTypes.MinterStorage storage $ = MinterStorage.get();
        $.fees[_asset] = _feeData;
    }

    function mockTotalSupplies(address _asset, uint256 _totalSupply) external {
        _totalSupplies[_asset] = _totalSupply;
    }

    function totalSupplies(address _asset) external view returns (uint256) {
        return _totalSupplies[_asset];
    }

    function minter_getAmountOut(DataTypes.AmountOutParams memory params) external view returns (uint256) {
        DataTypes.MinterStorage storage $ = MinterStorage.get();
        return MinterLogic.amountOut($, params);
    }
}

contract MockOracle {
    mapping(address => uint256) public _prices;

    function setPrice(address _asset, uint256 _price) external {
        _prices[_asset] = _price;
    }

    function getPrice(address _asset) external view returns (uint256) {
        return _prices[_asset];
    }
}

contract MinterLogicTest is Test {
    MockERC20 public asset;
    MockOracle public oracle;
    MockVault public vault;

    function setUp() public {
        // Deploy mocks so we can test the minter logic
        asset = new MockERC20("Test Asset", "TEST", 18);
        oracle = new MockOracle();
        vault = new MockVault();

        oracle.setPrice(address(asset), 1e8); // $1
        oracle.setPrice(address(vault), 1e8); // $1

        // Mock the vault data
        vault.mockOracle(address(oracle));
        vault.mockRedeemFee(0);
        vault.mockFees(
            address(asset),
            DataTypes.FeeData({ slope0: 0, slope1: 0, mintKinkRatio: 0, burnKinkRatio: 0, optimalRatio: 0 })
        );
        vault.mockDecimals(18);
    }

    function test_getAmountOut_firstDeposit() public {
        // First deposit
        vault.mockMinimumTotalSupply(0);
        vault.mockTotalSupplies(address(asset), 0);
        oracle.setPrice(address(vault), 0); // there is no price for the vault at that point

        DataTypes.AmountOutParams memory params =
            DataTypes.AmountOutParams({ asset: address(asset), amount: 1000e18, mint: true });
        uint256 amount = vault.minter_getAmountOut(params);

        assertEq(amount, 1000e18, "Amount should be equal to input for first deposit");
    }

    function test_getAmountOut_subsequentDeposit() public {
        // Setup existing state
        vault.mockMinimumTotalSupply(1000e18);
        vault.mockTotalSupplies(address(asset), 1000e18);
        vault.mockTotalSupplies(address(vault), 1000e18);

        DataTypes.AmountOutParams memory params =
            DataTypes.AmountOutParams({ asset: address(asset), amount: 500e18, mint: true });
        uint256 amount = vault.minter_getAmountOut(params);

        assertApproxEqAbs(amount, 500e18, 2, "Amount should be proportional to existing supply");
    }

    function test_getAmountOut_partialBurn() public {
        // Setup existing state
        vault.mockMinimumTotalSupply(1000e18);
        vault.mockTotalSupplies(address(asset), 1000e18);
        vault.mockTotalSupplies(address(vault), 1000e18);

        DataTypes.AmountOutParams memory params =
            DataTypes.AmountOutParams({ asset: address(asset), amount: 300e18, mint: false });

        uint256 amount = vault.minter_getAmountOut(params);

        assertApproxEqAbs(amount, 300e18, 2, "Burn amount should be proportional");
    }

    function test_getAmountOut_fullBurn() public {
        // Setup existing state
        vault.mockMinimumTotalSupply(1000e18);
        vault.mockTotalSupplies(address(asset), 1000e18);
        vault.mockTotalSupplies(address(vault), 1000e18);

        DataTypes.AmountOutParams memory params =
            DataTypes.AmountOutParams({ asset: address(asset), amount: 1000e18, mint: false });

        uint256 amount = vault.minter_getAmountOut(params);

        assertApproxEqAbs(amount, 1000e18, 2, "Should burn entire amount");
    }

    function test_getAmountOut_differentPrices() public {
        // Set different prices (using 1e8 scale as in setUp)
        oracle.setPrice(address(asset), 2e8); // Asset is worth $2
        oracle.setPrice(address(vault), 1e8); // Vault token is worth $1

        // Setup existing state
        vault.mockMinimumTotalSupply(1000e18);
        vault.mockTotalSupplies(address(asset), 1000e18);
        vault.mockTotalSupplies(address(vault), 1000e18);

        DataTypes.AmountOutParams memory params =
            DataTypes.AmountOutParams({ asset: address(asset), amount: 100e18, mint: true });

        uint256 amount = vault.minter_getAmountOut(params);

        assertApproxEqAbs(amount, 200e18, 2, "Amount should account for price difference");
    }

    function test_getAmountOut_zeroAmount() public {
        // Setup existing state
        vault.mockMinimumTotalSupply(1000e18);
        vault.mockTotalSupplies(address(asset), 1000e18);
        vault.mockTotalSupplies(address(vault), 1000e18);

        DataTypes.AmountOutParams memory params =
            DataTypes.AmountOutParams({ asset: address(asset), amount: 0, mint: true });

        uint256 amount = vault.minter_getAmountOut(params);

        assertEq(amount, 0, "Amount should be zero");
    }

    function test_getAmountOut_differentDecimals() public {
        // Create new asset with different decimals
        MockERC20 asset6Dec = new MockERC20("Test Asset 6Dec", "TEST6", 6);

        // Set prices (using 1e8 scale as in setUp)
        oracle.setPrice(address(asset6Dec), 1e8);
        oracle.setPrice(address(vault), 1e8);

        // Setup state for the new asset
        vault.mockMinimumTotalSupply(1000e18);
        vault.mockTotalSupplies(address(asset6Dec), 1000e6);
        vault.mockTotalSupplies(address(vault), 1000e18);
        vault.mockFees(
            address(asset6Dec),
            DataTypes.FeeData({ slope0: 0, slope1: 0, mintKinkRatio: 0, burnKinkRatio: 0, optimalRatio: 0 })
        );

        DataTypes.AmountOutParams memory params =
            DataTypes.AmountOutParams({ asset: address(asset6Dec), amount: 100e6, mint: true });
        uint256 amount = vault.minter_getAmountOut(params);

        assertApproxEqAbs(amount, 100e18, 2, "Amount should be scaled to 18 decimals");
    }
}
