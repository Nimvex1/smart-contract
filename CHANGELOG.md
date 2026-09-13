# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); versioning is
mirror-of-record with `package.json`.

## [Unreleased]

### Added

- `contracts/DAOReadHub.sol`: stateless view aggregator — `proposalCard`,
  `packageStatus` (executable flag, blocked-reason codes, seconds-to-ready,
  predecessor flags), `treasurySnapshot` (balances, floor, spendable headroom),
  `timelockMinDelay`. No storage, roles, or fund movement.
- `DAOTreasuryExecutionEngine.closeStuckPackage`: permissionless finalization of
  successors stuck behind a cancelled predecessor (emits `PackageCancelled`).
- `script/Renounce.s.sol`: wiring-verified deployer-admin renunciation
  (`verifyWiring` + `renounceRole`, fails loudly on misconfiguration).
- `test/Examples.t.sol`: runnable end-to-end Flows A (treasury payment),
  B (reserve-floor configuration), C (token distribution + delegation).
- Docs: `docs/INTEGRATION.md`, `docs/CAST.md`, `docs/EVENTS.md`,
  `docs/DEPLOYMENT.md`, `RUNBOOK.md`, `LISTING.md`, `docs/adr/`,
  `ENGINEERING_LOG.md`.
- `contracts/DAOStreamVesting.sol`: standalone linear vesting with cliff,
  permissionless claims, `claimable`/`vested` views and events; revocation
  returns only the unvested portion to the funder, vested pay stays claimable.
  Schedules record tokens actually received (fee-token safe). No roles, no
  governance coupling.
- `contracts/ProposalBuilder.sol`: pure library building treasury-payment,
  tier, allowlist, and reserve-floor governance payloads plus description
  hashes (inlined, no deployment, no trust).
- `DAOReadHub.schedulePreview` (scheduling dry-run: id commitment, quarantine
  estimate, cap/allowlist admission) and `DAOReadHub.timelockStatus`
  (operation id, pending/ready/done, ETA) for frontends and keepers.
- Treasury asset registry: governance-only `registerAsset`/`deregisterAsset`
  (informational only — unregistered tokens work identically),
  `registeredAssets`, `spendableERC20` headroom view, `AssetRegistered` /
  `AssetDeregistered` events, and one-RPC `DAOReadHub.treasuryPortfolio`.
- `script/Delegate.s.sol`: holder-key delegation with DELEGATEE override
  (defaults to self-delegation), with the broadcast call inline so it executes
  as the holder.
- Storage packing: `Package.expiresAt` shares the timing/flags slot (15 bytes),
  `TierConfig` spans two slots instead of three; pinned by
  `test/TreasuryStorageLayout.t.sol` golden slot test.
- Operations: view-only `script/HealthCheck.s.sol` (roles, tiers, floors,
  allowlist, sealed-state gate), `DAOReadHub.isSelfSovereign` banner view,
  required deploy → renounce → health-check → fund pipeline, guardian-loss
  playbook, keeper batch-chunking guidance (≤10, measured ~2.4M gas per
  10-batch).
- `frontend/dao-readhub.ts` typed client (blocked-reason labels, view types),
  `subgraph/schema.graphql` sketch with terminal-state derivation rules.
- `test/FormalChecks.t.sol`: Halmos-convention `check_` properties (package-id
  commitment, quorum clamping, expiry finality) — compile-gated by forge,
  executable under halmos.
- `contracts/DAOStaking.sol`: single-pool staking with fixed-duration,
  pre-funded reward epochs (owner = timelock). Liability bounded by funding
  (no mint); leftover rolls over; durations change only between epochs; owner
  can never move user stakes. Staked tokens earn but do not vote (pool never
  delegates).

### Fixed

- Enforced `MAX_PACKAGE_EXPIRY` at scheduling (`ExpiryHorizonTooLong`) —
  governance can no longer park a package decades out (AUDIT M1).
- Rejected scheduling on a cancelled predecessor (`PredecessorCancelled`) so
  permanently unexecutable packages cannot be created (AUDIT L1).
- Removed dead `PackageApproved` V1 event and the unreachable predecessor guard
  (AUDIT L2); removed the now-unused `PredecessorCycle` error.
- `closeExpiredPackage` on a live package now reverts with a distinct
  `PackageNotExpired` instead of reusing execution-path `PackageNotReady`.
- Clarified `setERC20ReserveFloor` NatSpec: informational monitoring threshold,
  NOT an on-chain control; the native floor remains the sole on-chain reserve
  check (AUDIT M2). No API rename — function signature unchanged.
- `depositERC1155` zero-amount guard verified already present (AUDIT L4 needed
  no change).

### Security

- No trust-model change: no new roles, guardian still fund-less, treasury
  governance still flows exclusively through the timelock. See `SECURITY.md`.

## [2.0.1] — prior release

See `README.md` "What changed in v2" for the v2 hardening record (time-bound
guardian powers, linear dynamic quorum, batch execution, tier delay cap).
