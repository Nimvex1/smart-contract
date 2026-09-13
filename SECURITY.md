# Security Model — Enterprise DAO Ecosystem

This document is the formal threat model for the system. It answers, for every
privileged component: **who can move funds, under what conditions, what each
emergency actor can and cannot do, and what happens if that actor is compromised.**

## Upgradeability: none, by design

There is no upgrade path. Contracts contain no proxies, no `delegatecall`, and
no admin upgrade keys; governor parameters are welded as immutables and the
treasury is self-administered with role changes gated behind governance
itself. Patching a bug or shipping a feature means deploying a new instance
and migrating via the normal governance path (see `docs/DEPLOYMENT.md` §0).
This is intentional: an upgrade key would be a strictly more powerful version
of the timelock-admin capture this architecture is built to prevent.

## System topology

```
Token holders
     │  (vote)
     ▼
EnterpriseDAO (Governor)
     │  (queue + execute proposals)
     ▼
TimelockController  ──holds──▶ GOVERNANCE_ROLE on Treasury
     │                                   ▲
     │                                   │ GUARDIAN_ROLE
     ▼                                   │
DAOTreasuryExecutionEngine ◀──────── Guardian multisig
     │  (packages: delayed, permissionless execution)
     ▼
Arbitrary targets (calls + native value)
```

**Funds movement is only possible through a chain that requires:**
1. A proposal that passes the governor (dynamic quorum + majority of cast votes),
2. The timelock delay elapsing (default 2 days),
3. The treasury tier quarantine delay elapsing (1–14 days by tier),
4. Then *anyone* may execute the package.

The shortest possible path from "decision" to "funds move" is therefore
`voting period + 2 days + tier delay`. No single key can shortcut it.

## Who can move funds

| Actor | Can move funds directly? | Conditions |
|---|---|---|
| Token holder | No | Can only vote / propose |
| Governor | No | Only via timelock operations |
| Timelock | Only indirectly | Executes passed proposals after delay |
| Treasury GOVERNANCE_ROLE (the timelock) | No | Only *schedules* packages (funds move at permissionless execution) |
| Guardian | **No** | Has zero fund-movement authority (see below) |
| Random address | No | May only *execute* already-approved packages after all delays |
| Deployer | No (post-bootstrap) | Must renounce admin on the timelock |

## Privileged components and compromise analysis

### 1. The Guardian (multisig)

**Powers:**
- `pause()` — halt package execution and deposits, any time.
- `cancelPackage(id)` — cancel a package, **only before its `executeAfter`** (the quarantine window).

**Cannot:**
- Move, withdraw, or redirect funds.
- Unpause (`unpause()` is GOVERNANCE_ROLE-only, i.e. requires a full proposal + timelock delay).
- Cancel after the quarantine window closes.
- Configure tiers, thresholds, or the allowlist.
- Grant or revoke any role.

**If compromised, worst case:**
- Denial-of-service: pause the treasury and cancel fresh packages. Funds are **not
  at risk of theft**, but withdrawals halt until governance (which the guardian cannot
  stop) unpauses. Post-quarantine cancellation is impossible, so any package whose
  window has elapsed still executes.

**Mitigations:** time-bound window (`GuardianCancelWindowClosed`), pause/unpause split,
zero custody, all powers reviewed above are tested in `TreasuryFuzz.t.sol` and
`TreasuryInvariant.t.sol`.

### 2. The Timelock (TimelockController)

- Holds `GOVERNANCE_ROLE` on the treasury; it is the *only* scheduler of packages.
- `EXECUTOR_ROLE` is open (`address(0)`): anyone can execute a *ready* timelock
  operation — this is a liveness feature, not a power grant.
- Initially administered by the deployer; the deployer **must renounce**
  `DEFAULT_ADMIN_ROLE` after bootstrap (see `DAODeploymentNotes.sol`).

**If compromised (e.g. admin key never renounced):**
- An attacker controlling the timelock admin can schedule arbitrary treasury
  packages. Each package still waits out its tier delay (1–14 days), giving the
  community a detection window, but the funds are ultimately movable.
- This is why renunciation is the mandatory final deployment step and is asserted
  in the deploy script's checklist output.

### 3. The Governor

- Proposal threshold is bounded by immutable min/max; quorum parameters are immutable.
- `setProposalThreshold` is `onlyGovernance` and clamped to the immutable bounds
  (fix for the v1 access-control regression — see README).
- Dynamic quorum is snapshot-safe: `getPastTotalSupply` is used, so flash-loan /
  same-block supply manipulation cannot lower a live proposal's quorum
  (tested in `GovernanceAttack.t.sol`).

**If 50% of voting power is captured:**
- The attacker can pass any proposal but still waits out the timelock + tier delays;
  the delay ladder is the last line of defense. Tiers cap native value per package
  (5–250 ETH), and the destination allowlist + reserve floors can be pre-configured
  to bound the blast radius even under full capture.

### 4. Treasury tier configuration

- Only GOVERNANCE_ROLE (the timelock). Delays capped at `MAX_TIER_DELAY = 365 days`;
  value caps are arbitrary but set at construction.
- **Optional destination allowlist:** once enabled, packages may only target
  allowlisted addresses — a hard containment boundary.
- **Asset registry (`registerAsset` / `deregisterAsset`, governance-only):**
  purely informational accounting scope for portfolio views; registration gates
  no custody or execution path, so a malicious entry can at worst distort a
  frontend row, never move funds.
- **Optional native reserve floor:** execution that would drop the ETH balance below
  the floor reverts (`ReserveFloorBreached`).
- **Per-token ERC20 reserve floors** are stored on-chain and intended for
  off-chain monitoring (the treasury cannot generically parse arbitrary target
  calldata to enforce them on-chain).

## Package lifecycle guarantees

For every package id, exactly one of the following is true at any time:
`Pending → (Executed | Cancelled | Expired)` — finality is exclusive
(`PackageAlreadyFinalized`). Scheduling additionally guarantees: non-zero
`expiresAt` lies within `MAX_PACKAGE_EXPIRY` of approval
(`ExpiryHorizonTooLong`), and a predecessor must exist and not be cancelled
(`PredecessorCancelled`). Successors stuck behind a cancelled predecessor are
finalizable by anyone via `closeStuckPackage` (emits `PackageCancelled`);
expired packages via `closeExpiredPackage` (emits `PackageExpired`). Invariants (see `TreasuryInvariant.t.sol`):

1. An executed package can **never** execute again.
2. A cancelled package can **never** execute.
3. An expired package (`expiresAt` passed) can **never** execute; anyone may finalize
   it via `closeExpiredPackage`.
4. A package with a predecessor can only execute after the predecessor executed.
5. Only GOVERNANCE_ROLE can ever create a package — no other path exists
   (fuzzed across every account).
6. Package ids commit to `(contract, target, value, calldata hash, tier, nonce)` —
   substitution or replay of any field produces a different, unknown id.

## Failure modes and responses

| Failure | Effect | Response |
|---|---|---|
| Guardian key theft | DoS only (pause/cancel window) | Rotate GUARDIAN_ROLE via governance; wait out quarantine |
| Timelock admin not renounced | Ultimate power retained by deployer | Renounce immediately (asserted at deploy) |
| Malicious token deposited | Token-side accounting lies | Treasury never trusts token balances for control flow; SafeERC20 for transfers |
| Reentrant target | Attempted double execution | `nonReentrant` on execute paths; tested with a reentering target |
| Gas-griefing target | Package execution reverts | Execution is permissionless and retryable; `executed` flag rolls back on failure |
| Quorum flash-loan | Same-block supply swing | Snapshot-safe quorum via historical checkpoints |
| Expired package confusion | Stale calldata executed | Explicit `expiresAt` deadline checked before execution; `MAX_PACKAGE_EXPIRY` bounds the horizon at scheduling |
| Cancelled-predecessor successor | Permanently stuck package | Rejected at scheduling (`PredecessorCancelled`); pre-existing cases closable by anyone (`closeStuckPackage`) |

## Out-of-scope components (no privileges)
`DAOReadHub` (view-only, no storage/roles/funds), `ProposalBuilder` (pure
library, inlined), and `DAOStreamVesting` (standalone schedules whose only
trust boundary is funder <-> beneficiary; revocation returns solely unvested
tokens to the funder and can never claw back vested pay) hold no DAO roles and
cannot move treasury funds. A vesting schedule's revoker is its funding
`msg.sender`, never a global admin.

`DAOStaking` is timelock-owned, so its privileged surface is governance-gated
by construction: the owner can fund epochs, retarget durations between epochs,
and rescue non-staked tokens — and cannot move user stakes (no such function
exists). Stakers accept suspended voting power while staked (the pool never
delegates); principal is always withdrawable by its owner.

## Audit posture

This repository contains extensive adversarial tests (fuzzing, invariants,
malicious-token suites, governance attack simulations) but **has not undergone a
professional third-party audit**. Before deploying real assets:
1. Commission an independent audit of these exact commits.
2. Run `forge test --profile ci` and Slither in CI (both are wired).
3. Review the deployment checklist in `contracts/DAODeploymentNotes.sol`.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to the repository maintainers.
Do not open public issues for exploitable findings.
