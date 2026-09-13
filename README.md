# Enterprise DAO Toolkit — Governor, Timelock Treasury, Read Hub

Production-oriented DAO stack: dynamic-quorum governor, quarantined treasury engine, stateless read hub, scripts, examples, and runbooks.

Solidity 0.8.24 / OpenZeppelin 5.1.0 / Foundry v1.8.1 / MIT. Not formally audited — see [SECURITY.md](SECURITY.md).

## Features

| Area | What you get |
| --- | --- |
| Governance | `EnterpriseDAO` governor with snapshot-safe linear dynamic quorum, bounded proposal threshold, timelock execution |
| Treasury ops | `DAOTreasuryExecutionEngine`: tiered quarantine, expiry horizon, predecessor ordering, destination allowlist, native reserve floor, atomic batch execution, permissionless stuck-package cleanup, curated asset registry |
| Frontend-ready reads | `DAOReadHub`: one-RPC proposal cards, package readiness cards, treasury snapshots, schedule previews, timelock status |
| Tokenomics | `DAOStreamVesting`: standalone linear vesting with cliff, permissionless claims, funder-only revocation of unvested |
| Staking | `DAOStaking`: pre-funded reward epochs, owner-is-timelock, no seizure of stakes (staked tokens earn, don't vote) |
| Proposal UX | `ProposalBuilder`: pure library for treasury-payment, tier, allowlist, and floor payloads |
| Deployment | `Deploy.s.sol` bootstrap with loud wiring assertions; `Renounce.s.sol` verified self-sovereignty step |
| Examples | Runnable Flows A (treasury payment), B (config change), C (token distribution) in `test/Examples.t.sol` |
| Operators | `RUNBOOK.md`, `docs/EVENTS.md` monitor catalog, `docs/CAST.md` cookbook, `docs/DEPLOYMENT.md` checklist |
| Decisions | `docs/adr/` records, `ENGINEERING_LOG.md` bug log, `CHANGELOG.md` |

## Quickstart

```bash
forge build
forge test --no-match-test "testFuzz_|invariant_"
forge test --profile invariant-smoke
```

Modular DAO architecture built around OpenZeppelin Contracts 5.x, with a **linear dynamic
quorum governor**, a **multi-tier quarantined treasury execution engine** with
**time-bound guardian powers**, a **stateless read hub** for frontends, and a
**bootstrap deployment script**.

## Files

| Path | Purpose |
| --- | --- |
| `contracts/DAOGovernanceToken.sol` | ERC20 + ERC20Permit + ERC20Votes + ERC20Burnable with historical checkpoints and compiler-safe overrides. Fixed supply, minted once at construction. |
| `contracts/EnterpriseDAO.sol` | GovernorSettings + GovernorCountingSimple + GovernorVotes + GovernorTimelockControl with block-based settings, bounded variable proposal threshold, and a snapshot-safe **linear dynamic quorum**. Constructor takes a single `GovernorConfig` struct (stack-safe without `via_ir`). |
| `contracts/DAOTreasuryExecutionEngine.sol` | Multi-tier quarantine execution engine, governance-only scheduling, **time-bound** guardian emergency cancellation/pause, permissionless post-delay execution (single + batch), ETH/ERC20/ERC721/ERC1155 custody, native-value caps, delay upper bound, **package expiry horizon**, **predecessor dependencies** (cancelled predecessors rejected), **destination allowlist**, **native reserve floor**, permissionless expired/stuck cleanup, and package hashing. |
| `contracts/DAOReadHub.sol` | Stateless view aggregator (no storage/roles/funds): one-RPC proposal cards, package readiness cards (executable flag, blocked-reason codes, ETA, predecessor flags), treasury snapshots, schedule previews, timelock status, timelock delay. |
| `contracts/DAOStreamVesting.sol` | Standalone linear vesting with cliff and optional revocation (unvested returns to funder, vested stays claimable); no roles, no governance coupling. |
| `contracts/ProposalBuilder.sol` | Pure library building treasury-payment, tier-config, allowlist, and reserve-floor governance payloads (inlined, no deployment). |
| `contracts/DAOStaking.sol` | Single-pool staking: fixed-duration pre-funded epochs, timelock owner, bounded liability, owner can never move stakes. |
| `contracts/DAODeploymentNotes.sol` | Secure bootstrap and role hand-off sequence (checklist form). |
| `script/Deploy.s.sol` | Executable bootstrap deployment following the notes. |
| `script/Renounce.s.sol` | Wiring-verified deployer-admin renunciation (fails loudly on misconfiguration; re-run proves sealed state). |
| `script/Delegate.s.sol` | Holder-key delegation with DELEGATEE override (defaults to self-delegation). |
| `script/HealthCheck.s.sol` | View-only post-deploy verification (roles, tiers, floors, allowlist, sealed-state gate). |
| `frontend/dao-readhub.ts`, `subgraph/schema.graphql` | Typed hub client + indexer schema sketch. |
| `test/Examples.t.sol` | Runnable end-to-end Flows A–C using only real APIs (treasury payment, config change, token distribution). |
| `test/TreasuryOpsHardening.t.sol`, `test/DAOReadHub.t.sol`, `test/RenounceScript.t.sol` | Regression suites for the hardening, views, and renounce gate. |
| `docs/` | `INTEGRATION.md` (deployment/lifecycle/events), `CAST.md` (live-chain cookbook), `EVENTS.md` (monitor catalog), `DEPLOYMENT.md` (verification checklist), `adr/` (design records). |
| `RUNBOOK.md`, `ENGINEERING_LOG.md`, `CHANGELOG.md`, `LISTING.md` | Incident playbook, bug log with counterexamples, changelog, catalog listing. |
| `test/*.t.sol` | Foundry test suites: unit, fuzz, invariant, malicious-token and governance-attack coverage (~90 tests). |
| `foundry.toml` | Solidity 0.8.24 Foundry configuration (default + CI fuzz profiles). |
| `package.json` | Project metadata and convenience scripts. |
| `setup-foundry.ps1` | One-shot Windows installer for Foundry v1.8.1: downloads the official zip, verifies its SHA-256, extracts `forge`/`cast`/`anvil`/`chisel`/`solar` to `%USERPROFILE%\foundry`, and adds it to the user PATH. |

## Install

### Step 0 — Install Foundry (the `forge` CLI is NOT an npm package)

This project is built and tested with **Foundry v1.8.1**. `npm install forge` installs an
unrelated 2013-era JavaScript library and will never give you the `forge` command — Foundry
is not distributed through npm. If you already ran it, clean up (this is harmless either
way, since Foundry does not use `node_modules` at all):

```powershell
npm uninstall forge
Remove-Item -Recurse -Force node_modules
```

**Windows — one-shot installer (recommended).** From the project folder in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-foundry.ps1
```

The script downloads the official `foundry_v1.8.1_win32_amd64.zip` from the Foundry GitHub
releases, verifies the SHA-256 checksum, extracts the binaries to `C:\Users\<you>\foundry`,
and appends that folder to your user PATH. Afterwards **open a new PowerShell window** and
confirm with `forge --version`.

**Windows — manual alternative.**

```powershell
Invoke-WebRequest https://github.com/foundry-rs/foundry/releases/download/v1.8.1/foundry_v1.8.1_win32_amd64.zip -OutFile foundry.zip
Expand-Archive foundry.zip -DestinationPath "$env:USERPROFILE\foundry"
$dest = "$env:USERPROFILE\foundry"
$p = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $p) { $p = "" }
if ($p -notlike "*$dest*") { [Environment]::SetEnvironmentVariable("Path", "$p;$dest", "User") }
```

Then open a **new** PowerShell window and run `forge --version`.

**macOS / Linux.**

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

**Windows via WSL (alternative).** Run `wsl --install -d Ubuntu`, then use the two commands
above inside Ubuntu and `cd /mnt/c/Users/<you>/...` into the project folder.

### Step 1 — Build & test

Dependencies are vendored under `lib/` (OpenZeppelin Contracts v5.1.0, forge-std v1.9.7,
no `.git`, no submodules), so the project builds out of the box — no `git`, no
`forge install`, no network needed for dependencies (only the solc 0.8.24 download on
first run):

```bash
forge build
forge test
```

Prefer submodules instead of vendoring?

```bash
rm -rf lib/openzeppelin-contracts lib/forge-std
git submodule add https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
git submodule add https://github.com/foundry-rs/forge-std lib/forge-std
git -C lib/openzeppelin-contracts checkout v5.1.0
git -C lib/forge-std checkout v1.9.7
```

## Deploy

```bash
export INITIAL_RECIPIENT=0x...   # multisig receiving the initial supply
export GUARDIAN_ADDRESS=0x...    # emergency guardian multisig
forge script script/Deploy.s.sol --rpc-url <url> --broadcast
```

Optional `TOKEN_NAME`, `TOKEN_SYMBOL`, `INITIAL_SUPPLY`, `TIMELOCK_MIN_DELAY`,
`GOV_VOTING_DELAY`, `GOV_VOTING_PERIOD`, `GOV_QUORUM_MIN_BPS`, `GOV_QUORUM_MAX_BPS`
and `GOV_THRESHOLD` override the defaults (see the script header).

**Final manual step (deliberately not automated):** after verifying roles, renounce the
deployer's `DEFAULT_ADMIN_ROLE` on the timelock. From that moment governance is
self-sovereign.

## What changed in v2 (vs the original reference)

The original package did not compile. Five concrete defects were fixed and several
behaviors hardened:

1. **Compile error — invalid override list.** `EnterpriseDAO.supportsInterface`
   listed `GovernorTimelockControl`, which does not define that function.
2. **Compile error — `msg.value` in a non-payable function.**
   `DAOTreasuryExecutionEngine.executePackage` read `msg.value` while non-payable.
   It is now `payable` with an explicit `UnexpectedMsgValue` refund.
3. **Compile error — stack-too-deep.** The governor constructor had 11 parameters and
   required `via_ir`, contradicting the project's own `via_ir = false` config. The
   constructor now takes a single `GovernorConfig` struct.
4. **Access-control regression.** The `setProposalThreshold` override dropped OZ's
   `onlyGovernance` modifier (Solidity overrides do not inherit modifiers), and its
   `super` call double-consumed OZ's governance-call whitelist, so **threshold changes
   via real proposals always panicked** — governance could never adjust the threshold.
   The override now applies the modifier once and routes to the internal
   `_setProposalThreshold`.
5. **Vestigial dynamic quorum.** The old ±1 basis-point adjustment was effectively a
   no-op. Replaced with a genuine linear ramp (below).

Hardening added in v2:

- **Time-bound guardian cancellation** — guardians may cancel only during a package's
  quarantine window (before `executeAfter`); governance retains unlimited cancellation.
  A compromised guardian can no longer suppress approved packages indefinitely.
- **Linear dynamic quorum** — the quorum fraction interpolates between an immutable
  min and max (bps) as historical total supply grows between two immutable thresholds.
- **Batch execution** (`executePackages`) — atomic multi-package execution in one tx.
- **Post-execution storage cleanup** — executed packages wipe their calldata payload
  (gas refund, lean state; metadata retained).
- **ERC1155 deposits** (the contract always inherited `ERC1155Holder`, but had no
  deposit path/events), native deposit events for accounting, zero-amount guards.
- **Tier delay upper bound** (`MAX_TIER_DELAY = 365 days`) — prevents `uint48`
  truncation abuse and nonsensical multi-year quarantines.
- **Storage packing** — `executeAfter`, `tier`, `executed`, `cancelled` share one slot.
- **~90-test Foundry suite** (unit, fuzz, invariant, malicious-token, governance-attack) and a bootstrap deployment script.

## Security architecture

### Governance token

`DAOGovernanceToken` inherits `ERC20Votes`, whose checkpoints provide historical voting
power. The Governor uses the proposal snapshot instead of current balances, preventing a
voter from acquiring voting power after the snapshot and influencing an already-created
proposal (covered by `test_VotesAcquiredAfterSnapshotIgnored`). The permit nonce
namespace is unified with delegation nonces per EIP-2612/ERC-6372.

### Governor

`EnterpriseDAO` combines OpenZeppelin governor modules and Timelock execution. Voting
delay and voting period are block-based under the default ERC-6372 clock supplied by
ERC20Votes. Proposal threshold changes are bounded by immutable minimum/maximum limits
and remain governance-controlled through `GovernorSettings`.

**Dynamic quorum** (snapshot-safe): for a proposal snapshot at timepoint `t`, the
quorum fraction is computed from the token's **historical** total supply at `t`:

```
supply <= low  threshold  ->  quorumMinBps
supply >= high threshold  ->  quorumMaxBps
otherwise                 ->  quorumMinBps + (quorumMaxBps - quorumMinBps)
                              * (supply - low) / (high - low)
```

Rationale: at low supply, participation is scarce, so the required fraction is lower;
as the token supply grows, the fraction climbs to its ceiling. The ramp parameters are
immutable; `quorumFractionAtSupply` is public for tooling.

### Timelock

The Governor queues successful proposals in `TimelockController`. This deployment
grants `EXECUTOR_ROLE` to `address(0)` (permissionless execution), gives the Governor
proposer/canceller permissions, and removes the temporary deployer admin once
bootstrap is complete. The end-to-end path (proposal → timelock → treasury → package
execution) is covered by `test_FullGovernanceToTreasuryFlow`.

### Treasury execution engine

Execution packages contain: exact target, exact native value, exact calldata, execution
tier, monotonically increasing nonce, and delayed `executeAfter` timestamp. The package
identifier commits to the contract address, target, native value, calldata hash, tier,
and nonce. After the quarantine delay, anyone can execute a package (single or batch),
reducing liveness risk from a dead executor.

Default tiers (governance-reconfigurable within bounds; delays capped at 365 days):

| Tier | Delay | Maximum native value |
| --- | ---: | ---: |
| Low | 1 day | 250 ETH |
| Medium | 3 days | 100 ETH |
| High | 7 days | 25 ETH |
| Critical | 14 days | 5 ETH |

**Guardian powers are split and time-bound:**

- `pause()` — guardian, anytime (execution and deposits halt).
- `unpause()` — governance only.
- `cancelPackage` — guardian **only before `executeAfter`** (quarantine window);
  governance anytime. After the window, cancellation requires a governance decision,
  which itself passes through the timelock delay.

Deposits: native ETH (with events), ERC20 (allowance-based), ERC721 and ERC1155
(safe-transfer with holder hooks). Withdrawals and every fund-moving action happen
exclusively through governance-approved packages.

## Production role topology

Recommended trust model:

`Token holders -> Governor -> TimelockController -> TreasuryExecutionEngine`

Use a multisig/security council for the emergency guardian. Do not leave a deployer EOA
as a permanent administrator. Role grants, timelock delay, governor parameters, tier
caps, and pause/unpause powers should be reviewed independently before funding the
system.

## Testing

```bash
forge test                          # default profile (unit + fuzz + invariants)
forge test --profile ci             # 5000-run fuzz + deep invariant suite
forge test --profile invariant-smoke # fast local invariant check
forge snapshot                      # gas snapshot (checked in CI)
forge fmt --check                   # formatting (checked in CI)
```

The suite (155 tests across 20 files) covers:

- **Unit** — token permits/checkpoints/burns; proposal lifecycle, snapshot safety,
  dynamic quorum regimes and boundary math, constructor validation, threshold
  bounds via real proposals, timelock delay enforcement; treasury deposits, tier
  mechanics, value caps, pause/unpause split (single + batch), time-bound
  guardian cancellation, batch execution, batch atomicity/rollback/starvation,
  3-long predecessor chains, storage-layout packing pins, and the full
  governor→timelock→treasury integration.
- **Fuzz** (`TreasuryFuzz.t.sol`, `QuorumFuzzTest`) — package-id commitment,
  tier/delay/cap boundaries, guardian cancellation timing, expiry windows,
  predecessor ordering, destination allowlist, native reserve floors,
  unauthorized-scheduling ACL; quorum fraction monotonicity, clamping, exact
  linear interpolation, degenerate ramp safety.
- **Invariants** (`TreasuryInvariant.t.sol`) — handler-driven state machine:
  executed packages can never execute again; cancelled packages can never
  execute; executed/cancelled are mutually exclusive; unauthorized accounts can
  never schedule packages.
- **Malicious tokens** (`MaliciousToken.t.sol`) — reentrant ERC20 deposits,
  malformed return data, false-return tokens, always-reverting tokens,
  gas-guzzler targets, and reentrancy across `executePackage` (blocked by
  `nonReentrant`).
- **Governance attacks** (`GovernanceAttack.t.sol`) — exact 50% ties, snapshot
  safety against post-snapshot acquisitions, flash-loan-style zero-weight votes,
  delegation flips around snapshots, quorum manipulation via burns before/after
  snapshots, proposer-threshold edge cases.

## Test matrix

| File | Unit / edge / event / ACL | Fuzz | Invariant |
| --- | --- | --- | --- |
| `DAOGovernanceToken.t.sol` | 6 | — | — |
| `EnterpriseDAO.t.sol` | 12 | — | — |
| `DAOTreasuryExecutionEngine.t.sol` | 30 | — | — |
| `TreasuryFuzz.t.sol` | — | 10 | — |
| `TreasuryInvariant.t.sol` | — | — | 5 |
| `TreasuryAssetRegistry.t.sol` | 6 | 1 | — |
| `DelegateScript.t.sol` | 3 | — | — |
| `TreasuryOpsHardening.t.sol` | 8 | 1 | — |
| `DAOReadHub.t.sol` | 11 | 1 | — |
| `DAOStreamVesting.t.sol` | 9 | 1 | — |
| `ProposalBuilder.t.sol` | 3 | — | — |
| `GovernanceAttack.t.sol` | 9 | 5 | — |
| `MaliciousToken.t.sol` | 7 | — | — |
| `DeployScript.t.sol` | 1 | — | — |
| `RenounceScript.t.sol` | 4 | — | — |
| `Examples.t.sol` | 3 | — | — |
| `TreasuryStorageLayout.t.sol` | 2 | — | — |
| `HealthCheck.t.sol` | 4 | — | — |
| `DAOStaking.t.sol` | 11 | 2 | — |
| **Total** | **129** | **21** | **5** |

Plus `test/FormalChecks.t.sol`: 3 Halmos-convention `check_` properties
(package-id commitment, quorum clamping, expiry finality) — ignored by forge,
executed symbolically by halmos.

## Third-party attribution

OpenZeppelin Contracts v5.1.0 and forge-std v1.9.7 are vendored under `lib/`
under their own licenses; all project source files carry MIT headers
(`LICENSE` at repo root).

## Security

See [SECURITY.md](SECURITY.md) for the formal threat model: who can move funds
under which conditions, what the guardian can and cannot do, and compromise
analysis for every privileged component.

## Static analysis

CI runs `forge build`, unit tests, `forge fmt --check`, gas snapshot check,
a 5000-run fuzz + invariant job, and Slither (SARIF uploaded to GitHub
Security tab). Slither is filtered to project contracts (`lib/` excluded).

## Important audit note

This package is a reference architecture, not a claim of formal verification or
production audit status. Before deploying real assets, run the exact dependency
versions through Foundry/Slither and a professional smart-contract audit, with
adversarial tests for governance capture, timelock bypass, arbitrary-call abuse,
ERC777-style callbacks, malicious ERC20/721/1155 implementations, failed low-level
calls, gas griefing, quorum/threshold parameter changes, and guardian compromise.
