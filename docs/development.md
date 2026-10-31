# Development

```sh
bundle install
bundle exec rake check
```

Tests use real native libSQL databases and clean up temporary files. No network service or credentials are required for the default suite. `sqlite3` is a development dependency for upstream compatibility tests; it is not loaded by the adapter.

## Code checks

`rake` defaults to `check`: `lint` followed by the tests. As in Sequel, tests run with `-w` and, on Ruby 3.4+, `-W:strict_unused_block`. There is no RuboCop/Standard configuration or complexity analyzer in Sequel's repository.

- `bundle exec rake check_syntax` checks Ruby syntax and parser warnings in project library, test, task, and example files, plus Gemfile/Rakefile/gemspec. It fails on invalid syntax or warnings. Ignored clones, private notes, and installed gems are outside its file list.
- `bundle exec rake check_visibility` uses Jeremy Evans' `visibility_checker`, also used by Sequel's optional visibility checks. It checks the database, dataset, and prepared dataset; changes originating in the adapter fail the task. Preexisting visibility changes inside Sequel itself are excluded.
- `bundle exec rake lint` runs both checks.
- `.github/workflows/ci.yml` runs `rake check` on Linux with Ruby 3.3, 3.4, and 4.0. The workflow configuration has been validated locally; those hosted jobs have not yet run for these changes.

Code size was reviewed using Ruby's Prism AST to locate complete methods. No artificial complexity score is enforced. The largest configuration/type-inference methods were split by responsibility; see [testing-review.md](testing-review.md) for the measured sizes and coverage findings.

## Reference sources

Reference repositories are checked out under Git-ignored `tmp/upstream/`. The adapter does not load implementation code from them.

```sh
mkdir -p tmp/upstream
git clone --depth 1 https://github.com/tursodatabase/libsql-ruby.git tmp/upstream/libsql-ruby
git clone --depth 1 https://github.com/tursodatabase/libsql-activerecord.git tmp/upstream/libsql-activerecord
git clone --depth 1 https://github.com/jeremyevans/sequel.git tmp/upstream/sequel
git clone --depth 1 https://github.com/sparklemotion/sqlite3-ruby.git tmp/upstream/sqlite3-ruby
git clone --depth 1 https://github.com/tursodatabase/libsql-c.git tmp/upstream/libsql-c
git clone --depth 1 https://github.com/tursodatabase/libsql-client-ts.git tmp/upstream/libsql-client-ts
git clone --depth 1 https://github.com/libsql/hrana-client-ts.git tmp/upstream/hrana-client-ts
git clone --depth 1 --filter=blob:none --sparse https://github.com/tursodatabase/libsql.git tmp/upstream/libsql
git -C tmp/upstream/libsql sparse-checkout set libsql/src libsql-hrana
```

`bundle exec rake upstream` runs the cloned Sequel SQLite adapter tests plus its integration suite in the upstream working directory, preserving its migration fixtures. It loads the cloned Sequel itself rather than accidentally loading two Sequel versions into one process. Tests use an in-memory database.

## Native HTTP integration

Prepare the official test server in an isolated Python environment:

```sh
python3.11 -m venv tmp/hrana-venv
tmp/hrana-venv/bin/pip install -r tmp/upstream/libsql-client-ts/testing/hrana-test-server/requirements.txt
bundle exec rake remote_local
```

The fixture needs a free localhost port 8080. It creates a temporary SQLite file, spawns the Ruby tests, then shuts down and removes its database. `test/support/hrana_server.py` fixes only the Python fixture's base64 padding incompatibility with the Rust client. No upstream source is modified.

For a disposable hosted database, export `LIBSQL_TEST_URL` and `LIBSQL_TEST_AUTH_TOKEN`, then run `bundle exec rake remote`. Tests create randomly named tables and drop only those tables. Do not point destructive integration fixtures from another project at a production database.

## Packaging

```sh
mkdir -p pkg
gem build libsql-sequel.gemspec --output pkg/libsql-sequel-0.1.0.gem
```

The explicit gem file list includes Ruby library files, public docs, examples, README, and LICENSE. It excludes private notes, cloned repositories, credentials, tests, and temporary databases. Nothing is automatically published.

## Agent continuation

Private research is in `private_docs/`, ignored by Git and excluded from the package. Read `private_docs/CONTINUATION.md`, then `ARCHITECTURE.md` and `RESEARCH.md`, after compaction before resuming work. Update the checkpoint with actual commands/results and open limitations as implementation changes.
