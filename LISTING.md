# Listing

Title: Enterprise DAO Toolkit — Governor, Timelock Treasury, Read Hub

One-liner: Production-oriented DAO stack: dynamic-quorum governor, quarantined
treasury engine, stateless read hub, scripts, examples, and runbooks.

## Description

What's included: `DAOGovernanceToken` (fixed-supply ERC20Votes), `EnterpriseDAO`
(dynamic-quorum Governor + TimelockControl), `DAOTreasuryExecutionEngine`
(tiered quarantine, expiry, predecessors, allowlist, reserve floor, batch
execution), `DAOReadHub` (one-RPC proposal/package/treasury cards),
`DAOStreamVesting` (linear vesting with cliff and revocation),
`ProposalBuilder` (pure governance-payload library),
`Deploy.s.sol` + `Renounce.s.sol` + `Delegate.s.sol` scripts, three runnable
end-to-end examples, 155 Foundry tests (unit, fuzz, invariant,
malicious-token, governance-attack),
integration/cast/event/deployment guides, runbook, ADRs, and engineering log.

Intended use: reference architecture for on-chain DAO governance and treasury
operations on EVM chains; study, fork, and adapt before any production funding.

Rights: MIT (see LICENSE). Third-party: OpenZeppelin Contracts v5.1.0 and
forge-std v1.9.7, vendored under `lib/` under their own licenses. Not formally
audited — no audit is claimed; see SECURITY.md and AUDIT.md.
