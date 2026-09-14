"""
capmath.py - exact integer replicas of the Cap v2 arithmetic at HEAD a843c1d (branch cap-network).

Every function mirrors one Solidity function with the same rounding and the same uint256 revert
behaviour (Revert is raised where the EVM would revert; shifts are unchecked, as in Solidity).
Quantities are Python ints: 1e27 = one ray, 1e18 = one wad / one cUSD. Line numbers cite HEAD.

Sources:
  contracts/utils/WadRayMath.sol      rayMul L58-65, rayDiv L72-79, rayPow L96-105, rayPowRay L114-123,
                                      rayLn L128-149, rayExp L154-167
  contracts/utils/MathUtils.sol       calculateCompoundedInterest L43-78 (Aave 3-term binomial)
  contracts/cap/InterestRateModel.sol _nextLiquidityRate L297-306, termMultiplier L167-171,
                                      _setAveragingPeriod L195-203, _averagingWeight L270-272, _carry L279-283,
                                      averageSupplies L206-211, unsmoothedCredit L220-224,
                                      averageUtilizationAfterMint L227-239, fixedRatesAfterMint L156-164,
                                      _index L311-317, bounds: kink L111, bonus L181, averaging L196
  contracts/cap/market/BaseMarket.sol healthiness L230-234, maxLiquidatable L245-255, recoverableDebt L258-260,
                                      unrecoverableDebt L263-267, lockedValue L270-289 (ceil), _liquidate L353-376,
                                      _chargePremium L435-475, _earnsPremium L482-485, variableCreditLimit L315-322
  contracts/cap/market/FloatingMarket.sol _growIndex L195-202, _premium L215-227, _borrowWithin L148-154,
                                      _repayWithin L159-167, index L139-143, totalDebt L116-118
  contracts/cap/market/FixedMarket.sol _premium L391-399, _principalWithin L294-296, _borrowPremium L337-351,
                                      _ratesStillToMint L255-263, _rollFromNow L314-319, extend L92-110,
                                      extendAdmin L113-124, availableCredit(term) L186-208
  contracts/cap/Stablecoin.sol        unlockedSupply L184-192 (capped by on-hand balance), backing L195-197,
                                      _convertToAssets L236-261, _convertToShares L267-287, _onWithdraw L320-330,
                                      recognizeBadDebtInReserve L152-156, recognizeBadDebtInCredit L159-167
  contracts/cap/Tranche.sol           slash L71-95 (floor-to-zero passes on), unlockedSupply L163-174 (ceil x2),
                                      totalCapital L177-181, KILL_RATIO L39
  contracts/cap/Underwriter.sol       _mark L187-203, totalAssets L243-245 (stale book), report L213-215 (KEEPER)
  contracts/utils/PremiumVesting.sol  VESTING_PERIOD L27 (12 h), _vested L311-316, _weight L329-332
  OZ 5.7.0 ERC4626Upgradeable         _convertToShares L259-261, _convertToAssets L266-268 (offset 0)

Deploy defaults: script/deploy/service/DeployInfra.sol L88-93 (IRM init 1e27, 2e27, 1e27, 0.02e27, 1 hours)
and L168-170 (Registry lt 0.8 / buffer 0.1 / targetHealth 1.25). NO liquidity slopes, term multiplier
slope, underwriter rate or ltv are set by any deploy script: the production curve is base 0 / slope0 0 /
slope1 0 until GOVERNOR calls setLiquiditySlopes. The values below marked HARNESS come from
test/shared/CapDeployer.sol L113-133 and are applied only when `applyLiquiditySlopes` is true.
"""

RAY = 10**27
HALF_RAY = RAY // 2
WAD = 10**18
UINT256_MAX = 2**256 - 1
SECONDS_PER_YEAR = 365 * 24 * 3600
DAY = 86400
HOUR = 3600
LN2_RAY = 693147180559945309417232121
VESTING_PERIOD = 12 * HOUR

DEFAULTS = dict(
    lt=int(0.8e27), buffer=int(0.1e27), targetHealth=int(1.25e27),          # DeployInfra (Registry)
    liquidationBonus=int(0.02e27), averagingPeriod=HOUR,                     # DeployInfra (IRM)
    minimumMarketMultiplier=RAY, maximumMarketMultiplier=2 * RAY, maximumUnderwriterRate=RAY,
    ltv=int(0.5e27), underwriterRate=int(0.2e27), marketMultiplier=RAY,     # HARNESS
    base=int(0.05e27), slope0=int(0.05e27), slope1=int(0.1e27), kink=int(0.8e27),  # HARNESS
    termMultiplierSlope=0, weights=[RAY - int(0.05e27), int(0.05e27)],       # HARNESS
    maximumTermLimit=30 * DAY, minimumTermLimit=1 * DAY, grace=1 * DAY,     # HARNESS
    KILL_RATIO=100, MINIMUM_AVERAGING_PERIOD=5 * 60, MAXIMUM_AVERAGING_PERIOD=DAY, DEAD_SHARES=1000,
)


class Revert(Exception):
    """The EVM would revert here."""


def _u256(x):
    if x < 0 or x > UINT256_MAX:
        raise Revert("uint256 out of range: %d" % x)
    return x


# ---- WadRayMath ------------------------------------------------------------------------------
def rayMul(a, b):
    """WadRayMath.rayMul L58-65: half-up, reverts if a > (max - HALF_RAY)/b."""
    if b != 0 and a > (UINT256_MAX - HALF_RAY) // b:
        raise Revert("rayMul overflow")
    return (a * b + HALF_RAY) // RAY


def rayDiv(a, b):
    """WadRayMath.rayDiv L72-79: half-up, reverts on b == 0 or overflow."""
    if b == 0 or a > (UINT256_MAX - b // 2) // RAY:
        raise Revert("rayDiv overflow or div by zero")
    return (a * RAY + b // 2) // b


FLOOR, CEIL = 0, 1


def mulDiv(a, b, c, rounding=FLOOR):
    """OZ Math.mulDiv (512-bit exact); reverts on c == 0 or result > uint256."""
    if c == 0:
        raise Revert("mulDiv division by zero")
    r = (a * b) // c if rounding == FLOOR else -((-(a * b)) // c)
    return _u256(r)


def opposite(rounding):
    return FLOOR if rounding == CEIL else CEIL


def ray_pow(a, n):
    """WadRayMath.rayPow L96-105: square-and-multiply, half-up per step, final squaring skipped."""
    c = RAY
    while n > 0:
        if n & 1 == 1:
            c = rayMul(c, a)
        n >>= 1
        if n > 0:
            a = rayMul(a, a)
    return c


def ray_ln(x):
    """WadRayMath.rayLn L128-149: artanh series after halving onto [1,2); 0 for x <= RAY."""
    if x <= RAY:
        return 0
    k = 0
    while x >= 2 * RAY:
        x //= 2
        k += 1
    z = x - RAY
    v = mulDiv(z, RAY, 2 * RAY + z)
    v2 = rayMul(v, v)
    term, s = v, v
    n = 3
    while n < 64:
        term = rayMul(term, v2)
        if term < n:
            break
        s += term // n
        n += 2
    return 2 * s + k * LN2_RAY


def ray_exp(x):
    """WadRayMath.rayExp L154-167: Taylor on x mod ln2, then `exp <<= k` (UNCHECKED shift, wraps)."""
    if x == 0:
        return RAY
    k, r = divmod(x, LN2_RAY)
    e, term = RAY, RAY
    for n in range(1, 48):
        term = mulDiv(term, r, n * RAY)
        if term == 0:
            break
        e += term
    return (e << k) & UINT256_MAX


def ray_pow_ray(base, exp):
    """WadRayMath.rayPowRay L114-123: base^exp, both ray."""
    if exp == 0 or base == RAY:
        return RAY
    if exp == RAY:
        return base
    integer, frac = divmod(exp, RAY)
    c = RAY if integer == 0 else ray_pow(base, integer)
    if frac == 0:
        return c
    return rayMul(c, ray_exp(rayMul(frac, ray_ln(base))))


# ---- MathUtils -------------------------------------------------------------------------------
def compounded_interest(rate, exp):
    """MathUtils.calculateCompoundedInterest L43-78. rate*exp, secondTerm, thirdTerm are checked."""
    if exp == 0:
        return RAY
    expMinusOne = exp - 1
    expMinusTwo = exp - 2 if exp > 2 else 0
    basePowerTwo = rayMul(rate, rate) // (SECONDS_PER_YEAR * SECONDS_PER_YEAR)
    basePowerThree = rayMul(basePowerTwo, rate) // SECONDS_PER_YEAR
    secondTerm = _u256(exp * expMinusOne * basePowerTwo) // 2
    thirdTerm = _u256(exp * expMinusOne * expMinusTwo * basePowerThree) // 6
    return _u256(RAY + _u256(rate * exp) // SECONDS_PER_YEAR + secondTerm + thirdTerm)


# ---- InterestRateModel -----------------------------------------------------------------------
def next_liquidity_rate(u, base, slope0, slope1, kink):
    """IRM._nextLiquidityRate L297-306."""
    if u <= kink:
        ratio = 0 if kink == 0 else rayDiv(u, kink)
        return _u256(base + rayMul(slope0, ratio))
    return _u256(base + slope0 + rayMul(slope1, rayDiv(u - kink, RAY - kink)))


def liquidity_rate_default(u, p=DEFAULTS):
    return next_liquidity_rate(u, p["base"], p["slope0"], p["slope1"], p["kink"])


def term_multiplier(termUtilization, slope):
    """IRM.termMultiplier L167-171: 1 + slope*(1 - term/maxTerm); 1 at or beyond the max term."""
    if termUtilization >= RAY:
        return RAY
    return _u256(RAY + rayMul(slope, RAY - termUtilization))


def retention_per_second(period):
    """IRM._setAveragingPeriod L201: 1e27 - 1e27/period."""
    return RAY - RAY // period


def averaging_weight(elapsed, period):
    """IRM._averagingWeight L270-272: 1 - retention^elapsed (~0.632 after one period)."""
    return RAY - ray_pow(retention_per_second(period), elapsed)


def carry(average, observed, weight):
    """IRM._carry L279-283."""
    if observed > average:
        return average + rayMul(observed - average, weight)
    return average - rayMul(average - observed, weight)


def ratio(credit, supply):
    """IRM._ratio L289-292 / Stablecoin._utilizationRate L146-149."""
    return 0 if supply == 0 else rayDiv(credit, supply)


class UtilizationAverage:
    """IRM.utilizationAverage + _accrueAverage L251-265 + the HEAD after-mint rule L227-239."""

    def __init__(self, t0, period):
        self.credit = self.supply = self.observedCredit = self.observedSupply = 0
        self.lastUpdate, self.period = t0, period

    def accrue(self, now, live_credit, live_supply):
        elapsed = now - self.lastUpdate
        if elapsed > 0:
            w = averaging_weight(elapsed, self.period)
            self.credit = carry(self.credit, self.observedCredit, w)
            self.supply = carry(self.supply, self.observedSupply, w)
            self.lastUpdate = now
        self.observedCredit, self.observedSupply = live_credit, live_supply

    def average_supplies(self, now):
        w = averaging_weight(now - self.lastUpdate, self.period)
        return carry(self.credit, self.observedCredit, w), carry(self.supply, self.observedSupply, w)

    def unsmoothed_credit(self, now, live_credit):
        """IRM.unsmoothedCredit L220-224: live credit not yet absorbed into the average."""
        c, _ = self.average_supplies(now)
        return live_credit - c if live_credit > c else 0

    def average_utilization_after_mint(self, now, live_credit, mint):
        """IRM.averageUtilizationAfterMint L227-239: unabsorbed CREDIT is added to both sides;
        reserve-only moves (deposits) are not."""
        c, s = self.average_supplies(now)
        if live_credit > c:
            extra = live_credit - c
            c += extra
            s += extra
        return ratio(c + mint, s + mint)


def fixed_liquidity_rate(avg_util, term, p=DEFAULTS):
    """IRM.fixedRatesAfterMint L156-164 liquidity leg, then FixedMarket._ratesStillToMint L262
    multiplies by marketMultiplier LINEARLY (rayMul) - the fixed market does not use the exponent."""
    projected = liquidity_rate_default(avg_util, p)
    tu = rayDiv(term, p["maximumTermLimit"])
    return rayMul(rayMul(projected, term_multiplier(tu, p["termMultiplierSlope"])), p["marketMultiplier"])


# ---- FloatingMarket --------------------------------------------------------------------------
def grow_index(lastLocal, lastGlobal, globalNow, multiplier):
    """FloatingMarket._growIndex L195-202: local *= (globalNow/lastGlobal) ^ multiplier."""
    if lastGlobal == 0 or globalNow <= lastGlobal:
        return lastLocal
    return rayMul(lastLocal, ray_pow_ray(rayDiv(globalNow, lastGlobal), multiplier))


def floating_premium(scaled, prevLiq, prevUw, curLiq, curUw):
    """FloatingMarket._premium L215-227: difference of three half-up valuations."""
    previous = rayMul(scaled, rayMul(prevLiq, prevUw))
    afterLiq = rayMul(scaled, rayMul(curLiq, prevUw))
    current = rayMul(scaled, rayMul(curLiq, curUw))
    return _u256(afterLiq - previous), _u256(current - afterLiq)


# ---- FixedMarket -----------------------------------------------------------------------------
def fixed_premium(chargeableDebt, term, liquidityRate, underwriterRate):
    """FixedMarket._premium L391-399: linear, per-second prorated."""
    cumulative = _u256(chargeableDebt * term)
    return rayMul(cumulative, liquidityRate) // SECONDS_PER_YEAR, rayMul(cumulative, underwriterRate) // SECONDS_PER_YEAR


def principal_within(limit, term, rate):
    """FixedMarket._principalWithin L294-296."""
    return mulDiv(limit, RAY, RAY + (term * rate) // SECONDS_PER_YEAR)


def borrow_premium(prior, principal, term, rate_after, rate_before, uw_rate):
    """FixedMarket._borrowPremium L337-351: f(prior + principal) at the after-mint rate minus f(prior)
    at the no-mint rate; `prior` is IRM.unsmoothedCredit (global, any market, any type)."""
    liq, uw = fixed_premium(prior + principal, term, rate_after, uw_rate)
    if prior == 0:
        return liq, uw
    liq0, uw0 = fixed_premium(prior, term, rate_before, uw_rate)
    return (liq - liq0 if liq > liq0 else 0), (uw - uw0 if uw > uw0 else 0)


# ---- BaseMarket ------------------------------------------------------------------------------
def slash_per_debt(bonus):
    return RAY + bonus


def healthiness(K, debt, lt):
    """BaseMarket.healthiness L230-234."""
    return RAY if debt == 0 else rayDiv(rayMul(K, lt), debt)


def recoverable_debt(K, bonus):
    """BaseMarket.recoverableDebt L258-260."""
    return rayDiv(K, slash_per_debt(bonus))


def unrecoverable_debt(K, debt, bonus):
    """BaseMarket.unrecoverableDebt L263-267."""
    r = recoverable_debt(K, bonus)
    return debt - r if debt > r else 0


def max_liquidatable(K, debt, lt, targetHealth, bonus):
    """BaseMarket.maxLiquidatable L245-255."""
    threshold = rayMul(K, lt)
    if debt <= threshold:
        return 0
    perCleared = _u256(targetHealth - rayMul(slash_per_debt(bonus), lt))
    liq = rayDiv(_u256(rayMul(targetHealth, debt) - threshold), perCleared)
    return min(liq, min(debt, recoverable_debt(K, bonus)))


def locked_value(debt, lt, buffer, capitals, idx):
    """BaseMarket.lockedValue L270-289: ceil(debt/(lt-buffer)) minus every tranche junior to idx."""
    if debt == 0:
        return 0
    value = mulDiv(debt, RAY, _u256(lt - buffer), CEIL)
    i = len(capitals)
    while i > 0:
        i -= 1
        if i == idx:
            break
        if capitals[i] > value:
            return 0
        value -= capitals[i]
    return value


def liquidate(tranches, repaid, bonus):
    """BaseMarket._liquidate L360-373 waterfall: slash junior-first, each tranche reports delivered
    value, remainder passes on. Returns (slashed per tranche senior->junior, uncollected dust)."""
    toSlash = rayMul(repaid, slash_per_debt(bonus))
    out = [0] * len(tranches)
    for i in range(len(tranches) - 1, -1, -1):
        got = tranches[i].slash(toSlash)
        out[i] = got
        toSlash -= got
        if toSlash == 0:
            break
    return out, toSlash


def charge_underwriter_premium(uw, weights, earns):
    """BaseMarket._chargePremium L445-474: juniors take weight*uw if _earnsPremium, senior takes the
    rest if it earns, else the rest vests on the stablecoin. Returns list per tranche + stablecoin."""
    remaining, seniorActive, out = uw, False, [0] * len(weights)
    for i, w in enumerate(weights):
        if not earns[i]:
            continue
        if i == 0:
            seniorActive = True
            continue
        prem = min(rayMul(uw, w), remaining)
        if prem == 0:
            continue
        remaining -= prem
        out[i] = prem
    to_stable = 0
    if remaining:
        if seniorActive:
            out[0] += remaining
        else:
            to_stable = remaining
    return out, to_stable


# ---- Tranche ---------------------------------------------------------------------------------
class TrancheState:
    """Tranche at HEAD: ERC-4626 over Vault balance (OZ conversions, offset 0), slash L71-95,
    unlockedSupply L163-174, totalCapital L177-181. `price` is USD per token in 18 dec."""

    def __init__(self, assets, price, decimals=18, supply=None, staked=None):
        self.assets, self.price, self.dec = assets, price, decimals
        self.supply = assets if supply is None else supply
        self.staked = self.supply if staked is None else staked
        self.killed = False

    @property
    def unit(self):
        return 10 ** self.dec

    def total_capital(self):
        return 0 if self.assets == 0 else self.assets * self.price // self.unit

    def convert_to_assets(self, shares, rounding=FLOOR):
        return mulDiv(shares, self.assets + 1, self.supply + 1, rounding)

    def convert_to_shares(self, assets, rounding=FLOOR):
        return mulDiv(assets, self.supply + 1, self.assets + 1, rounding)

    def slash(self, value):
        total = self.assets
        if total == 0:
            return 0
        assets = mulDiv(value, self.unit, self.price)
        if assets > total:
            assets = total
        slashedValue = mulDiv(assets, self.price, self.unit)
        if slashedValue == 0:
            return 0
        if not self.killed and self.supply > (total - assets) * DEFAULTS["KILL_RATIO"]:
            self.killed = True
        self.assets -= assets
        return slashedValue

    def unlocked_supply(self, locked):
        if locked == 0:
            return self.supply
        lockedAssets = mulDiv(locked, self.unit, self.price, CEIL)
        lockedShares = self.convert_to_shares(lockedAssets, CEIL)
        return self.supply - lockedShares if self.supply > lockedShares else 0

    def earns_premium(self):
        """BaseMarket._earnsPremium L482-485."""
        return self.staked > 0 and self.total_capital() > 0


# ---- Stablecoin ------------------------------------------------------------------------------
class StablecoinState:
    """Stablecoin at HEAD. totalSupply / creditBackedSupply / badDebt in 18 dec; `balance` is
    underlying ON HAND (underlying decimals); `invested` is in the Aera reserveVault (invisible)."""

    def __init__(self, totalSupply, creditBackedSupply, badDebt, dec, balance=None, invested=0):
        self.totalSupply, self.creditBackedSupply, self.badDebt, self.dec = totalSupply, creditBackedSupply, badDebt, dec
        reserve = (totalSupply - creditBackedSupply - badDebt) * 10**dec // 10**18
        self.balance = reserve - invested if balance is None else balance
        self.invested = invested

    def backing(self):
        return _u256(self.totalSupply - self.badDebt)

    def unlockedSupply(self):
        locked = self.creditBackedSupply + self.badDebt
        unlocked = self.totalSupply - locked if self.totalSupply > locked else 0
        available = self._convertToShares(self.balance, CEIL)
        return min(unlocked, available)

    def _convertToAssets(self, shares, rounding):
        shortfall = self.badDebt
        if shortfall == 0:
            value = shares
        else:
            supply, recognized = self.totalSupply, self.backing()
            if shares >= supply:
                value = recognized
            else:
                remaining = supply - shares
                anchor = supply * recognized
                retained = mulDiv(remaining, anchor, anchor + remaining * shortfall, opposite(rounding))
                value = recognized - retained if recognized > retained else 0
        return mulDiv(value, 10**self.dec, 10**18, rounding)

    def _convertToShares(self, assets, rounding):
        if assets == 0:
            return 0
        value = mulDiv(assets, 10**18, 10**self.dec, rounding)
        shortfall = self.badDebt
        if shortfall == 0:
            return value
        supply, recognized = self.totalSupply, self.backing()
        if value >= recognized:
            return supply
        retained = recognized - value
        anchor = supply * recognized
        remaining = mulDiv(retained, anchor, anchor - retained * shortfall, opposite(rounding))
        return supply - remaining if supply > remaining else 0

    def previewRedeem(self, shares):
        return self._convertToAssets(shares, FLOOR)

    def _onWithdraw(self, assets, shares):
        if self.badDebt > 0:
            paidInShares = mulDiv(assets, 10**18, 10**self.dec)
            reduced = shares - paidInShares if shares > paidInShares else 0
            self.badDebt -= min(reduced, self.badDebt)

    def redeem(self, shares):
        if shares > self.unlockedSupply():
            raise Revert("exceeds unlockedSupply")
        assets = self.previewRedeem(shares)
        self.totalSupply -= shares
        self._onWithdraw(assets, shares)
        self.balance -= assets
        return assets

    def deposit(self, assets):
        shares = mulDiv(assets, 10**18, 10**self.dec, FLOOR)
        self.totalSupply += shares
        self.balance += assets
        return shares

    def recognize_in_reserve(self, amount):
        """L152-156: badDebt += amount; creditBackedSupply untouched -> unlockedSupply falls by amount."""
        self.badDebt += amount
        if self.badDebt > self.totalSupply:
            raise Revert("BadDebtExceedsSupply")

    def recognize_in_credit(self, amount):
        """L159-167: badDebt += amount; creditBackedSupply -= amount -> unlockedSupply unchanged."""
        self.badDebt += amount
        if self.badDebt > self.totalSupply:
            raise Revert("BadDebtExceedsSupply")
        self.creditBackedSupply -= amount

    def copy(self):
        s = StablecoinState.__new__(StablecoinState)
        s.__dict__.update(self.__dict__)
        return s


# ---- PremiumVesting --------------------------------------------------------------------------
def vesting_weight(elapsed):
    """PremiumVesting._weight L329-332 with VESTING_PERIOD = 12 h."""
    return RAY - ray_pow(RAY - RAY // VESTING_PERIOD, elapsed)


def vested(remainder, elapsed):
    """PremiumVesting._vested L311-316."""
    w = vesting_weight(elapsed)
    return 0 if w == 0 else remainder * w // RAY


# ---- formatting ------------------------------------------------------------------------------
def fmt_ray(x, d=4):
    return ("%." + str(d) + "f") % (x / RAY)


def fmt_usd(x):
    v = x / WAD
    if abs(v) >= 1e9:
        return "$%.2fB" % (v / 1e9)
    if abs(v) >= 1e6:
        return "$%.2fM" % (v / 1e6)
    if abs(v) >= 1e3:
        return "$%.1fk" % (v / 1e3)
    return "$%.2f" % v
