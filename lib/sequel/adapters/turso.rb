# frozen-string-literal: true

require_relative 'libsql'

# Route Sequel.connect('turso://...') through the same adapter and pool.
Sequel.synchronize { Sequel::ADAPTER_MAP[:turso] = Sequel::LibSQL::Database }
