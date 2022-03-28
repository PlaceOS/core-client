module PlaceOS::Core
  class Error < Exception
    getter message

    def initialize(@message : String = "")
      super(@message)
    end
  end

  class ClientError < Error
    getter status_code : Int32
    getter response_code : Int32
    getter remote_backtrace : Array(String)? = nil

    def initialize(@status_code : Int32, message = "", @response_code : Int32 = 500)
      super(message)
    end

    def initialize(path : String, @status_code : Int32, message : String, @response_code : Int32 = 500)
      super("request to #{path} failed with #{message}")
    end

    def initialize(path : String, @status_code : Int32, @response_code : Int32 = 500)
      super("request to #{path} failed")
    end

    def initialize(
      @status_code : Int32,
      message : String = "",
      @remote_backtrace : Array(String)? = nil,
      @response_code : Int32 = 500
    )
      super(message)
    end

    def self.from_response(path : String, response : HTTP::Client::Response)
      new(path, response.status_code, response.body, response.headers["Response-Code"]?.try(&.to_i) || (response.success? ? 200 : 500))
    end
  end

  class DriverRaisedError < ClientError
  end

  class UnexpectedFailureError < ClientError
  end

  class APIResponseError < ClientError
  end
end
