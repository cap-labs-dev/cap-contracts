// NOTE: The following handlers are purposefully ignored because they cause too many false positives due to admin mistakes

// function lender_setMinBorrow(address _asset, uint256 _minBorrow) public asAdmin {
//     lender.setMinBorrow(_asset, _minBorrow);
// }

// function capToken_setRedeemFee(uint256 _redeemFee) public updateGhosts asActor {
//     capToken.setRedeemFee(_redeemFee);
// }

// function oracle_setMarketOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
//     require(_oracleData.adapter != address(0));
//     oracle.setMarketOracleData(_asset, _oracleData);
// }

// function oracle_setUtilizationOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
//     require(_oracleData.adapter != address(0));
//     oracle.setUtilizationOracleData(_asset, _oracleData);
// }
