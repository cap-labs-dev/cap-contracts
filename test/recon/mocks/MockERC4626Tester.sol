// SPDX-License-Identifier: MIT
// Heavily inspired by https://github.com/liquity/V2-gov/blob/9632de9a988522775336d9b60cdf2542efc600db/test/mocks/MaliciousInitiative.sol
pragma solidity ^0.8.0;

import { MockERC20 } from "@recon/MockERC20.sol";

abstract contract ERC4626 is MockERC20 {
    MockERC20 public immutable asset;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    constructor(MockERC20 _asset) MockERC20("MockERC4626Tester", "MCT", 18) {
        asset = _asset;
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        uint256 shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public virtual returns (uint256) {
        uint256 assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual returns (uint256) {
        uint256 assets = previewRedeem(shares);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    function totalAssets() public view virtual returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : assets * supply / totalAssets();
    }

    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function previewWithdraw(uint256 assets) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : assets * supply / totalAssets();
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return convertToAssets(shares);
    }

    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf[owner];
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        asset.transferFrom(caller, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
    {
        if (caller != owner) {
            allowance[owner][caller] -= shares;
        }
        _burn(owner, shares);
        asset.transfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }
}

enum FunctionType {
    NONE,
    DEPOSIT,
    MINT,
    WITHDRAW,
    REDEEM
}

enum RevertType {
    NONE,
    THROW,
    OOG,
    RETURN_BOMB,
    REVERT_BOMB
}

contract MockERC4626Tester is ERC4626 {
    mapping(FunctionType => RevertType) public revertBehaviours;

    uint8 public decimalsOffset;
    /// @dev Track total losses
    uint256 public totalLosses;
    uint256 public lossOnWithdraw;
    uint256 public MAX_BPS = 10_000;

    constructor(address _asset) ERC4626(MockERC20(_asset)) { }

    /// @dev Set the decimal offset. Only possible with no supply.
    function setDecimalsOffset(uint8 targetDecimalsOffset) external {
        if (totalSupply != 0) {
            revert("Supply is not zero");
        }
        decimalsOffset = targetDecimalsOffset;
    }

    function _decimalsOffset() internal view returns (uint8) {
        return decimalsOffset;
    }

    /// @dev Specify the revert behaviour on each function
    function setRevertBehaviour(FunctionType ft, RevertType rt) public {
        revertBehaviours[ft] = rt;
    }

    // /// @dev Simulate a loss on the vault's assets
    // function simulateLoss(uint256 lossAmount) external {
    //     MockERC20(asset).transfer(address(0xbeef), lossAmount);
    //     totalLosses += lossAmount;
    // }

    // /// @dev Simulate a gain on the vault's assets (similar to Yearn's profit taking)
    // function simulateGain(uint256 gainAmount) external {
    //     MockERC20(asset).transferFrom(msg.sender, address(this), gainAmount);
    // }

    function setLossOnWithdraw(uint256 _lossOnWithdraw) public {
        _lossOnWithdraw %= MAX_BPS + 1; // clamp to ensure we set a max of 100%
        lossOnWithdraw = _lossOnWithdraw;
    }

    /// @dev Increase the yield by a given percentage by taking assets from the caller.
    /// @param increasePercentageFP4 Percentage increase in basis points (e.g., 100 = 1%)
    function increaseYield(uint256 increasePercentageFP4) public {
        require(increasePercentageFP4 <= 10000, "Invalid percentage");
        uint256 amount = totalAssets() * increasePercentageFP4 / 10000;
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    /// @dev Decrease the yield by a given percentage by burning the underlying asset from the vault.
    /// @param decreasePercentageFP4 Percentage decrease in basis points (e.g., 100 = 1%)
    function decreaseYield(uint256 decreasePercentageFP4) public {
        require(decreasePercentageFP4 <= 10000, "Invalid percentage");
        uint256 amount = totalAssets() * decreasePercentageFP4 / 10000;
        MockERC20(asset).transfer(address(0xbeef), amount);

        totalLosses += amount;
    }

    /// @dev Deposit assets, reverts as specified
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _performRevertBehaviour(revertBehaviours[FunctionType.DEPOSIT]);
        return super.deposit(assets, receiver);
    }

    /// @dev Mint shares, reverts as specified
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _performRevertBehaviour(revertBehaviours[FunctionType.MINT]);
        return super.mint(shares, receiver);
    }

    /// @dev Withdraw assets, reverts as specified
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        _performRevertBehaviour(revertBehaviours[FunctionType.WITHDRAW]);

        uint256 shares = previewWithdraw(assets);
        uint256 lossyAssets = assets - (assets * lossOnWithdraw / MAX_BPS);
        _withdraw(msg.sender, receiver, owner, lossyAssets, shares);

        return shares;
    }

    /// @dev Redeem shares, reverts as specified
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _performRevertBehaviour(revertBehaviours[FunctionType.REDEEM]);

        uint256 assets = previewRedeem(shares);
        uint256 lossyAssets = assets - (assets * lossOnWithdraw / MAX_BPS);
        _withdraw(msg.sender, receiver, owner, lossyAssets, shares);

        return lossyAssets;
    }

    /// @dev Preview deposit, reverts as specified
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        _performRevertBehaviour(revertBehaviours[FunctionType.DEPOSIT]);
        return super.previewDeposit(assets);
    }

    /// @dev Preview mint, reverts as specified
    function previewMint(uint256 shares) public view override returns (uint256) {
        _performRevertBehaviour(revertBehaviours[FunctionType.MINT]);
        return super.previewMint(shares);
    }

    /// @dev Preview withdraw, reverts as specified
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        _performRevertBehaviour(revertBehaviours[FunctionType.WITHDRAW]);
        return super.previewWithdraw(assets);
    }

    /// @dev Preview redeem, reverts as specified
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        _performRevertBehaviour(revertBehaviours[FunctionType.REDEEM]);
        return super.previewRedeem(shares);
    }

    /// @dev Revert in different ways to test the revert behaviour
    function _performRevertBehaviour(RevertType action) internal pure {
        if (action == RevertType.THROW) {
            revert("A normal Revert");
        }

        // 3 gas per iteration, consider changing to storage changes if traces are cluttered
        if (action == RevertType.OOG) {
            uint256 i;
            while (true) {
                ++i;
            }
        }

        if (action == RevertType.RETURN_BOMB) {
            uint256 _bytes = 2_000_000;
            assembly {
                return(0, _bytes)
            }
        }

        if (action == RevertType.REVERT_BOMB) {
            uint256 _bytes = 2_000_000;
            assembly {
                revert(0, _bytes)
            }
        }

        return; // NONE
    }
}
