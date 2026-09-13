# Engineering log — bugs found during QW implementation

## 1. Far-future expiry accepted (AUDIT M1, confirmed)

- Counterexample: `approvePackage(t, 0, "", 0, now + 10 years, 0)` succeeded,
  parking an executable package a decade out despite `MAX_PACKAGE_EXPIRY`.
- Fix: `ExpiryHorizonTooLong` bound in `approvePackage`.
- Test: `test_ExpiryHorizon_RevertsWhen_BeyondMaxExpiry` (+ boundary + fuzz).

## 2. Scheduling on a cancelled predecessor created stuck packages (AUDIT L1)

- Counterexample: cancel `pred`, then `approvePackage(..., pred)` succeeded;
  the successor could never execute and (with `expiresAt = 0`) never close.
- Fix: `PredecessorCancelled` revert at scheduling + permissionless
  `closeStuckPackage` for already-stuck successors.
- Test: `test_PredecessorCancelled_RevertsWhen_SchedulingOnCancelled`,
  `test_CloseStuckPackage_*`.

## 3. `closeExpiredPackage` reused `PackageNotReady` for "not yet expired"

- Counterexample: closing a live package emitted an error indistinguishable
  from "quarantine not elapsed", confusing operators and indexers.
- Fix: distinct `PackageNotExpired(packageId, expiresAt)`; execution path keeps
  `PackageNotReady`.
- Test: `test_CloseExpiredPackage_RevertsWhen_NotExpired`.

## 4. Dead code: V1 `PackageApproved` event, unreachable predecessor guard

- `PackageApproved` was never emitted (superseded by V2); the
  `if (predecessor == bytes32(0))` guard inside `if (predecessor != bytes32(0))`
  was unreachable, leaving `PredecessorCycle` unused (forge lint confirmed).
- Fix: removed event, guard, and unused error. No test referenced them.

## 5. Misleading ERC20 floor API (AUDIT M2)

- `setERC20ReserveFloor` implied on-chain enforcement that does not exist
  (arbitrary calldata cannot be attributed on-chain). Kept the signature for
  compatibility; rewrote NatSpec as INFORMATIONAL ONLY and documented the
  monitoring contract in `docs/INTEGRATION.md` / `docs/EVENTS.md`.

## 6. AUDIT L4 already resolved

- `depositERC1155` already reverts on `amount == 0`; no change needed. Logged
  so the audit item is not re-opened.

## 7. Own test bug: empty calldata against a fallback-less target

- `DAOReadHubTest.test_PackageStatus_Transitions...` approved `""` calldata to
  a target without `receive`/`fallback`; execution reverted with
  `ExecutionFailed` and the test failed.
- Fix: approve real `setFlag` calldata in the test. Lesson: execution tests
  must use callable targets (as the existing suites do with `CallTarget`).

## 8. Script payable-conversion compile errors

- `Renounce.s.sol` initially converted `vm.envAddress` directly to
  `EnterpriseDAO` / `DAOTreasuryExecutionEngine`; both have payable fallbacks
  (via inheritance), so Solidity required `payable(...)` intermediate casts.
- Fix: `EnterpriseDAO(payable(...))` / engine `payable(...)`. Caught by
  `forge build` before any test ran.

## 9. Dropped contract brace during test append (Phase 1)

- Appending P1-3 tests to `DAOReadHub.t.sol` replaced the trailing `}` of the
  test contract with the last test's brace; the file no longer compiled.
- Fix: re-added the contract-closing brace. Caught immediately by `forge build`;
  lesson: when an edit's `oldString` includes structural braces, verify the
  tail of the file after applying.

## 10. Raw `revert(bytes)` is not Solidity (Phase 1)

- `DAOReadHub.schedulePreview` first tried
  `revert(abi.encodeWithSelector(...InvalidTier...))` to reuse the treasury's
  error; solc rejects `revert(bytes)` outside assembly.
- Fix: direct cross-contract reference
  `revert DAOTreasuryExecutionEngine.InvalidTier(tier)` — same selector on the
  wire, checked by `test_SchedulePreview_FlagsCapBreachAndBadTier`.

## 11. Delegation through a helper contract delegates nobody's votes (P1-5)

- First `Delegate.s.sol` draft called `token.delegate` from a public helper;
  in tests the token saw the helper contract (zero votes) as `msg.sender`,
  and all three tests failed with zero voting power. Live `--broadcast` would
  have worked (forge submits from the broadcaster EOA), but the shape was a
  silent-no-op footgun for any direct caller.
- Fix: `token.delegate` inline in `run()` plus a NatSpec warning; the only
  branching logic (env override) isolated in testable `resolveDelegatee`.

## 12. Parallel forge tests race on shared env vars (P1-5)

- Two `DelegateScript` tests each `vm.setEnv("DELEGATEE", ...)`; run together,
  one intermittently read the other's value (pass-alone, fail-in-suite).
- Fix: exactly one test in the suite touches DELEGATEE; the rest are env-free.
  Rule going forward: env-mutating tests must be unique writers per var.

## 13. Slither `costly-loop` on deregisterAsset accepted (P1-4)

- The swap-and-pop search loop in governance-only `deregisterAsset` flags
  `costly-loop` (INFO). An O(1) index mapping would silence it at the cost of
  extra storage and bookkeeping on every register/deregister.
- Accepted: the loop runs only on rare governance curation over a
  curator-bounded list and breaks on first match — no user/keeper path loops.
  No behavior change; documented here instead of gilded.

## 14. Fee-mock taxed mints too (audit fix R3)

- First `FeeMint` mock applied the 5% fee in `_update` unconditionally, so
  `mint` itself paid the fee and the funder never held the funded amount —
  `create` reverted with `ERC20InsufficientBalance`, looking like a vesting bug.
- Fix: skip the fee when `from`/`to` is zero (mint/burn path). Lesson: mock
  fidelity first — a failing test of a correct fix means the mock is wrong,
  not the code. Verified by the now-passing insolveless-claim assertions.

## 15. TierConfig reorder broke 9 positional destructurings (audit §4)

- Reordering to `{delay, enabled, maxNativeValue}` broke every
  `(, uint256 cap,)`-style destructure across contracts, tests, and
  `Deploy.s.sol` (bool↔uint256 type errors — loud, at least).
- Fix: updated all 9 sites (found by compiler, confirmed by grep); the golden
  layout test now pins the order so future drift fails fast. Lesson: public
  struct getters expose positional coupling — prefer named access in tests
  where readability allows.

## 16. Slither `incorrect-equality` on `received == 0` accepted (audit R3)

- The zero-arrival guard in `DAOStreamVesting.create` re-triggers the same
  heuristic removed from `claim` in Phase 1. Here the strict comparison is
  exact and safe (freshly measured uint delta, not a balance race), and the
  `<=`-rewrite would obscure intent — accepted as a documented false positive
  alongside the `costly-loop` entry above. Slither remains at pre-existing
  families + these two logged INFOs. Same treatment applied to
  `DAOStaking.rewardRate == 0` (dust-epoch guard, exact and safe) and the
  staking timestamp family (epoch accounting IS time-based by definition).

## 17. Four staking test failures, zero contract bugs (new primitive)

- Reward assertions of exactly 3,000e18 failed by ~1e6 wei: `rewardRate`
  truncates on division (`3000e18/30days`), so epochs pay (rate × duration),
  not the headline amount. Fix: `assertApproxEqAbs` with 1e12 tolerance and
  event expectations computed from `earned()`, never hard-coded round numbers.
- `vm.prank` + view-call ordering: reading `rewardRate()` for event args
  consumed the prank, failing with `OwnableUnauthorizedAccount`. Fix: read all
  expectations before pranking (same lesson as log #9, new disguise).
- Fuzz `withdraw(0)` hit the by-design `ZeroAmount` revert: bounded `b` to
  ≥1. Lesson: fuzz domains must exclude documented revert paths or assert them
  explicitly — a "failure" on a specified revert is a test bug, three times
  out of three in this suite.
