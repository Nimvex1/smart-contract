# Event catalog — what to monitor

## Governance (OpenZeppelin Governor + TimelockController)

| Event | Watch for |
|---|---|
| `ProposalCreated` | every new proposal; alert on unknown proposers near threshold changes |
| `VoteCast` | participation anomalies, last-minute whale swings |
| `ProposalCanceled` / `ProposalExecuted` | terminal states; reconcile with frontend cards |
| `TimelockCallScheduled` (`CallScheduled`) | queue entries; start of the delay window |
| `TimelockCallExecuted` (`CallExecuted`) | executions; match against scheduled batches |

## Treasury execution (`DAOTreasuryExecutionEngine`)

| Event | Watch for |
|---|---|
| `PackageApprovedV2` | every scheduled package: target, value, tier, executeAfter, expiry, predecessor |
| `PackageExecuted` | fund movement; reconcile target/value with the approval |
| `PackagesBatchExecuted` | batch runs; count mismatches indicate partial construction (batches are atomic) |
| `PackageCancelled` | guardian (quarantine-only) or governance cancellations; spike = incident |
| `PackageExpired` | dead packages finalized by anyone (`closeExpiredPackage`) or stuck successors (`closeStuckPackage` emits `PackageCancelled`) |

## Treasury custody (deposits)

`NativeDeposited`, `ERC20Deposited`, `ERC721Deposited`, `ERC1155Deposited` —
reconcile treasury accounting; unexpected deposit tokens warrant review before
any package targets them.

## Vesting (`DAOStreamVesting`)

`VestingCreated` (schedule terms: beneficiary, token, amount, start, cliff,
duration, revocability), `VestedClaimed` (payouts to beneficiaries),
`VestingRevoked` (unvested returned). Alert on revocations — legitimate ones
trace to a known offboarding; anything else is suspect.

## Staking (`DAOStaking`)

`Staked` / `Withdrawn` (principal flows), `RewardPaid` (yield claims),
`RewardAdded` (epoch funded: amount, rate, finish — reconcile against the
treasury transfer that preceded it), `RewardsDurationUpdated`,
`Recovered` (stray-token rescue; must never reference the staking token).
Alert on `RewardAdded` with no matching treasury funding, and on any
`Recovered` event (verify the token is genuinely stray).

## Administration

| Event | Watch for |
|---|---|
| `TierConfigured` | delay/cap relaxations shrink the detection window — treat as high-severity |
| `TargetAllowlistToggled` / `TargetAllowlistUpdated` | allowlist disabled or emptied removes the containment boundary |
| `ReserveFloorsConfigured` | native floor lowered — direct blast-radius change |
| `ERC20ReserveFloorConfigured` | monitoring-threshold change only (NOT on-chain enforced); update alerts |
| `AssetRegistered` / `AssetDeregistered` | accounting-scope changes; unexpected removals may hide positions from portfolio views (funds unaffected) |
| `TreasuryPaused` / `TreasuryUnpaused` | pause without a matching incident = investigate; unpause must trace to a passed proposal |

## Failures / incidents

Execution reverts surface as transaction reverts with named errors, not events:
`PackageNotReady`, `PackageExpiredError`, `PredecessorNotExecuted`,
`ReserveFloorBreached`, `ExecutionFailed`, `GuardianCancelWindowClosed`.
Alert on repeated `ExecutionFailed` for the same package (griefing or broken
target) and on any `TierConfigured`/`TargetAllowlistToggled` outside a known
proposal. Response playbook: `RUNBOOK.md`.
