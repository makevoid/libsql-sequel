# frozen-string-literal: true

module Sequel
  module LibSQL
    # Normalize local, remote, and embedded-replica options in one place.
    class Configuration
      attr_reader :native_options

      def initialize(db, options)
        @db = db
        database = options[:database]
        database = nil if database.to_s.empty?
        url = options[:url]
        if database && /\A(?:libsql|https?):\/\//i.match?(database.to_s)
          raise Sequel::Error, 'specify the remote URL with database or url, not both' if url && url != database
          url = database
          database = nil
        end
        path = options[:path] || database
        raise Sequel::Error, 'path must not be empty' if path && path.to_s.empty?
        if options[:path] && database && options[:path].to_s != database.to_s
          raise Sequel::Error, 'database and path specify different local files'
        end
        path = ':memory:' unless path || url
        if url
          uri = URI.parse(url.to_s)
          unless %w[libsql https http].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.fragment && !uri.query
            raise Sequel::Error, 'libSQL URL must use libsql, https, or http with a host and no credentials, query, or fragment'
          end
        elsif options[:auth_token]
          raise Sequel::Error, 'auth_token requires a remote URL'
        end

        @native_options = {:path => path && path.to_s, :url => url && url.to_s}
        [:auth_token, :encryption_key].each{|key| @native_options[key] = options[key] if options.key?(key)}
        # 0.2.0 requires a non-null token pointer even for an unauthenticated
        # local Hrana server. An empty token is the native no-auth convention.
        @native_options[:auth_token] ||= '' if url
        if options.key?(:namespace)
          unless CLibsql::DatabaseDesc.members.include?(:namespace)
            raise Sequel::Error, 'namespace is not supported by this turso_libsql release'
          end
          @native_options[:namespace] = options[:namespace]
        end
        @native_options[:read_your_writes] = boolean(options.fetch(:read_your_writes, true))
        interval = Integer(options.fetch(:sync_interval, 0))
        raise Sequel::Error, 'sync_interval must be an unsigned 64-bit millisecond interval' unless (0...(1 << 64)).cover?(interval)
        raise Sequel::Error, 'sync_interval requires an embedded replica' if interval > 0 && !replica?
        raise Sequel::Error, 'an embedded replica requires a file path, not :memory:' if replica? && path == ':memory:'
        @native_options[:sync_interval] = interval

        if url
          [:timeout, :case_sensitive_like, :auto_vacuum, :synchronous, :temp_store].each do |key|
            raise Sequel::Error, "#{key} is only supported for local libSQL databases" if options.key?(key)
          end
        end

        [:readonly, :disable_dqs, :setup_regexp_function, :synced, :webpki].each do |key|
          raise Sequel::Error, "#{key} is not supported by this adapter" if options.key?(key)
        end
        if single_connection? && Integer(options.fetch(:max_connections, 1)) != 1
          raise Sequel::Error, 'memory databases and embedded replicas require max_connections: 1'
        end
      rescue URI::InvalidURIError, ArgumentError, TypeError
        raise Sequel::Error, 'invalid libSQL connection configuration'
      end

      def replica?
        !!(@native_options[:path] && @native_options[:url])
      end

      def remote?
        !!@native_options[:url]
      end

      def single_connection?
        replica? || @native_options[:path] == ':memory:'
      end

      private

      def boolean(value)
        @db.send(:typecast_value_boolean, value)
      end
    end
  end
end
