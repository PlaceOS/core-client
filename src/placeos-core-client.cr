require "http"
require "json"
require "mutex"
require "placeos-models/executable"
require "placeos-models/version"
require "responsible"
require "retriable"
require "uri"
require "uuid"

require "./error"

module PlaceOS::Core
  class Client
    include Responsible

    # Core base
    BASE_PATH    = "/api/core"
    CORE_VERSION = "v1"

    getter core_version : String = CORE_VERSION

    # Set the request_id on the client
    property request_id : String? = nil
    getter host : String = ENV["CORE_HOST"]? || "localhost"
    getter port : Int32 = (ENV["CORE_PORT"]? || 3000).to_i

    private getter retries

    # Base struct for `Engine::Core` responses
    private abstract struct BaseResponse
      include JSON::Serializable
    end

    # A one-shot Core client
    def self.client(
      uri : URI,
      request_id : String? = nil,
      core_version : String = CORE_VERSION,
      retries : Int32 = 10,
      &
    )
      client = new(uri, request_id, core_version, retries)
      begin
        response = yield client
      ensure
        client.connection.close
      end

      response
    end

    def initialize(
      uri : URI,
      @request_id : String? = nil,
      @core_version : String = CORE_VERSION,
      @retries : Int32 = 10,
    )
      uri_host = uri.host
      @host = uri_host if uri_host
      @port = uri.port || 3000

      @connection = conn = HTTP::Client.new(uri)
      conn.connect_timeout = 10.seconds
      conn.read_timeout = 5.minutes
      conn.write_timeout = 1.minute
    end

    def initialize(
      host : String? = nil,
      port : Int32? = nil,
      @request_id : String? = nil,
      @core_version : String = CORE_VERSION,
      @retries : Int32 = 10,
    )
      @host = host if host
      @port = port if port

      @connection = conn = HTTP::Client.new(host: @host, port: @port)
      conn.connect_timeout = 10.seconds
      conn.read_timeout = 5.minutes
      conn.write_timeout = 1.minute
    end

    protected getter! connection : HTTP::Client

    protected getter connection_lock : Mutex = Mutex.new

    def close
      connection_lock.synchronize do
        connection.close
      end
    end

    # Drivers
    ###########################################################################

    # Returns drivers available
    def drivers(repository : String) : Array(String)
      params = HTTP::Params{"repository" => repository}
      parse_to_return_type do
        get("/drivers?#{params}")
      end
    end

    struct DriverCommit < BaseResponse
      getter commit : String
      getter date : String
      getter author : String
      getter subject : String
    end

    # Returns the commits for a particular driver
    def driver(driver_id : String, repository : String, branch : String, count : Int32? = nil) : Array(DriverCommit)
      params = HTTP::Params{
        "repository" => repository,
        "branch"     => branch,
      }
      params["count"] = count.to_s if count
      parse_to_return_type do
        get("/drivers/#{URI.encode_www_form(driver_id)}?#{params}")
      end
    end

    # Returns the metadata for a particular driver
    def driver_details(file_name : String, commit : String, repository : String, branch : String = "master") : String
      params = HTTP::Params{
        "commit"     => commit,
        "repository" => repository,
        "branch"     => branch,
      }
      # Response looks like:
      # https://github.com/placeos/driver/blob/master/docs/command_line_options.md#discovery-and-defaults
      get("/drivers/#{URI.encode_www_form(file_name)}/details?#{params}").body
    end

    def driver_compiled?(file_name : String, commit : String, repository : String, tag : String) : Bool
      params = HTTP::Params{
        "commit"     => commit,
        "repository" => repository,
        "tag"        => tag,
      }

      parse_to_return_type do
        get("/drivers/#{URI.encode_www_form(file_name)}/compiled?#{params}")
      end
    end

    def driver_recompile(file_name : String, commit : String, repository : String, tag : String)
      params = HTTP::Params{
        "commit"     => commit,
        "repository" => repository,
        "tag"        => tag,
      }

      resp = post("/drivers/#{URI.encode_www_form(file_name)}/recompile?#{params}")
      {resp.status_code, resp.body}
    end

    def driver_reload(driver_id : String)
      resp = post("/drivers/#{URI.encode_www_form(driver_id)}/reload")
      {resp.status_code, resp.body}
    end

    def branches?(repository : String) : Array(String)?
      parse_to_return_type do
        get("/drivers/#{repository}/branches")
      end
    rescue e : Core::ClientError
      raise e unless e.status_code == 404
    end

    # Build Serivce Monitor
    enum State
      Pending
      Running
      Cancelled
      Error
      Done

      def to_s(io : IO) : Nil
        io << (member_name || value.to_s).downcase
      end

      def to_s : String
        String.build { |io| to_s(io) }
      end
    end

    def monitor_jobs(state : State = State::Pending)
      params = HTTP::Params{"state" => state.to_s}
      resp = get("/build/monitor?#{params}")
      {resp.status_code, resp.body}
    end

    def cancel_job(job : String)
      resp = delete("/build/cancel/#{URI.encode_www_form(job)}")
      {resp.status_code, resp.body}
    end

    # Command
    ###########################################################################

    # Returns the JSON response of executing a method on module
    def execute(
      module_id : String,
      method : String | Symbol,
      arguments = [] of JSON::Any,
      user_id : String? = nil,
    )
      payload = {
        :__exec__ => method,
        method    => arguments,
      }.to_json

      params = HTTP::Params.new
      params["user_id"] = user_id if user_id && user_id.presence

      response = post("/command/#{module_id}/execute?#{params}", body: payload)

      case response.status_code
      when 200
        # exec was successful, json string returned
        {response.body, response.headers["Response-Code"]?.try(&.to_i) || 200}
      when 203
        response_code = response.headers["Response-Code"]?.try(&.to_i) || 500
        begin
          # exec sent to module and it raised an error
          info = NamedTuple(error: String, backtrace: Array(String)?).from_json(response.body)
          raise Core::DriverRaisedError.new(response.status_code, "module raised: #{info[:error]}", info[:backtrace], response_code)
        rescue e : JSON::Error
          message = "failed to parse exception response, response code #{response_code}\n#{response.body}"
          Log.error(exception: e) { message }
          raise Exception.new(message, cause: e)
        end
      else
        # some other failure
        raise Core::UnexpectedFailureError.new(response.status_code, "unexpected response code #{response.status_code}")
      end
    end

    # Grab the STDOUT of a module process
    #
    # Sets up a websocket connection with core, and forwards messages to captured block
    def debug(module_id : String, &block : String ->) : Nil
      socket = debug(module_id)
      socket.on_message(&block)
      socket.run
    end

    def debug(module_id : String) : HTTP::WebSocket
      headers = HTTP::Headers.new
      headers["X-Request-ID"] = request_id.as(String) if request_id

      HTTP::WebSocket.new(
        host: host,
        path: "#{BASE_PATH}/#{CORE_VERSION}/command/#{module_id}/debugger",
        port: port,
        headers: headers,
      )
    end

    def load(module_id : String)
      post("/command/#{module_id}/load").success?
    end

    struct Loaded < BaseResponse
      alias Processes = Hash(String, Array(String))

      getter edge : Hash(String, Processes) = {} of String => Processes
      getter local : Processes = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
    end

    # Returns the loaded modules on the node
    def loaded : Loaded
      parse_to_return_type do
        get("/status/loaded")
      end
    end

    # Status
    ###########################################################################

    struct CoreStatus < BaseResponse
      struct Error < BaseResponse
        getter name : String
        getter reason : String
      end

      struct Count < BaseResponse
        getter modules : Int32
        getter drivers : Int32
      end

      struct RunCount < BaseResponse
        getter local : Count
        getter edge : Hash(String, Count)
      end

      # getter driver_binaries : Array(PlaceOS::Model::Executable)
      getter available_repositories : Array(String)
      getter unavailable_repositories : Array(Error)
      getter compiled_drivers : Array(String)
      getter unavailable_drivers : Array(Error)

      getter run_count : RunCount
    end

    # Core status
    def core_status : CoreStatus
      parse_to_return_type do
        get("/status")
      end
    end

    def version : PlaceOS::Model::Version
      parse_to_return_type do
        get("/version")
      end
    end

    struct Load < BaseResponse
      getter local : SystemLoad
      getter edge : Hash(String, SystemLoad)
    end

    struct SystemLoad < BaseResponse
      getter hostname : String
      getter cpu_count : Int32
      getter core_cpu : Float64
      getter total_cpu : Float64
      getter memory_total : Int64
      getter memory_usage : Int64
      getter core_memory : Int64
    end

    # Details about machine load
    def core_load : Load
      parse_to_return_type do
        get("/status/load")
      end
    end

    struct DriverStatus < BaseResponse
      struct Metadata < BaseResponse
        # ameba:disable Naming/QueryBoolMethods
        getter running : Bool = false
        getter module_instances : Int32 = -1
        getter last_exit_code : Int32 = -1
        getter launch_count : Int32 = -1
        getter launch_time : Int64 = -1

        getter percentage_cpu : Float64? = nil
        getter memory_total : Int64? = nil
        getter memory_usage : Int64? = nil
      end

      # :nodoc:
      def initialize
      end

      getter local : Metadata? = nil
      getter edge : Hash(String, Metadata?) = {} of String => PlaceOS::Core::Client::DriverStatus::Metadata?
    end

    # Driver status
    def driver_status(path : String) : DriverStatus
      parse_to_return_type do
        get("/status/driver?path=#{path}")
      end
    rescue e : Core::ClientError
      DriverStatus.new
    end

    # Chaos
    ###########################################################################

    def terminate(path : String) : Bool
      post("/chaos/terminate?path=#{path}").success?
    end

    # Edge Monitoring
    ###########################################################################

    struct EdgeError < BaseResponse
      getter timestamp : Int64
      getter edge_id : String
      getter error_type : String
      getter message : String
      getter context : Hash(String, String)
      getter severity : String
    end

    struct EdgeHealth < BaseResponse
      getter edge_id : String
      getter connected : Bool
      getter last_seen : Int64
      getter connection_uptime : Int64
      getter error_count_24h : Int32
      getter module_count : Int32
      getter failed_modules : Array(String)
    end

    struct ConnectionMetrics < BaseResponse
      getter edge_id : String
      getter total_connections : Int32
      getter failed_connections : Int32
      getter average_uptime : Int64
      getter last_connection_attempt : Int64
      getter last_successful_connection : Int64
    end

    struct EdgeModuleStatus < BaseResponse
      getter edge_id : String
      getter total_modules : Int32
      getter running_modules : Int32
      getter failed_modules : Array(String)
      getter initialization_errors : Array(Hash(String, JSON::Any))
    end

    struct EdgeStatistics < BaseResponse
      getter total_edges : Int32
      getter connected_edges : Int32
      getter edges_with_errors : Int32
      getter total_errors_24h : Int32
      getter total_modules : Int32
      getter failed_modules : Int32
      getter timestamp : String
    end

    # Get errors for a specific edge
    def edge_errors(edge_id : String, limit : Int32? = nil, type : String? = nil) : Array(EdgeError)
      params = HTTP::Params.new
      params["limit"] = limit.to_s if limit
      params["type"] = type if type

      parse_to_return_type do
        get("/status/edge/#{URI.encode_www_form(edge_id)}/errors?#{params}")
      end
    end

    # Get module status for a specific edge
    def edge_module_status(edge_id : String) : EdgeModuleStatus
      parse_to_return_type do
        get("/status/edge/#{URI.encode_www_form(edge_id)}/modules/status")
      end
    end

    # Get health status for all edges
    def edges_health : Hash(String, EdgeHealth)
      parse_to_return_type do
        get("/status/edges/health")
      end
    end

    # Get connection metrics for all edges
    def edges_connections : Hash(String, ConnectionMetrics)
      parse_to_return_type do
        get("/status/edges/connections")
      end
    end

    # Get errors from all edges
    def edges_errors(limit : Int32? = nil, type : String? = nil) : Hash(String, Array(EdgeError))
      params = HTTP::Params.new
      params["limit"] = limit.to_s if limit
      params["type"] = type if type

      parse_to_return_type do
        get("/status/edges/errors?#{params}")
      end
    end

    # Get module failures from all edges
    def edges_module_failures : Hash(String, Array(Hash(String, JSON::Any)))
      parse_to_return_type do
        get("/status/edges/modules/failures")
      end
    end

    # Get overall edge statistics
    def edges_statistics : EdgeStatistics
      parse_to_return_type do
        get("/status/edges/statistics")
      end
    end

    # Trigger error cleanup for edges
    def cleanup_edge_errors(hours : Int32 = 24) : Hash(String, JSON::Any)
      params = HTTP::Params{"hours" => hours.to_s}

      parse_to_return_type do
        post("/monitoring/cleanup?#{params}")
      end
    end

    # Get real-time error summary
    def edge_monitoring_summary : Hash(String, JSON::Any)
      parse_to_return_type do
        get("/monitoring/summary")
      end
    end

    # API modem
    ###########################################################################

    {% for method in %w(get post patch delete) %}
    # Executes a {{method.id.upcase}} request on core connection.
    #
    # The response status will be automatically checked and a `PlaceOS::Core::ClientError` raised if
    # unsuccessful and `raises` is `true`.
    private def {{method.id}}(path : String, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType? = nil, raises : Bool = true) : HTTP::Client::Response
      {{method.id}}(path, headers, body, raises) { |response| response }
    end

    # Executes a {{method.id.upcase}} request and yields a `HTTP::Client::Response`.
    #
    # When working with endpoint that provide stream responses these may be accessed as available
    # by calling `#body_io` on the yielded response object.
    #
    # The response status will be automatically checked and a `PlaceOS::Core::ClientError` raised if
    # unsuccessful and `raises` is `true`.
    private def {{method.id}}(path, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil, raises : Bool = false)
      headers ||= HTTP::Headers.new
      headers["Content-Type"] = "application/json"
      headers["X-Request-ID"] = request_id || UUID.random.to_s unless headers.has_key? "X-Request-ID"

      path = File.join(BASE_PATH, core_version, path)
      rewind_io = ->(e : Exception, _a : Int32, _t : Time::Span, _n : Time::Span) {
        Log.error(exception: e) { {method: {{ method }}, path: path, message: "failed to request core"} }
        body.rewind if body.responds_to? :rewind
      }
      Retriable.retry on: {IO::Error, Core::APIResponseError}, times: retries, max_interval: 40.seconds, on_retry: rewind_io do
        connection_lock.synchronize do
          response = connection.{{method.id}}(path, headers, body)
          if response.success? || !raises
            yield response
          else
            raise Core::APIResponseError.from_response("#{@host}:#{@port}#{path}", response)
          end
        end
      end
    end
    {% end %}
  end
end
