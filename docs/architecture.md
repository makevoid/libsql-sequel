# Architecture

The adapter follows Sequel's small Database/Dataset adapter pattern and delegates SQL dialect behavior to `Sequel::SQLite::DatabaseMethods` and `DatasetMethods`. It does not subclass the sqlite3-backed adapter, avoiding a second native database driver in production.

| Component | Responsibility |
| --- | --- |
| `lib/sequel/adapters/libsql.rb` | Register `:libsql`, create pooled connections, execute/log SQL, map errors, bind Ruby values, expose replica sync |
| `lib/sequel/libsql/configuration.rb` | Normalize memory/file/remote/replica options, reject unsupported or conflicting configuration |
| `lib/sequel/libsql/connection.rb` | Own database/connection handles; scope statements, results, and rows with `ensure` |
| `lib/sequel/libsql/native.rb` | Use the driver's native library/ABI; correct error, string, blob, and signed-integer handling |
| `lib/sequel/libsql/dataset.rb` | Map native rows to Sequel hashes, bind query parameters, and quote text |
| `lib/sequel/libsql/result_types.rb` | Resolve column origins and explicit type hints; reject ambiguous inference |
| `lib/sequel/libsql/type_converter.rb` | Convert storage values to semantic SQLite types |

## Ownership and concurrency

Each Sequel pool slot owns one native Database and Connection. A query owns its Statement, Result, and one Row at a time. Values are copied into Ruby before the row is freed. Native strings/blobs returned by the C API are copied and freed exactly once. Cleanup runs in reverse order on success, errors, early iteration exit, and connection setup failure. A result retained after its block raises rather than touching freed native memory.

Potentially blocking initialization, prepare, execute, query, row advance, and sync calls release the Ruby GVL. Sequel serializes access to a given connection; independent pool slots can run concurrently. Memory and embedded-replica pools are restricted to one slot. Explicit `disconnect` closes both handles, is idempotent, and leaves Sequel able to reconnect lazily.

There are no finalizers: explicit ownership avoids GC freeing a native parent while a child is in use. Application code must disconnect databases it no longer needs. Connections detect use from a different process and reject it. The upstream Rust runtime must be initialized in each worker after fork; this is not a fork-safe driver.

## Transactions and prepared queries

Sequel reserves one pool connection for the transaction and issues SQL BEGIN, COMMIT, ROLLBACK, and SAVEPOINT commands. The driver's native Transaction object is deliberately unused because its commit/rollback C functions return void and unwrap errors. SQL errors instead pass through a typed `Native::Error`, then Sequel's error classification.

Sequel's unnumbered argument mapper generates `?` placeholders and orders/repeats values correctly. Both `.call` and named `.prepare` queries use native binding. Native statements are short-lived, so failed statements cannot leave stale bindings, and DDL never needs to clear a statement cache. This trades additional prepare work (including remote round trips) for predictable resource handling.

## Type information

The C API exposes runtime types and column names, but not column declarations/origins. General sqlite3-style automatic result conversion is therefore impossible without a new upstream API. This adapter resolves only known single-table column projections, consulting Sequel's schema cache after the SQL has successfully prepared. It leaves expressions and ambiguous projections unchanged and offers `with_libsql_types` for explicit conversions.

Sequel's cached placeholder literalizer optimization is disabled because it replaces projected columns with opaque arguments. Without native declared-type metadata, that made repeated `get` calls lose their conversions after the cache activated. Native bound variables and named prepared statements remain supported; the tradeoff is additional Ruby SQL generation work.

Numeric timestamps follow Sequel's SQLite convention: Integer means Unix seconds and Float means Julian day. Numeric TIME values preserve microseconds. BLOB columns containing integer/real/text storage values convert through their string representation, and nonnumeric text in a decimal column remains text, matching Sequel's SQLite adapter.

Sequel invalidates its own schema cache for schema DSL changes. External schema changes and arbitrary DDL via `run` follow Sequel's usual cache rules; reload the affected schema or reconnect the Database object when needed. No extra unbounded type cache is introduced.

## Driver boundary

The compatibility layer uses `turso_libsql`'s shipped structs and binary functions without altering `Libsql` or `CLibsql` globally. Error messages are copied before freeing their C allocation. Signed integers are recovered from the upstream unsigned declaration. Blob binding is checked before String binding, and text uses UTF-8 byte lengths with a retained input pointer. Slice release uses the correct ABI type. Descriptor strings remain retained for their native database lifetime.

The exact 0.2.0 dependency prevents accidental activation of the credential-logging 0.2.1 native release. A future driver upgrade needs local/HTTP contract tests plus native binary review, not just a version bump.
