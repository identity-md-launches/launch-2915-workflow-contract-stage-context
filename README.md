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
| `src/UnlockV2Token.sol` | ERC-20 "UNLOCK V2" / "UNLK2", 18 decimals, exactly 1,000,000,000 minted once to the factory. `burn(amount)` is the only extra behaviour; it reports to the hook. No owner, mint, tax, blacklist, seizure, pause or upgrade. |
| `src/UnlockV2Hook.sol` | Official pool gatekeeper: factory-only one-time initialization, trading closed until `activate()`, origin-bucketed sell rights, ten permanent gates, 1% IMD hook fee, on-chain FDV/volume pricing, swarm-claim and migration credits. |
| `src/MigrationVault.sol` | 1 V1 -> 1 V2, V1 locked forever, hard cap 700,000,000, first come first served. No owner, no withdrawal, no deadline. |
| `src/RewardPot.sol` | Non-transferable burn points (1 per UNLK2 burned), seven-day streaming of redeemed IMD fees into the point pot, one claim per weekly epoch per beneficiary. No owner. |

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
(`BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA`
= `0x20CC`). The constructor makes a low-level call to `token.registerHook(factory)`; the token accepts
it only while the factory still holds the entire supply (that is, inside the launch transaction) and
only once. The constructor never requires the token to have code, so launch pre-checks on an empty
chain pass; `isBound()` reports whether the binding succeeded.

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
5. **Activate.** `hook.activate()`. Requirements: official pool initialized by the factory, chain id 1,
   vault fully funded, feed decimals 8, valid IMD/USD and UNLK2/IMD prices. It credits the founder's
   exactly 50m sell-rights allocation to the owner and opens trading.

Liquidity can be added while trading is closed (the hook has no liquidity callbacks). The factory's
fee collection (`modifyLiquidity` with zero delta) is never intercepted.

## Trading rules

**Hook fee.** 1% (`HOOK_FEE_BPS = 100`) of the IMD leg of every official swap, buys and sells,
exact-input and exact-output. It is taken from the IMD side only (beforeSwap return delta when IMD is
the specified currency, afterSwap return delta otherwise), kept as IMD (never swapped to ETH) as an
ERC-6909 claim owned by the hook, and moved to the RewardPot by anyone calling `redeemFees()`.
The pool's own 1.25% LP fee is the launch policy's and is collected by the factory for the owner
(the founder fee recipient).

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
contract's buckets, so all of its users share one allowance (tested in
`test_unregisteredRouterIsOneSharedAccount`). Users should trade through the registered routers.

**Burns.** `UNLK2.burn(amount)` is irreversible, reduces `totalSupply`, credits `amount` points, counts
toward the current gate's burn target and debits credits conservatively. Formula, in order:
pending (unmatured) buys, then held buy credits (`buyCredited - buySold`), then held other credits
(`otherCredited - otherSold`); whatever remains is uncredited balance. Sold counters never change, so
a partially sold holding can end with zero allowance. `previewBurn(account, amount)` returns the exact
debits and the allowance afterwards. Burns can never create or recycle eligibility.

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
Falling prices never relock. Volume accumulates from activation and never resets. Burn targets are per
gate: when a gate opens by burn the excess carries to the next gate; when it opens by FDV or volume the
burn counter for the next gate starts from zero.

**Volume** counts each successful official swap's executed IMD leg (the pool's IMD delta, excluding
the hook fee) once, converted to USD at execution. Repeated same-account trades count. This is gross
volume, not organic demand. Failed swaps, transfers and other pools are excluded.

## On-chain pricing

- IMD/USD = Chainlink ETH/USD (8 decimals, `answer > 0`, `updatedAt` within 90 minutes and not in
  the future, `answeredInRound >= roundId`, decimals checked at activation) divided by IMD-per-ETH from
  the v4 reference pool (native ETH / IMD, fee 10000, tickSpacing 200, hooks zero; `sqrtPriceX96 != 0`
  and positive liquidity required). Chain id must equal `expectedChainId`.
- UNLK2/IMD = the official pool's current `sqrtPriceX96` (either currency order).
- FDV USD = price per UNLK2 in USD times the current `totalSupply()` (locked reserves included, burned
  supply excluded).
- An invalid price (stale feed, reverted feed, uninitialized or empty reference pool, wrong chain)
  skips price and volume progress for that swap only. Trading under already granted rights, migration
  and burns continue. No TWAP or waiting requirement.

**Spot-manipulation disclosure.** Both prices are spot readings. A large swap in the official pool or
in the ETH/IMD reference pool within one transaction moves the observed FDV and the USD value of
volume, and gates once open never close. A deep-pocketed trader can therefore open gates early by
pushing the price (paying the 1.25% LP fee, the 1% hook fee and the price impact); the fuzz test
shows a single large buy can open all gates. This is an accepted property of the requested design.

## Migration

`MigrationVault.migrate(amount)` after approving V1: V1 is pulled and locked forever, V2 is sent 1:1,
the hook credits the `other` bucket. Rejects zero, amounts above the remaining capacity, and amounts
the vault's actual V2 balance cannot back. Works before and after activation. The 700m cap is smaller
than the V1 supply, so not all V1 can migrate (`test_migrate_capCannotCoverEntireV1Supply`). A V1
transfer that delivers less than `amount` (fee-on-transfer) reverts the migration.

## Burn points and weekly rewards

- Points: 1 per UNLK2 burned (18 decimals), non-transferable, never spent.
- `redeemFees()` (anyone) moves the hook's IMD claims to the RewardPot and starts/merges a seven-day
  linear stream. `checkpoint()` (anyone) moves streamed IMD into the point pot pro rata.
- IMD streamed while nobody holds points is carried and goes to the first holders.
- `claim()` sends the caller's accrued IMD to the caller, at most once per weekly epoch (epochs start
  at the pot's deployment). Only each beneficiary can claim their own rewards.

## Chosen constants (brief left open)

| Constant | Value | Where |
| --- | --- | --- |
| Reward stream duration | 7 days | `RewardPot.STREAM_DURATION` |
| Claim epoch length | 7 days | `RewardPot.EPOCH_LENGTH` |
| Buy maturity | 1 block | `UnlockV2Hook._mature` |
| Feed max age | 90 minutes | `UnlockV2Hook.MAX_FEED_AGE` |
| Burn carry rule | excess carries after a burn-opened gate | `UnlockV2Hook._advanceGates` |

## Callbacks implemented and why

`beforeInitialize` (factory-only, exact key, once), `beforeSwap` + `beforeSwapReturnDelta` (trading
gate, trader resolution, fee when IMD is the specified currency), `afterSwap` + `afterSwapReturnDelta`
(fee when IMD is unspecified, sell-right debit / buy credit, price and volume observation). No
liquidity or donate callbacks, so the factory's liquidity and fee collection are never blocked.

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
swarm evidence, reward streaming and weekly claims, gate table, volume/burn gate logic, fuzz
monotonicity).

Run: `forge test` (fuzz seed pinned in `foundry.toml`).
