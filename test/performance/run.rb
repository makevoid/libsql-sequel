# frozen-string-literal: true

require 'optparse'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'rbconfig'
require 'time'
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'libsql-sequel'
require_relative 'workloads'

module LibSQLPerformance
  class Runner
    def initialize(argv)
      @options = {:adapter => 'libsql', :storage => 'memory', :iterations => 100,
        :warmup => 10, :samples => 5, :rows => 1000, :batch => 20, :workers => 4, :seed => 42}
      OptionParser.new do |parser|
        parser.banner = 'Usage: bundle exec ruby test/performance/run.rb [options]'
        parser.on('--adapter NAME', %w[libsql sqlite]){|value| @options[:adapter] = value}
        parser.on('--storage MODE', %w[memory file]){|value| @options[:storage] = value}
        [:iterations, :warmup, :samples, :rows, :batch, :workers, :seed].each do |key|
          parser.on("--#{key} N", Integer){|value| @options[key] = value}
        end
        parser.on('--filter REGEXP'){|value| @options[:filter] = value}
        parser.on('--output FILE'){|value| @options[:output] = value}
        parser.on('-h', '--help'){puts parser; exit}
      end.parse!(argv)
      raise ArgumentError, 'Unexpected positional arguments' unless argv.empty?
      [:iterations, :warmup, :samples, :rows, :batch, :workers].each do |key|
        raise ArgumentError, "#{key} must be positive" unless @options[key] > 0
      end
      raise ArgumentError, 'rows must be at least 10' if @options[:rows] < 10
    end

    def run
      Dir.mktmpdir('libsql-performance-') do |directory|
        connection_options = {:adapter => @options[:adapter].to_sym, :keep_reference => false,
          :database => @options[:storage] == 'memory' ? ':memory:' : File.join(directory, 'benchmark.db'),
          :max_connections => @options[:storage] == 'memory' ? 1 : @options[:workers], :synchronous => :normal}
        suite = Workloads.new(connection_options, @options[:rows], @options[:batch], @options[:workers])
        begin
          cases = suite.cases.select{|item| !@options[:filter] || Regexp.new(@options[:filter]).match?(item.name)}
          raise ArgumentError, 'Filter matched no workloads' if cases.empty?
          results = cases.to_h{|item| [item.name, []]}
          metadata = metadata(suite.db)
          puts "#{RUBY_DESCRIPTION}\n#{@options[:adapter]} / #{@options[:storage]}: #{cases.length} workloads, #{@options[:samples]} samples; GC enabled"
          cases.each{|item| exercise(item, @options[:warmup])}
          random = Random.new(@options[:seed])
          @options[:samples].times do |sample|
            cases.shuffle(:random => random).each do |item|
              count = item.iterations ? [item.iterations, @options[:iterations]].min : @options[:iterations]
              results[item.name] << exercise(item, count, true)
            end
            puts "Completed sample #{sample + 1}/#{@options[:samples]}"
          end
          report = {:format_version => 1, :metadata => metadata, :config => @options,
            :results => cases.map do |item|
              samples = results.fetch(item.name)
              {:name => item.name, :kind => item.kind, :units_per_iteration => item.units,
                :median_us => median(samples.map{|sample| sample[:us_per_iteration]}),
                :median_allocations => median(samples.map{|sample| sample[:allocations_per_iteration]}),
                :min_us => samples.map{|sample| sample[:us_per_iteration]}.min,
                :max_us => samples.map{|sample| sample[:us_per_iteration]}.max,
                :samples => samples}
            end}
          puts format('%-38s %12s %12s %12s', 'Workload', 'median us/op', 'units/sec', 'objects/op')
          report[:results].each do |result|
            puts format('%-38s %12.2f %12.0f %12.1f', result[:name], result[:median_us],
              result[:units_per_iteration] * 1_000_000 / result[:median_us], result[:median_allocations])
          end
          if path = @options[:output]
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, JSON.pretty_generate(report) + "\n")
            puts "Saved #{path}"
          end
        ensure
          suite.stop_workers
          suite.close
        end
      end
    end

    private

    def exercise(item, count, timed = false)
      item.prepare.call(count) if item.prepare
      GC.start if timed
      before = GC.stat if timed
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = nil
      count.times{|index| value = item.run.call(index)}
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      after = GC.stat if timed
      item.verify.call(value, count)
      return unless timed
      {:iterations => count, :elapsed_seconds => elapsed, :us_per_iteration => elapsed * 1_000_000 / count,
        :allocations_per_iteration => (after[:total_allocated_objects] - before[:total_allocated_objects]).fdiv(count),
        :gc_count => after[:count] - before[:count], :gc_time_ms => after[:time] - before[:time]}
    end

    def median(values)
      sorted = values.sort
      middle = sorted.length / 2
      sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def metadata(db)
      {:recorded_at => Time.now.utc.iso8601, :ruby => RUBY_DESCRIPTION,
        :platform => RUBY_PLATFORM, :host_cpu => RbConfig::CONFIG['host_cpu'],
        :yjit => defined?(RubyVM::YJIT) ? RubyVM::YJIT.enabled? : false,
        :gems => %w[sequel turso_libsql ffi sqlite3].to_h{|name| [name, Gem.loaded_specs[name]&.version&.to_s]},
        :sqlite_version => db.get(Sequel.function(:sqlite_version)),
        :journal_mode => db.fetch('PRAGMA journal_mode').single_value,
        :synchronous => db.fetch('PRAGMA synchronous').single_value,
        :adapter_source_sha256 => Digest::SHA256.hexdigest(Dir[File.expand_path('../../lib/**/*.rb', __dir__)].sort.map{|file| File.read(file)}.join),
        :harness_sha256 => Digest::SHA256.hexdigest(%w[run.rb workloads.rb].map{|file| File.read(File.join(__dir__, file))}.join)}
    end
  end
end

LibSQLPerformance::Runner.new(ARGV).run if $PROGRAM_NAME == __FILE__
