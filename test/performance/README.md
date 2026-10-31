# Local end-to-end benchmarks

Run from the repository root after `bundle install`. No extra gems, Docker,
server, credentials, or existing database are required. This measures the actual
native **libSQL engine shipped by `turso_libsql` 0.2.0**, not Turso's newer rewritten
engine. Every run owns a temporary directory and deletes it after disconnecting.

```sh
bundle exec rake performance:smoke
bundle exec rake performance
bundle exec ruby test/performance/run.rb --output tmp/performance/before.json
# Make an adapter change, then use the same command/settings:
bundle exec ruby test/performance/run.rb --output tmp/performance/after.json
ruby test/performance/compare.rb tmp/performance/before.json tmp/performance/after.json

# File/WAL database, including persistent workers and pool contention:
bundle exec ruby test/performance/run.rb --storage file --output tmp/performance/file.json
# Sequel's mature SQLite adapter as a reference (different native engine/driver):
bundle exec ruby test/performance/run.rb --adapter sqlite --storage file --output tmp/performance/sqlite.json
ruby test/performance/compare.rb tmp/performance/file.json tmp/performance/sqlite.json

# Longer focused measurements:
bundle exec ruby test/performance/run.rb --filter 'read\.(chain|reused_dataset|prepared|bound_call)$' --iterations 2000 --warmup 100 --samples 7
bundle exec ruby test/performance/run.rb --help
```

The default is 100 iterations, 10 warmups, five samples, 1,000 fixture rows,
20 writes per bulk iteration, and four pool slots/workers for file databases.
Memory databases require one pool slot. Connection creation is capped at ten
iterations per measured sample. Use the same parameters for before/after runs.
Run benchmarks serially on an otherwise idle machine; do not run the tests or
other benchmark processes simultaneously. Warmups include correctness checks.

## Coverage

| Area | Workloads |
| --- | --- |
| Ruby only | Rebuild a chain and generate SQL; reuse a dataset's cached SQL |
| Reads | Chained/reused/raw queries, scalar, primary-key hit/miss, get, bound call, named prepared query, `DB.call`, mixed bound text/integer/blob values |
| Results | Narrow and typed 1,000-row results, streaming, early exit, select_map, aggregate, join |
| Models | Primary-key lookup, materialization, N+1 association reads versus eager loading |
| Writes | Insert, bound insert, update, delete, RETURNING, upsert, unique-constraint failure |
| Transactions | Commit, rollback, nested savepoint rollback |
| Bulk | Autocommit loop, transaction loop, prepared transaction loop, import, SQL batch in a transaction |
| Schema | Cached/reloaded schema, create/drop table |
| Connections | Pool checkout, connect/query/disconnect; file-only serial, held-pool, and concurrent reads |

Both adapters use WAL and `synchronous=NORMAL` for file databases. These settings
are explicit benchmark choices, not production durability recommendations. Memory
mode records the actual journal setting. Report metadata includes the runtime,
YJIT state, gem/engine versions, settings, and source hashes. Defaults preserve the
process's YJIT setting. To test it, start Ruby with `--yjit` and keep that setting
constant for both runs.

Each sample resets write fixtures outside the timer, runs a full GC, then measures
with GC **enabled**. The monotonic clock covers the whole operation, including SQL
generation, pool acquisition, native calls, row decoding, and model construction
where applicable. Correctness checks run after the timer and allocation snapshot;
exceptions and incorrect results fail the command. Delete/update fixtures contain
one real target per iteration, so these do not degenerate into no-op writes.

`us/op` is the median of sample mean microseconds per workload invocation.
`units/sec` normalizes scans by returned rows and bulk writes by inserted rows;
other cases use one unit per invocation, except connection read groups. It is not
a cross-workload score. `objects/op` counts Ruby allocations; native Rust/C memory
is excluded. JSON retains individual sample times, allocations, GC counts/time,
and min/max sample means. Those ranges are **not** p95/p99 request latency.
The comparator checks matching settings/runtime/harness, and prints shared cases
for cross-adapter comparisons; native-only cases have no SQLite counterpart.

## Interpreting opportunities

- Compare `read.chain` with `read.reused_dataset` to measure reusable immutable
  datasets. `ruby.reused_sql` alone is a cached Ruby string lookup, not a query.
- Compare `read.bound_call` with `read.prepared`: prepare Sequel's query object once
  when practical. This adapter still creates/releases the native statement on each
  call. There is no persistent native statement cache.
- Compare bulk methods with equal row counts. SQL batching and transactions are
  synchronous; this is **not asynchronous network pipelining**. Bound values should
  still be used for application inputs; the batch fixture contains constant SQL.
- Compare serial and concurrent reads with the same query count. Persistent worker
  startup is excluded, but dispatch, scheduling, and pool contention are included.
  More connections need not improve small local reads.
- SQLite reference timings include differences in native engines, APIs, statement
  caching, and conversion support. They do not isolate Ruby overhead by themselves.

This is representative coverage, not every Sequel API or every production workload.
It does not measure HTTP latency, authentication, replication/sync, remote pipeline
support, cold process startup, multi-writer contention, or disk power-loss durability.
The project's Hrana fixture is a protocol test server, not a production performance
substitute. Performance numbers are observations, not CI pass/fail thresholds.

Jeremy Evans' [dataset documentation](https://sequel.jeremyevans.net/rdoc/files/doc/dataset_basics_rdoc.html)
describes immutable reusable datasets; his [prepared statement guide](https://sequel.jeremyevans.net/rdoc/files/doc/prepared_statements_rdoc.html)
recommends creating prepared query objects during initialization. The installed
Sequel SQLite adapter's `Dataset#fetch_rows` also provides a concrete reference for
indexed row loops and per-result conversion setup. Measurements for this change
are recorded in [results.md](results.md).
