# frozen-string-literal: true

require 'libsql-sequel'
require 'visibility_checker'

# Also check a prepared dataset: Sequel mixes additional modules into it.
Sequel.connect(:adapter => :libsql) do |db|
  prepared = db.select(Sequel.as(:$value, :value)).prepare(:first, :visibility_check)
  classes = [db.singleton_class, db.dataset.singleton_class, prepared.singleton_class]
  changes = classes.flat_map{|klass| VisibilityChecker.visibility_changes(klass)}.uniq
  # Sequel's own prepared module changes literal_symbol_append visibility.
  # Report changes introduced by this adapter, not inherited upstream changes.
  library = File.expand_path('../lib/', __dir__) + '/'
  changes.select! do |change|
    source = change.overridden_by.instance_method(change.method).source_location
    source && source.first.start_with?(library)
  end
  changes.each do |change|
    warn "#{change.overridden_by}##{change.method}: #{change.new_visibility} overrides #{change.original_visibility} in #{change.defined_in}"
  end
  abort 'Adapter method visibility changed' unless changes.empty?
end

puts 'No adapter method visibility changes'
