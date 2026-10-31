# Compatibility and verification

## Verified in this workspace

As of 2026-10-31, Apple Silicon macOS, Ruby 4.0.5, `turso_libsql` 0.2.0, bundled SQLite 3.45.1:

- Native local/file tests cover CRUD, signed integer boundaries, UTF-8, arbitrary/empty blobs, invalid input, native lifetime cleanup, prepared queries, constraints, transactions/savepoints/commit failure, models, associations, migrations, schema alteration, pool concurrency, reconnect, and type hints.
- The same project suite passes with Sequel 5.80.0 and 5.109.0.
- Sequel upstream at `75b425dd1c1f34908426dd70371d14e4afb9c933`: SQLite adapter plus integration run passes (901 tests, six upstream skips). The test sources are unmodified. Some additional groups are never defined for an external adapter: seven SQLite type-conversion cases gated on `adapter_scheme == :sqlite` now have local equivalents. See [the coverage review](testing-review.md).
- Real native HTTP execution against the official Hrana v3 Python fixture covers prepared Unicode/blob values, affected counts, inserted IDs, constraints, transactions/savepoints, reconnect, schema metadata, empty results, NULL values, models using prepared statements, and INSERT/UPDATE/DELETE RETURNING.
- The fixture wrapper only normalizes padded/unpadded base64 between Python and Rust. SQL and stream handling stay upstream. This is a protocol integration test, not a hosted Turso test.
- Hosted Turso remote mode was verified with a `turso://` URL normalized to HTTPS and a real database token, using Sequel 5.109.0. The warning-enabled `test/remote.rb` suite passed all five tests (24 assertions), covering CRUD, prepared bindings, Unicode/blobs, constraints, transactions/savepoints/rollback, reconnect persistence, schema metadata, models, and returning writes. Only randomly named test tables were created and dropped; credentials were not logged.

## Not verified

Live embedded replication, sync scheduling/read-your-writes behavior against a primary, encryption, Linux native execution, and Ruby 3.3/3.4 execution have not been tested here. The connection descriptor and sync API support replicas; that does not establish end-to-end replication correctness. Hosted remote checks do not cover token expiry/rotation, custom TLS settings, or production load behavior.

## Known limits

- No declared result type metadata from the C API: raw SQL/joins/CTEs/expressions need explicit hints for semantic SQLite types.
- Existing TEXT values containing NUL are truncated by the upstream C API; the adapter rejects NUL text inputs. BLOB is binary-safe.
- Remote native SQL parsing rejects local PRAGMAs such as busy_timeout/case_sensitive_like. Remote LIKE behavior follows the server. Local-only options are rejected when a remote URL is configured.
- No custom regexp functions, read-only opening, loadable extensions, DQS configuration, offline-write sync mode, or configurable HTTP timeout.
- Memory/replica pools are limited to one connection. Disconnecting a memory database destroys it.
- Initialize in worker processes after fork; release any parent connections in `before_fork`. Child `disconnect` quietly discards inherited handles, while inherited queries remain unsupported. This cleanup does not reset an inherited native runtime or establish that reconnecting in the child is safe.
- No automatic retry or idempotency policy for transport failures. If a write response is lost, its outcome can be uncertain.
- `turso_libsql` 0.2.0 ships only Apple Silicon macOS and glibc Linux x86_64/aarch64 binaries. Other platforms need an independently validated driver build.
- This targets libSQL and Turso's libSQL-compatible service, not the separate newer `turso` Rust engine API.

## Upstream references

- [libsql-ruby](https://github.com/tursodatabase/libsql-ruby): FFI declarations, Ruby wrappers, examples, bundled libraries. Upstream main differs from published 0.2.0 and 0.2.1.
- [libsql-activerecord](https://github.com/tursodatabase/libsql-activerecord): ORM execution and schema comparison.
- [Sequel SQLite adapter](https://github.com/jeremyevans/sequel/blob/75b425dd1c1f34908426dd70371d14e4afb9c933/lib/sequel/adapters/sqlite.rb) and shared SQLite modules: integration conventions and dialect behavior.
- [sqlite3-ruby](https://github.com/sparklemotion/sqlite3-ruby): comparison of value and declared-column metadata APIs.
- [libsql-c](https://github.com/tursodatabase/libsql-c): native ABI, ownership, descriptors, errors, and parameter conversion. Published 0.2.0-era revision: `cb3a8c2c2c7330e104e4df536189eddb83a8f491`.
- [libsql-client-ts](https://github.com/tursodatabase/libsql-client-ts/tree/9496c782af413f6380235c7f5d0c97b5371f49b7/testing/hrana-test-server): official protocol fixture.
- [hrana-client-ts](https://github.com/libsql/hrana-client-ts) and [libSQL](https://github.com/tursodatabase/libsql): HTTP streams, remote SQL behavior, and blob encoding.
