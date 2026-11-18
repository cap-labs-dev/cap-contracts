// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { Wrapper } from "../../contracts/cap/Wrapper.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { ChainlinkAdapter } from "../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IChainlink } from "../../contracts/interfaces/IChainlink.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { TestnetERC20 } from "../../contracts/testnet/TestnetERC20.sol";
import { TestnetPriceFeed } from "../../contracts/testnet/TestnetPriceFeed.sol";
import { CapRoles } from "../../contracts/utils/CapRoles.sol";
import { InfraConfig } from "../deploy/interfaces/DeployConfigs.sol";
import { CreateXUtils } from "../deploy/utils/CreateXUtils.sol";
import { SepoliaActors } from "./SepoliaActors.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

/// @title SepoliaScenarios
/// @notice The testnet storyline: mock tokens, operator groups, four markets, three underwriter
/// pools, borrowing on both market types, admin reconfiguration, group swaps, a liquidation, and
/// exits. Every step is signed by the actor who would do it in production.
/// @dev Each `_s(...)` call prints the scenario id, title and what it demonstrates, so the broadcast
/// log doubles as the scenario catalogue. State is kept in storage so later phases can refer to
/// what earlier ones created. Phases run in a fixed order because locks and admissions depend on it:
/// underwriters allocate and deallocate before any debt locks tranche capital, and the liquidation
/// runs after every borrow so its price move only touches the market built for it.
abstract contract SepoliaScenarios is SepoliaActors, CreateXUtils {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint64 internal constant PUBLIC_ROLE = type(uint64).max;
    uint256 internal constant RAY = 1e27;

    // ── Sepolia externals ──────────────────────────────────────────────────────
    /// @dev Chainlink ETH / USD on Sepolia, 8 decimals, heartbeat 1h
    address public constant ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    /// @dev Chainlink BTC / USD on Sepolia, 8 decimals, heartbeat 1h
    address public constant BTC_USD = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    /// @dev Testnet feeds pause now and then; accept a day-old answer rather than brick markets
    uint256 public constant FEED_MAX_AGE = 24 hours;
    /// @dev The admin-set feed stamps every read with `block.timestamp`, so this never binds
    uint256 public constant MOCK_FEED_MAX_AGE = 365 days;
    /// @dev Where the scripted wstETH price starts, in feed decimals
    int256 public constant WSTETH_INITIAL_PRICE = 2_150e8;

    // ── handles filled in by the deploy phase ──────────────────────────────────
    address internal deployer;
    bytes32 internal namespace;
    InfraConfig internal infra;
    IAccessManager internal manager;
    Registry internal registry;
    Stablecoin internal cusd;
    Wrapper internal stcusd;

    TestnetERC20 public mUsdc;
    TestnetERC20 public mWeth;
    TestnetERC20 public mWbtc;
    TestnetERC20 public mWsteth;
    TestnetPriceFeed public wstethFeed;
    /// @dev Admin-set fallbacks behind the two Chainlink feeds, seeded with the live price at deploy
    TestnetPriceFeed public ethFallbackFeed;
    TestnetPriceFeed public btcFallbackFeed;

    // ── operator groups ────────────────────────────────────────────────────────
    uint64 public atlasOwners;
    uint64 public borealOwners;
    uint64 public cinderOwners;
    uint64[3] public curatorRoles;

    uint64 public atlasBorrowersA;
    uint64 public atlasBorrowersB;
    uint64 public borealBorrowersA;
    uint64 public borealBorrowersB;
    uint64 public cinderBtcBorrowers;
    uint64 public cinderWstethBorrowersA;
    uint64 public cinderWstethBorrowersB;

    uint64 public atlasLpsV1;
    uint64 public atlasLpsV2;

    // ── markets ────────────────────────────────────────────────────────────────
    address public atlas; // floating: mWeth senior, mwstETH mezzanine, mWbtc junior
    address public boreal; // fixed: mWeth senior, mWeth junior
    address public cinderBtc; // floating: single mWbtc tranche, co-owned
    address public cinderWsteth; // floating: two mwstETH tranches, liquidated on purpose
    address[] public atlasTranches;
    address[] public borealTranches;
    address[] public cinderBtcTranches;
    address[] public cinderWstethTranches;
    address public atlasRetiredTranche;

    // ── underwriter pools ──────────────────────────────────────────────────────
    address public uwWeth;
    address public uwWbtc;
    address public uwWsteth;
    uint64 public uwWethAllocators;
    uint64 public uwWethDepositors;
    uint64 public uwWbtcAllocators;
    uint64 public uwWstethAllocatorsV1;
    uint64 public uwWstethAllocatorsV2;
    uint64 public uwWstethDepositors;

    // ── fixed loans ────────────────────────────────────────────────────────────
    uint256 public borealLoanB5;
    uint256 public borealLoanB6;
    uint256 public borealLoanB1;

    // ── broadcast helpers ──────────────────────────────────────────────────────

    function _as(Actor memory actor) internal {
        VM.startBroadcast(actor.key);
    }

    function _asDeployer() internal {
        VM.startBroadcast(deployer);
    }

    function _done() internal {
        VM.stopBroadcast();
    }

    /// @dev Simulated minutes between scenarios. A broadcast spreads these transactions over an
    /// hour or more of real blocks, so premium accrual, vesting checkpoints and rate updates take
    /// their "time has passed" branches on chain. Simulating at a single timestamp would estimate
    /// the cheap branch and leave those transactions short of gas; warping the simulation keeps the
    /// estimates honest. On chain `vm.warp` does nothing.
    uint256 internal constant SCENARIO_GAP = 3 minutes;

    /// @dev Announce a scenario. The id is stable so the UI team can reference it.
    function _s(string memory id, string memory title, string memory what) internal {
        VM.warp(block.timestamp + SCENARIO_GAP);
        console.log("");
        console.log(string.concat("[", id, "] ", title));
        console.log(string.concat("    ", what));
    }

    function _depositorRoleOf(address capVault) internal view returns (uint64 roleId) {
        roleId = manager.getTargetFunctionRole(capVault, IERC4626.deposit.selector);
    }

    function _group(address a) internal pure returns (address[][] memory members) {
        members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = a;
    }

    function _group(address a, address b) internal pure returns (address[][] memory members) {
        members = new address[][](1);
        members[0] = new address[](2);
        members[0][0] = a;
        members[0][1] = b;
    }

    function _group(address a, address b, address c) internal pure returns (address[][] memory members) {
        members = new address[][](1);
        members[0] = new address[](3);
        members[0][0] = a;
        members[0][1] = b;
        members[0][2] = c;
    }

    function _weights1(uint256 a) internal pure returns (uint256[] memory w) {
        w = new uint256[](1);
        w[0] = a;
    }

    function _weights2(uint256 a, uint256 b) internal pure returns (uint256[] memory w) {
        w = new uint256[](2);
        w[0] = a;
        w[1] = b;
    }

    function _weights3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory w) {
        w = new uint256[](3);
        w[0] = a;
        w[1] = b;
        w[2] = c;
    }

    function _weights4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory w) {
        w = new uint256[](4);
        w[0] = a;
        w[1] = b;
        w[2] = c;
        w[3] = d;
    }

    function _weights5(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
        internal
        pure
        returns (uint256[] memory w)
    {
        w = new uint256[](5);
        w[0] = a;
        w[1] = b;
        w[2] = c;
        w[3] = d;
        w[4] = e;
    }

    function _assets(address a, address b, address c) internal pure returns (address[] memory list) {
        list = new address[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }

    function _assets(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _assets(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 0 — testnet tokens and feeds
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Mock tokens through CreateX so their addresses are predictable from the namespace.
    /// Runs before the infrastructure because the wrapper seed needs 1 mUsdc in the deployer.
    function _phaseTokens() internal {
        _s(
            "0.1",
            "Deploy admin-mintable testnet tokens",
            "mUSDC (6dp) backs cUSD; mWETH (18dp), mWBTC (8dp) and mwstETH (18dp) are collateral. Only the admin can mint."
        );
        _asDeployer();
        mUsdc = TestnetERC20(_token("mUSDC", "Mock USD Coin", 6));
        mWeth = TestnetERC20(_token("mWETH", "Mock Wrapped Ether", 18));
        mWbtc = TestnetERC20(_token("mWBTC", "Mock Wrapped Bitcoin", 8));
        mWsteth = TestnetERC20(_token("mwstETH", "Mock Lido Wrapped Staked Ether", 18));
        wstethFeed = _feed("wstethFeed", "wstETH / USD (testnet)", WSTETH_INITIAL_PRICE);
        // if Chainlink Sepolia goes quiet for longer than FEED_MAX_AGE, the oracle falls through to
        // these, frozen at whatever the real feed said when the stack was deployed
        ethFallbackFeed = _feed("ethFallbackFeed", "ETH / USD (fallback)", _liveAnswer(ETH_USD));
        btcFallbackFeed = _feed("btcFallbackFeed", "BTC / USD (fallback)", _liveAnswer(BTC_USD));
        // the wrapper seed, paid by the deployer during infra deployment
        mUsdc.mint(deployer, 100e6);
        _done();
        console.log("    mUSDC ", address(mUsdc));
        console.log("    mWETH ", address(mWeth));
        console.log("    mWBTC ", address(mWbtc));
        console.log("    mwstETH", address(mWsteth));
        console.log("    wstETH/USD admin feed", address(wstethFeed));
        console.log("    ETH/USD fallback feed", address(ethFallbackFeed));
        console.log("    BTC/USD fallback feed", address(btcFallbackFeed));
    }

    function _token(bytes32 key, string memory name, uint8 decimals) private returns (address token) {
        string memory symbol = string(abi.encodePacked(_trim(key)));
        token = _create3(
            _createXSalt(deployer, namespace, key),
            abi.encodePacked(type(TestnetERC20).creationCode, abi.encode(name, symbol, decimals, deployer))
        );
    }

    function _feed(bytes32 key, string memory description, int256 answer) private returns (TestnetPriceFeed feed) {
        feed = TestnetPriceFeed(
            _create3(
                _createXSalt(deployer, namespace, key),
                abi.encodePacked(type(TestnetPriceFeed).creationCode, abi.encode(deployer, description, answer))
            )
        );
    }

    /// @dev The real feed's current answer, so a fallback starts at market rather than a guess
    function _liveAnswer(address feed) private view returns (int256 answer) {
        (, answer,,,) = IChainlink(feed).latestRoundData();
    }

    function _trim(bytes32 key) private pure returns (bytes memory out) {
        uint256 len;
        while (len < 32 && key[len] != 0) ++len;
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = key[i];
        }
    }

    /// @dev Predict every token and feed address for `save()` and the pre-flight namespace check
    function _predictTokens(address wallet, bytes32 ns) internal view returns (address[7] memory predicted) {
        predicted[0] = _predictCreate3(_createXSalt(wallet, ns, "mUSDC"), wallet);
        predicted[1] = _predictCreate3(_createXSalt(wallet, ns, "mWETH"), wallet);
        predicted[2] = _predictCreate3(_createXSalt(wallet, ns, "mWBTC"), wallet);
        predicted[3] = _predictCreate3(_createXSalt(wallet, ns, "mwstETH"), wallet);
        predicted[4] = _predictCreate3(_createXSalt(wallet, ns, "wstethFeed"), wallet);
        predicted[5] = _predictCreate3(_createXSalt(wallet, ns, "ethFallbackFeed"), wallet);
        predicted[6] = _predictCreate3(_createXSalt(wallet, ns, "btcFallbackFeed"), wallet);
    }

    /// @dev Governor points each collateral at its feed. Chainlink for the two tokens that have a
    /// Sepolia feed, the admin feed for wstETH so the liquidation scenario can move it.
    function _phaseOracle() internal {
        _s(
            "0.3",
            "Governor configures oracle sources",
            "mWETH -> Chainlink ETH/USD, mWBTC -> Chainlink BTC/USD (24h staleness, each with an admin-set fallback behind it), mwstETH -> admin-set feed."
        );
        _asDeployer();
        IOracle(infra.oracle)
            .setSource(address(mWeth), _chainlinkSource(ETH_USD, FEED_MAX_AGE, address(ethFallbackFeed)));
        IOracle(infra.oracle)
            .setSource(address(mWbtc), _chainlinkSource(BTC_USD, FEED_MAX_AGE, address(btcFallbackFeed)));
        IOracle(infra.oracle)
            .setSource(address(mWsteth), _chainlinkSource(address(wstethFeed), MOCK_FEED_MAX_AGE, address(0)));
        _done();
        console.log("    mWETH/USD ", IOracle(infra.oracle).price(address(mWeth)));
        console.log("    mWBTC/USD ", IOracle(infra.oracle).price(address(mWbtc)));
        console.log("    mwstETH/USD", IOracle(infra.oracle).price(address(mWsteth)));
    }

    /// @dev One hop: `feed` as primary, `fallbackFeed` (if any) as secondary, read when the primary is stale
    function _chainlinkSource(address feed, uint256 staleness, address fallbackFeed)
        internal
        view
        returns (IOracle.Sources[] memory sources)
    {
        sources = new IOracle.Sources[](1);
        sources[0].primary = IOracle.Source({
            adapter: infra.chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, feed),
            staleness: staleness
        });
        if (fallbackFeed != address(0)) {
            sources[0].secondary = IOracle.Source({
                adapter: infra.chainlinkAdapter,
                payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, fallbackFeed),
                staleness: MOCK_FEED_MAX_AGE
            });
        }
    }

    /// @dev Reject a dead feed before anything is deployed
    function _checkChainlinkFeed(address feed, string memory label) internal view {
        require(feed.code.length > 0, string.concat(label, " feed missing"));
        (, int256 answer,, uint256 updatedAt,) = IChainlink(feed).latestRoundData();
        require(answer > 0 && IChainlink(feed).decimals() == 8, string.concat("invalid ", label, " price"));
        require(updatedAt > 0 && updatedAt <= block.timestamp, string.concat("invalid ", label, " timestamp"));
        require(block.timestamp - updatedAt <= FEED_MAX_AGE, string.concat("stale ", label, " feed"));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 1 — roles and funding
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Protocol roles beyond the deployer: a dedicated liquidator, and WHITELISTED for the
    /// operators who stand up their own groups, markets and pools.
    function _phaseProtocolRoles() internal {
        _s(
            "1.1",
            "Admin whitelists operators and names a liquidator",
            "Market owners and curators get WHITELISTED so they can create groups, markets and pools themselves. A separate liquidator wallet gets LIQUIDATOR."
        );
        _asDeployer();
        manager.grantRole(CapRoles.LIQUIDATOR, liquidator.addr, 0);
        for (uint256 i; i < 3; ++i) {
            manager.grantRole(CapRoles.WHITELISTED, owners[i].addr, 0);
            manager.grantRole(CapRoles.WHITELISTED, curators[i].addr, 0);
        }
        // the test fixture's nonzero curve: 5% base, 10% at 80% utilisation, 20% at 100%
        InterestRateModel(infra.irm)
            .setLiquiditySlopes(
                IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
            );
        _done();
    }

    /// @dev Sepolia ETH for gas and test tokens for every actor. Top-ups only, so a re-run does
    /// not double-fund.
    function _phaseFunding(uint256 ethPerActor) internal {
        _s(
            "1.2",
            "Deployer funds the cast",
            "Each actor is topped up to the configured Sepolia ETH balance and minted the mock tokens its role needs."
        );
        _asDeployer();
        for (uint256 i; i < allActors.length; ++i) {
            address a = allActors[i].addr;
            if (a.balance < ethPerActor) {
                (bool ok,) = a.call{ value: ethPerActor - a.balance }("");
                require(ok, "fund actor");
            }
        }
        // depositors and pool LPs hold collateral and reserve; borrowers hold reserve to cover
        // premium on repayment; the liquidator holds enough reserve to clear a market
        for (uint256 i; i < 5; ++i) {
            _mintSet(depositors[i].addr, 100e18, 5e8, 100e18, 100_000e6);
        }
        for (uint256 i; i < 3; ++i) {
            _mintSet(lps[i].addr, 100e18, 5e8, 100e18, 10_000e6);
        }
        for (uint256 i; i < 6; ++i) {
            mUsdc.mint(borrowers[i].addr, 20_000e6);
        }
        mUsdc.mint(liquidator.addr, 1_000_000e6);
        _done();
    }

    function _mintSet(address to, uint256 weth, uint256 wbtc, uint256 steth, uint256 usdc) private {
        mWeth.mint(to, weth);
        mWbtc.mint(to, wbtc);
        mWsteth.mint(to, steth);
        mUsdc.mint(to, usdc);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 2 — operator groups
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Owner and curator groups, administered by GOVERNOR. Cinder is co-owned so a second
    /// member can act on its markets later.
    function _phaseOperatorGroups() internal {
        _s(
            "2.1",
            "Admin creates market-owner groups",
            "Three owner groups under GOVERNOR: Atlas [owner A], Boreal [owner B], Cinder [owner C + owner A] (co-owned)."
        );
        _asDeployer();
        atlasOwners = registry.createChildRoles(CapRoles.GOVERNOR, _group(owners[0].addr))[0];
        borealOwners = registry.createChildRoles(CapRoles.GOVERNOR, _group(owners[1].addr))[0];
        cinderOwners = registry.createChildRoles(CapRoles.GOVERNOR, _group(owners[2].addr, owners[0].addr))[0];
        _done();
        console.log("    atlasOwners role ", atlasOwners);
        console.log("    borealOwners role", borealOwners);
        console.log("    cinderOwners role", cinderOwners);

        _s(
            "2.2",
            "Admin creates curator groups",
            "One curator group per underwriter pool, each with a single curator, administered by GOVERNOR."
        );
        _asDeployer();
        for (uint256 i; i < 3; ++i) {
            curatorRoles[i] = registry.createChildRoles(CapRoles.GOVERNOR, _group(curators[i].addr))[0];
            console.log("    curator role", i, curatorRoles[i]);
        }
        _done();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 3 — markets
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseMarkets() internal {
        _s(
            "3.1",
            "Owner A creates 'Atlas ETH Credit' (floating, 3 tranches, mixed collateral)",
            "Tranches: mWETH senior 60%, mwstETH mezzanine 30%, mWBTC junior 10%. Owner sets LTV 60% and a 10% underwriter rate."
        );
        _as(owners[0]);
        (atlas, atlasTranches) = registry.createFloatingMarket(
            _assets(address(mWeth), address(mWsteth), address(mWbtc)),
            _weights3(0.6e27, 0.3e27, 0.1e27),
            "Atlas ETH Credit",
            atlasOwners
        );
        IBaseMarket(atlas).setLoanToValue(0.6e27);
        IBaseMarket(atlas).setUnderwriterRate(0.1e27);
        _done();
        _governorOpensMarket(atlas, 10_000_000e18, 1e27);

        _s(
            "3.2",
            "Owner B creates 'Boreal Fixed Term' (fixed-term loans)",
            "Two mWETH tranches 80/20, terms 1-30 days, 1 day grace. Owner sets LTV 50% and a 15% underwriter rate."
        );
        _as(owners[1]);
        (boreal, borealTranches) = registry.createFixedMarket(
            _assets(address(mWeth), address(mWeth)),
            _weights2(0.8e27, 0.2e27),
            "Boreal Fixed Term",
            borealOwners,
            30 days,
            1 days,
            1 days
        );
        IBaseMarket(boreal).setLoanToValue(0.5e27);
        IBaseMarket(boreal).setUnderwriterRate(0.15e27);
        _done();
        _governorOpensMarket(boreal, 10_000_000e18, 1e27);

        _s(
            "3.3",
            "Owner C creates 'Cinder BTC Credit' (floating, single tranche, co-owned)",
            "One mWBTC tranche at 100%. Owner C sets LTV 40% and a 20% underwriter rate; owner A co-administers through the shared Cinder group."
        );
        _as(owners[2]);
        (cinderBtc, cinderBtcTranches) =
            registry.createFloatingMarket(_assets(address(mWbtc)), _weights1(1e27), "Cinder BTC Credit", cinderOwners);
        IBaseMarket(cinderBtc).setLoanToValue(0.4e27);
        IBaseMarket(cinderBtc).setUnderwriterRate(0.2e27);
        _done();
        _governorOpensMarket(cinderBtc, 10_000_000e18, 1e27);

        _s(
            "3.4",
            "Owner C creates 'Cinder wstETH Credit' (floating, the liquidation sandbox)",
            "Two mwstETH tranches 70/30 priced by the admin feed. LTV 65% (the maximum under LT 80% - buffer 10%) so a scripted price drop makes it liquidatable."
        );
        _as(owners[2]);
        (cinderWsteth, cinderWstethTranches) = registry.createFloatingMarket(
            _assets(address(mWsteth), address(mWsteth)), _weights2(0.7e27, 0.3e27), "Cinder wstETH Credit", cinderOwners
        );
        IBaseMarket(cinderWsteth).setLoanToValue(0.65e27);
        IBaseMarket(cinderWsteth).setUnderwriterRate(0.25e27);
        _done();
        _governorOpensMarket(cinderWsteth, 10_000_000e18, 1e27);
    }

    /// @dev A new market lends nothing until GOVERNOR caps each tranche's countable capital
    function _governorOpensMarket(address market, uint256 maxCapital, uint256 multiplier) private {
        _asDeployer();
        IBaseMarket.Tranche[] memory ts = IBaseMarket(market).tranches();
        for (uint256 i; i < ts.length; ++i) {
            Tranche(ts[i].tranche).setMaxCapital(maxCapital);
        }
        IBaseMarket(market).setMarketMultiplier(multiplier);
        _done();
        console.log("    market", market);
        for (uint256 i; i < ts.length; ++i) {
            console.log("    tranche", i, ts[i].tranche);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 4 — borrower groups (created, edited, swapped by market owners)
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseBorrowerGroups() internal {
        _s(
            "4.1",
            "Owner A creates borrower group 'Atlas Borrowers A' and wires it to the market",
            "Group under the Atlas owner role with borrowers A and B, then market.setBorrowerRole(group). Until this, nobody can draw."
        );
        _as(owners[0]);
        atlasBorrowersA = registry.createChildRoles(atlasOwners, _group(borrowers[0].addr, borrowers[1].addr))[0];
        IBaseMarket(atlas).setBorrowerRole(atlasBorrowersA);
        _done();

        _s(
            "4.2",
            "Owner A edits the group's membership directly on AccessManager",
            "Adds borrower C (grantRole) and removes borrower B (revokeRole). The market keeps pointing at the same group."
        );
        _as(owners[0]);
        manager.grantRole(atlasBorrowersA, borrowers[2].addr, 0);
        manager.revokeRole(atlasBorrowersA, borrowers[1].addr);
        _done();

        _s(
            "4.3",
            "Owner B creates 'Boreal Borrowers A' [E, F] for the fixed market",
            "Same pattern on the fixed-term market: a group under the Boreal owner role, then setBorrowerRole."
        );
        _as(owners[1]);
        borealBorrowersA = registry.createChildRoles(borealOwners, _group(borrowers[4].addr, borrowers[5].addr))[0];
        IBaseMarket(boreal).setBorrowerRole(borealBorrowersA);
        _done();

        _s(
            "4.4",
            "Owner C creates 'Cinder BTC Borrowers' [B, F]; co-owner A then swaps F out for C",
            "Shows two members of one owner group administering the same borrower group: C creates it, A revokes F and grants C."
        );
        _as(owners[2]);
        cinderBtcBorrowers = registry.createChildRoles(cinderOwners, _group(borrowers[1].addr, borrowers[5].addr))[0];
        IBaseMarket(cinderBtc).setBorrowerRole(cinderBtcBorrowers);
        _done();
        _as(owners[0]);
        manager.revokeRole(cinderBtcBorrowers, borrowers[5].addr);
        manager.grantRole(cinderBtcBorrowers, borrowers[2].addr, 0);
        _done();

        _s(
            "4.5",
            "Owner C creates 'Cinder wstETH Borrowers A' [C]",
            "A single-member borrower group for the liquidation sandbox. It is swapped for a fresh group after the liquidation (9.4)."
        );
        _as(owners[2]);
        cinderWstethBorrowersA = registry.createChildRoles(cinderOwners, _group(borrowers[2].addr))[0];
        IBaseMarket(cinderWsteth).setBorrowerRole(cinderWstethBorrowersA);
        _done();

        console.log("    atlasBorrowersA      ", atlasBorrowersA);
        console.log("    borealBorrowersA     ", borealBorrowersA);
        console.log("    cinderBtcBorrowers   ", cinderBtcBorrowers);
        console.log("    cinderWstethBorrowersA", cinderWstethBorrowersA);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 5 — depositor groups
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseDepositorGroups() internal {
        _s(
            "5.1",
            "Owner A creates 'Atlas LPs v1' [A, B, C] and sets it as the senior tranche's depositor role",
            "A named depositor group replaces the closed role the registry minted at creation. Only members can deposit into Atlas tranche 0."
        );
        _as(owners[0]);
        atlasLpsV1 = registry.createChildRoles(
            atlasOwners, _group(depositors[0].addr, depositors[1].addr, depositors[2].addr)
        )[0];
        Tranche(atlasTranches[0]).setDepositorRole(atlasLpsV1);
        _done();

        _s(
            "5.2",
            "Owner A admits depositor D to the mezzanine tranche's default closed role",
            "No new group: the owner grants membership of the registry-minted depositor role (read from AccessManager) directly."
        );
        _as(owners[0]);
        manager.grantRole(_depositorRoleOf(atlasTranches[1]), depositors[3].addr, 0);
        _done();

        _s(
            "5.3",
            "Owner A opens the junior tranche to the public",
            "tranche.setDepositorRole(PUBLIC_ROLE): anyone, including underwriter pools, can deposit mWBTC into Atlas tranche 2."
        );
        _as(owners[0]);
        Tranche(atlasTranches[2]).setDepositorRole(PUBLIC_ROLE);
        _done();

        _s(
            "5.4",
            "Owner B admits depositors A and B to Boreal senior, C to Boreal junior",
            "Fixed-market tranches use the registry-minted closed roles; the owner grants members one by one."
        );
        _as(owners[1]);
        manager.grantRole(_depositorRoleOf(borealTranches[0]), depositors[0].addr, 0);
        manager.grantRole(_depositorRoleOf(borealTranches[0]), depositors[1].addr, 0);
        manager.grantRole(_depositorRoleOf(borealTranches[1]), depositors[2].addr, 0);
        _done();

        _s(
            "5.5",
            "Owner C admits depositors to the Cinder tranches",
            "BTC tranche: C and E. wstETH senior: D and E. wstETH junior: A."
        );
        _as(owners[2]);
        manager.grantRole(_depositorRoleOf(cinderBtcTranches[0]), depositors[2].addr, 0);
        manager.grantRole(_depositorRoleOf(cinderBtcTranches[0]), depositors[4].addr, 0);
        manager.grantRole(_depositorRoleOf(cinderWstethTranches[0]), depositors[3].addr, 0);
        manager.grantRole(_depositorRoleOf(cinderWstethTranches[0]), depositors[4].addr, 0);
        manager.grantRole(_depositorRoleOf(cinderWstethTranches[1]), depositors[0].addr, 0);
        _done();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 6 — depositors supply collateral and reserve
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseTrancheDeposits() internal {
        _s(
            "6.1",
            "Depositors A, B, C supply mWETH to Atlas senior and opt in to premiums",
            "10 / 5 / 2.5 mWETH. The first deposit carves out the dead shares. optIn() makes the position earn cUSD premium."
        );
        _deposit(depositors[0], atlasTranches[0], mWeth, 10e18);
        _deposit(depositors[1], atlasTranches[0], mWeth, 5e18);
        _deposit(depositors[2], atlasTranches[0], mWeth, 2.5e18);

        _s(
            "6.2",
            "Depositor D supplies mwstETH to Atlas mezzanine; E supplies mWBTC to the public junior",
            "20 mwstETH and 0.5 mWBTC. E was never admitted anywhere: the junior tranche is public."
        );
        _deposit(depositors[3], atlasTranches[1], mWsteth, 20e18);
        _deposit(depositors[4], atlasTranches[2], mWbtc, 0.5e8);

        _s(
            "6.3",
            "Depositors fund the Boreal fixed market",
            "A: 4 mWETH and B: 6 mWETH into senior, C: 1 mWETH into junior."
        );
        _deposit(depositors[0], borealTranches[0], mWeth, 4e18);
        _deposit(depositors[1], borealTranches[0], mWeth, 6e18);
        _deposit(depositors[2], borealTranches[1], mWeth, 1e18);

        _s(
            "6.4",
            "Depositors fund the two Cinder markets",
            "BTC: C 1 mWBTC, E 0.25 mWBTC. wstETH senior: D 30, E 20 mwstETH. wstETH junior: A 10 mwstETH."
        );
        _deposit(depositors[2], cinderBtcTranches[0], mWbtc, 1e8);
        _deposit(depositors[4], cinderBtcTranches[0], mWbtc, 0.25e8);
        _deposit(depositors[3], cinderWstethTranches[0], mWsteth, 30e18);
        _deposit(depositors[4], cinderWstethTranches[0], mWsteth, 20e18);
        _deposit(depositors[0], cinderWstethTranches[1], mWsteth, 10e18);
    }

    function _deposit(Actor memory who, address tranche, TestnetERC20 token, uint256 amount) private {
        _as(who);
        token.approve(tranche, amount);
        Tranche(tranche).deposit(amount, who.addr);
        Tranche(tranche).optIn();
        _done();
    }

    function _phaseStablecoinDeposits() internal {
        _s(
            "6.5",
            "Depositors D and E mint cUSD from mUSDC; D wraps half into stcUSD",
            "D: 10,000 mUSDC -> cUSD, opts in, wraps 5,000 cUSD. E: 5,000 mUSDC -> cUSD and opts in. Permissionless, no role needed."
        );
        _mintCusd(depositors[3], 10_000e6);
        _as(depositors[3]);
        cusd.optIn();
        cusd.approve(address(stcusd), 5_000e18);
        stcusd.deposit(5_000e18, depositors[3].addr);
        _done();
        _mintCusd(depositors[4], 5_000e6);
        _as(depositors[4]);
        cusd.optIn();
        _done();

        _s(
            "6.6",
            "Liquidator and borrowers hold cUSD reserve",
            "Liquidator mints 200,000 cUSD to repay a liquidation later; borrowers E, F mint 1,000 cUSD each to cover fixed-loan premium on repayment."
        );
        _mintCusd(liquidator, 200_000e6);
        _mintCusd(borrowers[4], 1_000e6);
        _mintCusd(borrowers[5], 1_000e6);
    }

    function _mintCusd(Actor memory who, uint256 usdcAmount) private {
        _as(who);
        mUsdc.approve(address(cusd), usdcAmount);
        cusd.deposit(usdcAmount, who.addr);
        _done();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 7 — underwriter pools
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseUnderwriters() internal {
        _uwWeth();
        _uwWbtc();
        _uwSteth();
    }

    function _uwWeth() private {
        _s(
            "7.1",
            "Curator A creates the 'Cap WETH Underwriter' pool with allocator and depositor groups",
            "Curator creates the pool, mints child groups under its curator role: allocators [Allocator A], depositors [LP A, LP B], and wires both."
        );
        _as(curators[0]);
        uwWeth = registry.createUnderwriter(address(mWeth), "Cap WETH Underwriter", "uwWETH", curatorRoles[0]);
        uint64[] memory roles =
            registry.createChildRoles(curatorRoles[0], _twoGroups(allocators[0].addr, lps[0].addr, lps[1].addr));
        uwWethAllocators = roles[0];
        uwWethDepositors = roles[1];
        Underwriter(uwWeth).setAllocatorRole(uwWethAllocators);
        Underwriter(uwWeth).setDepositorRole(uwWethDepositors);
        Underwriter(uwWeth).addTranche(atlasTranches[0]);
        Underwriter(uwWeth).addTranche(borealTranches[0]);
        _done();
        console.log("    uwWeth", uwWeth);

        _s(
            "7.2",
            "Owners A and B admit the pool contract to their senior tranches",
            "A pool is a depositor like any other: owner A adds the pool address to 'Atlas LPs v1', owner B grants Boreal senior's closed role."
        );
        _as(owners[0]);
        manager.grantRole(atlasLpsV1, uwWeth, 0);
        _done();
        _as(owners[1]);
        manager.grantRole(_depositorRoleOf(borealTranches[0]), uwWeth, 0);
        _done();

        _s(
            "7.3",
            "LP A deposits 20 mWETH; Allocator A spreads it across two markets and picks a default",
            "No default yet, so the deposit sits idle. Allocator A allocates 12 to Atlas senior and 6 to Boreal senior, then sets Atlas senior as the default route."
        );
        _poolDeposit(lps[0], uwWeth, mWeth, 20e18);
        _as(allocators[0]);
        Underwriter(uwWeth).allocate(atlasTranches[0], 12e18);
        Underwriter(uwWeth).allocate(borealTranches[0], 6e18);
        Underwriter(uwWeth).setDefaultTranche(atlasTranches[0]);
        _done();

        _s(
            "7.4",
            "LP B deposits 10 mWETH, which auto-routes to the default tranche",
            "With a default set, the pool mints tranche shares in the same transaction as the deposit."
        );
        _poolDeposit(lps[1], uwWeth, mWeth, 10e18);

        _s(
            "7.5",
            "Allocator A deallocates: 2 mWETH instantly from Boreal, 1 mWETH queued from Atlas",
            "deallocate() redeems unlocked tranche shares at once; deallocateAsync() queues an ERC-7540 request that fills as capital unlocks."
        );
        _as(allocators[0]);
        Underwriter(uwWeth).deallocate(borealTranches[0], 2e18);
        Underwriter(uwWeth).deallocateAsync(atlasTranches[0], 1e18);
        _done();

        _s(
            "7.6",
            "Keeper reports both positions",
            "report() re-marks the pool's book against the tranche and claims any vested premium into the pool."
        );
        _asDeployer();
        Underwriter(uwWeth).report(atlasTranches[0]);
        Underwriter(uwWeth).report(borealTranches[0]);
        _done();
    }

    function _uwWbtc() private {
        _s(
            "7.7",
            "Curator B creates the 'Cap WBTC Underwriter' pool and opens deposits to the public",
            "Allocator group [Allocator B]; depositor role set to PUBLIC. Registers Cinder BTC and the public Atlas junior tranche."
        );
        _as(curators[1]);
        uwWbtc = registry.createUnderwriter(address(mWbtc), "Cap WBTC Underwriter", "uwWBTC", curatorRoles[1]);
        uwWbtcAllocators = registry.createChildRoles(curatorRoles[1], _group(allocators[1].addr))[0];
        Underwriter(uwWbtc).setAllocatorRole(uwWbtcAllocators);
        Underwriter(uwWbtc).setDepositorRole(PUBLIC_ROLE);
        Underwriter(uwWbtc).addTranche(cinderBtcTranches[0]);
        Underwriter(uwWbtc).addTranche(atlasTranches[2]);
        _done();
        console.log("    uwWbtc", uwWbtc);

        _s(
            "7.8",
            "Owner C admits the WBTC pool to the Cinder BTC tranche; LP C deposits; Allocator B allocates",
            "LP C (never whitelisted) deposits 2 mWBTC into the public pool. Allocator B puts 1.5 into Cinder BTC, 0.25 into Atlas junior, and makes Cinder BTC the default."
        );
        _as(owners[2]);
        manager.grantRole(_depositorRoleOf(cinderBtcTranches[0]), uwWbtc, 0);
        _done();
        _poolDeposit(lps[2], uwWbtc, mWbtc, 2e8);
        _as(allocators[1]);
        Underwriter(uwWbtc).allocate(cinderBtcTranches[0], 1.5e8);
        Underwriter(uwWbtc).allocate(atlasTranches[2], 0.25e8);
        Underwriter(uwWbtc).setDefaultTranche(cinderBtcTranches[0]);
        _done();
    }

    function _uwSteth() private {
        _s(
            "7.9",
            "Curator C creates the 'Cap wstETH Underwriter' pool",
            "Allocators [Allocator C], depositors [LP A]. Registers Cinder wstETH senior (the liquidation sandbox) and Atlas mezzanine."
        );
        _as(curators[2]);
        uwWsteth = registry.createUnderwriter(address(mWsteth), "Cap wstETH Underwriter", "uwwstETH", curatorRoles[2]);
        uint64[] memory roles =
            registry.createChildRoles(curatorRoles[2], _twoGroups(allocators[2].addr, lps[0].addr, address(0)));
        uwWstethAllocatorsV1 = roles[0];
        uwWstethDepositors = roles[1];
        Underwriter(uwWsteth).setAllocatorRole(uwWstethAllocatorsV1);
        Underwriter(uwWsteth).setDepositorRole(uwWstethDepositors);
        Underwriter(uwWsteth).addTranche(cinderWstethTranches[0]);
        Underwriter(uwWsteth).addTranche(atlasTranches[1]);
        _done();
        console.log("    uwWsteth", uwWsteth);

        _s(
            "7.10",
            "Owners admit the wstETH pool; LP A deposits 40 mwstETH; Allocator C allocates 30 + 5",
            "Owner C grants the pool on Cinder wstETH senior, owner A on Atlas mezzanine. Default route becomes Cinder wstETH senior."
        );
        _as(owners[2]);
        manager.grantRole(_depositorRoleOf(cinderWstethTranches[0]), uwWsteth, 0);
        _done();
        _as(owners[0]);
        manager.grantRole(_depositorRoleOf(atlasTranches[1]), uwWsteth, 0);
        _done();
        _poolDeposit(lps[0], uwWsteth, mWsteth, 40e18);
        _as(allocators[2]);
        Underwriter(uwWsteth).allocate(cinderWstethTranches[0], 30e18);
        Underwriter(uwWsteth).allocate(atlasTranches[1], 5e18);
        Underwriter(uwWsteth).setDefaultTranche(cinderWstethTranches[0]);
        _done();

        _s(
            "7.11",
            "Curator C swaps the allocator group: 'v2' [Allocator A] replaces [Allocator C]",
            "createChildRoles under the curator role, then setAllocatorRole(v2). Allocator C loses the ability to move capital; Allocator A gains it."
        );
        _as(curators[2]);
        uwWstethAllocatorsV2 = registry.createChildRoles(curatorRoles[2], _group(allocators[0].addr))[0];
        Underwriter(uwWsteth).setAllocatorRole(uwWstethAllocatorsV2);
        _done();

        _s(
            "7.12",
            "New allocator A pulls the pool out of Atlas mezzanine; Curator C deregisters that tranche",
            "deallocate() the whole Atlas mezzanine position (unlocked: Atlas has no debt yet), then removeTranche() closes it to new allocations."
        );
        _as(allocators[0]);
        Underwriter(uwWsteth).deallocate(atlasTranches[1], type(uint256).max);
        _done();
        _as(curators[2]);
        Underwriter(uwWsteth).removeTranche(atlasTranches[1]);
        _done();
    }

    function _poolDeposit(Actor memory who, address pool, TestnetERC20 token, uint256 amount) private {
        _as(who);
        token.approve(pool, amount);
        Underwriter(pool).deposit(amount, who.addr);
        Underwriter(pool).optIn();
        _done();
    }

    /// @dev Two groups in one call: `[a]` and `[b, c]` (`c` omitted when zero)
    function _twoGroups(address a, address b, address c) private pure returns (address[][] memory members) {
        members = new address[][](2);
        members[0] = new address[](1);
        members[0][0] = a;
        members[1] = new address[](c == address(0) ? 1 : 2);
        members[1][0] = b;
        if (c != address(0)) members[1][1] = c;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 8 — borrowing
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseBorrowing() internal {
        _s(
            "8.1",
            "Borrower A draws 5,000 cUSD from Atlas",
            "Floating borrow mints credit-backed cUSD to the recipient and records scaled debt against the market."
        );
        _as(borrowers[0]);
        FloatingMarket(atlas).borrow(borrowers[0].addr, 5_000e18);
        _done();

        _s(
            "8.2",
            "Owner A swaps Atlas to borrower group B [Borrower D]; D draws 20,000 cUSD",
            "A new group replaces group A on the market. Members of A keep their debt exposure but can no longer draw; D can."
        );
        _as(owners[0]);
        atlasBorrowersB = registry.createChildRoles(atlasOwners, _group(borrowers[3].addr))[0];
        IBaseMarket(atlas).setBorrowerRole(atlasBorrowersB);
        _done();
        _as(borrowers[3]);
        FloatingMarket(atlas).borrow(borrowers[3].addr, 20_000e18);
        _done();

        _s(
            "8.3",
            "Borrower A repays 1,000 cUSD to Atlas",
            "repay() burns credit-backed cUSD from the caller; repayment is open to anyone holding cUSD, not just group members."
        );
        _as(borrowers[0]);
        FloatingMarket(atlas).repay(1_000e18);
        _done();

        _s(
            "8.4",
            "Borrower E opens a 7-day fixed loan of 3,000 cUSD on Boreal; F opens 14 days for 2,000",
            "Fixed loans charge the term's liquidity + underwriting premium up front into the debt. maxPremium is uncapped here."
        );
        _as(borrowers[4]);
        (borealLoanB5,) = FixedMarket(boreal).borrow(borrowers[4].addr, 3_000e18, 7 days, type(uint256).max);
        _done();
        _as(borrowers[5]);
        (borealLoanB6,) = FixedMarket(boreal).borrow(borrowers[5].addr, 2_000e18, 14 days, type(uint256).max);
        _done();

        _s(
            "8.5",
            "Borrower E tops up loan #0 by 500 and extends it 7 days; Borrower F repays loan #1 in full",
            "borrowMore() adds principal over the remaining term; extend() buys more term; repay(max) clears principal plus premium."
        );
        _as(borrowers[4]);
        FixedMarket(boreal).borrowMore(borealLoanB5, borrowers[4].addr, 500e18, type(uint256).max);
        FixedMarket(boreal).extend(borealLoanB5, 7 days, type(uint256).max);
        _done();
        _as(borrowers[5]);
        FixedMarket(boreal).repay(borealLoanB6, type(uint256).max);
        _done();

        _s(
            "8.6",
            "Owner B swaps Boreal to borrower group B [A, E]; Borrower A opens a 10-day loan of 1,000",
            "Borrower A now borrows on two markets; F, dropped with the swap, can no longer open loans here."
        );
        _as(owners[1]);
        borealBorrowersB = registry.createChildRoles(borealOwners, _group(borrowers[0].addr, borrowers[4].addr))[0];
        IBaseMarket(boreal).setBorrowerRole(borealBorrowersB);
        _done();
        _as(borrowers[0]);
        (borealLoanB1,) = FixedMarket(boreal).borrow(borrowers[0].addr, 1_000e18, 10 days, type(uint256).max);
        _done();

        _s(
            "8.7",
            "Borrower B draws 10,000 cUSD from Cinder BTC",
            "Borrower B is a member of the Cinder BTC group (4.4) but was removed from Atlas (4.2)."
        );
        _as(borrowers[1]);
        FloatingMarket(cinderBtc).borrow(borrowers[1].addr, 10_000e18);
        _done();

        _s(
            "8.8",
            "Borrower C draws the full available credit from Cinder wstETH",
            "borrow(max) fills availableCredit exactly, which puts the market at its LTV so the price drop in 9.1 tips it under LT."
        );
        _as(borrowers[2]);
        FloatingMarket(cinderWsteth).borrow(borrowers[2].addr, type(uint256).max);
        _done();

        _s(
            "8.9",
            "Anyone realises accrued premium on the floating markets",
            "chargePremium() is permissionless: it mints the elapsed premium to cUSD holders and tranches. Early on it is tiny."
        );
        _as(depositors[0]);
        FloatingMarket(atlas).chargePremium();
        FloatingMarket(cinderBtc).chargePremium();
        _done();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 9 — liquidation on the wstETH sandbox
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseLiquidation(bool writeOff) internal {
        _s(
            "9.1",
            "Admin drops the wstETH feed 25% (2,150 -> 1,612.50)",
            "Cinder wstETH was borrowed to its 65% LTV; at 75% of the price its debt exceeds 80% of capital and the market is unhealthy."
        );
        _asDeployer();
        wstethFeed.setAnswer(1_612.5e8);
        _done();
        console.log("    health (ray)", IBaseMarket(cinderWsteth).healthiness());
        console.log("    maxLiquidatable", IBaseMarket(cinderWsteth).maxLiquidatable());

        _s(
            "9.2",
            "Liquidator repays up to maxLiquidatable and receives slashed mwstETH",
            "Liquidation burns the liquidator's cUSD, slashes junior collateral first then senior, and leaves the market at target health 1.25."
        );
        _as(liquidator);
        FloatingMarket(cinderWsteth).liquidate(liquidator.addr, type(uint256).max);
        _done();
        console.log("    health after (ray)", IBaseMarket(cinderWsteth).healthiness());
        console.log("    liquidator mwstETH", mWsteth.balanceOf(liquidator.addr));

        if (writeOff) {
            _s(
                "9.3",
                "Admin crashes the feed to 215; Guardian writes off unrecoverable debt (opt-in)",
                "SCENARIO_WRITEOFF=true only. Leaves recognised bad debt on cUSD for the rest of the testnet's life."
            );
            _asDeployer();
            wstethFeed.setAnswer(215e8);
            FloatingMarket(cinderWsteth).writeOff();
            _done();
        }

        _s(
            "9.4",
            "Admin restores the feed to 2,150; Keeper reports the wstETH pool's loss; Owner C swaps the borrower group",
            "report() marks the pool's slashed position down. The sandbox then moves to borrower group B [Borrower D] for further UI testing."
        );
        _asDeployer();
        wstethFeed.setAnswer(WSTETH_INITIAL_PRICE);
        Underwriter(uwWsteth).report(cinderWstethTranches[0]);
        _done();
        _as(owners[2]);
        cinderWstethBorrowersB = registry.createChildRoles(cinderOwners, _group(borrowers[3].addr))[0];
        IBaseMarket(cinderWsteth).setBorrowerRole(cinderWstethBorrowersB);
        _done();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 10 — owners reconfigure markets
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseMarketAdmin() internal {
        _s(
            "10.1",
            "Owner A lowers Atlas LTV to 55%, reweights tranches 50/30/20, raises underwriter rate to 12%",
            "setLoanToValue, setTrancheWeights (settles premium under the old weights first) and setUnderwriterRate, all owner calls."
        );
        _as(owners[0]);
        IBaseMarket(atlas).setLoanToValue(0.55e27);
        IBaseMarket(atlas).setTrancheWeights(_weights3(0.5e27, 0.3e27, 0.2e27));
        IBaseMarket(atlas).setUnderwriterRate(0.12e27);
        _done();

        _s(
            "10.2",
            "Owner A adds a fourth Atlas tranche (mWETH) and a fifth (mwstETH), then removes the fifth",
            "createTranche deploys and reweights 45/30/15/10; a second one goes to 45/30/15/5/5; removeTranche retires it and returns to four. The retired tranche stays visible with zero lock."
        );
        _as(owners[0]);
        address t3 =
            IBaseMarket(atlas).createTranche(address(mWeth), _weights4(0.45e27, 0.3e27, 0.15e27, 0.1e27), 12 hours);
        atlasTranches.push(t3);
        address t4 = IBaseMarket(atlas)
            .createTranche(address(mWsteth), _weights5(0.45e27, 0.3e27, 0.15e27, 0.05e27, 0.05e27), 6 hours);
        IBaseMarket(atlas).removeTranche(t4, _weights4(0.45e27, 0.3e27, 0.15e27, 0.1e27));
        atlasRetiredTranche = t4;
        _done();
        _asDeployer();
        Tranche(t3).setMaxCapital(10_000_000e18);
        _done();
        console.log("    new tranche 3", t3);
        console.log("    retired tranche", t4);

        _s(
            "10.3",
            "Owner A swaps Atlas senior to depositor group 'Atlas LPs v2' [A, E, WETH pool]; E deposits 1 mWETH",
            "B and C keep their shares but can no longer deposit; E can. The pool stays in so its default route keeps working."
        );
        _as(owners[0]);
        atlasLpsV2 = registry.createChildRoles(atlasOwners, _group(depositors[0].addr, depositors[4].addr, uwWeth))[0];
        Tranche(atlasTranches[0]).setDepositorRole(atlasLpsV2);
        _done();
        _deposit(depositors[4], atlasTranches[0], mWeth, 1e18);

        _s(
            "10.4",
            "Co-owner A raises Cinder BTC's LTV to 45%",
            "Owner A acts on a Cinder market through the shared Cinder owner group created in 2.1."
        );
        _as(owners[0]);
        IBaseMarket(cinderBtc).setLoanToValue(0.45e27);
        _done();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 11 — governor, guardian, keeper
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseGovernance() internal {
        _s(
            "11.1",
            "Governor tunes Boreal: market multiplier 1.5x, term band 1-60 days; Atlas target health 1.3",
            "Governor-only market setters. Outstanding fixed principal does not jump; the multiplier applies to the next term."
        );
        _asDeployer();
        IBaseMarket(boreal).setMarketMultiplier(1.5e27);
        FixedMarket(boreal).setTermLimits(60 days, 1 days);
        IBaseMarket(atlas).setTargetHealth(1.3e27);
        _done();

        _s(
            "11.2",
            "Governor shortens premium vesting: Atlas senior 6h, cUSD 8h; sets a term-multiplier slope",
            "setVestingPeriod checkpoints elapsed vesting first. setTermMultiplierSlope makes longer fixed terms cost more."
        );
        _asDeployer();
        Tranche(atlasTranches[0]).setVestingPeriod(6 hours);
        cusd.setVestingPeriod(8 hours);
        InterestRateModel(infra.irm).setTermMultiplierSlope(0.1e27);
        _done();

        _s(
            "11.3",
            "Guardian tightens Cinder BTC: liquidation threshold 85%, buffer 15%",
            "Guardian-only risk setters. Effective credit is min(LTV, LT - buffer) = min(45%, 70%) so the owner's LTV still binds."
        );
        _asDeployer();
        IBaseMarket(cinderBtc).setLiquidationThreshold(0.85e27);
        IBaseMarket(cinderBtc).setBuffer(0.15e27);
        _done();

        _s(
            "11.4",
            "Keeper reports every pool position",
            "After the price round-trip and the reweights, the keeper refreshes each pool's cached values."
        );
        _asDeployer();
        Underwriter(uwWeth).report(atlasTranches[0]);
        Underwriter(uwWeth).report(borealTranches[0]);
        Underwriter(uwWbtc).report(cinderBtcTranches[0]);
        Underwriter(uwWbtc).report(atlasTranches[2]);
        Underwriter(uwWsteth).report(cinderWstethTranches[0]);
        _done();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Phase 12 — exits and claims
    // ═════════════════════════════════════════════════════════════════════════

    function _phaseExits() internal {
        _s(
            "12.1",
            "Depositor A instantly redeems a quarter of its Atlas senior shares; B queues half",
            "Senior is unlocked because the junior tranches cover Atlas's debt. instantRedeem pays now; requestRedeem queues an ERC-7540 request."
        );
        Tranche senior = Tranche(atlasTranches[0]);
        uint256 aShares = senior.balanceOf(depositors[0].addr) / 4;
        uint256 aInstant = senior.maxInstantRedeem(depositors[0].addr);
        if (aInstant < aShares) aShares = aInstant;
        if (aShares > 0) {
            _as(depositors[0]);
            senior.instantRedeem(aShares, depositors[0].addr, depositors[0].addr);
            _done();
        }
        _as(depositors[1]);
        senior.requestRedeem(senior.balanceOf(depositors[1].addr) / 2, depositors[1].addr, depositors[1].addr);
        _done();

        _s(
            "12.2",
            "Depositor E queues a full exit from the locked Atlas junior tranche",
            "Junior capital backs the debt, so the request stays pending until debt is repaid or capital arrives above it."
        );
        Tranche junior = Tranche(atlasTranches[2]);
        _as(depositors[4]);
        junior.requestRedeem(junior.balanceOf(depositors[4].addr), depositors[4].addr, depositors[4].addr);
        _done();

        _s(
            "12.3",
            "LP B queues a redemption of 5 uwWETH shares from the WETH pool",
            "Pool exits are also ERC-7540: the request fills from idle assets and finalized deallocations."
        );
        _as(lps[1]);
        Underwriter(uwWeth).requestRedeem(5e18, lps[1].addr, lps[1].addr);
        _done();

        _s(
            "12.4",
            "Depositor D unwraps 2,000 stcUSD and instantly redeems 1,000 cUSD for mUSDC; E queues 500 cUSD",
            "stcUSD -> cUSD via the wrapper's ERC-4626 redeem; cUSD -> mUSDC instantly while reserves allow, otherwise queued."
        );
        _as(depositors[3]);
        stcusd.redeem(2_000e18, depositors[3].addr, depositors[3].addr);
        cusd.instantRedeem(1_000e18, depositors[3].addr, depositors[3].addr);
        _done();
        _as(depositors[4]);
        cusd.requestRedeem(500e18, depositors[4].addr, depositors[4].addr);
        _done();

        _s(
            "12.5",
            "Opted-in holders claim premium",
            "claim() pays whatever has vested so far; this early it is small or zero, but the call path is exercised for the UI."
        );
        _as(depositors[0]);
        senior.claim(depositors[0].addr);
        cusd.claim(depositors[0].addr);
        _done();
        _as(depositors[3]);
        cusd.claim(depositors[3].addr);
        _done();
    }
}
