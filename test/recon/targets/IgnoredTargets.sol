// NOTE: The following handlers are purposefully ignored because they cause too many false positives due to admin mistakes

// function lender_setMinBorrow(address _asset, uint256 _minBorrow) public asAdmin {
//     lender.setMinBorrow(_asset, _minBorrow);
// }

// function capToken_setRedeemFee(uint256 _redeemFee) public updateGhosts asActor {
//     capToken.setRedeemFee(_redeemFee);
// }

// function lender_removeAsset(address _asset) public asAdmin {
//     lender.removeAsset(_asset);
// }

// function oracle_setMarketOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
//     oracle.setMarketOracleData(_asset, _oracleData);
// }

// function oracle_setPriceBackupOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
//     oracle.setPriceBackupOracleData(_asset, _oracleData);
// }

// function oracle_setPriceOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
//     oracle.setPriceOracleData(_asset, _oracleData);
// }

// function oracle_setUtilizationOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
//     oracle.setUtilizationOracleData(_asset, _oracleData);
// }

// function mockERC4626Tester_deposit(uint256 assets, address receiver) public asActor {
//     MockERC4626Tester(_getVault()).deposit(assets, receiver);
// }

// function mockERC4626Tester_mint(uint256 shares, address receiver) public asActor {
//     MockERC4626Tester(_getVault()).mint(shares, receiver);
// }

// function mockERC4626Tester_redeem(uint256 shares, address receiver, address owner) public asActor {
//     MockERC4626Tester(_getVault()).redeem(shares, receiver, owner);
// }

// function mockERC4626Tester_withdraw(uint256 assets, address receiver, address owner) public asActor {
//     MockERC4626Tester(_getVault()).withdraw(assets, receiver, owner);
// }
