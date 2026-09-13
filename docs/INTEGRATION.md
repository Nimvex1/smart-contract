# Integration guide

## Deployment

1. Set `INITIAL_RECIPIENT` (bootstrap multisig) and `GUARDIAN_ADDRESS` (security
   multisig). Optional overrides are listed in `script/Deploy.s.sol`.
2. `forge script script/Deploy.s.sol --rpc-url <url> --broadcast`. The script
   asserts full wiring and fails loudly on mismatch.
3. Verify roles/parameters against `contracts/DAODeploymentNotes.sol`, then seal
   with `script/Renounce.s.sol` (re-verifies wiring, then renounces the deployer
   timelock admin). See `docs/DEPLOYMENT.md`.

## Governance lifecycle

`propose -> vote (delay + period, blocks) -> queue (timelock delay) -> execute`.
Quorum is snapshot-safe and dynamic: `EnterpriseDAO.quorum(snapshotBlock)` reads
historical total supply; `quorumFractionAtSupply(supply)` exposes the linear ramp
for tooling. Proposal threshold is governance-adjustable within immutable bounds.

Frontend read pattern (2 calls per proposal card):

- `DAOReadHub.proposalCard(proposalId, account)` — snapshot, deadline, state,
  for/against/abstain, quorum required, account snapshot weight, voted flag,
  queuing flag.
- `DAOReadHub.timelockMinDelay()` — queue delay backing execution.

## Treasury lifecycle

Governance (timelock) schedules via `approvePackage(target, value, data, tier,
expiresAt, predecessor)`; anyone executes after the tier quarantine with
`executePackage` / `executePackages`. Guardian may `pause` anytime and
`cancelPackage` only before `executeAfter`; `unpause` and all configuration are
governance-only.

Frontend read pattern (2 calls per treasury view):

- `DAOReadHub.packageStatus(packageId)` — target/value/tier/timing, predecessor
  execution flags, `executable` boolean, `blockedReason` code
  (0 ready, 1 finalized, 2 not-ready, 3 expired, 4 predecessor, 5 paused,
  6 reserve-breach), `secondsToReady`.
- `DAOReadHub.treasurySnapshot()` — ETH balance, native floor, spendable
  headroom, pause state, next nonce, allowlist flag.

Scheduling dry-run and keeper polling:

- `DAOReadHub.schedulePreview(target, value, data, tier)` — the package id that
  scheduling now would produce (exact unless a package interleaves and moves
  the nonce), the quarantine estimate, and cap/allowlist admission.
- `DAOReadHub.timelockStatus(targets, values, calldatas, descriptionHash)` —
  timelock operation id, pending/ready/done flags, scheduled ETA. Poll this
  instead of indexing `CallScheduled` events.

## Treasury accounting

Governance curates an informational asset registry (`registerAsset` /
`deregisterAsset`; registration gates nothing — unregistered tokens deposit
and move identically). Read paths:

- `treasury.registeredAssets()` + `treasury.spendableERC20(token)` (balance
  above the token's floor, clamped at zero — monitoring convenience, not an
  enforcement boundary).
- `DAOReadHub.treasuryPortfolio()` — one-RPC balance/floor/spendable rows for
  every registered asset; pair with `treasurySnapshot()` for the native side.
- Note: reserve floors interact with native value only. ERC721/ERC1155 deposits
  carry no native value and can never breach a floor — there is deliberately no
  floor logic on NFT paths to test or monitor.

## Building proposals

Use `ProposalBuilder` (pure library, no deployment) instead of hand-rolling
calldata: `treasuryPackage` for payments and package scheduling generally,
`configureTier`, `setTargetAllowed`, `setTargetAllowlistEnabled`,
`setNativeReserveFloor`, and `descriptionHash` for the queue/execute hash.
`test/ProposalBuilder.t.sol` proves a built payload through the full
propose -> vote -> queue -> execute path.

## Vesting lifecycle

`create(beneficiary, token, amount, start, cliff, duration, revocable)` pulls
funds from the caller via allowance — no pre-funding step, no dust account.
`claim` is permissionless (anyone may poke it; funds go to the beneficiary);
`claimable`/`vested` views and `VestingCreated/VestedClaimed/VestingRevoked`
events feed frontends and indexers. Only the funding `msg.sender` may `revoke`,
and only the unvested portion returns — vested pay is never clawed back.

Funding from the treasury takes two packages executed atomically via
`executePackages` with predecessor ordering: (1) `token.approve(vesting,
amount)`, (2) `vesting.create(...)` (the timelock must first approve the
vesting contract to pull, which package 1 does). A multisig funder simply
approves and calls `create` directly.

## Staking lifecycle

Deploy `DAOStaking(stakingToken, rewardsToken, timelock, duration)` with the
timelock as owner, so every privileged action passes governance. Fund each
epoch from the treasury: package 1 transfers reward tokens to the staking
contract, package 2 (predecessor: package 1) calls `notifyRewardAmount` —
leftover from a live epoch rolls over automatically, and underfunded epochs
revert instead of stranding stakers. Users `stake` / `withdraw` / `getReward`
/ `exit` directly; claims are permissionless pokes.

Two facts frontends must surface before anyone stakes: (1) staked tokens earn
but do not vote — the pool never delegates, so voting power pauses until
withdrawal; (2) durations change only between epochs, so a live rate never
shifts under stakers. External DeFi (lending, AMMs) is intentionally not built
here: interact with audited protocols through allowlisted treasury packages
instead.

## Token lifecycle

`DAOGovernanceToken` is fixed-supply, minted once to the bootstrap recipient.
Distribute, then each holder `delegate`s (self or another) to activate checkpoint
voting power; the Governor reads historical power at proposal snapshots, so
post-snapshot acquisitions never count. `burn` is permissionless on own balance
and reduces supply (quorum implications are tested in `GovernanceAttack.t.sol`).

## Event consumption (indexers)

- Governance: standard OpenZeppelin Governor/Timelock events
  (`ProposalCreated/Canceled/Executed`, `CallScheduled/Executed`).
- Treasury execution: `PackageApprovedV2`, `PackageExecuted`,
  `PackagesBatchExecuted`, `PackageCancelled`, `PackageExpired`.
- Treasury custody: `NativeDeposited`, `ERC20Deposited`, `ERC721Deposited`,
  `ERC1155Deposited`.
- Administration: `TierConfigured`, `TargetAllowlistToggled/Updated`,
  `ReserveFloorsConfigured`, `ERC20ReserveFloorConfigured` (informational, see
  below), `TreasuryPaused/Unpaused`.

`erc20ReserveFloors` values are governance-published monitoring thresholds, NOT
on-chain controls — the only on-chain reserve check is the native floor in
`_executePackage`. Indexers should alert on them; frontends must not present
them as enforced guarantees. Full grouped catalog: `docs/EVENTS.md`.

## Worked flows

Runnable in-process equivalents live in `test/Examples.t.sol` (one command:
`forge test --match-contract ExamplesTest`):

- Flow A (treasury): fund -> propose payment -> vote -> queue -> timelock-execute
  -> package-execute -> payee paid.
- Flow B (configuration): propose reserve-floor change -> vote -> queue ->
  execute -> floor updated.
- Flow C (distribution): allocate -> delegate -> verify snapshot voting power.

Live-chain step-by-step commands: `docs/CAST.md`.
