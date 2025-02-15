// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IInterestDebtToken {
    /// @custom:storage-location erc7201:cap.storage.InterestDebt
    struct InterestDebtTokenStorage {
        // Addresses
        address oracle;
        address debtToken;
        address asset;
        // Token parameters
        uint8 decimals;
        uint256 totalSupply;
        /// @dev Value is encoded in ray (27 decimals) and encodes rate per second
        uint256 interestRate;
        uint256 index;
        /// @dev timestamp of the last update
        uint256 lastUpdate;
        // Agent state
        mapping(address => uint256) storedIndex;
        mapping(address => uint256) lastAgentUpdate;
    }

    /// @dev Operation not supported
    error OperationNotSupported();

    /// @notice Initialize the interest debt token with the underlying asset
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    /// @param _debtToken Principal debt token
    /// @param _asset Asset address
    function initialize(address _accessControl, address _oracle, address _debtToken, address _asset) external;

    /// @notice Update the accrued interest and the interest rate
    /// @dev Left permissionless
    /// @param _agent Agent address to accrue interest for
    function update(address _agent) external;

    /// @notice Interest rate index representing the increase of debt per asset borrowed
    /// @dev A value of 1e27 means there is no debt. As time passes, the debt is accrued. A value
    /// of 2*1e27 means that for each unit of debt, one unit worth of interest has been accumulated
    /// @return latestIndex Current interest rate index
    function currentIndex() external view returns (uint256 latestIndex);

    /// @notice Burn the debt token, only callable by the lender
    /// @dev All underlying token transfers are handled by the lender instead of this contract
    /// @param _agent Agent address that will have it's debt repaid
    /// @param _amount Amount of underlying asset to repay to lender
    /// @return actualRepaid Actual amount repaid
    function burn(address _agent, uint256 _amount) external returns (uint256 actualRepaid);

    /// @notice Next interest rate on update
    /// @dev Value is encoded in ray (27 decimals) and encodes rate per second
    /// @param rate Interest rate
    function nextInterestRate() external returns (uint256 rate);

    /// @notice Get the current state for a restaker/agent
    /// @param _agent The address of the agent/restaker
    /// @return _storedIndex The stored index for the agent
    /// @return _lastUpdate The timestamp of the last update for this agent
    function agent(address _agent) external view returns (uint256 _storedIndex, uint256 _lastUpdate);

    /// @notice Get the oracle address
    /// @return _oracle The oracle address
    function oracle() external view returns (address _oracle);

    /// @notice Get the debt token address
    /// @return _debtToken The debt token address
    function debtToken() external view returns (address _debtToken);

    /// @notice Get the asset address
    /// @return _asset The asset address
    function asset() external view returns (address _asset);

    /// @notice Get the current interest rate
    /// @dev Value is encoded in ray (27 decimals) and encodes rate per second
    /// @return _interestRate The current interest rate
    function interestRate() external view returns (uint256 _interestRate);

    /// @notice Get the current index
    /// @return _index The current index
    function index() external view returns (uint256 _index);

    /// @notice Get the last update timestamp
    /// @return _lastUpdate The last update timestamp
    function lastUpdate() external view returns (uint256 _lastUpdate);
}
