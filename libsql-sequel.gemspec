# frozen-string-literal: true

require_relative 'lib/sequel/libsql/version'

Gem::Specification.new do |s|
  s.name = 'libsql-sequel'
  s.version = Sequel::LibSQL::VERSION
  s.summary = 'A libSQL and Turso adapter for Sequel'
  s.description = 'Sequel SQL, models, migrations, and transactions using the native libSQL Ruby driver.'
  s.authors = ['Francesco Canessa']
  s.homepage = 'https://github.com/makevoid/libsql-sequel'
  s.license = 'MIT'
  s.required_ruby_version = '>= 3.3'
  s.files = Dir['lib/**/*.rb', 'docs/**/*.md', 'examples/*.rb'] + ['README.md', 'LICENSE']
  s.require_paths = ['lib']
  s.add_dependency 'sequel', '>= 5.80', '< 6'
  # 0.2.1 bundles native debug logging of auth tokens. Re-evaluate new releases
  # against the driver contract tests before widening this requirement.
  s.add_dependency 'turso_libsql', '= 0.2.0'
end
