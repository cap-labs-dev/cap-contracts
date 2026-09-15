"""
capmath.py - exact integer replication of the Cap v2 arithmetic the models depend on.

Every function here mirrors a specific Solidity function, with the same rounding and the same
uint256 overflow behaviour (raises OverflowError where the EVM would revert). All quantities are
Python ints: 1e27 = one ray, 1e18 = one wad / one cUSD.

Sources (contracts/ on branch cap-network):
  WadRayMath.sol            rayMul / rayDiv (half-up, revert on overflow)
  OZ Math.sol               mulDiv floor / ceil (512-bit exact in the EVM; Python ints are exact)
  MathUtils.sol             calculateCompoundedInterest (Aave binomial, 3 terms)
  InterestRateModel.sol     _nextLiquidityRate, termMultiplier, _averagingWeight, _carry, _accrueAverage
  Stablecoin.sol            _convertToAssets, _convertToShares, _opposite, _onWithdraw, unlockedSupply
  BaseMarket.sol            healthiness, maxLiquidatable, recoverableDebt, unrecoverableDebt, lockedValue
  FixedMarket.sol           _premium, _principalWithin
  Tranche.sol               slash (value -> assets at price), KILL_RATIO

Default parameters are taken from contracts/deploy/service/DeployInfra.sol (IRM init
`1e27, 2e27, 1e27, 0.02e27, 1 hours`; Registry lt/buffer/targetHealth 0.8/0.1/1.25) and
test/shared/CapDeployer.sol (ltv 0.5, slopes base 5% / slope0 5% / slope1 10% / kink 80%,
underwriterRate 20%, tranche weights 95/5, max term 30d, min term 1d, grace 1d).
NOTE: DeployInfra never calls setLiquiditySlopes, so a production deploy starts with all slopes
at zero (0% liquidity rate) until governance sets them. The CapDeployer slopes are used here as
the "intended" curve.
"""

RAY = 10**27
HALF_RAY = RAY // 2
WAD = 10**18
UINT256_MAX = 2**256 - 1
SECONDS_PER_YEAR = 365 * 24 * 3600
DAY = 86400
HOUR = 3600

# ---- defaults -------------------------------------------------------------------------------
DEFAULTS = dict(
    lt=int(0.8e27),
    buffer=int(0.1e27),
    ltv=int(0.5e27),
    targetHealth=int(1.25e27),
    liquidationBonus=int(0.02e27),
    averagingPeriod=HOUR,
    minimumMarketMultiplier=RAY,
    maximumMarketMultiplier=2 * RAY,
    maximumUnderwriterRate=RAY,
    underwriterRate=int(0.2e27),
    marketMultiplier=RAY,
    termMultiplierSlope=0,
    base=int(0.05e27),
    slope0=int(0.05e27),
    slope1=int(0.1e27),
    kink=int(0.8e27),
    weights=[RAY - int(0.05e27), int(0.05e27)],
    fixedCreditLimit=1000 * WAD,
    maximumTermLimit=30 * DAY,
    minimumTermLimit=1 * DAY,
    grace=1 * DAY,
    vestingPeriod=6 * HOUR,
    KILL_RATIO=100,
    MINIMUM_AVERAGING_PERIOD=5 * 60,
    MAXIMUM_AVERAGING_PERIOD=DAY,
    DEAD_SHARES=1000,
)


class Revert(Exception):
    """The EVM would revert here (overflow, division by zero, explicit revert)."""


def _u256(x):
    if x < 0 or x > UINT256_MAX:
        raise Revert("uint256 overflow/underflow: %d" % x)
    return x


# ---- WadRayMath -----------------------------------------------------------------------------
def rayMul(a, b):
    # if b != 0 and a > (UINT256_MAX - HALF_RAY) / b: revert
    if b != 0 and a > (UINT256_MAX - HALF_RAY) // b:
        raise Revert("rayMul overflow")
    return (a * b + HALF_RAY) // RAY


def rayDiv(a, b):
    if b == 0 or a > (UINT256_MAX - b // 2) // RAY:
        raise Revert("rayDiv overflow or div by zero")
    return (a * RAY + b // 2) // b


# ---- OZ Math.mulDiv -------------------------------------------------------------------------
FLOOR, CEIL = 0, 1


def mulDiv(a, b, c, rounding=FLOOR):
    if c == 0:
        raise Revert("mulDiv division by zero")
    if rounding == FLOOR:
        r = (a * b) // c
    else:
        r = -((-(a * b)) // c)
    return _u256(r)


def opposite(rounding):
    return FLOOR if rounding == CEIL else CEIL


# ---- MathUtils.calculateCompoundedInterest ---------------------------------------------------
def compounded_interest(rate, exp):
    """Aave 3-term binomial, exactly as MathUtils.sol. Raises Revert on checked overflow."""
    if exp == 0:
        return RAY
    expMinusOne = exp - 1
    expMinusTwo = exp - 2 if exp > 2 else 0
    # unchecked block: rayMul still reverts on overflow inside the assembly guard
    basePowerTwo = rayMul(rate, rate) // (SECONDS_PER_YEAR * SECONDS_PER_YEAR)
    basePowerThree = rayMul(basePowerTwo, rate) // SECONDS_PER_YEAR
    secondTerm = _u256(exp * expMinusOne * basePowerTwo) // 2
    thirdTerm = _u256(exp * expMinusOne * expMinusTwo * basePowerThree) // 6
    return _u256(RAY + _u256(rate * exp) // SECONDS_PER_YEAR + secondTerm + thirdTerm)


def linear_interest(rate, exp):
    return RAY + _u256(rate * exp) // SECONDS_PER_YEAR


# ---- InterestRateModel ----------------------------------------------------------------------
def next_liquidity_rate(utilization, base, slope0, slope1, kink):
    if utilization <= kink:
        ratio = 0 if kink == 0 else rayDiv(utilization, kink)
        return _u256(base + rayMul(slope0, ratio))
    return _u256(base + slope0 + rayMul(slope1, rayDiv(utilization - kink, RAY - kink)))


def liquidity_rate_default(utilization, p=DEFAULTS):
    return next_liquidity_rate(utilization, p["base"], p["slope0"], p["slope1"], p["kink"])


def term_multiplier(termUtilization, termMultiplierSlope):
    if termUtilization >= RAY:
        return RAY
    return _u256(RAY + rayMul(termMultiplierSlope, RAY - termUtilization))


def averaging_weight(elapsed, period):
    return RAY if elapsed >= period else elapsed * RAY // period


def carry(average, observed, weight):
    if observed > average:
        return average + rayMul(observed - average, weight)
    return average - rayMul(average - observed, weight)


class UtilizationAverage:
    """Exact replica of IRM.utilizationAverage state and _accrueAverage."""

    def __init__(self, t0, period):
        self.credit = 0
        self.supply = 0
        self.observedCredit = 0
        self.observedSupply = 0
        self.lastUpdate = t0
        self.period = period

    def accrue(self, now, live_credit, live_supply):
        elapsed = now - self.lastUpdate
        if elapsed > 0:
            w = averaging_weight(elapsed, self.period)
            self.credit = carry(self.credit, self.observedCredit, w)
            self.supply = carry(self.supply, self.observedSupply, w)
            self.lastUpdate = now
        if live_credit != self.observedCredit:
            self.observedCredit = live_credit
        if live_supply != self.observedSupply:
            self.observedSupply = live_supply

    def average_supplies(self, now):
        w = averaging_weight(now - self.lastUpdate, self.period)
        return carry(self.credit, self.observedCredit, w), carry(self.supply, self.observedSupply, w)

    def average_utilization_after_mint(self, now, mint):
        c, s = self.average_supplies(now)
        return ratio(c + mint, s + mint)


def ratio(credit, supply):
    if supply == 0:
        return 0
    return rayDiv(credit, supply)


# ---- Stablecoin haircut curve ---------------------------------------------------------------
class StablecoinState:
    """Minimal Stablecoin state: totalSupply, creditBackedSupply, badDebt, underlying balance."""

    def __init__(self, totalSupply, creditBackedSupply, badDebt, underlyingDecimals, reserve_balance=None):
        self.totalSupply = totalSupply
        self.creditBackedSupply = creditBackedSupply
        self.badDebt = badDebt
        self.dec = underlyingDecimals
        # real underlying held: by construction the reserve equals supply - credit - badDebt in
        # 18dp, scaled down to the underlying's decimals. Caller may override.
        if reserve_balance is None:
            reserve_balance = (totalSupply - creditBackedSupply - badDebt) * 10**self.dec // 10**18
        self.balance = reserve_balance

    # totalAssets / unlockedSupply
    def totalAssets(self):
        return _u256(self.totalSupply - self.badDebt)

    def unlockedSupply(self):
        locked = self.creditBackedSupply + self.badDebt
        return self.totalSupply - locked if self.totalSupply > locked else 0

    def previewDeposit(self, assets):
        return mulDiv(assets, 10**18, 10**self.dec, FLOOR)

    def previewMint(self, shares):
        return mulDiv(shares, 10**self.dec, 10**18, CEIL)

    def _convertToAssets(self, shares, rounding):
        shortfall = self.badDebt
        if shortfall == 0:
            value = shares
        else:
            supply = self.totalSupply
            backing = self.totalAssets()
            if shares >= supply:
                value = backing
            else:
                remaining = supply - shares
                anchor = supply * backing
                retained = mulDiv(remaining, anchor, _u256(anchor + remaining * shortfall), opposite(rounding))
                value = backing - retained if backing > retained else 0
        return mulDiv(value, 10**self.dec, 10**18, rounding)

    def _convertToShares(self, assets, rounding):
        if assets == 0:
            return 0
        value = mulDiv(assets, 10**18, 10**self.dec, rounding)
        shortfall = self.badDebt
        if shortfall == 0:
            return value
        supply = self.totalSupply
        backing = self.totalAssets()
        if value >= backing:
            return supply
        retained = backing - value
        anchor = supply * backing
        remaining = mulDiv(retained, anchor, _u256(anchor - retained * shortfall), opposite(rounding))
        return supply - remaining if supply > remaining else 0

    # ERC4626 preview functions (OZ: previewRedeem = convertToAssets floor, previewWithdraw = convertToShares ceil)
    def previewRedeem(self, shares):
        return self._convertToAssets(shares, FLOOR)

    def previewWithdraw(self, assets):
        return self._convertToShares(assets, CEIL)

    def _onWithdraw(self, assets, shares):
        reduced = 0
        if self.badDebt > 0:
            paidInShares = mulDiv(assets, 10**18, 10**self.dec, FLOOR)
            reduced = shares - paidInShares if shares > paidInShares else 0
            if reduced > self.badDebt:
                reduced = self.badDebt
            self.badDebt -= reduced
        return reduced

    def redeem(self, shares):
        """Instant redeem path: burn shares, pay previewRedeem, run _onWithdraw. Returns assets."""
        if shares > self.unlockedSupply():
            raise Revert("exceeds unlocked supply")
        assets = self.previewRedeem(shares)
        self.totalSupply = _u256(self.totalSupply - shares)
        self._onWithdraw(assets, shares)
        self.balance = _u256(self.balance - assets)
        return assets

    def withdraw(self, assets):
        shares = self.previewWithdraw(assets)
        if shares > self.unlockedSupply():
            raise Revert("exceeds unlocked supply")
        self.totalSupply = _u256(self.totalSupply - shares)
        self._onWithdraw(assets, shares)
        self.balance = _u256(self.balance - assets)
        return shares

    def deposit(self, assets):
        shares = self.previewDeposit(assets)
        self.totalSupply += shares
        self.balance += assets
        return shares

    def copy(self):
        s = StablecoinState.__new__(StablecoinState)
        s.__dict__.update(self.__dict__)
        return s


# ---- BaseMarket ------------------------------------------------------------------------------
def slash_per_debt(bonus):
    return RAY + bonus


def healthiness(totalCapital, debt, lt):
    if debt == 0:
        return RAY
    return rayDiv(rayMul(totalCapital, lt), debt)


def recoverable_debt(totalCapital, bonus):
    return rayDiv(totalCapital, slash_per_debt(bonus))


def unrecoverable_debt(totalCapital, debt, bonus):
    r = recoverable_debt(totalCapital, bonus)
    return debt - r if debt > r else 0


def max_liquidatable(totalCapital, debt, lt, targetHealth, bonus):
    threshold = rayMul(totalCapital, lt)
    if debt <= threshold:
        return 0
    perCleared = _u256(targetHealth - rayMul(slash_per_debt(bonus), lt))
    liquidatable = rayDiv(_u256(rayMul(targetHealth, debt) - threshold), perCleared)
    cap = min(debt, recoverable_debt(totalCapital, bonus))
    return min(liquidatable, cap)


def locked_value(debt, lt, buffer, tranche_capitals, idx):
    """lockedValue for tranche at index idx given capitals ordered senior->junior."""
    value = rayDiv(debt, _u256(lt - buffer))
    i = len(tranche_capitals)
    while i > 0:
        i -= 1
        if i == idx:
            break
        cap = tranche_capitals[i]
        if cap > value:
            return 0
        value -= cap
    return value


def variable_credit_limit(active_capitals, ltv):
    return rayMul(sum(active_capitals), ltv)


# ---- FixedMarket -----------------------------------------------------------------------------
def fixed_premium(chargeableDebt, term, liquidityRate, underwriterRate):
    cumulative = _u256(chargeableDebt * term)
    return (rayMul(cumulative, liquidityRate) // SECONDS_PER_YEAR,
            rayMul(cumulative, underwriterRate) // SECONDS_PER_YEAR)


def principal_within(limit, term, rate):
    return mulDiv(limit, RAY, RAY + (term * rate) // SECONDS_PER_YEAR)


# ---- Tranche ---------------------------------------------------------------------------------
def tranche_slash(value, total_assets, price, decimals=18):
    """Returns (assets_taken, slashedValue) exactly as Tranche.slash."""
    unit = 10**decimals
    assets = value * unit // price
    if assets > total_assets:
        assets = total_assets
        slashedValue = total_assets * price // unit
    else:
        slashedValue = value
    return assets, slashedValue


def fmt_ray(x, digits=4):
    return ("%." + str(digits) + "f") % (x / RAY)


def fmt_usd(x_wad):
    v = x_wad / WAD
    if abs(v) >= 1e9:
        return "$%.2fB" % (v / 1e9)
    if abs(v) >= 1e6:
        return "$%.2fM" % (v / 1e6)
    if abs(v) >= 1e3:
        return "$%.1fk" % (v / 1e3)
    return "$%.2f" % v
