# Multi-provider Soroban RPC read quorum (issue #272)

Status: design note. Not implemented yet — this document is the plan of record.

## Problem

Every critical chain read (latest ledger header, contract data / ledger entries,
account + sequence) currently goes to a single `SOROBAN_RPC_URL`
(`src/chain/config.rs`, `src/chain/rpc.rs`). A single lying, lagging or
compromised provider can therefore feed the fee oracle, the indexer and the
settlement path wrong state with no detection. Fund-critical reads need
M-of-N agreement over decoded domain values, plus visibility when providers
disagree.

## Approach

Add a quorum layer *above* the existing `SorobanRpc` trait so nothing that
already consumes the trait has to change:

1. **Config** (`src/chain/config.rs`, `.env.example`)
   - `SOROBAN_RPC_URLS` — comma-separated provider list (falls back to
     `SOROBAN_RPC_URL` as a single provider).
   - `SOROBAN_RPC_QUORUM` — M (default 2, clamped to `1..=N`).
   - `SOROBAN_RPC_TIMEOUT_MS` — reused as the per-provider fan-out timeout.
   - `SOROBAN_RPC_DIVERGENCE_POLICY` — `log` | `alert` | `demote` |
     `fail_closed` (default `fail_closed` for fund-critical reads).
   - `SOROBAN_RPC_PROVIDER_COOLDOWN_SECS` — demotion cooldown before
     re-admission (default 60).
   - Validate each URL with the existing HTTPS-outside-localhost rule.

2. **Quorum client** (new `src/chain/quorum.rs`, registered in
   `src/chain/mod.rs`)
   - `QuorumRpc` holding `Vec<ProviderHandle>` where each handle wraps an
     `Arc<dyn SorobanRpc>` plus health state.
   - `get_ledger_header_quorum()`, `get_contract_data_quorum(keys)`,
     `get_account_quorum(account_id)` fan out with `futures::future::join_all`
     under a per-provider timeout, decode into domain types
     (`LedgerHeader`, `Vec<LedgerEntryInfo>`, `AccountState { account_id,
     sequence }`), and group responses by structural equality of the decoded
     value (`PartialEq` on the domain type — never raw JSON comparison).
   - Return the value only when the largest agreeing group has `>= M`
     members; otherwise return `QuorumError::Divergence { groups }` or
     `QuorumError::Insufficient { responded, required }`.
   - Reads are tagged `Criticality::{FundCritical, NonCritical}`; only
     `NonCritical` reads may fail open (return the plurality value and record
     a divergence metric).

3. **Health scoring and re-admission**
   - Per provider: `errors`, `requests`, `agreements`, `disagreements`,
     `last_lag_ledgers`, `demoted_until: Option<Instant>`.
   - Error rate and agreement rate are derived; a provider is demoted when it
     disagrees with the quorum or exceeds the error-rate threshold, and is
     re-admitted automatically once `demoted_until` has passed.
   - Expose `QuorumMetrics::snapshot()` and `render_prometheus()` following
     the `IndexerMetrics` / `CostLedger::render_metrics` pattern, with series
     `zenith_rpc_provider_health{provider=...}`,
     `zenith_rpc_provider_agreement_ratio{provider=...}`,
     `zenith_rpc_quorum_divergences_total`, `zenith_rpc_quorum_failures_total`.

4. **Wiring**
   - `ChainConfig::quorum_client()` builds the `QuorumRpc`; the fee oracle,
     indexer and settlement read paths take `Arc<QuorumRpc>` for the three
     critical reads. Single-provider configs keep working (M=1).

## Files to change

- `.env.example` — new variables with comments.
- `src/chain/config.rs` — parse/validate provider list, quorum, policy.
- `src/chain/quorum.rs` — new module (client, domain types, health, metrics).
- `src/chain/mod.rs` — `pub mod quorum;` and re-exports.
- `src/chain/rpc.rs` — add `get_ledger_header` / `get_contract_data` /
  `get_account` to the `SorobanRpc` trait plus `RpcClient` and
  `MockSorobanRpc` implementations (mock gains scripted per-provider values
  so divergence can be exercised).
- `docs/chain-rpc.md` — document the new configuration and failure modes.

## Steps in order

1. Extend the `SorobanRpc` trait with the three decoded read methods and
   implement them for `RpcClient` and `MockSorobanRpc`.
2. Add config parsing + validation and the `.env.example` entries.
3. Implement `QuorumRpc` fan-out, structural comparison and quorum decision.
4. Add health scoring, demotion/re-admission and metrics rendering.
5. Wire the fee oracle / indexer / settlement reads to the quorum client.
6. Document behaviour in `docs/chain-rpc.md`.

## Done when

- With N=3, M=2 and one provider returning a different ledger header, the
  quorum read returns the majority value, records a divergence, and demotes
  the odd provider; after the cooldown it is queried again.
- With two of three providers disagreeing, a fund-critical read fails closed
  with `QuorumError::Divergence`; a non-critical read fails open and is
  counted.
- Provider list, quorum size, timeout, policy and cooldown all come from
  environment configuration; no values are hard-coded.
- `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` and
  `cargo test` are green.
