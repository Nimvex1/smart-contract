# ADR 0014 — First-party staking with pre-funded epochs

Status: accepted.

## Context

DAOs want yield for holders, but the governance token is fixed-supply (no
mint), and pooled staking interacts with vote checkpoints. External "DeFi"
(lending, AMMs) is deliberately out of scope: each is an
audited-protocol-scale project; the repo's DeFi story is governance-approved
interaction with external audited protocols (allowlist + packages) plus this
one bounded primitive.

## Decision

Ship `DAOStaking`: Synthetix-style reward-per-token accumulator, fixed
durations, owner = timelock. Liability is bounded by pre-funding
(`notifyRewardAmount` reverts unless the epoch is fully collateralized);
leftover rolls over; durations change only between epochs. The owner can set
rates, retarget durations, and rescue non-staked tokens — and NOTHING else:
no function moves user stakes (pinned by test). Staked tokens earn but do not
vote (the pool contract never delegates); NatSpec, guides, and the frontend
contract say so explicitly.

## Consequences

- Positive: no inflation key, no slashing role, no new global trust; funding
  flows through existing treasury packages.
- Negative: stakers sit out votes while staked (inherent to ERC20Votes
  pooling); dust from rate division is real but bounded and tested with
  tolerances, never exact equality.
