> This copy supersedes the root README.md for the burn, contribution, fee, reward and pricing sections
> (the root file is outside this contribution's write scope and still describes the earlier reward pot
> and spot-only gate pricing).

# UNLOCK V2 (UNLK2) — token, hook, migration vault, burn points and weekly rewards

Ethereum (chain id 1) Uniswap v4 custom-token launch. The launch factory deploys two contracts,
`UnlockV2Token` and `UnlockV2Hook`; the hook's constructor creates the `MigrationVault` and the
`RewardPot` and exposes them through `migrationVault()` and `rewardPot()`.

Foundry project at the repository root: `forge build`, `forge test`, `forge fmt --check`.
Compiler pinned to `solc = "0.8.26"`, `via_ir`, `bytecode_hash = "none"`. All dependencies are
vendored as plain files under `lib/` (Uniswap v4-core, OpenZeppelin v5.1, forge-std, a minimal
solmate `Owned` used only by the test PoolManager).

## Contracts

| Contract | Role |
| --- | --- |
| `src/UnlockV2Token.sol` | ERC-20 "UNLOCK V2" / "UNLK2", 18 decimals, exactly 1,000,000,000 minted once to the factory. `burn(amount)` (voluntary burn) and `contribute(expectedGate, amount)` (gate contribution) are the only extra behaviour; both report to the hook. No owner, mint, tax, blacklist, seizure, pause or upgrade. |
| `src/UnlockV2Hook.sol` | Official pool gatekeeper: factory-only one-time initialization, trading closed until `activate()`, origin-bucketed sell rights, ten permanent gates, 1% IMD hook fee, on-chain FDV/volume pricing, swarm-claim and migration credits. |
| `src/MigrationVault.sol` | 1 V1 -> 1 V2, V1 locked forever, hard cap 700,000,000, first come first served. No owner, no withdrawal, no deadline. |
| `src/RewardPot.sol` | Non-transferable burn points (1 per UNLK2 burned, 18-decimal precision). Reward fees attributed when earned; pre-point pot released linearly over 7 days from the first point; entitlements mature in 7-day epochs from activation and never expire. No owner. |

ABI exports: `docs/abi/<Contract>.json`.

## Constructor arguments (launch manifest)

`UnlockV2Token` takes no arguments. It mints the supply to `msg.sender` (the factory) and records it
as `factory()`.

`UnlockV2Hook(poolManager, token, imd, factory, owner, v1Token, ethUsdFeed, expectedChainId)`:

| # | Argument | Value |
| --- | --- | --- |
| 1 | `poolManager_` | `$poolManager` |
| 2 | `token_` | `$token` |
| 3 | `imd_` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (IMD, Ethereum) |
| 4 | `factory_` | `$factory` |
| 5 | `owner_` | `$owner` (resolves to `0x48e4e74fe1d0c14404ceb57b9fec5b21329c6ec9`) |
| 6 | `v1Token_` | `0x99fa82b022be4575891a43b757bc770691e18fda` (UNLOCK V1) |
| 7 | `ethUsdFeed_` | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` (Chainlink ETH/USD, 8 decimals) |
| 8 | `expectedChainId_` | `1` |

The hook must be deployed at an address whose low bits equal `requiredAddressFlags()`
(`BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA |
AFTER_SWAP_RETURNS_DELTA` = `0x28CC`; the manifest's permissions list must name `beforeAddLiquidity` as
well). The constructor makes a low-level call to `token.registerHook(factory)`; the token accepts
it only while the factory still holds the entire supply (that is, inside the launch transaction) and
only once. The constructor never requires the token to have code, so launch pre-checks on an empty
chain pass; `isBound()` reports whether the binding succeeded, and `activate()` refuses
(`HookNotBound`) unless `token.hook()` is this hook, so a launch whose binding failed or was taken by a
stranger can never be sealed.

Pool: `pool.pairedCurrency` IMD, `pool.fee` 12500, `pool.tickSpacing` 60, hooks = the hook. The hook's
`beforeInitialize` accepts exactly this key (either currency order), only from the factory, only once.

## Allocation and funding (conservation)

| Share | Amount | Path |
| --- | --- | --- |
| Pool | 150,000,000 (poolBps 1500) | factory seeds the pool |
| Native swarm | 100,000,000 | factory sends to the launch MerkleDistributor |
| Migration reserve | 700,000,000 | owner receives it inside the 750m remainder and transfers it to `migrationVault()` before activation |
| Founder | 50,000,000 | stays with the owner; credited as sell rights at activation |

`allocation()` returns the four constants; the test `test_allocationSumsToSupply` checks they sum to
the supply. `activate()` refuses until `migrationVault.remainingBacking() >= remainingCapacity()`
(700m before any migration). The vault's actual balance is the backing, never a promise.
No contract here can withdraw migration principal or participant rewards.

## Owner setup guide ("After launch")

Everything below is owner-only and must happen before `activate()`. Activation seals the hook
forever: afterwards no setter works and nothing is owner-controlled.

1. **Fund the migration vault.** From the owner wallet: `UNLK2.transfer(hook.migrationVault(), 700_000_000e18)`.
   Check `migrationVault.isFullyFunded()` is true.
2. **Register supported routers.** `hook.setRouter(router, true)` for each standard router that exposes
   `msgSender()` (Uniswap Universal Router on Ethereum, the v4 periphery `V4Router`). Get the addresses
   from Uniswap's published deployments for chain 1. Swaps through unregistered contracts are attributed
   to that contract (see "Shared-account limitation").
3. **Set the swarm distributor.** `hook.setSwarmDistributor(distributor)` with the launch's
   MerkleDistributor address, read from the launch record. It must expose `merkleRoot()` and
   `isClaimed(index)` with Uniswap's leaf format `keccak256(abi.encodePacked(index, account, amount))`.
   If the launch's distributor differs, swarm claims cannot be credited; set it correctly before sealing.
4. **Check references.** `hook.isReferenceAvailable()` must be true: the ETH/IMD v4 reference pool
   (PoolId `0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3`, verified in
   `test_referencePoolIdMatchesMainnet`) initialized with positive liquidity and the Chainlink feed fresh.
5. **Activate.** `hook.activate()`. Requirements: `token.hook()` is this hook (`isBound()`), official
   pool initialized by the factory, chain id 1, vault fully funded, feed decimals 8, valid IMD/USD and
   UNLK2/IMD prices. It credits the founder's exactly 50m sell-rights allocation to the owner (less any
   UNLK2 the owner burned uncredited before activation, see "Burns") and opens trading. It does not check
   that a swarm distributor or a router is set: an activation without them is permanent (no swarm claim
   can ever be credited; every swap is attributed to its router contract), so check steps 2 and 3 first.

**Liquidity.** While trading is closed anyone may add liquidity to the official pool (the launch's own
seeding, however the factory routes it). After activation only the factory itself (the direct caller of
`PoolManager.modifyLiquidity`) may add; any other adder is refused (`LiquidityRestricted`). Otherwise a
holder with 0% sell rights could park UNLK2 as a token-only range order just above the price, let buyers
swap through it and remove it as IMD: an unmetered exit from the official pool. Removal, including the
factory's zero-delta fee collection, is never intercepted, whoever the sender is. Liquidity that third
parties added before activation is not metered either; the owner can read the pool's liquidity before
sealing. Third-party pools remain outside these quotas, as the workflow states.

## Trading rules

**Fees.** Two fees with different bases. They do not simply add up to 2.25%.

1. **Pool LP fee 1.25%** (`pool.fee` 12500 pips, unchanged): the launch policy's fee, split by the
   launch as 1% founder (the owner) + 0.25% platform (`feeSchedule()`). Uniswap v4 charges it inside
   the pool on the swap's *input* currency (IMD on buys, UNLK2 on sells), rounded up per step by the
   pool math. The factory collects it; this code never touches it.
2. **Reward fee exactly 1%** (`HOOK_FEE_BPS = 100`), added by the hook, replacing NFT purchases. Always
   IMD, never converted to ETH, owned only by burn-point holders (contributors), never by the owner.
   `hookFee(x) = floor(x * 100 / 10000)` (rounded down; below 100 wei of IMD it is 0). Its base `x` per
   swap shape:

| Swap shape | Reward-fee base `x` | Trader | Pool IMD leg |
| --- | --- | --- | --- |
| exact-input buy (pay X IMD) | X, the trader's gross IMD input | pays X | swaps `X - fee` (LP fee taken from this) |
| exact-output buy (receive T UNLK2) | Z, the pool's IMD input incl. LP fee | pays `Z + fee` | Z |
| exact-input sell (pay T UNLK2) | Z, the pool's IMD output after the LP fee on T | receives `Z - fee` | Z |
| exact-output sell (receive Y IMD) | Y, the trader's requested IMD | receives Y | delivers `Y + fee` |

Effective cost against a fee-free swap at the same price, ignoring price impact and rounding:
exact-input shapes `1 - 0.99 * 0.9875 = 2.2375%`; exact-output shapes `1.01 / 0.9875 - 1 ≈ 2.2785%`.
`test_feeBases_twinPoolComparison` proves the bases against a hookless twin pool with identical price
and liquidity: an exact-input buy of X through the official pool returns exactly what `X - floor(X/100)`
returns in the twin, and an exact-input sell returns exactly `Z - floor(Z/100)` of the twin's output Z.

**Partial fills.** A swap stops early at its `sqrtPriceLimitX96` or when in-range liquidity runs out.
For the two shapes whose fee is taken up front on the requested amount (exact-input buy, exact-output
sell), Uniswap v4 cannot adjust the specified-side delta afterwards, so the hook recomputes the fee in
`afterSwap` as `floor(E / 100)` of the executed pool IMD leg `E` and returns the difference to the
trader (`PartialFillRefunded`): the trader's wallet receives the refund directly through
`PoolManager.take`, outside the router's own settlement, so a router that checks its own balances does
not see it. For a swap through an unregistered contract the refund goes to that contract, like its
credits. The pot is only ever attributed the recomputed fee. The other two shapes already use the
executed leg. The effective fee is therefore never above 1% of the executed IMD leg
(`testFuzz_partialFillFeeNeverExceedsOnePercentOfExecuted`).

The reward fee is minted to the hook as an ERC-6909 IMD claim inside the swap and attributed to the
RewardPot in the same call (`RewardPot.onFeeAccrued`). Anyone may later call `redeemFees()` to move the
IMD itself into the RewardPot; `claim()` redeems automatically when the pot holds too little. Anyone can
mint or transfer extra ERC-6909 IMD claims to the hook's address; `redeemFees()` attributes such a
surplus as an ordinary reward fee (`SurplusClaimsAttributed`) before moving it, so a gift of 1 wei cannot
make redemption or claims revert, and the gift belongs to the points holders.

**Sell rights (official pool only).** Each account has separate buckets:

- `buy`: UNLK2 bought in the official pool, credited to the authenticated trader, matures one block later.
- `other`: migrated tokens, verified swarm claims, the founder's 50m.

Before gate 1 the buy bucket may sell 20% cumulative, the other bucket 0%. From gate g on, every bucket
uses the gate's percentage. Allowance per bucket = `pct * credited / 100 - sold`, floored at zero; a
sale debits the buy bucket first. Sales are cumulative and never reset. Balance alone and plain
transfers create no rights. Gate 10 bypasses every quota check for every holder, including
uncredited tokens. These quotas govern the official pool; third-party pools are not prevented.

**Trader authentication.** If the swap's `sender` is a registered router, the trader is
`IMsgSender(sender).msgSender()`; otherwise the trader is the `sender` contract itself. `hookData` is
never trusted.

**Shared-account limitation.** A swap through an unregistered contract credits and debits that
contract's buckets, so all of its users share one allowance: one user's buy creates allowance another
user can spend (tested in `test_unregisteredRouterIsOneSharedAccount`). Users should trade through the
registered routers. Registration ends at activation, so a router deployed later can never be added and
its users share one bucket until gate 10. Register only routers whose `msgSender()` is known to report
the real caller.

**Credits belong to accounts, not tokens.** Rights are counters on the account and transfers do not move
them (there is no transfer hook). An account that sends its tokens away keeps its allowance and can later
sell tokens it receives from anyone, including tokens that earned no credit. The receiver of a transfer
never gains eligibility, and total official-pool selling stays bounded by the sum of credits times the
unlocked percentage, so this is not an aggregate quota bypass
(`test_creditedAccountCanSellTokensReceivedFromOthers`).

**Burns.** Two burn paths, both irreversible (never refunded), both reduce `totalSupply`, credit `amount`
burn points and debit sell credits conservatively. Any holding origin may burn (credited or not).

- `UNLK2.contribute(expectedGate, amount)`: a gate contribution. Counts toward the burn target of the gate
  currently collecting burns. The whole call reverts and nothing is burned if `expectedGate` is not that
  gate (`StaleGate`: e.g. the gate opened by FDV/volume or by other contributors in the meantime), if
  `amount` is above what the gate still needs (`ExceedsGateRemaining`; read `hook.contributionQuote()`
  for `(expectedGate, maxAmount)`), if `amount` is 0, or once gate 10 is open (`GoldenVaultOpen`).
  Excess is never silently burned into a later gate.
- `UNLK2.burn(amount)`: a voluntary burn. Earns points, never counts toward a gate. After gate 10 (the
  Golden Vault) this is the only burn: no more locks or gates, burns keep earning points.

Debit formula, in order:
pending (unmatured) buys, then held buy credits (`buyCredited - buySold`), then held other credits
(`otherCredited - otherSold`); whatever remains is uncredited balance and is recorded in
`uncreditedBurned[account]`. Sold counters never change, so a partially sold holding can end with zero
allowance. `previewBurn(account, amount)` returns the exact debits and the allowance afterwards.

Two credits are recorded later than the tokens arrive: a native swarm claim (credited by
`creditSwarmClaim`, anyone may submit the evidence at any time) and the founder's 50m (credited at
`activate()`). Each is netted against `uncreditedBurned` first (`CreditNetted`): burning before the
credit is recorded gives exactly the same rights as burning after it, so the call order cannot keep a
credit alive for tokens that no longer exist. Migration credits are recorded in the same call as the
tokens and are not netted. Burns can never create or recycle eligibility.

## Gates

| gate | unlocked % | FDV USD | cumulative official USD volume | burn target for this gate |
| --- | --- | --- | --- | --- |
| 1 | 25 | 250,000 | 125,000 | 25,000,000 |
| 2 | 30 | 500,000 | 375,000 | 22,000,000 |
| 3 | 35 | 1,000,000 | 750,000 | 19,000,000 |
| 4 | 40 | 2,000,000 | 1,500,000 | 16,000,000 |
| 5 | 50 | 3,500,000 | 2,500,000 | 13,000,000 |
| 6 | 60 | 5,000,000 | 4,000,000 | 10,000,000 |
| 7 | 70 | 8,000,000 | 6,000,000 | 8,000,000 |
| 8 | 80 | 12,000,000 | 9,000,000 | 6,000,000 |
| 9 | 90 | 18,000,000 | 12,500,000 | 4,000,000 |
| 10 | 100 | 25,000,000 | 20,000,000 | 2,000,000 |

Any one threshold opens its gate, forever. Gates open sequentially; one observation can open several.
FDV is read once per block, before that block's first official swap (see "On-chain pricing"), so a buy
that lifts the FDV opens its gates on the first swap of a later block, not in its own swap. Volume and
contributions open gates immediately. Falling prices never relock. Volume accumulates from activation and never resets. Burn targets are per
gate and only contributions count (`gateBurned`; `totalBurned` counts every burn). A contribution can
never exceed the open gate's remainder, so a burn-opened gate leaves nothing to carry; when a gate opens
by FDV or volume the next gate's burn counter starts from zero. Contributions already made are not
refunded and their points survive.

**Volume** counts each successful official swap's executed IMD leg (the pool's IMD delta, excluding
the hook fee) once, converted to USD at execution with the gate IMD price below. Repeated same-account trades count. This is gross
volume, not organic demand. Failed swaps, transfers and other pools are excluded.

## On-chain pricing

- Spot IMD/USD (`imdUsdPrice()`) = Chainlink ETH/USD (8 decimals, `answer > 0`, `updatedAt` within 90
  minutes and not in the future, `answeredInRound >= roundId`, decimals checked at activation) divided by
  IMD-per-ETH from the v4 reference pool (native ETH / IMD, fee 10000, tickSpacing 200, hooks zero;
  `sqrtPriceX96 != 0` and positive liquidity required). Chain id must equal `expectedChainId`.
- Gate IMD/USD (`gateImdUsdPrice()`, used for FDV gates and volume) = the same formula with IMD-per-ETH
  replaced by the larger of the pool's spot and a rate-limited tracker (`trackedImdPerEth`). The tracker is
  seeded at activation and updated by swaps. It moves toward spot by at most 5% per hour of elapsed time
  (`REFERENCE_MOVE_BPS_PER_HOUR`), and one update can use at most 4 hours (`REFERENCE_MAX_GAP`), so at most
  20%. The allowed move is computed at 1e18 precision (`RATE_PRECISION`), so a 12-second gap allows 1.67 bps
  rather than a floored 1 bp: an update every block follows a held price at the same rate as sparse
  updates. Each bound is relative to the previous tracked value, so many small updates compound to at most
  (1 + 1/6000)^300 ≈ 5.13% per hour. IMD is therefore never valued above spot: a fall counts at once, a
  rise counts only as fast as the tracker follows. The Chainlink ETH/USD part is not rate limited.
- UNLK2/IMD = the official pool's `sqrtPriceX96` (either currency order).
- FDV USD = price per UNLK2 in USD times the current `totalSupply()` (locked reserves included, burned
  supply excluded).
- **When FDV is read.** Once per block (`lastFdvBlock`), at the start of that block's first official swap,
  before the swap moves the price. All official swaps pass through this hook, so that reading is the price
  the previous block left. `lastFdvUsd` records it. `fdvUsd()` and `imdUsdPrice()` are informational spot
  views and do not drive gates. There is no TWAP and no waiting period, and one reading can open several
  gates. The swap that triggers the reading is judged under the gates it opened. If no swap follows, the
  gate opens with the next swap. `sellAllowance()` and `contributionQuote()` report the stored gate count;
  `pendingGatesOpen()` previews the count the block's first swap will be judged under. A frontend quoting
  a sell or a contribution in a block that has not traded yet should read `pendingGatesOpen()` first: a
  contribution quoted for gate N reverts `StaleGate` if that reading opens gate N before it lands.
- An invalid price (stale feed, reverted feed, uninitialized or empty reference pool, wrong chain)
  skips price and volume progress for that swap only. Trading under already granted rights, migration
  and burns continue. The IMD leg of a swap made during an outage is not counted later, because no valid
  USD price existed at its execution and the brief converts at execution. Gross volume therefore
  undercounts during outages and never overcounts.

**Manipulation disclosure.** A price spike that is undone within one block cannot open an FDV gate
(`test/Manipulation.t.sol`), in either pool. What remains:

- *Holding across a block boundary.* A buy left in place until the next block's first swap is a valid
  reading and can open every gate up to gate 10, permanently, after which all quotas are gone. The buyer
  can then sell back. That needs real capital rather than a flash loan, and the position is exposed to the
  market for that one block, but a trader controlling consecutive blocks carries little of that risk. The
  brief asks for no TWAP or minimum duration, so none was added; deeper official liquidity raises the cost.
  Measured on the test fixture by the independent review: one exact-input buy that sweeps the in-range
  liquidity, held for one block, then sold back, costs the swap fees of a few hundred IMD plus the
  one-block market exposure (the partial-fill fee that made up most of the measured 10,111 IMD is now
  refunded). Concentrated factory liquidity makes it cheaper, since past the range the price moves for
  free. **This is a requester decision before release if a longer holding rule is wanted.**
- *Repeated reference-pool pressure.* Pushing the reference pool at every update moves the tracker at most
  5% per hour, so reaching a 100x valuation takes about 94 hours of sustained, fee-paying pressure while
  ordinary swaps pull the tracker back. One update after a quiet period can move it 20%.
- *Griefing and lag.* Pushing IMD down in the reference pool lowers the valuation for that swap and pulls
  the tracker the same bounded way, delaying FDV and volume progress, not opening anything. After a real
  IMD rise, valuations lag spot, so gates can open later than spot implies, never earlier.
- *Activation.* The tracker seed is the reference spot at `activate()`. A swap bundled around that one
  transaction could skew the seed; the tracker then corrects at its normal rate.
- *Wash volume.* Repeated fee-paying trades count by design, so the volume path can be bought at the cost
  of fees (about 2.24% of the volume per swap at current fee rates). It is labelled gross volume.

## Migration

`MigrationVault.migrate(amount)` after approving V1: V1 is pulled and locked forever, V2 is sent 1:1,
the hook credits the `other` bucket. Rejects zero, amounts above the remaining capacity, and amounts
the vault's actual V2 balance cannot back. Works before and after activation. The 700m cap is smaller
than the V1 supply, so not all V1 can migrate (`test_migrate_capCannotCoverEntireV1Supply`). A V1
transfer that delivers less than `amount` (fee-on-transfer) reverts the migration.

## Burn points and weekly rewards (`RewardPot`)

- **Points**: 1 point per UNLK2 burned (18 decimals, fractions kept), non-transferable, never spent.
  Points share all future reward fees indefinitely, also after gate 10. Later points dilute only fees
  earned after they exist. No yield or return is promised: rewards are only whatever 1% fees future
  trading produces.
- **Attribution when earned**: every reward fee is attributed in the swap that earns it
  (`onFeeAccrued`), before any redemption. A late `redeemFees()` only moves IMD; it cannot hand old
  earnings to new points (`test_delayedRedemptionCannotGiveOldFeesToNewPoints`).
- **Pre-point pot**: fees earned while no point exists are kept separately (`prePointPot`). The first
  point (`firstPointTime`) starts a linear 7-day release: `released(t) = prePointPot * min(t - firstPointTime, 7 days) / 7 days`.
  Each released slice is split among the points present during that slice; the pot checkpoints before
  every point change, so the first burner does not receive the pot at once and a later burner shares
  only the slices after their burn.
- **After the first point**: each fee is split immediately among the points present: `accRewardPerPoint += fee * 1e36 / totalPoints`.
- **Epochs**: 7 days each, epoch 0 starts at `hook.activate()`. Entitlement accrued during a closed epoch
  is claimable; what accrued in the current epoch is shown as maturing (`rewardsOf(account)` returns
  `(claimableNow, maturing)`). Unclaimed rewards never expire. No end-of-week balance snapshot and no
  retroactive rewards: a burner earns only from the moment of the burn.
- **Gas**: O(1) per action. One global accumulator plus its value at the start of the current epoch
  (`accAtEpochStart`), written by the first checkpoint of each epoch, which first releases the
  pre-point pot up to the exact boundary. No loop over holders or epochs.
- **Claims**: `claim()` pays only `msg.sender` its own matured entitlement; a second claim with nothing
  new matured reverts `NothingToClaim`. Guarded against reentrancy, state updated before transfer. If the
  pot holds too little redeemed IMD it first calls the hook's permissionless `redeemFees()`.
- **No owner access**: the pot has no owner, no rescue and no withdrawal other than `claim()`.
  `addPoints`, `onFeeAccrued`, `onRedeemed` and `activate` are callable only by the hook. The owner
  earns rewards only as any other burner would, by burning its own tokens.

**Solvency.** Four separate counters: `totalAccrued` (fees attributed), `totalVested` (allocated to
points: direct fees plus released pre-point pot), `totalRedeemed` (IMD moved in from the PoolManager),
`totalPaid` (IMD claimed). Invariants, checked after every step of `testFuzz_rewardsConservedAndSolvent`:
`paid <= vested <= accrued`, `redeemed <= accrued` (enforced in `onRedeemed`),
`accrued - redeemed <= hook.pendingFees()` (equal except between a third party's claim gift and the next
redemption, which attributes the gift), `IMD held >= redeemed - paid`, hence
`IMD held + pending claims >= accrued - paid` (`isSolvent()`), and the sum of all entitlements never
exceeds `vested` (rounding is down, dust stays in the pot). `solvency()` returns all of them.

## Chosen constants (brief left open)

| Constant | Value | Where |
| --- | --- | --- |
| Pre-point pot release | 7 days (brief) | `RewardPot.RELEASE_DURATION` |
| Reward epoch length | 7 days from activation (brief) | `RewardPot.EPOCH_LENGTH` |
| Reward accumulator precision | 1e36 | `RewardPot.ACC_PRECISION` |
| Buy maturity | 1 block | `UnlockV2Hook._mature` |
| Feed max age | 90 minutes | `UnlockV2Hook.MAX_FEED_AGE` |
| Reference tracker rate | 5% per hour | `UnlockV2Hook.REFERENCE_MOVE_BPS_PER_HOUR` |
| Reference tracker longest gap per update | 4 hours (so 20% at most) | `UnlockV2Hook.REFERENCE_MAX_GAP` |
| Reference tracker move precision | 1e18 (fractional basis points kept) | `UnlockV2Hook.RATE_PRECISION` |
| Liquidity after activation | factory only | `UnlockV2Hook.beforeAddLiquidity` |
| FDV reading | once per block, before its first swap | `UnlockV2Hook._observeSettledFdv` |
| Burn carry rule | none: excess contributions are rejected | `UnlockV2Hook.onContribute` |

## Callbacks implemented and why

`beforeInitialize` (factory-only, exact key, once), `beforeAddLiquidity` (open before activation,
factory-only after it), `beforeSwap` + `beforeSwapReturnDelta` (trading gate, trader resolution, fee when
IMD is the specified currency), `afterSwap` + `afterSwapReturnDelta` (fee when IMD is unspecified,
partial-fill fee correction, sell-right debit / buy credit, volume observation). `beforeSwap` also takes
the block's FDV reading. No remove-liquidity or donate callbacks, so the factory's fee collection and
withdrawals are never blocked.

## Assumptions and operational responsibilities

- IMD is a plain 18-decimal ERC-20 that allows `PoolManager.take` to the RewardPot; the hook never
  pulls IMD out of the PoolManager during a swap.
- The launch MerkleDistributor follows Uniswap's interface and leaf format; otherwise swarm claims
  cannot be credited (set the right address before sealing).
- Registered routers truthfully report `msgSender()`; a malicious registered router could misattribute
  rights, so register only Uniswap's audited routers.
- The owner funds 700m to the vault, registers routers, sets the distributor and activates. After
  sealing nobody can change anything; a wrong setting is permanent.
- Chainlink or the reference pool failing only pauses gate progress by price/volume. Burn progress is
  unaffected.
- Tests pass does not equal an audit. An independent adversarial review is required before release.
- Not implemented here: website, publishing, deployment transactions (IMD's deployer launches through
  the factory; nothing here signs or broadcasts).

## Tests

`test/Token.t.sol` (supply, transfers wallet/contract, hook binding, burns), `test/Launch.t.sol`
(reference PoolId, permissions, factory-only initialization, wrong keys, closed trading, activation
requirements and sealing, pricing validity), `test/Trading.t.sol` (fee on all four swap shapes, fee
redemption, maturity, 20% pre-gate allowance, transfers grant nothing, migrated 0%, router
authentication, shared account, FDV multi-gate crossing, invalid prices, volume accounting, burn gates
and gate-10 bypass, burn debit formula, fuzz), `test/Companions.t.sol` (migration success/failure/cap,
swarm evidence, gate table, volume/burn gate logic, fuzz monotonicity), `test/Rewards.t.sol`
(pre-point pot and its 7-day release, epoch-boundary split, immediate accrual, no retroactive rewards,
delayed redemption, epoch maturity, no expiry, auto-redemption on claim, beneficiary-only claims and
hook-only bookkeeping, contribution stale-gate/excess/zero/race/FDV cases, Golden Vault, fee bases
against a hookless twin pool, fuzzed conservation and solvency), `test/Manipulation.t.sol` (spikes inside
one block open nothing, a price held across a block opens several gates at once, reference-pool spikes do
not inflate FDV or volume, tracker rate and 20% cap, per-block tracker rate, IMD falls counted at once,
feed outage, credits per account), `test/Revision.t.sol` (surplus ERC-6909 claims cannot block redemption
or claims, partial fills of the up-front-fee shapes, liquidity provision after activation, activation of
an unbound hook refused, swarm and founder credits netted against earlier uncredited burns, migration
credits not netted, the gate preview view).

Run: `forge test` (fuzz seed pinned in `foundry.toml`).
