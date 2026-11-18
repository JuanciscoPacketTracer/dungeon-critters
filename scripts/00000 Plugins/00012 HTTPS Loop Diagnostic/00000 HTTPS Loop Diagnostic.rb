if ENV['PSDK_HTTPS_LOOP_DIAGNOSTIC'] == '1'
  require 'net/http'
  require 'openssl'
  require 'thread'
  require 'timeout'
  require 'uri'

  module DungeonCritters
    module HTTPSLoopDiagnostic
      MONOTONIC_CLOCK = Process::CLOCK_MONOTONIC
      SCENARIO_DURATION = 10.0
      COMPLETION_TIMEOUT = 2.0
      BASELINE_RUNS = 3
      HTTPS_VALID_RUNS = 3
      DIRECTED_HTTPS_VALID_RUNS = 5
      CONNECTION_FAILURE_RUNS = 1
      REQUESTS = {
        https_valid: {
          url: 'https://example.com/',
          open_timeout: 4,
          read_timeout: 6,
          total_timeout: 8
        },
        https_delayed: {
          url: 'https://httpbin.org/delay/5',
          open_timeout: 4,
          read_timeout: 8,
          total_timeout: 9
        },
        https_connection_failure: {
          url: 'https://127.0.0.1:1/',
          open_timeout: 2,
          read_timeout: 2,
          total_timeout: 3,
          classify_connection_failure: true
        }
      }.freeze
      CONNECTION_ERRORS = [
        Errno::ECONNREFUSED,
        Errno::ETIMEDOUT,
        Errno::EHOSTUNREACH,
        Errno::ENETUNREACH
      ].freeze

      Scenario = Struct.new(
        :name,
        :run_id,
        :started_at,
        :ended_at,
        :previous_entry_at,
        :frame_count,
        :intervals,
        :request,
        :request_thread,
        :request_result,
        :stop_requested_at,
        :completion_wait_expired,
        :request_active_at_deadline,
        :request_not_terminated,
        :cancelled,
        :incomplete,
        :metrics_frozen,
        keyword_init: true
      )

      COMMANDS = Queue.new
      EVENTS = Queue.new
      REQUEST_RESULTS = Queue.new
      STATE_MUTEX = Mutex.new
      @active_scenario = nil
      @controller_started = false
      @pending_events = []
      @campaign_runs = []
      @campaign_blocked = false
      @request_threads = []
      @campaign_serial = 0
      @campaign_mode = 'full'

      module_function

      def monotonic_time
        Process.clock_gettime(MONOTONIC_CLOCK)
      end

      def ca_file
        @ca_file ||= ENV['PSDK_HTTPS_CA_FILE'].to_s
      end

      def ca_status
        return [false, 'PSDK_HTTPS_CA_FILE no está definido'] if ca_file.empty?
        return [false, "el archivo no existe: #{ca_file}"] unless File.file?(ca_file)
        return [false, "el archivo no es legible: #{ca_file}"] unless File.readable?(ca_file)

        [true, ca_file]
      rescue SystemCallError => e
        [false, "no se pudo validar #{ca_file}: #{e.class}: #{e.message}"]
      end

      def on_graphics_entry(now)
        STATE_MUTEX.synchronize do
          scenario = @active_scenario
          unless scenario&.metrics_frozen
            if scenario
              scenario.frame_count += 1
              if scenario.previous_entry_at
                scenario.intervals << (now - scenario.previous_entry_at)
              end
              scenario.previous_entry_at = now
            end
          end

          process_commands(now)
        end
      end

      def process_commands(now)
        loop do
          command = begin
            COMMANDS.pop(true)
          rescue ThreadError
            nil
          end
          break unless command

          case command[0]
          when :start
            scenario = command[1]
            next if scenario.cancelled || scenario.metrics_frozen

            scenario.started_at = now
            @active_scenario = scenario
            EVENTS << [:started, scenario]
          when :stop
            scenario = command[1]
            next unless @active_scenario.equal?(scenario)

            scenario.ended_at = now
            @active_scenario = nil
            EVENTS << [:completed, scenario]
          end
        end
      end

      def start
        return if @controller_started
        return unless reset_campaign_state

        @controller_started = true
        Thread.new { run_controller }
      end

      def reset_campaign_state
        return false if @request_threads.any?(&:alive?)

        drain_queue(COMMANDS)
        drain_queue(EVENTS)
        drain_queue(REQUEST_RESULTS)
        @active_scenario = nil
        @pending_events.clear
        @campaign_runs = []
        @request_threads = []
        @ca_file = nil
        @ca_valid = nil
        @ca_detail = nil
        @campaign_serial += 1
        @campaign_mode = ENV['PSDK_HTTPS_LOOP_DIAGNOSTIC_MODE'].to_s == 'directed_valid' ? 'directed_valid' : 'full'
        @campaign_id = "#{Time.now.strftime('%Y%m%d-%H%M%S-%L')}-#{Process.pid}-#{@campaign_serial}"
        true
      end

      def drain_queue(queue)
        loop do
          queue.pop(true)
        rescue ThreadError
          break
        end
      end

      def run_controller
        controller_error = nil
        valid_ca, detail = ca_status
        @ca_valid = valid_ca
        @ca_detail = detail
        warn("[HTTPSLoopDiagnostic] HTTPS omitido: #{detail}") unless valid_ca

        unless run_repeated('baseline', BASELINE_RUNS)
          reason = 'diagnóstico detenido porque baseline no terminó correctamente'
          write_skipped_repeated('https_valid', valid_run_count, reason)
          write_full_campaign_skips(reason)
          return
        end
        unless @ca_valid
          write_skipped_repeated('https_valid', valid_run_count, @ca_detail)
          write_full_campaign_skips(@ca_detail)
          return
        end

        if @campaign_mode == 'directed_valid'
          run_directed_valid_campaign
          return
        end

        unless run_warmup(REQUESTS[:https_valid])
          reason = 'calentamiento HTTPS no terminó dentro del plazo'
          write_skipped_repeated('https_valid', valid_run_count, reason)
          write_full_campaign_skips(reason)
          return
        end
        run_repeated('https_valid', HTTPS_VALID_RUNS, REQUESTS[:https_valid])
        unless @campaign_blocked
          run_measurement('https_delayed', REQUESTS[:https_delayed], "#{@campaign_id}-https_delayed-1")
        else
          write_skipped_report(
            'https_delayed',
            'omitido porque una ejecución anterior dejó un hilo activo',
            "#{@campaign_id}-https_delayed-1"
          )
        end
        unless @campaign_blocked
          run_repeated(
            'https_connection_failure',
            CONNECTION_FAILURE_RUNS,
            REQUESTS[:https_connection_failure]
          )
        else
          write_skipped_report(
            'https_connection_failure',
            'omitido porque una ejecución anterior dejó un hilo activo',
            "#{@campaign_id}-https_connection_failure-1"
          )
        end
      rescue StandardError => e
        controller_error = e
        warn("[HTTPSLoopDiagnostic] controlador: #{e.class}: #{e.message}")
      ensure
        terminate_active_request_threads
        write_controller_error(controller_error) if controller_error
        write_missing_campaign_reports
        write_campaign_summary
        @controller_started = false
      end

      def run_repeated(name, count, request = nil)
        completed = true
        completed_count = 0
        count.times do |index|
          break if @campaign_blocked

          completed = run_measurement(
            name,
            request,
            "#{@campaign_id}-#{name}-#{index + 1}"
          ) && completed
          completed_count += 1
        end
        if @campaign_blocked
          (completed_count...count).each do |index|
            write_skipped_report(
              name,
              "omitido porque una ejecución anterior dejó un hilo activo",
              "#{@campaign_id}-#{name}-#{index + 1}"
            )
          end
        end

        completed
      end

      def run_directed_valid_campaign
        unless run_warmup(REQUESTS[:https_valid])
          reason = 'calentamiento HTTPS no terminó dentro del plazo'
          write_skipped_repeated('https_valid', DIRECTED_HTTPS_VALID_RUNS, reason)
          return
        end

        run_repeated(
          'https_valid',
          DIRECTED_HTTPS_VALID_RUNS,
          REQUESTS[:https_valid]
        )
      end

      def valid_run_count
        @campaign_mode == 'directed_valid' ? DIRECTED_HTTPS_VALID_RUNS : HTTPS_VALID_RUNS
      end

      def write_full_campaign_skips(reason)
        return unless @campaign_mode == 'full'

        write_skipped_report('https_delayed', reason, "#{@campaign_id}-https_delayed-skipped")
        write_skipped_report(
          'https_connection_failure',
          reason,
          "#{@campaign_id}-https_connection_failure-skipped"
        )
      end

      def run_warmup(request)
        scenario = Scenario.new(
          name: 'https_warmup',
          run_id: "#{@campaign_id}-https_warmup-1",
          frame_count: 0,
          intervals: [],
          request: request,
          stop_requested_at: nil,
          completion_wait_expired: false,
          request_active_at_deadline: false,
          request_not_terminated: false,
          cancelled: false,
          incomplete: false,
          metrics_frozen: false
        )
        scenario.request_thread = Thread.new { perform_request(scenario) }
        @request_threads << scenario.request_thread
        scenario.request_thread.abort_on_exception = false
        request_terminated = wait_for_request_completion(
          scenario,
          request[:total_timeout] + COMPLETION_TIMEOUT
        )
        unless request_terminated
          request_terminated = terminate_request_thread(scenario)
          @campaign_blocked = true unless request_terminated
        end
        collect_request_results
        result = scenario.request_result
        report = [
          'scenario=https_warmup',
          "run_id=#{scenario.run_id}",
          "campaign_mode=#{@campaign_mode}",
          'status=warmup',
          "request_url=#{result && result[:url].inspect}",
          "request_started_at_monotonic=#{result && result[:started_at].inspect}",
          "request_ended_at_monotonic=#{result && result[:ended_at].inspect}",
          "request_duration_ms=#{result && result[:duration].to_f * 1000}",
          "request_http_status=#{result && result[:http_status].inspect}",
          "request_exception=#{result && result[:exception].inspect}",
          "request_exception_class=#{result && result[:exception_class].inspect}",
          "request_classification=#{result && result[:classification].inspect}",
          "request_not_terminated=#{!request_terminated}"
        ].join("\n") + "\n"
        @campaign_runs << report
        write_report_file('https_warmup', report, scenario.run_id)
      rescue StandardError => e
        terminated = terminate_request_thread(scenario)
        @campaign_blocked = true unless terminated
        report = [
          'scenario=https_warmup',
          "run_id=#{scenario.run_id}",
          'status=failed',
          "error=#{e.class}: #{e.message}"
        ].join("\n") + "\n"
        @campaign_runs << report
        write_report_file('https_warmup', report, scenario.run_id)
        false
      else
        request_terminated
      end

      def run_measurement(name, request = nil, run_id = name)
        scenario = Scenario.new(
          name: name,
          run_id: run_id,
          frame_count: 0,
          intervals: [],
          request: request,
            stop_requested_at: nil,
            completion_wait_expired: false,
          request_active_at_deadline: false,
          request_not_terminated: false,
          cancelled: false,
          incomplete: false,
          metrics_frozen: false
        )
        COMMANDS << [:start, scenario]
        unless wait_for_event(:started, scenario, COMPLETION_TIMEOUT)
          start_state = cancel_or_confirm_started(scenario)
          unless start_state == :started
            write_report(scenario, 'Graphics.update no confirmó el inicio del escenario')
            return false
          end
        end

        if request
          scenario.request_thread = Thread.new { perform_request(scenario) }
          @request_threads << scenario.request_thread
          scenario.request_thread.abort_on_exception = false
        end

        wait_until(monotonic_time + SCENARIO_DURATION)
        if scenario.request_thread&.alive?
          scenario.request_active_at_deadline = true
        end
        scenario.stop_requested_at = monotonic_time
        COMMANDS << [:stop, scenario]
        completed = wait_for_event(:completed, scenario, COMPLETION_TIMEOUT)
        scenario.completion_wait_expired = !completed
        completed = freeze_incomplete_scenario(scenario) unless completed
        request_terminated = wait_for_request_completion(scenario, COMPLETION_TIMEOUT)
        unless request_terminated
          request_terminated = terminate_request_thread(scenario)
        end
        extra_error = if completed
                        nil
                      else
                        'Graphics.update no confirmó el fin del escenario'
                      end
        if scenario.request_thread && !request_terminated
          scenario.request_not_terminated = true
          @campaign_blocked = true
          extra_error = [extra_error, 'el hilo HTTPS no terminó dentro del plazo'].compact.join('; ')
        end
        write_report(scenario, extra_error)

        completed && request_terminated
      rescue StandardError => e
        terminated = terminate_request_thread(scenario)
        @campaign_blocked = true unless terminated
        scenario.incomplete = true
        write_report(scenario, "ejecución abortada: #{e.class}: #{e.message}")
        false
      end

      def cancel_or_confirm_started(scenario)
        STATE_MUTEX.synchronize do
          if scenario.started_at
            :started
          else
            scenario.cancelled = true
            :cancelled
          end
        end
      end

      def freeze_incomplete_scenario(scenario)
        STATE_MUTEX.synchronize do
          return true if scenario.ended_at

          scenario.incomplete = true
          scenario.metrics_frozen = true
          @active_scenario = nil if @active_scenario.equal?(scenario)
          false
        end
      end

      def wait_until(deadline)
        while monotonic_time < deadline
          collect_request_results
          sleep(0.01)
        end
        collect_request_results
      end

      def wait_for_event(kind, scenario, timeout)
        deadline = monotonic_time + timeout
        while monotonic_time < deadline
          pending_index = @pending_events.index do |event|
            event[0] == kind && event[1].equal?(scenario)
          end
          return true if pending_index && @pending_events.delete_at(pending_index)

          event = pop_event
          if event
            return true if event[0] == kind && event[1].equal?(scenario)

            @pending_events << event
          end

          sleep(0.01)
        end
        false
      end

      def pop_event
        EVENTS.pop(true)
      rescue ThreadError
        nil
      end

      def wait_for_request_completion(scenario, timeout)
        thread = scenario.request_thread
        return true unless thread

        deadline = monotonic_time + timeout
        while thread.alive? && monotonic_time < deadline
          collect_request_results
          sleep(0.01)
        end
        collect_request_results
        !thread.alive?
      end

      def terminate_request_thread(scenario)
        thread = scenario.request_thread
        return true unless thread&.alive?

        thread.kill
        thread.join(COMPLETION_TIMEOUT)
        !thread.alive?
      end

      def terminate_active_request_threads
        @request_threads.each do |thread|
          next unless thread.alive?

          thread.kill
          thread.join(COMPLETION_TIMEOUT)
        end
        @campaign_blocked = @request_threads.any?(&:alive?)
      end

      def collect_request_results
        loop do
          result = begin
            REQUEST_RESULTS.pop(true)
          rescue ThreadError
            nil
          end
          break unless result

          result[:scenario].request_result = result
        end
      end

      def perform_request(scenario)
        request = scenario.request
        started_at = monotonic_time
        result = {
          scenario: scenario,
          url: request[:url],
          started_at: started_at,
          ended_at: nil,
          duration: nil,
          http_status: nil,
          exception: nil,
          exception_class: nil,
          classification: nil
        }
        begin
          Timeout.timeout(request[:total_timeout]) do
            uri = URI.parse(request[:url])
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
            http.ca_file = ca_file
            http.open_timeout = request[:open_timeout]
            http.read_timeout = request[:read_timeout]
            response = http.get(uri.request_uri)
            result[:http_status] = response.code.to_i
            result[:classification] = 'success'
          end
        rescue StandardError => e
          result[:exception] = "#{e.class}: #{e.message}"
          result[:exception_class] = e.class.name
          result[:classification] = classify_request_error(request, e)
        ensure
          result[:ended_at] = monotonic_time
          result[:duration] = result[:ended_at] - started_at
          REQUEST_RESULTS << result
        end
      end

      def classify_request_error(request, exception)
        return 'connection_timeout' if exception.is_a?(Errno::ETIMEDOUT)
        return 'connection_error' if CONNECTION_ERRORS.any? { |klass| exception.is_a?(klass) }
        return 'connection_timeout' if defined?(Net::OpenTimeout) && exception.is_a?(Net::OpenTimeout)
        return 'timeout' if defined?(Net::ReadTimeout) && exception.is_a?(Net::ReadTimeout)
        return 'timeout' if exception.is_a?(Timeout::Error)

        if exception.is_a?(SocketError)
          return 'dns_error' if exception.message =~ /getaddrinfo|name or service not known|nodename|host not found/i
        end

        if exception.is_a?(OpenSSL::SSL::SSLError)
          return 'certificate_error' if exception.message =~ /certificate|verify|hostname|issuer|self.signed/i

          return 'tls_error'
        end

        request[:classify_connection_failure] ? 'inconclusive' : 'error'
      end

      def percentile95(intervals)
        return 0.0 if intervals.empty?

        sorted = intervals.sort
        # Nearest-rank: rank = ceil(0.95 * n), converted to a zero-based index.
        sorted[(sorted.length * 0.95).ceil - 1]
      end

      def write_report(scenario, extra_error)
        collect_request_results
        intervals = scenario.intervals
        total_duration = if scenario.started_at && scenario.ended_at
                           scenario.ended_at - scenario.started_at
                         end
        pauses = {
          0.033 => intervals.count { |interval| interval > 0.033 },
          0.050 => intervals.count { |interval| interval > 0.050 },
          0.100 => intervals.count { |interval| interval > 0.100 }
        }
        request_result = scenario.request_result
        status = scenario.incomplete || extra_error ? 'failed' : 'completed'
        report = [
          "scenario=#{scenario.name}",
          "run_id=#{scenario.run_id}",
          "campaign_mode=#{@campaign_mode}",
          "status=#{status}",
          "started_at_monotonic=#{scenario.started_at.inspect}",
          "ended_at_monotonic=#{scenario.ended_at.inspect}",
          "duration_seconds=#{total_duration.inspect}",
          "stop_requested_at_monotonic=#{scenario.stop_requested_at.inspect}",
          "completion_wait_expired=#{scenario.completion_wait_expired}",
          "frames=#{scenario.frame_count}",
          "interval_count=#{intervals.length}",
          "mean_interval_ms=#{mean(intervals) * 1000}",
          "max_interval_ms=#{(intervals.max || 0.0) * 1000}",
          "p95_interval_ms=#{percentile95(intervals) * 1000}",
          "pauses_over_33ms=#{pauses[0.033]}",
          "pauses_over_50ms=#{pauses[0.050]}",
          "pauses_over_100ms=#{pauses[0.100]}",
          "request_url=#{request_result && request_result[:url].inspect}",
          "request_started_at_monotonic=#{request_result && request_result[:started_at].inspect}",
          "request_ended_at_monotonic=#{request_result && request_result[:ended_at].inspect}",
          "request_duration_ms=#{request_result && request_result[:duration].to_f * 1000}",
          "request_http_status=#{request_result && request_result[:http_status].inspect}",
          "request_exception=#{request_result && request_result[:exception].inspect}",
          "request_exception_class=#{request_result && request_result[:exception_class].inspect}",
          "request_classification=#{request_result && request_result[:classification].inspect}",
          "request_active_at_deadline=#{scenario.request_active_at_deadline}",
          "request_not_terminated=#{scenario.request_not_terminated}",
          "incomplete=#{scenario.incomplete}",
          'request_timeout_cancellation_guaranteed=false',
          "extra_error=#{extra_error.inspect}"
        ].join("\n") + "\n"
        @campaign_runs << report
        write_report_file(scenario.name, report, scenario.run_id)
      end

      def write_skipped_report(name, reason, run_id)
        report = [
          "scenario=#{name}",
          "run_id=#{run_id}",
          "campaign_mode=#{@campaign_mode}",
          'status=skipped',
          "reason=#{reason}"
        ].join("\n") + "\n"
        @campaign_runs << report
        write_report_file(name, report, run_id)
      end

      def write_skipped_repeated(name, count, reason)
        count.times do |index|
          write_skipped_report(
            name,
            reason,
            "#{@campaign_id}-#{name}-#{index + 1}"
          )
        end
      end

      def write_campaign_summary
        return if @campaign_runs.empty?

        write_report_file('campaign-summary', @campaign_runs.join("\n"), "#{@campaign_id}-all")
      end

      def write_controller_error(exception)
        report = [
          'scenario=campaign_controller',
          "run_id=#{@campaign_id}-controller-error",
          "campaign_mode=#{@campaign_mode}",
          'status=failed',
          "exception_class=#{exception.class.name}",
          "exception=#{exception.message.inspect}"
        ].join("\n") + "\n"
        @campaign_runs << report
        write_report_file('campaign-controller', report, "#{@campaign_id}-controller-error")
      end

      def write_missing_campaign_reports
        expected_runs = []
        BASELINE_RUNS.times { |index| expected_runs << ['baseline', "#{@campaign_id}-baseline-#{index + 1}"] }
        expected_runs << ['https_warmup', "#{@campaign_id}-https_warmup-1"]
        valid_runs = @campaign_mode == 'directed_valid' ? DIRECTED_HTTPS_VALID_RUNS : HTTPS_VALID_RUNS
        valid_runs.times { |index| expected_runs << ['https_valid', "#{@campaign_id}-https_valid-#{index + 1}"] }
        if @campaign_mode == 'full'
          expected_runs << ['https_delayed', "#{@campaign_id}-https_delayed-1"]
          expected_runs << ['https_connection_failure', "#{@campaign_id}-https_connection_failure-1"]
        end

        expected_runs.each do |name, run_id|
          next if @campaign_runs.any? { |report| report.include?("run_id=#{run_id}\n") }

          write_skipped_report(
            name,
            'omitido porque la campaña terminó antes de ejecutar este escenario',
            run_id
          )
        end
      end

      def write_report_file(name, report, run_id = nil)
        directory = [ENV['TEMP'], ENV['TMP']].compact.find do |candidate|
          !candidate.empty? && File.directory?(candidate) && File.writable?(candidate)
        end
        unless directory
          warn('[HTTPSLoopDiagnostic] no se pudo escribir el informe: TEMP/TMP no es un directorio temporal válido; no se escribirá en otro directorio')
          return
        end

        timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        suffix = run_id ? "-#{run_id}" : ''
        filename = File.join(directory, "dungeon-critters-https-loop-diagnostic-#{name}#{suffix}-#{Process.pid}-#{timestamp}.txt")
        File.binwrite(filename, report)
        puts("[HTTPSLoopDiagnostic] informe: #{filename}")
      rescue SystemCallError => e
        warn("[HTTPSLoopDiagnostic] no se pudo escribir el informe: #{e.class}: #{e.message}")
      end

      def mean(values)
        return 0.0 if values.empty?

        values.sum.fdiv(values.length)
      end
    end
  end

  module DungeonCrittersHTTPSLoopDiagnosticGraphicsPatch
    def update
      DungeonCritters::HTTPSLoopDiagnostic.on_graphics_entry(
        Process.clock_gettime(DungeonCritters::HTTPSLoopDiagnostic::MONOTONIC_CLOCK)
      )
      super
    end
  end

  Graphics.singleton_class.prepend(DungeonCrittersHTTPSLoopDiagnosticGraphicsPatch)
  Graphics.on_start { DungeonCritters::HTTPSLoopDiagnostic.start }
end
