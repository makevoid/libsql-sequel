# libsql-sequel

A modular Ruby adapter for using [Sequel](https://github.com/jeremyevans/sequel) with local libSQL databases, remote Turso databases, and embedded replicas through [libsql-ruby](https://github.com/tursodatabase/libsql-ruby).

```ruby
require 'libsql-sequel'

DB = Sequel.connect(
  adapter: :libsql,
  database: ENV.fetch('TURSO_DATABASE_URL'),
  auth_token: ENV.fetch('TURSO_AUTH_TOKEN')
)

DB.create_table?(:items) do
  primary_key :id
  String :name, null: false
  Integer :quantity, default: 0
end

id = DB[:items].insert(name: 'Hello, Turso', quantity: 3)
DB[:items].where(id: id).first
# => {id: 1, name: "Hello, Turso", quantity: 3}

DB.disconnect
```

## Installation

Until a RubyGems release is available, install directly from GitHub:

```ruby
# Gemfile
gem 'libsql-sequel', git: 'https://github.com/makevoid/libsql-sequel.git', branch: 'main'
```

Then `bundle install`. Ruby 3.3+ and Sequel 5.80–5.x are required. The native dependency is **pinned to `turso_libsql` 0.2.0**: 0.2.1 contains native debug output of connection credentials and SQL. Do not widen that dependency without reviewing the replacement library. The adapter uses the bundled native library with scoped corrections for the driver's Ruby wrapper; it does not patch global `Libsql` classes or require `sqlite3` at runtime.

The driver bundles Apple Silicon macOS and glibc Linux x86_64/aarch64 libraries. Intel macOS, Windows, musl Linux, and JRuby are not supported by this pinned distribution. Current verification was on Apple Silicon macOS / Ruby 4.0.5. See [compatibility and verification](docs/compatibility.md).

## Connection modes

Turso Cloud's `turso://` URLs are also accepted, both as `database:`/`url:`
options and directly through `Sequel.connect('turso://...', auth_token: ...)`.
They are normalized to `https://` for the pinned native driver before opening
a connection. The same credential/query/fragment validation applies. A
`turso://` database URL is never treated as a local file path.

```ruby
# Memory: a single pooled connection.
db = Sequel.connect(adapter: :libsql)

# Local file: regular Sequel pooling (default four connections).
db = Sequel.connect(adapter: :libsql, database: 'app.db', max_connections: 4)

# Native libsql:// URLs work directly. https:// and http:// use the hash form.
db = Sequel.connect(ENV.fetch('TURSO_DATABASE_URL'),
  auth_token: ENV.fetch('TURSO_AUTH_TOKEN'))

# Embedded replica: local file plus remote primary URL.
db = Sequel.connect(
  adapter: :libsql,
  database: ENV.fetch('TURSO_DATABASE_URL'),
  path: 'replica.db',
  auth_token: ENV.fetch('TURSO_AUTH_TOKEN'),
  sync_interval: 1_000,
  read_your_writes: true
)
db.sync # => {frame_no: ..., frames_synced: ...}
```

`url:` can also specify the remote URL; `database:` or `path:` then names the local replica. Memory databases and replicas require `max_connections: 1`. This avoids separate memory databases and multiple replication workers targeting one file. Replica sync cannot run inside a transaction. Embedded replication is implemented but has not been tested against a live Turso primary.

Keep tokens in the `auth_token:` option rather than the URL. URLs with credentials, query parameters, or fragments are rejected.

For Puma and other forking servers, initialize native connections inside each worker after forking. If the parent has opened connections, call `DB.disconnect` in `before_fork` to release them in their owning process. Calling `DB.disconnect` in a child quietly discards inherited handles without invoking native destructors; inherited queries still raise `Sequel::Error`. Disconnecting does not reset an already initialized Rust runtime, so child cleanup alone does not make preloading the native runtime safe.

Local connections enable foreign keys, case-sensitive `LIKE`, and a 5,000 ms SQLite busy timeout by default. `timeout:`, `case_sensitive_like:`, `auto_vacuum:`, `synchronous:`, and `temp_store:` are local-only options. The native remote parser rejects those PRAGMAs; remote connections keep the server's `LIKE` behavior. `timeout:` is a SQLite lock timeout, not an HTTP timeout. `readonly:`, custom regexp functions, `disable_dqs:`, offline-write mode, and custom TLS options are unsupported and rejected.

## Sequel features

SQL generation, schema introspection, migrations, models, associations, upserts, and `RETURNING` reuse Sequel's shared SQLite implementation. The adapter scheme is `:libsql`; `database_type` is `:sqlite`.

```ruby
DB.transaction do
  DB[:items].insert(name: 'committed')
  DB.transaction(savepoint: true) do
    DB[:items].insert(name: 'rolled back')
    raise Sequel::Rollback
  end
end

find_item = DB[:items].where(id: :$id).prepare(:first, :find_item)
find_item.call(id: 1)
DB.call(:find_item, id: 1)

DB[:items].where(id: :$id).call(:update, {id: 1, quantity: 5}, quantity: :$quantity)
DB[:items].returning(:id).insert(name: 'returned')
```

Bound values use native parameters. Named Sequel prepared queries prepare a native statement for each execution and always release it; there is no persistent statement cache. `DB.run` supports SQL batches. Commit and rollback run as SQL so errors propagate to Sequel instead of using the driver's abort-prone native transaction helpers. There are no automatic retries of failed writes.

## Values and result types

Integers preserve signed 64-bit values; strings are converted to UTF-8; blobs preserve all bytes. Use `Sequel.blob(bytes)` for binary data. Invalid text encodings and strings that cannot be converted to UTF-8 raise `Sequel::Error`. NUL-containing text is rejected on input because the native C API truncates it. The same upstream limitation affects existing TEXT values containing NUL when reading them; store those values as blobs. Out-of-range bound integers, invalid text, and non-finite bound floats are rejected.

The native API does not expose declared result-column types. Simple single-table datasets infer date, datetime, time, decimal, and boolean conversions from Sequel's schema cache, including direct column aliases and prepared queries. Raw SQL, joins, CTEs, compounds, and arbitrary expressions retain native SQLite values. Use explicit hints when necessary:

```ruby
DB.fetch('SELECT active, created_at FROM items').with_libsql_types(
  active: :boolean,
  created_at: :datetime
).all

# Supported hints: :boolean, :date, :datetime, :timestamp, :time, :decimal,
# :integer, :float, :blob, or a callable. NULL always remains nil.
DB.fetch('SELECT upper(name) AS label FROM items').with_libsql_types(
  label: ->(value) { value.freeze }
).all
```

Use `Sequel::Model` normally for single-table model datasets. Joined/eager-graph results with boolean or temporal columns may need explicit result type hints. Expression aliases never acquire a type merely because they match a table column name. SQLite's own numeric affinity and decimal precision limitations still apply.

## Development and tests

```sh
bundle install
bundle exec rake check         # syntax, visibility, and warning-enabled tests
bundle exec rake lint          # syntax and method visibility only
bundle exec rake test          # real native local/file databases
bundle exec rake upstream      # upstream SQLite + integration specs
bundle exec rake remote_local  # real native HTTP client, local Hrana server
```

`upstream` and `remote_local` need the ignored reference checkouts; setup instructions are in [development.md](docs/development.md). `rake` defaults to `check`. Checks follow Sequel's own syntax/warnings/visibility approach; Sequel does not configure RuboCop or a complexity analyzer. See [the spec and code-quality review](docs/testing-review.md).

For an explicit test against a **disposable** hosted database, set `LIBSQL_TEST_URL` and `LIBSQL_TEST_AUTH_TOKEN` in your environment, then run `bundle exec rake remote`. It creates randomly named test tables and drops those tables afterward. Hosted authentication and HTTPS remote operations have been validated with a `turso://` URL; embedded replication remains unverified. See [compatibility and verification](docs/compatibility.md) for the tested scope.

See [architecture](docs/architecture.md), [compatibility](docs/compatibility.md), and [the local example](examples/local.rb).
