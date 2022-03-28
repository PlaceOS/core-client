require "./spec_helper"

describe PlaceOS::Core::ClientError do
  it "should instantiate based on data in a HTTP response" do
    error = PlaceOS::Core::ClientError.from_response(
      "/testing",
      HTTP::Client::Response.new(
        status: :ok,
        body: "some data",
        headers: HTTP::Headers{
          "Response-Code" => "208"
        }
      )
    )

    error.message.should eq "request to /testing failed with some data"
    error.status_code.should eq 200
    error.response_code.should eq 208
    error.remote_backtrace.should eq nil

    error = PlaceOS::Core::ClientError.from_response(
      "/testing2",
      HTTP::Client::Response.new(
        status: :internal_server_error,
        body: "error"
      )
    )

    error.message.should eq "request to /testing2 failed with error"
    error.status_code.should eq 500
    error.response_code.should eq 500
    error.remote_backtrace.should eq nil
  end
end
