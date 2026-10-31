# Spec and code-quality review

Reviewed 2026-10-31 against the cloned upstream sources, after the initial adapter commit `0b966b1` was pushed.

## Upstream comparison

| Source | Existing coverage | Action here |
| --- | --- | --- |
| Sequel SQLite adapter + integration specs | SQL generation, schema changes, constraints, transactions, models, associations, migrations, prepared queries | Continue running unmodified upstream specs with `rake upstream` |
| Sequel SQLite type-conversion group | Seven cases defined only for `adapter_scheme == :sqlite`; absent from the external-adapter run | Added local equivalents in `test/sqlite_types_test.rb` |
| Sequel SQLite-specific URI, regexp, temporary-release groups | Target sqlite3-specific APIs or explicitly create `Sequel.sqlite` | Keep native libSQL URL tests and explicit rejection of unsupported regexp options; do not pretend these groups exercise this adapter |
| libsql-activerecord | No dedicated adapter spec directory or test CI; example Rails scaffold has controller/system CRUD tests and an empty model test | Existing model tests cover local CRUD; added remote model lifecycle with Sequel's prepared-statements plugin |
| libsql-activerecord execution code | Separates row-returning queries, batch execution, affected counts, and insert IDs | Added remote empty-result metadata, NULL values, and UPDATE/DELETE RETURNING cases |

The ActiveRecord adapter cannot be tested by loading its Rails scaffold into this project: that would exercise ActiveRecord's adapter, not the Sequel implementation.

## Bugs exposed by the new specs

- Integer and Float timestamps now use Unix seconds and Julian days, respectively, supporting both Time and DateTime output classes.
- Numeric TIME values now round fractional seconds to microseconds as Sequel does.
- Numeric/text storage values in a BLOB column now become `Sequel::SQL::Blob` rather than raising or remaining plain strings.
- Nonnumeric text in a decimal column remains text, consistent with SQLite's flexible storage and Sequel's converter.
- Repeated `get` calls no longer lose result types once Sequel's placeholder-literalizer cache activates. The adapter disables that optimization because it hides projection origins; native bound/prepared statements still work.

## Linting and size review

Sequel has no RuboCop, Standard, Flog, Reek, or cyclomatic-complexity configuration. Its Rakefile supplies `check_syntax`, warning-enabled spec commands, and optional `visibility_checker` integration. Its contribution guide asks contributors to follow surrounding code style rather than prescribing an automatic formatter.

This repository now provides `check_syntax`, `check_visibility`, `lint`, and `check` tasks. Syntax and visibility failures were tested with deliberately invalid temporary probes and correctly returned nonzero exit statuses. These checks apply only to project code, not ignored upstream checkouts. No wholesale reformatting was performed.

Prism AST source ranges identified `Configuration#initialize` (58 lines) and `Dataset#libsql_types` (50 lines) as the longest methods. Configuration now separates location normalization, URL validation, credentials, replication options, and option validation. `ResultTypes` handles projection origins and `TypeConverter` handles semantic conversions. `Dataset` shrank from 130 to 58 lines. The longest library method is now 24 lines; the largest library file is 178 lines. These are source-size measurements, not cyclomatic scores.

## Verification

- `bundle exec rake check upstream remote_local`: 40 local tests / 196 assertions; 901 upstream tests / 7469 assertions / six upstream skips; five real native HTTP tests / 24 assertions. No failures or errors. Current-bundle syntax, warnings, and adapter visibility checks pass.
- The 40 local tests also pass with Sequel 5.80.0. That older Sequel emits a Ruby 4 URI deprecation warning from its own code; it is not an adapter warning.
- The CI workflow parses and invokes `rake check`, but its Linux/Ruby matrix has not been executed here.

Hosted Turso authentication/TLS, live replica sync/read-your-writes behavior, and encryption still need real service tests. Local descriptor support or mocked native calls would not establish those guarantees, so this review does not claim them.

## Source pointers

- [Sequel Rakefile](https://github.com/jeremyevans/sequel/blob/75b425dd1c1f34908426dd70371d14e4afb9c933/Rakefile)
- [Sequel SQLite specs](https://github.com/jeremyevans/sequel/blob/75b425dd1c1f34908426dd70371d14e4afb9c933/spec/adapters/sqlite_spec.rb)
- [Sequel contribution guide](https://github.com/jeremyevans/sequel/blob/75b425dd1c1f34908426dd70371d14e4afb9c933/CONTRIBUTING)
- [libsql-activerecord example tests](https://github.com/tursodatabase/libsql-activerecord/tree/4873624743b046dde6c0188963b22576d8341e3a/examples/railsapp/test)
