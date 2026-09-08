// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IRegistry } from "../../contracts/interfaces/IRegistry.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { DeadShares } from "../../contracts/utils/DeadShares.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { CapRoles } from "../shared/CapRoles.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Vm } from "forge-std/Vm.sol";

contract TrancheTest is CapDeployer {
    address internal supplier = makeAddr("supplier");
    address internal stranger = makeAddr("stranger");
    Tranche internal tranche0;
    Tranche internal tranche1;
    FloatingMarket internal market;

    function setUp() public {
        _deployCap();
        address marketAddr;
        address s;
        address j;
        (marketAddr, s, j) = _createMarket("Market A");
        market = FloatingMarket(marketAddr);
        tranche0 = Tranche(s);
        tranche1 = Tranche(j);
    }

    function test_initializedState() public view {
        assertEq(tranche0.asset(), address(collateral));
        assertEq(tranche0.authority(), address(accessManager));
        assertEq(tranche0.totalAssets(), 0);
        assertEq(tranche0.totalSupply(), 0);
        assertEq(tranche0.market(), address(market));
    }

    function test_supportsInterface() public view {
        assertTrue(tranche0.supportsInterface(type(ITranche).interfaceId));
        assertFalse(tranche0.supportsInterface(0xffffffff));
    }

    // ── a market's tranches need not share a collateral ───────────────────────

    /// @dev The market itself never holds or names a collateral. It values every tranche in USD
    /// through {ITranche-totalCapital}, so the waterfall can be built out of whatever mix of
    /// assets the oracle can price.
    function test_createMarket_givesEachTrancheTheAssetItWasAskedFor() public {
        MockERC20 secondAsset = _newCollateral("Staked Ether", "stETH", 18, 2e18);

        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(secondAsset);

        (address mixedAddr, address[] memory mixed) =
            _createMarket("Mixed", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);

        assertEq(ITranche(mixed[0]).asset(), address(collateral), "senior holds the first asset");
        assertEq(ITranche(mixed[1]).asset(), address(secondAsset), "junior holds the second");

        _fundTranche(mixed[0], address(collateral), supplier, 10e18);
        _fundTranche(mixed[1], address(secondAsset), supplier, 10e18);

        // 10 units at $1 under 10 units at $2
        assertEq(FloatingMarket(mixedAddr).totalCapital(), 30e18, "each side priced off its own asset");
    }

    /// @dev An unpriceable tranche does not fail where you would expect. The market admits it,
    /// because {IBaseMarket-setTranches} only prices tranches through its health check and that
    /// short-circuits while there is no debt. It then fails inside {IBaseMarket-lockedValue},
    /// which every senior tranche's {ITranche-unlockedSupply} runs through, so admitting one
    /// would strand the redemptions of depositors already in the market. Hence the check up front.
    function test_createTranche_rejectsAnAssetTheOracleCannotPrice() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        MockERC20 unpriced = new MockERC20("Ghost", "GHOST", 18);

        vm.expectRevert(abi.encodeWithSelector(IRegistry.AssetNotPriced.selector, address(unpriced)));
        registry.createTranche(address(market), address(unpriced), _weights3(0.5e27, 0.3e27, 0.2e27));

        assertGt(tranche0.unlockedSupply(), 0, "existing depositors can still get out");
    }

    function test_createMarket_rejectsAnAssetTheOracleCannotPrice() public {
        MockERC20 unpriced = new MockERC20("Ghost", "GHOST", 18);

        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(unpriced);

        vm.expectRevert(abi.encodeWithSelector(IRegistry.AssetNotPriced.selector, address(unpriced)));
        registry.createMarket(assets, capConfig.defaultTrancheWeights, "Ghostly", defaultMarketOwner, defaultBorrower);
    }

    function test_createMarket_rejectsAssetsAndWeightsOfDifferentLengths() public {
        address[] memory assets = new address[](1);
        assets[0] = address(collateral);

        vm.expectRevert(IRegistry.TrancheAssetsMismatch.selector);
        registry.createMarket(assets, capConfig.defaultTrancheWeights, "Lopsided", defaultMarketOwner, defaultBorrower);
    }

    // ── admission is the AccessManager's, not a list on the tranche ───────────

    /// @dev The tranche keeps no allowlist of its own, so admitting and removing a depositor is
    /// nothing but a grant and a revoke of the role wired to the entry points.
    function test_depositorRoleMembershipDrivesAdmission() public {
        _fundVault(supplier, 3e18);
        vm.prank(supplier);
        vault.setOperator(address(tranche0), true);

        _expectDepositRejected(supplier);

        _admitDepositor(address(tranche0), supplier);
        vm.prank(supplier);
        tranche0.deposit(1e18, supplier);

        _expelDepositor(address(tranche0), supplier);
        _expectDepositRejected(supplier);
    }

    /// @dev The gate is on the caller, so it does not show up in {IERC4626-maxDeposit}. Reading
    /// that as "may I deposit" would be wrong in both directions, and the killed case below is
    /// what it does report.
    function test_maxDepositIsUnrestrictedBecauseTheGateIsOnTheCaller() public view {
        assertFalse(_mayDeposit(address(tranche0), supplier), "not admitted");
        assertEq(tranche0.maxDeposit(supplier), type(uint256).max);
        assertEq(tranche0.maxMint(supplier), type(uint256).max);
    }

    /// @dev Opening a tranche to everyone is repointing the selector at the public role, which is
    /// the AccessManager's to do rather than the market owner's.
    function test_publicRoleOnTheEntryPointsOpensTheTrancheToEveryone() public {
        _fundVault(supplier, 1e18);
        vm.prank(supplier);
        vault.setOperator(address(tranche0), true);

        _expectDepositRejected(supplier);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IERC4626.deposit.selector;
        selectors[1] = IERC4626.mint.selector;
        accessManager.setTargetFunctionRole(address(tranche0), selectors, type(uint64).max);

        vm.prank(supplier);
        tranche0.deposit(1e18, supplier);
        assertGt(tranche0.balanceOf(supplier), 0, "no grant needed once the gate is public");
    }

    function _expectDepositRejected(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        tranche0.deposit(1e18, caller);
    }

    function test_slash_onlyMarket() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        tranche0.slash(1e18, stranger);
    }

    function test_unlockedSupply_zeroWithoutDeposits() public view {
        assertEq(tranche0.unlockedSupply(), 0);
    }

    function test_tranchesAreDistinct() public view {
        assertTrue(address(tranche0) != address(tranche1));
        assertEq(tranche1.asset(), address(collateral));
    }

    // ── kill on catastrophic slash ────────────────────────────────────────────

    /// @dev Slashing is wired to {CapRoles-MARKET}. Take the role directly so a slash of an exact
    /// size can be aimed at the tranche without having to steer a market into liquidation first.
    function _becomeMarket() internal {
        accessManager.grantRole(CapRoles.MARKET, address(this), 0);
    }

    /// @dev Collateral is priced at one, so a slash of `value` removes `value` assets.
    function _slashTo(uint256 deposited, uint256 remaining) internal {
        _becomeMarket();
        tranche0.slash(deposited - remaining, stranger);
    }

    function test_slash_killsTrancheBelowOnePercentOfPar() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        assertFalse(tranche0.killed());

        // 0.5 assets against 100 shares is half a percent of par
        _slashTo(100e18, 0.5e18);

        assertTrue(tranche0.killed(), "half a percent of par must kill the tranche");
    }

    function test_slash_leavesTrancheAliveAtTwoPercentOfPar() public {
        _fundTranche(address(tranche0), supplier, 100e18);

        _slashTo(100e18, 2e18);

        assertFalse(tranche0.killed(), "two percent of par is above the threshold");
    }

    function test_slash_killsOnTotalWipeout() public {
        _fundTranche(address(tranche0), supplier, 100e18);

        _slashTo(100e18, 0);

        assertEq(tranche0.totalAssets(), 0);
        assertTrue(tranche0.killed(), "a total wipeout must kill the tranche");
    }

    /// @dev The rule is "below one percent", so par-over-a-hundred exactly is the last living
    /// share price. Pinned because the comparison is the whole feature.
    function test_slash_atExactlyOnePercentOfParStaysAlive() public {
        _fundTranche(address(tranche0), supplier, 100e18);

        // measured against the live supply, which counts the dead shares alongside the depositor's
        uint256 threshold = tranche0.totalSupply() / 100;
        _slashTo(100e18, threshold);

        assertFalse(tranche0.killed(), "exactly one percent of par is not below it");

        _becomeMarket();
        tranche0.slash(1, stranger);

        assertTrue(tranche0.killed(), "one wei under the threshold kills it");
    }

    /// @dev The point of killing is to retire the tranche, so the market has to be able to drop it
    /// out of the waterfall afterwards and carry on with the survivors.
    function test_killedTrancheCanBeDroppedFromTheMarket() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        _slashTo(100e18, 0.5e18);

        IBaseMarket.Tranche[] memory replacement = new IBaseMarket.Tranche[](1);
        replacement[0] = IBaseMarket.Tranche({ tranche: address(tranche1), weight: 1e27 });
        market.setTranches(replacement);

        assertEq(market.tranches().length, 1, "the dead tranche is out of the waterfall");
        assertEq(market.tranches()[0].tranche, address(tranche1));
    }

    /// @dev The whole replacement story end to end. {IRegistry-createTranche} only ever adds, so
    /// retiring a tranche is two steps: mint the successor into the waterfall, then call
    /// {IBaseMarket-setTranches} with the list that leaves the dead one out.
    function test_killedTrancheCanBeReplacedByAddingItsSuccessorThenDroppingIt() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        uint256 seniorWeight = market.tranches()[0].weight;
        uint256 juniorWeight = market.tranches()[1].weight;
        _slashTo(100e18, 0.5e18);

        // the dead tranche keeps its seat for now, but at no weight
        address fresh =
            registry.createTranche(address(market), address(collateral), _weights3(0, juniorWeight, seniorWeight));

        assertEq(ITranche(fresh).market(), address(market), "wired to the same market");
        assertEq(ITranche(fresh).asset(), tranche0.asset(), "and the same collateral");
        assertEq(ITranche(fresh).decimals(), tranche0.decimals(), "at the same decimals");
        assertFalse(ITranche(fresh).killed(), "the replacement starts alive");
        assertEq(ITranche(fresh).totalSupply(), 0, "and at par");
        assertEq(market.tranches().length, 3, "it joined the waterfall on the way out of the call");

        IBaseMarket.Tranche[] memory updated = new IBaseMarket.Tranche[](2);
        updated[0] = IBaseMarket.Tranche({ tranche: fresh, weight: seniorWeight });
        updated[1] = IBaseMarket.Tranche({ tranche: address(tranche1), weight: juniorWeight });
        market.setTranches(updated);

        assertEq(market.tranches().length, 2, "the dead tranche is out");
        assertEq(market.tranches()[0].tranche, fresh, "the replacement took the senior seat");
        assertEq(market.tranches()[0].weight, seniorWeight, "at the weight it replaced");

        // and it takes deposits, which the tranche it replaced no longer does
        assertEq(tranche0.maxDeposit(supplier), 0, "the dead tranche stays shut");
        assertEq(Tranche(fresh).maxDeposit(supplier), type(uint256).max, "the replacement is open");
    }

    /// @dev A market's tranche count is not fixed at deployment: the waterfall can be deepened
    /// later, and the new layer does not have to hold what the existing ones hold.
    function test_createTranche_addsAJuniorLayerWithItsOwnAsset() public {
        MockERC20 secondAsset = _newCollateral("Staked Ether", "stETH", 18, 2e18);

        address added = registry.createTranche(address(market), address(secondAsset), _weights3(0.5e27, 0.3e27, 0.2e27));

        assertEq(market.tranches().length, 3, "the waterfall got a layer deeper");
        assertEq(market.tranches()[2].tranche, added, "the new tranche is the most junior");
        assertEq(market.tranches()[2].weight, 0.2e27, "at the weight it was given");
        assertEq(market.tranches()[0].weight, 0.5e27, "and the existing seats were reweighted");
        assertEq(market.tranches()[1].weight, 0.3e27);
        assertEq(ITranche(added).asset(), address(secondAsset), "holding its own collateral");

        // the market values the mixed waterfall through each tranche's own oracle price
        _fundTranche(address(tranche0), supplier, 10e18);
        _fundTranche(added, address(secondAsset), supplier, 10e18);
        assertEq(market.totalCapital(), 10e18 * 1e18 / 1e18 + 10e18 * 2e18 / 1e18, "priced per tranche, not per market");
    }

    function test_createTranche_rejectsWeightsThatDoNotCoverTheNewTranche() public {
        uint256[] memory tooShort = capConfig.defaultTrancheWeights;
        vm.expectRevert(IRegistry.InvalidTrancheCount.selector);
        registry.createTranche(address(market), address(collateral), tooShort);
    }

    function test_createTranche_rejectsWeightsThatDoNotTotalOneRay() public {
        vm.expectRevert(IBaseMarket.InvalidTrancheWeightsTotal.selector);
        registry.createTranche(address(market), address(collateral), _weights3(0.5e27, 0.3e27, 0.1e27));
    }

    /// @dev The owner role comes off the market rather than off an argument, so there is no call
    /// shape that wires a tranche to somebody else's operator role.
    function test_createTranche_rejectsAMarketItDidNotDeploy() public {
        vm.expectRevert(IRegistry.UnknownMarket.selector);
        registry.createTranche(makeAddr("notAMarket"), address(collateral), _weights3(0.5e27, 0.3e27, 0.2e27));
    }

    function test_createTranche_namesDoNotCollideWithTheTrancheTheyReplace() public {
        address fresh = registry.createTranche(address(market), address(collateral), _weights3(0.5e27, 0.3e27, 0.2e27));

        assertTrue(
            keccak256(bytes(Tranche(fresh).name())) != keccak256(bytes(tranche0.name())), "distinct from tranche 0"
        );
        assertTrue(
            keccak256(bytes(Tranche(fresh).name())) != keccak256(bytes(tranche1.name())), "distinct from tranche 1"
        );
    }

    /// @dev Adding a tranche ends in a {IBaseMarket-setTranches} call, so it carries that call's
    /// authority rather than the keeper's.
    function test_createTranche_onlyAdmin() public {
        uint256[] memory weights = _weights3(0.5e27, 0.3e27, 0.2e27);

        accessManager.grantRole(CapRoles.KEEPER, stranger, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        registry.createTranche(address(market), address(collateral), weights);

        accessManager.grantRole(CapRoles.ADMIN, stranger, 0);
        vm.prank(stranger);
        registry.createTranche(address(market), address(collateral), weights);
    }

    function _weights3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](3);
        weights[0] = a;
        weights[1] = b;
        weights[2] = c;
    }

    function test_slash_doesNotKillAHealthyPartialSlash() public {
        _fundTranche(address(tranche0), supplier, 100e18);

        _slashTo(100e18, 50e18);

        assertFalse(tranche0.killed(), "a half slash is nowhere near the threshold");
    }

    /// @dev An empty tranche sits at par by the virtual-share convention, so an idle slash against
    /// one must not latch the flag and brick it before anybody has deposited.
    function test_slash_onEmptyTrancheDoesNotKill() public {
        _becomeMarket();
        tranche0.slash(1e18, stranger);

        assertFalse(tranche0.killed(), "an empty tranche is at par, not below the threshold");
    }

    function test_killedTrancheRejectsFurtherDeposits() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        _slashTo(100e18, 0.5e18);

        assertEq(tranche0.maxDeposit(supplier), 0, "a killed tranche accepts no assets");
        assertEq(tranche0.maxMint(supplier), 0, "a killed tranche mints no shares");

        _fundVault(supplier, 10e18);
        vm.startPrank(supplier);
        vault.setOperator(address(tranche0), true);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, supplier, 10e18, 0)
        );
        tranche0.deposit(10e18, supplier);
        vm.stopPrank();
    }

    /// @dev Killing only closes the entrance. Whoever was already in has to keep their exit, or the
    /// flag would strand the very depositors it exists to protect.
    function test_killedTrancheStillLetsExistingHoldersOut() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        _slashTo(100e18, 0.5e18);

        vm.startPrank(supplier);
        uint256 id = tranche0.requestRedeem(100e18 - DEAD_SHARES, supplier, supplier);
        uint256 claimable = tranche0.claimableRedeemRequest(id, supplier);
        assertGt(claimable, 0, "the remaining dust stays redeemable");
        tranche0.redeem(id, claimable, supplier, supplier);
        vm.stopPrank();

        assertGt(vault.balanceOf(supplier, address(collateral)), 0, "the holder recovers the dust");
    }

    function test_slash_emitsKilledOnlyOnce() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        _becomeMarket();

        vm.expectEmit(true, true, true, true, address(tranche0));
        emit ITranche.Killed();
        tranche0.slash(99.5e18, stranger);

        // already dead, so a second slash has nothing left to announce
        vm.recordLogs();
        tranche0.slash(0.1e18, stranger);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ITranche.Killed.selector, "Killed must not be re-emitted");
        }
    }

    function test_deposit_requestRedeem_redeem_roundtrip() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        uint256 held = 100e18 - DEAD_SHARES;
        assertEq(tranche0.totalSupply(), 100e18);
        assertEq(tranche0.balanceOf(supplier), held);
        assertEq(tranche0.unlockedSupply(), 100e18);

        vm.startPrank(supplier);
        uint256 id = tranche0.requestRedeem(held, supplier, supplier);
        assertEq(tranche0.claimableRedeemRequest(id, supplier), held);
        uint256 assets = tranche0.redeem(id, held, supplier, supplier);
        vm.stopPrank();

        // the dead shares keep their slice of the collateral and their place in the supply
        assertEq(assets, 100e18 - DEAD_SHARES);
        assertEq(tranche0.totalSupply(), DEAD_SHARES);
        assertEq(vault.balanceOf(supplier, address(collateral)), 100e18 - DEAD_SHARES);
    }

    // ── dead shares ───────────────────────────────────────────────────────────

    function test_firstDepositSeedsDeadSharesAtTheBurnAddress() public {
        _fundTranche(address(tranche0), supplier, 100e18);

        assertEq(tranche0.balanceOf(DeadShares.HOLDER), DEAD_SHARES, "the burn address holds them");
        assertEq(tranche0.totalSupply(), 100e18, "the whole first deposit, seed included");
        // carved out of the deposit rather than minted on top, so the quote is what they hold
        assertEq(tranche0.balanceOf(supplier), 100e18 - DEAD_SHARES, "the first depositor paid for the seed");
    }

    function test_deadSharesAreSeededOnlyOnce() public {
        _fundTranche(address(tranche0), supplier, 100e18);
        _fundTranche(address(tranche0), stranger, 100e18);

        assertEq(tranche0.balanceOf(DeadShares.HOLDER), DEAD_SHARES, "no second seeding");
        // and the second depositor pays nothing towards it
        assertEq(tranche0.balanceOf(stranger), 100e18, "only the first deposit carries the seed");
    }

    /// @dev A first deposit has to be able to cover the seed, so the wei-sized opening position the
    /// inflation attack starts from is refused outright rather than quietly rounding to nothing.
    function test_firstDepositBelowTheSeedIsRejected() public {
        _admitDepositor(address(tranche0), supplier);
        _fundVault(supplier, DEAD_SHARES);

        vm.startPrank(supplier);
        vault.setOperator(address(tranche0), true);
        vm.expectRevert(abi.encodeWithSelector(DeadShares.DepositBelowSeed.selector, DEAD_SHARES, DEAD_SHARES));
        tranche0.deposit(DEAD_SHARES, supplier);
        vm.stopPrank();
    }

    /// @dev Seeding during the first deposit would be one step too late, because ERC4626 fixes the
    /// share count from {IERC4626-previewDeposit} before the seed exists. Pricing the empty tranche
    /// at par instead is what closes that: a donation landing before anyone has deposited cannot
    /// set the rate, and turns into a windfall for the first depositor rather than a trap.
    function test_donationBeforeTheFirstDepositCannotRoundItAway() public {
        _admitDepositor(address(tranche0), supplier);
        _admitDepositor(address(tranche0), stranger);

        _fundVault(stranger, 100e18);
        vm.prank(stranger);
        vault.transfer(address(tranche0), address(collateral), 100e18);
        assertEq(tranche0.totalAssets(), 100e18, "donated while completely empty");
        assertEq(tranche0.totalSupply(), 0);

        _fundVault(supplier, 1e18);
        vm.startPrank(supplier);
        vault.setOperator(address(tranche0), true);
        uint256 shares = tranche0.deposit(1e18, supplier);
        vm.stopPrank();

        assertEq(shares, 1e18 - DEAD_SHARES, "priced at par, so the donation did not round them away");
        assertGt(tranche0.previewRedeem(shares), 1e18, "and it is theirs to collect");
    }

    /// @dev The stablecoin is not seeded, because its share price cannot be donated into:
    /// {IStablecoin-totalAssets} is derived from the supply rather than a balance, and issuance is
    /// priced at par. A seed there would be supply counted as backed and redeemable against a
    /// reserve that never received the assets for it.
    function test_stablecoinIsNotSeeded() public {
        _mintStable(supplier, 100e18);

        assertEq(stablecoin.balanceOf(address(stablecoin)), 0, "no seed held");
        assertEq(stablecoin.totalSupply(), 100e18, "and none in the supply");
        assertEq(stablecoin.previewRedeem(100e18), 100e18, "so redemption is still at par");
    }

    /// @dev {IBaseMarket-chargePremium} skips a tranche with nothing at work and routes its share
    /// elsewhere. The seed must not make an emptied tranche look busy, or premium would be minted
    /// to a tranche with no holder able to claim it.
    function test_emptiedTrancheIsStillSkippedByPremiumRouting() public {
        MarketBundle memory b = _createReadyMarket("routing");
        _fundTranche(b.tranche0Addr, supplier, 100e18);
        _fundTranche(b.tranche1Addr, stranger, 100e18);

        vm.prank(supplier);
        b.tranche0.requestRedeem(100e18 - DEAD_SHARES, supplier, supplier);
        assertEq(b.tranche0.activeSupply(), DEAD_SHARES, "the seed is all that is left");
        assertEq(b.tranche0.stakedSupply(), 0, "so nothing is underwriting");

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 50e18);
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();

        assertEq(stablecoin.balanceOf(b.tranche0Addr), 0, "no premium sent to the emptied tranche");
        assertGt(stablecoin.balanceOf(b.tranche1Addr), 0, "it went to the tranche that is working");
    }

    /// @dev The seed is excluded from {ITranche-stakedSupply}, which is the divisor premium is
    /// spread over, so the real holders are the only claim on it and can collect all of it.
    ///
    /// Run out two years of epochs, because the seed's nominal slice is `perShare × 1e3` and only
    /// climbs past a wei once `perShare` has accumulated. {ITranche-claimable} reports zero against
    /// it regardless, so the entitlements never sum past the premium the tranche is actually
    /// holding, which they otherwise would by a few wei that no caller could ever collect.
    function test_deadSharesDoNotSkimPremiumFromRealHolders() public {
        MarketBundle memory b = _createReadyMarket("premium");
        _fundTranche(b.tranche1Addr, supplier, 100e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 50e18);
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 30 days);
            b.market.chargePremium();
            b.tranche1.notifyPremium();
        }
        // and let the final epoch run out so everything funded has been released
        vm.warp(block.timestamp + 30 days);

        uint256 held = stablecoin.balanceOf(b.tranche1Addr);
        assertGt(held, 0, "there is premium at stake");
        assertEq(b.tranche1.claimable(DeadShares.HOLDER), 0, "the seed is owed none of it");
        assertLe(b.tranche1.claimable(supplier), held, "and the sole real claim is covered");

        vm.prank(supplier);
        uint256 collected = b.tranche1.claim(supplier);

        // the sole real holder takes the whole distribution, seed notwithstanding
        assertEq(collected, held, "the seed cost the holder nothing");
        assertEq(stablecoin.balanceOf(b.tranche1Addr), 0, "and left nothing stranded behind");
    }

    /// @dev The whole point of the dead shares. Anyone can push collateral to a tranche through
    /// {IVault-transfer} without minting against it, so a lone wei-sized holder could otherwise
    /// donate enough to round the next depositor down to nothing.
    function test_deadSharesDefeatTheDonationRounding() public {
        _admitDepositor(address(tranche0), supplier);
        _admitDepositor(address(tranche0), stranger);

        // attacker takes the smallest position the seed leaves open, one share
        _fundVault(supplier, DEAD_SHARES + 1);
        vm.startPrank(supplier);
        vault.setOperator(address(tranche0), true);
        tranche0.deposit(DEAD_SHARES + 1, supplier);
        assertEq(tranche0.balanceOf(supplier), 1, "and the seed dwarfs it");
        vm.stopPrank();

        // then donates far more than the victim is about to deposit
        _fundVault(supplier, 100e18);
        vm.prank(supplier);
        vault.transfer(address(tranche0), address(collateral), 100e18);

        _fundVault(stranger, 1e18);
        vm.startPrank(stranger);
        vault.setOperator(address(tranche0), true);
        uint256 shares = tranche0.deposit(1e18, stranger);
        vm.stopPrank();

        assertGt(shares, 0, "the victim still gets shares out of the deposit");
    }

    /// @dev The tranche is excluded from premium checkpointing, so premium must not be divided
    /// across the shares it holds. `activeSupply` also has to reach zero once every real holder has
    /// left, because both {PremiumVesting-accrue} and {IBaseMarket-chargePremium} read zero as "no
    /// capital at work here".
    function test_stakedSupplyExcludesDeadShares() public {
        assertEq(tranche0.stakedSupply(), 0, "nothing at work before the first deposit");

        _fundTranche(address(tranche0), supplier, 100e18);
        assertEq(tranche0.totalSupply(), 100e18);
        assertEq(tranche0.stakedSupply(), 100e18 - DEAD_SHARES, "the dead shares are not capital at work");

        vm.prank(supplier);
        tranche0.requestRedeem(100e18 - DEAD_SHARES, supplier, supplier);

        assertEq(tranche0.activeSupply(), DEAD_SHARES, "the seed is still not queued");
        assertEq(tranche0.stakedSupply(), 0, "but an emptied tranche reads as idle again");
    }
}
