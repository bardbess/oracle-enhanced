# frozen_string_literal: true

# oracle_enhanced_adapter.rb -- ActiveRecord adapter for Oracle 10g, 11g and 12c
#
# Authors or original oracle_adapter: Graham Jenkins, Michael Schoen
#
# Current maintainer: Raimonds Simanovskis (http://blog.rayapps.com)
#
#########################################################################
#
# See History.md for changes added to original oracle_adapter.rb
#
#########################################################################
#
# From original oracle_adapter.rb:
#
# Implementation notes:
# 1. Redefines (safely) a method in ActiveRecord to make it possible to
#    implement an autonumbering solution for Oracle.
# 2. The OCI8 driver is patched to properly handle values for LONG and
#    TIMESTAMP columns. The driver-author has indicated that a future
#    release of the driver will obviate this patch.
# 3. LOB support is implemented through an after_save callback.
# 4. Oracle does not offer native LIMIT and OFFSET options; this
#    functionality is mimiced through the use of nested selects.
#    See http://asktom.oracle.com/pls/ask/f?p=4950:8:::::F4950_P8_DISPLAYID:127412348064
#
# Do what you want with this code, at your own peril, but if any
# significant portion of my code remains then please acknowledge my
# contribution.
# portions Copyright 2005 Graham Jenkins

require "active_record/connection_adapters/abstract_adapter"
require "active_record/connection_adapters/statement_pool"
require "active_record/connection_adapters/oracle_enhanced/connection"
require "active_record/connection_adapters/oracle_enhanced/database_statements"
require "active_record/connection_adapters/oracle_enhanced/schema_creation"
require "active_record/connection_adapters/oracle_enhanced/schema_definitions"
require "active_record/connection_adapters/oracle_enhanced/schema_dumper"
require "active_record/connection_adapters/oracle_enhanced/schema_statements"
require "active_record/connection_adapters/oracle_enhanced/schema_statements_ext"
require "active_record/connection_adapters/oracle_enhanced/context_index"
require "active_record/connection_adapters/oracle_enhanced/column"
require "active_record/connection_adapters/oracle_enhanced/quoting"
require "active_record/connection_adapters/oracle_enhanced/database_limits"
require "active_record/connection_adapters/oracle_enhanced/dbms_output"
require "active_record/connection_adapters/oracle_enhanced/type_metadata"
require "active_record/connection_adapters/oracle_enhanced/structure_dump"
require "active_record/connection_adapters/oracle_enhanced/lob"

require "active_record/type/oracle_enhanced/raw"
require "active_record/type/oracle_enhanced/integer"
require "active_record/type/oracle_enhanced/string"
require "active_record/type/oracle_enhanced/national_character_string"
require "active_record/type/oracle_enhanced/text"
require "active_record/type/oracle_enhanced/national_character_text"
require "active_record/type/oracle_enhanced/boolean"
require "active_record/type/oracle_enhanced/json"
require "active_record/type/oracle_enhanced/timestamptz"
require "active_record/type/oracle_enhanced/timestampltz"

module ActiveRecord
  module ConnectionHandling #:nodoc:
    # Establishes a connection to the database that's used by all Active Record objects.
    def oracle_enhanced_connection(config) #:nodoc:
      if config[:emulate_oracle_adapter] == true
        # allows the enhanced adapter to look like the OracleAdapter. Useful to pick up
        # conditionals in the rails activerecord test suite
        require "active_record/connection_adapters/emulation/oracle_adapter"
        ConnectionAdapters::OracleAdapter.new(
          ConnectionAdapters::OracleEnhanced::Connection.create(config), logger, config)
      else
        ConnectionAdapters::OracleEnhancedAdapter.new(
          ConnectionAdapters::OracleEnhanced::Connection.create(config), logger, config)
      end
    end
  end

  module ConnectionAdapters #:nodoc:
    # Oracle enhanced adapter will work with both
    # CRuby ruby-oci8 gem (which provides interface to Oracle OCI client)
    # or with JRuby and Oracle JDBC driver.
    #
    # It should work with Oracle 10g, 11g and 12c databases.
    #
    # Usage notes:
    # * Key generation assumes a "${table_name}_seq" sequence is available
    #   for all tables; the sequence name can be changed using
    #   ActiveRecord::Base.set_sequence_name. When using Migrations, these
    #   sequences are created automatically.
    #   Use set_sequence_name :autogenerated with legacy tables that have
    #   triggers that populate primary keys automatically.
    # * Oracle uses DATE or TIMESTAMP datatypes for both dates and times.
    #   Consequently some hacks are employed to map data back to Date or Time
    #   in Ruby. Timezones and sub-second precision on timestamps are
    #   not supported.
    # * Default values that are functions (such as "SYSDATE") are not
    #   supported. This is a restriction of the way ActiveRecord supports
    #   default values.
    #
    # Required parameters:
    #
    # * <tt>:username</tt>
    # * <tt>:password</tt>
    # * <tt>:database</tt> - either TNS alias or connection string for OCI client or database name in JDBC connection string
    #
    # Optional parameters:
    #
    # * <tt>:host</tt> - host name for JDBC connection, defaults to "localhost"
    # * <tt>:port</tt> - port number for JDBC connection, defaults to 1521
    # * <tt>:privilege</tt> - set "SYSDBA" if you want to connect with this privilege
    # * <tt>:allow_concurrency</tt> - set to "true" if non-blocking mode should be enabled (just for OCI client)
    # * <tt>:prefetch_rows</tt> - how many rows should be fetched at one time to increase performance, defaults to 100
    # * <tt>:cursor_sharing</tt> - cursor sharing mode to minimize amount of unique statements, no default value
    # * <tt>:time_zone</tt> - database session time zone
    #   (it is recommended to set it using ENV['TZ'] which will be then also used for database session time zone)
    # * <tt>:schema</tt> - database schema which holds schema objects.
    #
    # Optionals NLS parameters:
    #
    # * <tt>:nls_calendar</tt>
    # * <tt>:nls_comp</tt>
    # * <tt>:nls_currency</tt>
    # * <tt>:nls_date_format</tt> - format for :date columns, defaults to <tt>YYYY-MM-DD HH24:MI:SS</tt>
    #   (changing `nls_date_format` parameter value is not supported. Use the default value.)
    # * <tt>:nls_date_language</tt>
    # * <tt>:nls_dual_currency</tt>
    # * <tt>:nls_iso_currency</tt>
    # * <tt>:nls_language</tt>
    # * <tt>:nls_length_semantics</tt> - semantics of size of VARCHAR2 and CHAR columns, defaults to <tt>CHAR</tt>
    #   (meaning that size specifies number of characters and not bytes)
    # * <tt>:nls_nchar_conv_excp</tt>
    # * <tt>:nls_numeric_characters</tt>
    # * <tt>:nls_sort</tt>
    # * <tt>:nls_territory</tt>
    # * <tt>:nls_timestamp_format</tt> - format for :timestamp columns, defaults to <tt>YYYY-MM-DD HH24:MI:SS:FF6</tt>
    #   (changing `nls_timestamp_format` parameter value is not supported. Use the default value.)
    # * <tt>:nls_timestamp_tz_format</tt>
    # * <tt>:nls_time_format</tt>
    # * <tt>:nls_time_tz_format</tt>
    #
    class OracleEnhancedAdapter < AbstractAdapter
      include OracleEnhanced::DatabaseStatements
      include OracleEnhanced::SchemaStatements
      include OracleEnhanced::SchemaStatementsExt
      include OracleEnhanced::ContextIndex
      include OracleEnhanced::Quoting
      include OracleEnhanced::DatabaseLimits
      include OracleEnhanced::DbmsOutput
      include OracleEnhanced::StructureDump

      ##
      # :singleton-method:
      # By default, the OracleEnhancedAdapter will consider all columns of type <tt>NUMBER(1)</tt>
      # as boolean. If you wish to disable this emulation you can add the following line
      # to your initializer file:
      #
      #   ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans = false
      cattr_accessor :emulate_booleans
      self.emulate_booleans = true

      ##
      # :singleton-method:
      # OracleEnhancedAdapter will use the default tablespace, but if you want specific types of
      # objects to go into specific tablespaces, specify them like this in an initializer:
      #
      #   ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.default_tablespaces =
      #  {:clob => 'TS_LOB', :blob => 'TS_LOB', :index => 'TS_INDEX', :table => 'TS_DATA'}
      #
      # Using the :tablespace option where available (e.g create_table) will take precedence
      # over these settings.
      cattr_accessor :default_tablespaces
      self.default_tablespaces = {}

      ##
      # :singleton-method:
      # If you wish that CHAR(1), VARCHAR2(1) columns are typecasted to booleans
      # then you can add the following line to your initializer file:
      #
      #   ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.emulate_booleans_from_strings = true
      cattr_accessor :emulate_booleans_from_strings
      self.emulate_booleans_from_strings = false

      ##
      # :singleton-method:
      # By default, OracleEnhanced adapter will use Oracle12 visitor
      # if database version is Oracle 12.1.
      # If you wish to use Oracle visitor which is intended to work with Oracle 11.2 or lower
      # for Oracle 12.1 database you can add the following line to your initializer file:
      #
      #   ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.use_old_oracle_visitor = true
      cattr_accessor :use_old_oracle_visitor
      self.use_old_oracle_visitor = false

      ##
      # :singleton-method:
      # Specify default sequence start with value (by default 10000 if not explicitly set), e.g.:
      #
      #   ActiveRecord::ConnectionAdapters::OracleEnhancedAdapter.default_sequence_start_value = 1
      cattr_accessor :default_sequence_start_value
      self.default_sequence_start_value = 10000

      class StatementPool < ConnectionAdapters::StatementPool
        private

          def dealloc(stmt)
            stmt.close
          end
      end

      def initialize(connection, logger = nil, config = {}) # :nodoc:
        super(connection, logger, config)
        @statements = StatementPool.new(self.class.type_cast_config_to_integer(config[:statement_limit]))
        @enable_dbms_output = false
      end

      ADAPTER_NAME = "OracleEnhanced".freeze

      def adapter_name #:nodoc:
        ADAPTER_NAME
      end

      def arel_visitor # :nodoc:
        if supports_fetch_first_n_rows_and_offset?
          Arel::Visitors::Oracle12.new(self)
        else
          Arel::Visitors::Oracle.new(self)
        end
      end

      def supports_savepoints? #:nodoc:
        true
      end

      def supports_transaction_isolation? #:nodoc:
        true
      end

      def supports_foreign_keys?
        true
      end

      def supports_foreign_keys_in_create?
        supports_foreign_keys?
      end

      def supports_views?
        true
      end

      def supports_fetch_first_n_rows_and_offset?
        if !use_old_oracle_visitor && @connection.database_version.first >= 12
          true
        else
          false
        end
      end

      def supports_datetime_with_precision?
        true
      end

      def supports_comments?
        true
      end

      def supports_multi_insert?
        @connection.database_version.to_s >= [11, 2].to_s
      end

      def supports_virtual_columns?
        @connection.database_version.first >= 11
      end

      def supports_json?
        # Oracle Database 12.1 or higher version supports JSON.
        # However, Oracle enhanced adapter has limited support for JSON data type.
        # which does not pass many of ActiveRecord JSON tests.
        #
        # No migration supported for :json type due to there is no `JSON` data type
        # in Oracle Database itself.
        #
        # If you want to use JSON data type, here are steps
        # 1.Define :string or :text in migration
        #
        # create_table :test_posts, force: true do |t|
        #   t.string  :title
        #   t.text    :article
        # end
        #
        # 2. Set :json attributes
        #
        # class TestPost < ActiveRecord::Base
        #  attribute :title, :json
        #  attribute :article, :json
        # end
        #
        # 3. Add `is json` database constraints by running sql statements
        #
        # alter table test_posts add constraint test_posts_title_is_json check (title is json)
        # alter table test_posts add constraint test_posts_article_is_json check (article is json)
        #
        false
      end

      #:stopdoc:
      DEFAULT_NLS_PARAMETERS = {
        nls_calendar: nil,
        nls_comp: nil,
        nls_currency: nil,
        nls_date_format: "YYYY-MM-DD HH24:MI:SS",
        nls_date_language: nil,
        nls_dual_currency: nil,
        nls_iso_currency: nil,
        nls_language: nil,
        nls_length_semantics: "CHAR",
        nls_nchar_conv_excp: nil,
        nls_numeric_characters: nil,
        nls_sort: nil,
        nls_territory: nil,
        nls_timestamp_format: "YYYY-MM-DD HH24:MI:SS:FF6",
        nls_timestamp_tz_format: nil,
        nls_time_format: nil,
        nls_time_tz_format: nil
      }

      #:stopdoc:
      NATIVE_DATABASE_TYPES = {
        primary_key: "NUMBER(38) NOT NULL PRIMARY KEY",
        string: { name: "VARCHAR2", limit: 255 },
        text: { name: "CLOB" },
        ntext: { name: "NCLOB" },
        integer: { name: "NUMBER", limit: 38 },
        float: { name: "BINARY_FLOAT" },
        decimal: { name: "DECIMAL" },
        datetime: { name: "TIMESTAMP" },
        timestamp: { name: "TIMESTAMP" },
        timestamptz: { name: "TIMESTAMP WITH TIME ZONE" },
        timestampltz: { name: "TIMESTAMP WITH LOCAL TIME ZONE" },
        time: { name: "TIMESTAMP" },
        date: { name: "DATE" },
        binary: { name: "BLOB" },
        boolean: { name: "NUMBER", limit: 1 },
        raw: { name: "RAW", limit: 2000 },
        bigint: { name: "NUMBER", limit: 19 }
      }
      # if emulate_booleans_from_strings then store booleans in VARCHAR2
      NATIVE_DATABASE_TYPES_BOOLEAN_STRINGS = NATIVE_DATABASE_TYPES.dup.merge(
        boolean: { name: "VARCHAR2", limit: 1 }
      )
      #:startdoc:

      def native_database_types #:nodoc:
        emulate_booleans_from_strings ? NATIVE_DATABASE_TYPES_BOOLEAN_STRINGS : NATIVE_DATABASE_TYPES
      end

      # CONNECTION MANAGEMENT ====================================
      #

      # If SQL statement fails due to lost connection then reconnect
      # and retry SQL statement if autocommit mode is enabled.
      # By default this functionality is disabled.
      attr_reader :auto_retry #:nodoc:
      @auto_retry = false

      def auto_retry=(value) #:nodoc:
        @auto_retry = value
        @connection.auto_retry = value if @connection
      end

      # return raw OCI8 or JDBC connection
      def raw_connection
        @connection.raw_connection
      end

      # Returns true if the connection is active.
      def active? #:nodoc:
        # Pings the connection to check if it's still good. Note that an
        # #active? method is also available, but that simply returns the
        # last known state, which isn't good enough if the connection has
        # gone stale since the last use.
        @connection.ping
      rescue OracleEnhanced::ConnectionException
        false
      end

      # Reconnects to the database.
      def reconnect! #:nodoc:
        super
        @connection.reset!
      rescue OracleEnhanced::ConnectionException => e
        @logger.warn "#{adapter_name} automatic reconnection failed: #{e.message}" if @logger
      end

      def reset!
        clear_cache!
        super
      end

      # Disconnects from the database.
      def disconnect! #:nodoc:
        super
        @connection.logoff rescue nil
      end

      def discard!
        @connection = nil
      end

      # use in set_sequence_name to avoid fetching primary key value from sequence
      AUTOGENERATED_SEQUENCE_NAME = "autogenerated".freeze

      # Returns the next sequence value from a sequence generator. Not generally
      # called directly; used by ActiveRecord to get the next primary key value
      # when inserting a new database record (see #prefetch_primary_key?).
      def next_sequence_value(sequence_name)
        # if sequence_name is set to :autogenerated then it means that primary key will be populated by trigger
        return nil if sequence_name == AUTOGENERATED_SEQUENCE_NAME
        # call directly connection method to avoid prepared statement which causes fetching of next sequence value twice
        select_value(<<-SQL.strip.gsub(/\s+/, " "), "next sequence value")
          SELECT #{quote_table_name(sequence_name)}.NEXTVAL FROM dual
        SQL
      end

      # Returns true for Oracle adapter (since Oracle requires primary key
      # values to be pre-fetched before insert). See also #next_sequence_value.
      def prefetch_primary_key?(table_name = nil)
        return true if table_name.nil?
        table_name = table_name.to_s
        owner, desc_table_name, db_link = @connection.describe(table_name)
        do_not_prefetch = !has_primary_key?(table_name, owner, desc_table_name, db_link) || has_primary_key_trigger?(table_name, owner, desc_table_name, db_link)
        !do_not_prefetch
      end

      def reset_pk_sequence!(table_name, primary_key = nil, sequence_name = nil) #:nodoc:
        return nil unless data_source_exists?(table_name)
        unless primary_key && sequence_name
          # *Note*: Only primary key is implemented - sequence will be nil.
          primary_key, sequence_name = pk_and_sequence_for(table_name)
          # TODO This sequence_name implemantation is just enough
          # to satisty fixures. To get correct sequence_name always
          # pk_and_sequence_for method needs some work.
          begin
            sequence_name = table_name.classify.constantize.sequence_name
          rescue
            sequence_name = default_sequence_name(table_name)
          end
        end

        if @logger && primary_key && !sequence_name
          @logger.warn "#{table_name} has primary key #{primary_key} with no default sequence"
        end

        if primary_key && sequence_name
          new_start_value = select_value(<<-SQL.strip.gsub(/\s+/, " "), "new start value")
            select NVL(max(#{quote_column_name(primary_key)}),0) + 1 from #{quote_table_name(table_name)}
          SQL

          execute "DROP SEQUENCE #{quote_table_name(sequence_name)}"
          execute "CREATE SEQUENCE #{quote_table_name(sequence_name)} START WITH #{new_start_value}"
        end
      end

      # Current database name
      def current_database
        select_value(<<-SQL.strip.gsub(/\s+/, " "), "current database on CDB ")
          SELECT SYS_CONTEXT('userenv', 'con_name') FROM dual
        SQL
      rescue ActiveRecord::StatementInvalid
        select_value(<<-SQL.strip.gsub(/\s+/, " "), "current database")
          SELECT SYS_CONTEXT('userenv', 'db_name') FROM dual
        SQL
      end

      # Current database session user
      def current_user
        select_value(<<-SQL.strip.gsub(/\s+/, " "), "current user")
          SELECT SYS_CONTEXT('userenv', 'session_user') FROM dual
        SQL
      end

      # Current database session schema
      def current_schema
        select_value(<<-SQL.strip.gsub(/\s+/, " "), "current schema")
          SELECT SYS_CONTEXT('userenv', 'current_schema') FROM dual
        SQL
      end

      # Default tablespace name of current user
      def default_tablespace
        select_value(<<-SQL.strip.gsub(/\s+/, " "), "default tablespace")
          SELECT LOWER(default_tablespace) FROM user_users
          WHERE username = SYS_CONTEXT('userenv', 'current_schema')
        SQL
      end

      # check if table has primary key trigger with _pkt suffix
      def has_primary_key_trigger?(table_name, owner = nil, desc_table_name = nil, db_link = nil)
        (owner, desc_table_name, db_link) = @connection.describe(table_name) unless owner

        trigger_name = default_trigger_name(table_name).upcase

        !!select_value(<<-SQL.strip.gsub(/\s+/, " "), "Primary Key Trigger", [bind_string("owner", owner), bind_string("trigger_name", trigger_name), bind_string("owner", owner), bind_string("table_name", desc_table_name)])
          SELECT trigger_name
          FROM all_triggers#{db_link}
          WHERE owner = :owner
            AND trigger_name = :trigger_name
            AND table_owner = :owner
            AND table_name = :table_name
            AND status = 'ENABLED'
        SQL
      end

      def column_definitions(table_name)
        (owner, desc_table_name, db_link) = @connection.describe(table_name)

        select_all(<<-SQL.strip.gsub(/\s+/, " "), "Column definitions", [bind_string("owner", owner), bind_string("table_name", desc_table_name)])
          SELECT cols.column_name AS name, cols.data_type AS sql_type,
                 cols.data_default, cols.nullable, cols.virtual_column, cols.hidden_column,
                 cols.data_type_owner AS sql_type_owner,
                 DECODE(cols.data_type, 'NUMBER', data_precision,
                                   'FLOAT', data_precision,
                                   'VARCHAR2', DECODE(char_used, 'C', char_length, data_length),
                                   'RAW', DECODE(char_used, 'C', char_length, data_length),
                                   'CHAR', DECODE(char_used, 'C', char_length, data_length),
                                    NULL) AS limit,
                 DECODE(data_type, 'NUMBER', data_scale, NULL) AS scale,
                 comments.comments as column_comment
            FROM all_tab_cols#{db_link} cols, all_col_comments#{db_link} comments
           WHERE cols.owner      = :owner
             AND cols.table_name = :table_name
             AND cols.hidden_column = 'NO'
             AND cols.owner = comments.owner
             AND cols.table_name = comments.table_name
             AND cols.column_name = comments.column_name
           ORDER BY cols.column_id
        SQL
      end

      # Find a table's primary key and sequence.
      # *Note*: Only primary key is implemented - sequence will be nil.
      def pk_and_sequence_for(table_name, owner = nil, desc_table_name = nil, db_link = nil) #:nodoc:
        (owner, desc_table_name, db_link) = @connection.describe(table_name) unless owner

        seqs = select_values(<<-SQL.strip.gsub(/\s+/, " "), "Sequence", [bind_string("owner", owner), bind_string("sequence_name", default_sequence_name(desc_table_name).upcase)])
          select us.sequence_name
          from all_sequences#{db_link} us
          where us.sequence_owner = :owner
          and us.sequence_name = :sequence_name
        SQL

        # changed back from user_constraints to all_constraints for consistency
        pks = select_values(<<-SQL.strip.gsub(/\s+/, " "), "Primary Key", [bind_string("owner", owner), bind_string("table_name", desc_table_name)])
          SELECT cc.column_name
            FROM all_constraints#{db_link} c, all_cons_columns#{db_link} cc
           WHERE c.owner = :owner
             AND c.table_name = :table_name
             AND c.constraint_type = 'P'
             AND cc.owner = c.owner
             AND cc.constraint_name = c.constraint_name
        SQL

        warn <<-WARNING.strip_heredoc if pks.count > 1
          WARNING: Active Record does not support composite primary key.

          #{table_name} has composite primary key. Composite primary key is ignored.
        WARNING

        # only support single column keys
        pks.size == 1 ? [oracle_downcase(pks.first),
                         oracle_downcase(seqs.first)] : nil
      end

      # Returns just a table's primary key
      def primary_key(table_name)
        pk_and_sequence = pk_and_sequence_for(table_name)
        pk_and_sequence && pk_and_sequence.first
      end

      def has_primary_key?(table_name, owner = nil, desc_table_name = nil, db_link = nil) #:nodoc:
        !pk_and_sequence_for(table_name, owner, desc_table_name, db_link).nil?
      end

      def primary_keys(table_name) # :nodoc:
        (owner, desc_table_name, db_link) = @connection.describe(table_name) unless owner

        pks = select_values(<<-SQL.strip.gsub(/\s+/, " "), "Primary Keys", [bind_string("owner", owner), bind_string("table_name", desc_table_name)])
          SELECT cc.column_name
            FROM all_constraints#{db_link} c, all_cons_columns#{db_link} cc
           WHERE c.owner = :owner
             AND c.table_name = :table_name
             AND c.constraint_type = 'P'
             AND cc.owner = c.owner
             AND cc.constraint_name = c.constraint_name
             order by cc.position
        SQL
        pks.map { |pk| oracle_downcase(pk) }
      end

      def columns_for_distinct(columns, orders) #:nodoc:
        # construct a valid columns name for DISTINCT clause,
        # ie. one that includes the ORDER BY columns, using FIRST_VALUE such that
        # the inclusion of these columns doesn't invalidate the DISTINCT
        #
        # It does not construct DISTINCT clause. Just return column names for distinct.
        order_columns = orders.reject(&:blank?).map { |s|
            s = s.to_sql unless s.is_a?(String)
            # remove any ASC/DESC modifiers
            s.gsub(/\s+(ASC|DESC)\s*?/i, "")
          }.reject(&:blank?).map.with_index { |column, i|
            "FIRST_VALUE(#{column}) OVER (PARTITION BY #{columns} ORDER BY #{column}) AS alias_#{i}__"
          }
        [super, *order_columns].join(", ")
      end

      def temporary_table?(table_name) #:nodoc:
        select_value(<<-SQL.strip.gsub(/\s+/, " "), "temporary table", [bind_string("table_name", table_name.upcase)]) == "Y"
          SELECT temporary FROM all_tables WHERE table_name = :table_name and owner = SYS_CONTEXT('userenv', 'session_user')
        SQL
      end

      private

        def initialize_type_map(m = type_map)
          super
          # oracle
          register_class_with_precision m, %r(WITH TIME ZONE)i,       Type::OracleEnhanced::TimestampTz
          register_class_with_precision m, %r(WITH LOCAL TIME ZONE)i, Type::OracleEnhanced::TimestampLtz
          register_class_with_limit m, %r(raw)i,            Type::OracleEnhanced::Raw
          register_class_with_limit m, %r(char)i,           Type::OracleEnhanced::String
          register_class_with_limit m, %r(clob)i,           Type::OracleEnhanced::Text
          register_class_with_limit m, %r(nclob)i,           Type::OracleEnhanced::NationalCharacterText

          m.register_type "NCHAR", Type::OracleEnhanced::NationalCharacterString.new
          m.alias_type %r(NVARCHAR2)i,    "NCHAR"

          m.register_type(%r(NUMBER)i) do |sql_type|
            scale = extract_scale(sql_type)
            precision = extract_precision(sql_type)
            limit = extract_limit(sql_type)
            if scale == 0
              Type::OracleEnhanced::Integer.new(precision: precision, limit: limit)
            else
              Type::Decimal.new(precision: precision, scale: scale)
            end
          end

          if OracleEnhancedAdapter.emulate_booleans
            if OracleEnhancedAdapter.emulate_booleans_from_strings
              m.register_type %r(^VARCHAR2\(1\))i, Type::OracleEnhanced::Boolean.new
            else
              m.register_type %r(^NUMBER\(1\))i, Type::Boolean.new
            end
          end
        end

        def extract_value_from_default(default)
          case default
          when String
            default.gsub("''", "'")
          else
            default
          end
        end

        def extract_limit(sql_type) #:nodoc:
          case sql_type
          when /^bigint/i
            19
          when /\((.*)\)/
            $1.to_i
          end
        end

        def translate_exception(exception, message) #:nodoc:
          case @connection.error_code(exception)
          when 1
            RecordNotUnique.new(message)
          when 60
            Deadlocked.new(message)
          when 900, 904, 942, 955, 1418, 2289, 2449, 17008
            ActiveRecord::StatementInvalid.new(message)
          when 1400
            ActiveRecord::NotNullViolation.new(message)
          when 2291
            InvalidForeignKey.new(message)
          when 12899
            ValueTooLong.new(message)
          else
            super
          end
        end

        # create bind object for type String
        def bind_string(name, value)
          ActiveRecord::Relation::QueryAttribute.new(name, value, Type::OracleEnhanced::String.new)
        end

        ActiveRecord::Type.register(:boolean, Type::OracleEnhanced::Boolean, adapter: :oracleenhanced)
        ActiveRecord::Type.register(:json, Type::OracleEnhanced::Json, adapter: :oracleenhanced)
    end
  end
end

require "active_record/connection_adapters/oracle_enhanced/version"

module ActiveRecord
  autoload :OracleEnhancedProcedures, "active_record/connection_adapters/oracle_enhanced/procedures"
end
