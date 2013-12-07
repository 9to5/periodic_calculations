module PeriodicCalculations
  class Query
    INTERVAL_UNIT = [:day, :week, :month, :year]

    # TODO:
    #  * prepared statement?
    #  * non-cumulative query doesn't need subquery
    #  * allow any aggregate function

    # Builds a periodic operation query with PostgresSQL window functions
    #
    # @param relation [ActiveRecord::Relation] Object to build query from
    # @param query_options [QueryOptions]
    # @return [Array<Array>] for each period the time of the interval and the count of it
    def initialize(relation, query_options)
      @relation = relation
      @operation = query_options.operation.upcase
      @column_name = query_options.column_name
      @window_function = window_function(query_options)
      @binds = {
        :unit     => query_options.interval_unit,
        :interval => "1 #{query_options.interval_unit.upcase}",
        :start    => query_options.window_start,
        :end      => query_options.window_end,
        :offset   => "#{query_options.timezone_offset} seconds"
      }
    end

    def execute
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute(sanitized_sql).map do |elem|
          [Date.parse(elem["frame"]).to_time, elem["result"].to_i]
        end
      end
    end

    private

    def sanitized_sql
      ActiveRecord::Base.send(:sanitize_sql_array, [Arel.sql(sql), @binds])
    end

    def sql
      # How are timezones managed?
      # * Take into account the timezone offset throughout the search,
      #   so that the periods are correctly grouped.
      # * Restore the timezone at the very end to return the date in UTC
      #   being consistent with the Rails convention

      # What does it do?
      # 1. group currently selected rows by the interval
      # 2. make a union to add possible missing time points
      # 3. iterate over a window function that can cumulate the previous counters if needed
      # 4. trim out rows outside the time window
      #    Cannot be done before in the same query because window function iterates after the
      #    where/group by/having clauses (could be improved for non cumulative queries)

      select_sql = <<-SQL
        date_trunc(:unit, activities.created_at + INTERVAL :offset) AS frame,
        #{@operation}(#{@column_name})                              AS result
      SQL

      frame_and_result_select = @relation.select(select_sql).to_sql

      <<-SQL
        WITH
          -- generate series within window
          -- (with shifted timezones utc_date -> zone_date)
          grid AS (
            SELECT  date_trunc(:unit, serie) AS frame,
                    NULL::integer            AS result
            FROM    generate_series(
                      :start::timestamp + INTERVAL :offset,
                      :end::timestamp + INTERVAL :offset,
                      :interval
                    )                                 AS serie
          )

          -- preprocess results grouping by interval
          -- (with shifted timezones utc_date -> zone_date)
          , preprocessed_results AS (
            #{frame_and_result_select}
            GROUP BY date_trunc(:unit, activities.created_at + INTERVAL :offset)
          )

          -- running window function calculate results and fill up gaps
          , results AS (
            SELECT  DISTINCT frame,
                    #{@operation}(result) OVER (#{@window_function} BY frame) AS result
            FROM (
              SELECT frame, result FROM preprocessed_results
              UNION ALL
              SELECT frame, result FROM grid
            ) AS fulfilled_gaps
          )

        -- cut out values outside window (needed here if cumulative, room for improvement)
        -- (with shifted timezones utc_date -> zone_date)
        SELECT    frame,
                  result
        FROM      results
        WHERE     frame BETWEEN
                    date_trunc(:unit, :start::timestamp + INTERVAL :offset)
                    AND
                    date_trunc(:unit, :end::timestamp + INTERVAL :offset)
        ORDER BY  frame ASC
      SQL
    end

    def window_function(query_options)
      query_options.cumulative ? "ORDER" : "PARTITION"
    end

  end

end

ActiveRecord::Base.extend PeriodicCalculations