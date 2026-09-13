# Runbook — Enterprise DAO operations

## Incident checklist (any suspected compromise)

1. Triage: identify the component (guardian key, timelock admin, governor
   capture, malicious package, failing target). Read `DAOReadHub` cards, not
   raw storage: `packageStatus` (blocked reason), `proposalCard` (state/votes),
   `treasurySnapshot` (balances/pause).
2. Contain: guardian `pause()` halts package execution and deposits
   (`cast send $TREASURY "pause()"`). Scheduling stays open so governance can
   keep preparing responses during the incident.
3. Decide the recovery path below. There is NO emergency fund-movement power —
   every recovery except quarantine-cancel and pause goes through a full
   proposal + timelock delay by design.
4. Communicate: publish the proposal id / package id and the expected
   timestamps (`executeAfter`, timelock ETA) so holders can verify independently.

## Treasury freeze / escalation
- Freeze: guardian multisig calls `pause()`. Effect is DoS-only and reversible
  exclusively by governance (`unpause` is `GOVERNANCE_ROLE`-only).
- Escalate: pass a governance proposal that cancels the dangerous package,
  reconfigures tiers/allowlist/floors, or rotates `GUARDIAN_ROLE` membership
  (treasury is self-administered; role changes are governance-mediated).
- A compromised guardian can only pause and cancel pre-`executeAfter` packages;
  post-quarantine packages still execute. Do not treat a guardian incident as a
  fund-theft incident.

## Guardian key lost (fail-safe, routine — NOT an incident)

Losing the guardian key costs the pause capability but nothing else: a dead
guardian cannot steal (it never could), cannot block governance, and cannot
stop already-approved post-quarantine packages. Governance, execution, and
deposits continue normally.

1. Elect a replacement multisig off-chain.
2. Pass one governance proposal that `grantRole(GUARDIAN_ROLE, new)` and
   `revokeRole(GUARDIAN_ROLE, old)` on the treasury (self-administered path,
   batched with predecessor ordering).
3. Priority: next regular governance cycle. Do NOT freeze, do NOT escalate —
   there is nothing to contain.

Contrast with *compromised* guardian (above): expect pause/cancel spam, do not
try to out-pause it on-chain, rotate via the same proposal path, and rely on
post-quarantine executability throughout.

## Keeper guidance: batch execution
- **Chunk at ≤10 packages per `executePackages` call**, trivial calldata only
  per batch. Anchor (measured, `test_BatchScalesLinearlyForKeeperChunking`):
  approving + executing 10 simple packages totals ~2.4M gas — more than 10x
  headroom on a 30M-gas block. One heavy target can still starve a batch
  (atomic rollback keeps state safe but burns the keeper's gas).
- Poll `DAOReadHub.packageStatus` per entry and skip non-`READY` ones
  client-side rather than letting the batch revert on them.
- On revert, retry entries individually to isolate the bad one, then re-batch
  the survivors.

## Staking epoch funding

- Fund each epoch with the two-package pattern (transfer then
  `notifyRewardAmount` with predecessor ordering); verify `RewardAdded`
  against the transfer amount — a mismatch means the epoch is mispriced.
- Never schedule `notifyRewardAmount` without its funding transfer in the same
  batch: it reverts (`RewardTooHigh`), which is safe but wastes a governance
  cycle.
- `setRewardsDuration` only takes effect between epochs; scheduling it
  mid-epoch reverts (`PeriodActive`) by design, not malfunction.

## Suspicious governance activity

- Unknown proposal near threshold/quorum parameters: vote against, prepare a
  cancelling proposal, alert holders. Remember the delay ladder (voting period
  + timelock delay + tier quarantine) is the last line of defense — use the
  time.
- `TierConfigured` relaxing delays/caps, allowlist disabled, or native floor
  lowered outside a known proposal: treat as high-severity, follow the freeze
  path above.

## Failed execution

- `ExecutionFailed(packageId, reason)`: the package is NOT marked executed and
  can be retried (permissionless). Diagnose the target (reverting logic, missing
  funds/approvals, gas-guzzling callee), fix the underlying condition, retry.
- Repeated failure with no path forward: governance `cancelPackage`, then
  schedule a corrected package.
- Batch (`executePackages`) is atomic: one failing entry rolls back the whole
  batch. Retry entries individually to isolate the bad one.

## Expired / stuck operations

- Past `expiresAt`: anyone calls `closeExpiredPackage` (emits `PackageExpired`).
- Successor of a cancelled predecessor: anyone calls `closeStuckPackage`
  (emits `PackageCancelled`). If it reverts with `PredecessorNotExecuted`, the
  package is not stuck — wait for the predecessor or check `packageStatus`.
- `closeExpiredPackage` on a live package reverts with `PackageNotExpired`
  (distinct from execution-path `PackageNotReady`).

## Deployment verification checklist

See `docs/DEPLOYMENT.md` sections 2–3. Never fund before the
`Renounce.s.sol` sealed state (`AdminNotHeld` on re-run).
