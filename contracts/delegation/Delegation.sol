// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";

import { IDelegation } from "../interfaces/IDelegation.sol";
import { ISymbioticNetworkMiddleware } from "../interfaces/ISymbioticNetworkMiddleware.sol";

import { DelegationStorageUtils } from "../storage/DelegationStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Delegation
/// @author weso, Cap Labs
/// @notice Delegations from restakers provide coverage to borrowers
contract Delegation is IDelegation, UUPSUpgradeable, Access, DelegationStorageUtils {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IDelegation
    function initialize(address _accessControl, address _oracle, uint256 _epochDuration) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        DelegationStorage storage $ = getDelegationStorage();
        $.oracle = _oracle;
        $.epochDuration = _epochDuration;
        $.ltvBuffer = 0.05e27; // 5%
    }

    /// @inheritdoc IDelegation
    function slash(address _agent, address _liquidator, uint256 _amount) external checkAccess(this.slash.selector) {
        DelegationStorage storage $ = getDelegationStorage();
        uint48 _slashTimestamp = slashTimestamp(_agent);

        address network = $.agentData[_agent].network;
        uint256 networkSlashableCollateral =
            ISymbioticNetworkMiddleware(network).slashableCollateral(_agent, _slashTimestamp);
        if (networkSlashableCollateral == 0) revert NoSlashableCollateral();
        uint256 slashShare = _amount * 1e18 / networkSlashableCollateral;
        if (slashShare > 1e18) slashShare = 1e18;

        ISymbioticNetworkMiddleware(network).slash(_agent, _liquidator, slashShare, _slashTimestamp);
        emit SlashNetwork(network, _amount);
    }

    /// @inheritdoc IDelegation
    function distributeRewards(address _agent, address _asset) external {
        DelegationStorage storage $ = getDelegationStorage();
        uint256 _amount = IERC20(_asset).balanceOf(address(this));

        uint256 totalCoverage = coverage(_agent);
        if (totalCoverage == 0) {
            IERC20(_asset).safeTransfer($.feeRecipient, _amount);
            return;
        }

        address network = $.agentData[_agent].network;
        IERC20(_asset).safeTransfer(network, _amount);
        ISymbioticNetworkMiddleware(network).distributeRewards(_agent, _asset);

        emit DistributeReward(_agent, _asset, _amount);
    }

    /// @inheritdoc IDelegation
    function setLastBorrow(address _agent) external checkAccess(this.setLastBorrow.selector) {
        DelegationStorage storage $ = getDelegationStorage();
        $.agentData[_agent].lastBorrow = block.timestamp;
    }

    /// @inheritdoc IDelegation
    function addAgent(address _agent, address _network, uint256 _ltv, uint256 _liquidationThreshold)
        external
        checkAccess(this.addAgent.selector)
    {
        DelegationStorage storage $ = getDelegationStorage();

        // if ltv is greater than 100% then agent could borrow more than they are collateralized for
        if (_liquidationThreshold > 1e27) revert InvalidLiquidationThreshold();
        if (_ltv != 0 && _liquidationThreshold < _ltv + $.ltvBuffer) revert LiquidationThresholdTooCloseToLtv();

        if (!$.networks.contains(_network)) revert NetworkDoesntExist();

        // If the agent already exists, we revert
        if (!$.agents.add(_agent)) revert DuplicateAgent();
        $.agentData[_agent].network = _network;
        $.agentData[_agent].ltv = _ltv;
        $.agentData[_agent].liquidationThreshold = _liquidationThreshold;
        emit AddAgent(_agent, _network, _ltv, _liquidationThreshold);
    }

    /// @inheritdoc IDelegation
    function modifyAgent(address _agent, uint256 _ltv, uint256 _liquidationThreshold)
        external
        checkAccess(this.modifyAgent.selector)
    {
        DelegationStorage storage $ = getDelegationStorage();

        // if ltv is greater than 100% then agent could borrow more than they are collateralized for
        if (_liquidationThreshold > 1e27) revert InvalidLiquidationThreshold();
        if (_ltv != 0 && _liquidationThreshold < _ltv + $.ltvBuffer) revert LiquidationThresholdTooCloseToLtv();

        // Check that the agent exists
        if (!$.agents.contains(_agent)) revert AgentDoesNotExist();

        $.agentData[_agent].ltv = _ltv;
        $.agentData[_agent].liquidationThreshold = _liquidationThreshold;
        emit ModifyAgent(_agent, _ltv, _liquidationThreshold);
    }

    /// @inheritdoc IDelegation
    function registerNetwork(address _network) external checkAccess(this.registerNetwork.selector) {
        DelegationStorage storage $ = getDelegationStorage();
        if (_network == address(0)) revert InvalidNetwork();

        // Check for duplicates
        if (!$.networks.add(_network)) revert DuplicateNetwork();
        emit RegisterNetwork(_network);
    }

    /// @inheritdoc IDelegation
    function setLtvBuffer(uint256 _ltvBuffer) external checkAccess(this.setLtvBuffer.selector) {
        if (_ltvBuffer > 1e27 || _ltvBuffer <= 0.01e27) revert InvalidLtvBuffer();
        getDelegationStorage().ltvBuffer = _ltvBuffer;
        emit SetLtvBuffer(_ltvBuffer);
    }

    /// @inheritdoc IDelegation
    function setFeeRecipient(address _feeRecipient) external checkAccess(this.setFeeRecipient.selector) {
        getDelegationStorage().feeRecipient = _feeRecipient;
        emit SetFeeRecipient(_feeRecipient);
    }

    /// @inheritdoc IDelegation
    function epochDuration() external view returns (uint256 duration) {
        DelegationStorage storage $ = getDelegationStorage();
        duration = $.epochDuration;
    }

    /// @inheritdoc IDelegation
    function epoch() public view returns (uint256 currentEpoch) {
        DelegationStorage storage $ = getDelegationStorage();
        currentEpoch = block.timestamp / $.epochDuration;
    }

    /// @inheritdoc IDelegation
    function ltvBuffer() external view returns (uint256 buffer) {
        buffer = getDelegationStorage().ltvBuffer;
    }

    /// @inheritdoc IDelegation
    function slashTimestamp(address _agent) public view returns (uint48 _slashTimestamp) {
        DelegationStorage storage $ = getDelegationStorage();
        _slashTimestamp = uint48(
            Math.max(
                (epoch() - 1) * $.epochDuration,
                $.agentData[_agent].lastBorrow > 0 ? $.agentData[_agent].lastBorrow - 1 : 0
            )
        );
        if (_slashTimestamp == block.timestamp) _slashTimestamp -= 1;
    }

    /// @inheritdoc IDelegation
    function coverage(address _agent) public view returns (uint256 delegation) {
        DelegationStorage storage $ = getDelegationStorage();
        uint256 _slashableCollateral = slashableCollateral(_agent);
        uint256 currentdelegation = ISymbioticNetworkMiddleware($.agentData[_agent].network).coverage(_agent);
        uint256 lastBorrowMinusOneDelegation = _lastborrowMinusOneDelegation(_agent);
        delegation = Math.min(_slashableCollateral, Math.min(currentdelegation, lastBorrowMinusOneDelegation));
    }

    /// @dev Returns the slashable collateral of the agent in the last epoch
    /// @param _agent The agent address
    /// @return delegation The slashable collateral of the agent in the last epoch
    function _lastborrowMinusOneDelegation(address _agent) internal view returns (uint256 delegation) {
        DelegationStorage storage $ = getDelegationStorage();
        delegation = ISymbioticNetworkMiddleware($.agentData[_agent].network).slashableCollateral(
            _agent, uint48(block.timestamp - 1)
        );
    }

    /// @inheritdoc IDelegation
    function slashableCollateral(address _agent) public view returns (uint256 _slashableCollateral) {
        DelegationStorage storage $ = getDelegationStorage();
        uint48 _slashTimestamp = slashTimestamp(_agent);
        _slashableCollateral =
            ISymbioticNetworkMiddleware($.agentData[_agent].network).slashableCollateral(_agent, _slashTimestamp);
    }

    /// @inheritdoc IDelegation
    function networks(address _agent) external view returns (address networkAddress) {
        networkAddress = getDelegationStorage().agentData[_agent].network;
    }

    /// @inheritdoc IDelegation
    function agents() external view returns (address[] memory agentAddresses) {
        agentAddresses = getDelegationStorage().agents.values();
    }

    /// @inheritdoc IDelegation
    function ltv(address _agent) external view returns (uint256 currentLtv) {
        currentLtv = getDelegationStorage().agentData[_agent].ltv;
    }

    /// @inheritdoc IDelegation
    function liquidationThreshold(address _agent) external view returns (uint256 lt) {
        lt = getDelegationStorage().agentData[_agent].liquidationThreshold;
    }

    /// @inheritdoc IDelegation
    function networkExists(address _network) external view returns (bool) {
        return getDelegationStorage().networks.contains(_network);
    }

    /// @inheritdoc IDelegation
    function feeRecipient() external view returns (address) {
        return getDelegationStorage().feeRecipient;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
