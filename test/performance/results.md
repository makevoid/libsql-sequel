# Local benchmark results — 2026-10-31

Measured the repository's actual embedded libSQL library on arm64 macOS, Ruby
4.0.5 (YJIT off), Sequel 5.109.0, turso_libsql 0.2.0, FFI 1.17.4. The native
libSQL library reports SQLite 3.45.1; the reference sqlite3 gem 2.10.2 reports
SQLite 3.54.1. This is not a benchmark of Turso's newer rewritten engine.

Full runs used 100 iterations per case, 10 warmups, five randomized-order samples,
1,000 fixture rows, 20 rows per bulk invocation, and four workers/pool slots for
file mode. File databases used WAL and synchronous=NORMAL. Runs were sequential,
with GC enabled. Times below are medians of sample means; no statistical
significance or production throughput claim is made.

## Adapter changes retained

| Workload | Memory before → after | File before → after | File speedup | Ruby objects saved per invocation |
| --- | ---: | ---: | ---: | ---: |
| Narrow scan, 1,000 rows | 6.714 → 6.112 ms | 6.686 → 6.074 ms | 1.10× | 2,999 |
| Typed scan, 1,000 rows | 35.270 → 33.728 ms | 36.928 → 34.079 ms | 1.08× | 6,999 |
| Stream/sum 1,000 IDs | 3.625 → 3.339 ms | 3.709 → 3.417 ms | 1.09× | 2,999 |
| Materialize 1,000 models | 36.014 → 34.060 ms | 36.952 → 34.354 ms | 1.08× | 6,999 |

For the file narrow scan, baseline sample means ranged from 6.551–6.972 ms and
optimized means from 5.999–6.164 ms. For the typed scan they ranged from
35.994–38.413 ms and 33.856–34.437 ms respectively. Allocation reductions were
consistent across both storage modes. Narrow scan allocations fell from 33,066 to
30,067 (9.1%); typed scan allocations fell from 155,091 to 148,092 (4.5%).

The combined patch:

- Resolves column types and count once per result and builds hashes with an indexed
  `while` loop, as Sequel's SQLite adapter does. Untyped values avoid a converter
  call. Native result iteration also reuses its column count.
- Hoists signed 64-bit integer constants out of per-value Bignum calculations and
  replaces per-bind range construction with direct comparisons.
- Reads the native value's type once and reuses frozen UTF-8 input strings. Mutable
  inputs are still copied before native calls release the GVL; validation remains.

These were measured together, so the report does not attribute the gain to any one
idiom. No native statement cache, persistent type cache, GVL behavior, transaction
semantics, or ownership policy changed.

Short-query changes are small and mixed. A separate seven-sample run with 2,000
iterations and 100 warmups found the following memory medians:

| Workload | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| Reused dataset | 27.13 µs | 26.95 µs | 1.01× |
| Named prepared query | 35.58 µs | 34.15 µs | 1.04× |
| Native bound query through the pool | 13.20 µs | 12.61 µs | 1.05× |
| Rebuild chain and query | 51.35 µs | 52.78 µs | 0.97× |
| Missing row | 36.15 µs | 37.66 µs | 0.96× |
| Unprepared bound call | 70.87 µs | 73.25 µs | 0.97× |

The missing-row path allocates one extra per-result type array. The optimizations
are useful for row-heavy workloads; they are not a universal query-speed improvement.
Most write/connection changes were small relative to sample variability.

## Larger application-level opportunities

These are alternatives measured **within the optimized file run**, not additional
speedups caused by the adapter patch:

| Choice | Measured time | Interpretation |
| --- | ---: | --- |
| Build chain / reuse dataset | 51.33 / 29.85 µs | Reuse immutable datasets for repeat shapes: 1.72× here |
| Bound `.call` / reuse `.prepare` | 66.80 / 34.37 µs | Prepare the Sequel query object once: 1.94× here |
| N+1 / eager load ten associations | 863.26 / 479.92 µs | Eager loading: 1.80× here |
| 20 autocommit inserts / transaction loop | 851.58 / 311.67 µs | Amortize transaction cost: 2.73× here |
| 20 autocommit inserts / import | 851.58 / 69.66 µs | Multi-row SQL: 12.23× here |
| 20 autocommit inserts / SQL batch in transaction | 851.58 / 87.98 µs | Synchronous batching: 9.68× here |
| Sequential / concurrent 40 scalar reads | 900.63 / 1,415.05 µs | Four threads/connections were slower for tiny local reads |
| New connection + query / existing scalar query | 353.40 / 22.46 µs | Connection reuse is much cheaper for this workload |

The prepared transaction insert loop took 321.74 µs for 20 rows versus 311.67 µs
for literal inserts in a transaction. Binding is important for inputs, but is not
automatically the fastest option for constant values. Holding the pool connection
around 40 reads took 880.46 µs versus 900.63 µs normally: little benefit here.

Native statements still prepare and close on every execution. The SQL batch case
does not demonstrate asynchronous pipelining or any remote round-trip savings.

## Follow-up opportunities

1. **Reduce native row/FFI overhead.** The SQLite reference's narrow scan took
   0.601 ms versus 6.074 ms for optimized libSQL (10.10×), and allocated 3,044 versus
   30,067 Ruby objects. Typed scans were 13.236 versus 34.079 ms (2.57×). Combined
   with the per-cell FFI structs visible in the implementation, this suggests a
   bulk native row decoder or a compiled bridge is worth investigating. Different
   engines/APIs/conversion paths mean the reference gap is not a measurement of
   Ruby overhead alone, or a promised achievable gain.
2. **Consider a bounded per-connection statement cache separately.** It may help
   repeated small queries, especially remotely. It needs deliberate reset/rebind,
   eviction, DDL, error, disconnect, and fork semantics. It was not implemented or
   measured by this patch. Sequel's existing SQL/query-object caching remains useful.
3. **Benchmark a real server before proposing remote pipelining.** Local embedded
   timings cannot establish network savings, HTTP concurrency, or replica behavior.
   The protocol fixture is used only for correctness checks.

The adapter's disabled placeholder literalizer should not simply be switched back
on for speed: it previously lost result-type information for repeated projections.
Any restoration needs a separate semantic design and type-conversion regression
coverage.

## Reproduction and evidence

Baseline source: git `e2acb6a8b37c350a6baaa6f29e3d401d6b9e8e16`.
Measurements preceded the release-only version bump from 0.3.0 to 0.3.1; the
optimized adapter implementation is the one shipped in 0.3.1.
Source SHA-256 before:
`1eda62671b39a6aee3d0bbf3046dac34503b83d8a4bd5c5ddb542481ab481c70`.
After: `d0353b81ff3b8941c8d655633fe8e0c5cd04218ee07fbc4542a9a6d90804a430`.
Harness: `c2b0a6afc68d90c16f295e1173e2e2e42e63c331c3fac3725466233ab685d119`.

Raw JSON and logs from this machine are retained in ignored `tmp/performance/`:
`baseline-memory`, `optimized-memory`, `baseline-file`, `optimized-file`,
`sqlite-file`, `focused-before`, and `focused-after`. They include every sample,
GC statistics, settings, versions, and source hashes. A compact portable record of
all measured cases is in [measurements.json](measurements.json). Reproduce runs
using [README.md](README.md); compare JSON with `compare.rb`.

The focused baseline used an isolated copy of `HEAD`'s `lib/` under
`tmp/performance/baseline-checkout`, with the same harness. Both source and harness
hashes match the earlier baseline; the working tree was not rolled back.

Validation after the adapter changes:

- `bundle exec rake check`: syntax/visibility checks and 45 tests, 222 assertions,
  zero failures/errors/skips.
- `bundle exec rake performance:smoke`: all 46 memory-libSQL, 49 file-libSQL, and
  47 file-SQLite workloads passed their correctness checks.
- `bundle exec rake upstream`: 901 tests, 7,468 assertions, zero failures/errors,
  six upstream skips.
- `bundle exec rake remote_local`: five tests, 24 assertions, zero failures/errors/
  skips against the local Hrana fixture. This validates local HTTP behavior, not
  hosted service performance or replication.
