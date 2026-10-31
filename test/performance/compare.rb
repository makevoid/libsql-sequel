# frozen-string-literal: true

require 'json'

abort 'Usage: ruby test/performance/compare.rb BEFORE.json AFTER.json' unless ARGV.length == 2
before, after = ARGV.map{|path| JSON.parse(File.read(path))}
%w[storage iterations warmup samples rows batch workers seed filter].each do |key|
  abort "Incompatible benchmark setting: #{key}" unless before.fetch('config')[key] == after.fetch('config')[key]
end
%w[ruby platform yjit harness_sha256 journal_mode synchronous].each do |key|
  abort "Incompatible benchmark environment: #{key}" unless before.fetch('metadata')[key] == after.fetch('metadata')[key]
end
if before.fetch('config')['adapter'] == after.fetch('config')['adapter']
  %w[gems sqlite_version].each do |key|
    abort "Incompatible benchmark dependency: #{key}" unless before.fetch('metadata')[key] == after.fetch('metadata')[key]
  end
end
reference = before.fetch('results').to_h{|result| [result.fetch('name'), result]}
puts 'Speedup = before / after; >1 is faster. Spread is min..max sample mean, not request latency percentiles.'
puts format('%-38s %9s %9s %9s %14s %21s', 'Workload', 'before us', 'after us', 'speedup', 'objects delta', 'after spread us')
after.fetch('results').each do |result|
  next unless original = reference[result.fetch('name')]
  abort 'Incompatible units' unless result['units_per_iteration'] == original['units_per_iteration']
  puts format('%-38s %9.2f %9.2f %8.2fx %14.1f %10.2f..%8.2f', result['name'],
    original['median_us'], result['median_us'], original['median_us'] / result['median_us'],
    result['median_allocations'] - original['median_allocations'], result['min_us'], result['max_us'])
end
