module ActiveRecord
  module OracleEnhanced
    module Type
      class StringBoolean < ActiveRecord::OracleEnhanced::Type::Boolean
        # Do not change the column type for emulate_booleans_from_strings boolean columns
        # this matches the behaviour we would get from using AR attributes and gives us
        # consistent column types when emulate_booleans_from_strings is true and false
        # https://github.com/rsim/oracle-enhanced/issues/1621
        def type
          :string
        end
      end
    end
  end
end
