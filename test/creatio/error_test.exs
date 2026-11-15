defmodule Creatio.ErrorTest do
  use ExUnit.Case, async: true

  alias Creatio.Error

  test "from_response with OData standard error payload" do
    resp = %Req.Response{
      status: 404,
      body: %{
        "error" => %{
          "code" => "EntityNotFound",
          "message" => "Item not found",
          "innererror" => %{"trace" => "abc"}
        }
      }
    }

    err = Error.from_response(resp)
    assert err.status == 404
    assert err.code == "EntityNotFound"
    assert err.message == "Item not found"
    assert err.details == %{"trace" => "abc"}
  end

  test "from_response with OAuth error payload" do
    resp = %Req.Response{
      status: 400,
      body: %{
        "error" => "unauthorized_client",
        "error_description" => "Client not authorized"
      }
    }

    err = Error.from_response(resp)
    assert err.status == 400
    assert err.code == "unauthorized_client"
    assert err.message == "Client not authorized"
  end

  test "from_response with Forms error payload" do
    resp = %Req.Response{
      status: 200,
      body: %{
        "Code" => -1,
        "Message" => "User locked",
        "Exception" => "LockedOutException"
      }
    }

    err = Error.from_response(resp)
    assert err.status == 200
    assert err.code == -1
    assert err.message == "User locked"
    assert err.details == "LockedOutException"
  end

  test "from_response with plain text body" do
    resp = %Req.Response{
      status: 502,
      body: "Bad Gateway"
    }

    err = Error.from_response(resp)
    assert err.status == 502
    assert err.message == "Bad Gateway"
    assert Exception.message(err) == "Bad Gateway"
  end

  test "from_response with nested OData 3 / WCF error message object" do
    resp = %Req.Response{
      status: 400,
      body: %{
        "error" => %{
          "code" => "1001",
          "message" => %{
            "lang" => "en-US",
            "value" => "An error occurred while processing this request."
          }
        }
      }
    }

    err = Error.from_response(resp)
    assert err.status == 400
    assert err.code == "1001"
    assert err.message == "An error occurred while processing this request."
    assert is_binary(Exception.message(err))
  end

  test "from_response with single OAuth error without description" do
    resp = %Req.Response{
      status: 401,
      body: %{"error" => "invalid_token"}
    }

    err = Error.from_response(resp)
    assert err.status == 401
    assert err.code == "invalid_token"
    assert err.message == "invalid_token"
  end

  test "from_response with empty string body defaults to HTTP status" do
    resp = %Req.Response{
      status: 404,
      body: ""
    }

    err = Error.from_response(resp)
    assert err.status == 404
    assert err.message == "HTTP 404"
  end

  test "from_response with DataService errorInfo payload" do
    resp = %Req.Response{
      status: 200,
      body: %{
        "success" => false,
        "errorInfo" => %{
          "errorCode" => "1002",
          "message" => "Database exception in SelectQuery"
        }
      }
    }

    err = Error.from_response(resp)
    assert err.status == 200
    assert err.code == "1002"
    assert err.message == "Database exception in SelectQuery"
    assert is_map(err.details)
  end

  test "from_response with ServiceStack responseStatus payload" do
    resp = %Req.Response{
      status: 400,
      body: %{
        "responseStatus" => %{
          "ErrorCode" => "ValidationError",
          "Message" => "Field is required"
        }
      }
    }

    err = Error.from_response(resp)
    assert err.status == 400
    assert err.code == "ValidationError"
    assert err.message == "Field is required"
  end

  test "from_response with legacy and alternative error payloads" do
    cases = [
      {%{"errorInfo" => %{"message" => "A", "errorCode" => "123"}}, "123", "A"},
      {%{"ErrorInfo" => %{"message" => "A", "errorCode" => "123"}}, "123", "A"},
      {%{"responseStatus" => %{"Message" => "A", "errorCode" => "123"}}, "123", "A"},
      {%{"ResponseStatus" => %{"Message" => "A", "ErrorCode" => "123"}}, "123", "A"},
      {%{"success" => false, "message" => "A"}, nil, "A"},
      {%{"success" => false, "errorInfo" => %{"message" => "A"}}, nil, "A"},
      {%{"success" => "false", "message" => "A"}, nil, "A"},
      {%{"error" => %{"message" => %{"value" => "nested"}}}, nil, "nested"},
      {%{"error" => "string error"}, "string error", "string error"},
      {%{"error" => %{"message" => "msg", "code" => "123"}}, "123", "msg"},
      {%{"error" => %{"code" => "123"}}, "123", "123"},
      {%{"error" => %{}}, nil, "HTTP 400"},
      {%{"error" => nil}, nil, inspect(%{"error" => nil})},
      {%{"Success" => false, "Message" => "Failed", "ErrorCode" => "ERR"}, "ERR", "Failed"},
      {%{"Message" => "Just message"}, nil, "Just message"},
      {%{"ExceptionMessage" => "Just exception message"}, nil, "Just exception message"},
      {%{"message" => %{"value" => "string value"}}, nil, "string value"},
      {%{"message" => "string value", "code" => "200"}, "200", "string value"},
      {%{}, nil, inspect(%{})},
      {%{"error" => %{"message" => "A", "code" => "B"}}, "B", "A"},
      {%{"error" => %{"Message" => "A", "ErrorCode" => "B"}}, nil, "HTTP 400"},
      {%{"message" => "A", "code" => "B"}, "B", "A"},
      {%{"Exception" => %{"Message" => "A", "ErrorCode" => "B"}}, nil,
       inspect(%{"Exception" => %{"Message" => "A", "ErrorCode" => "B"}})},
      {%{"Exception" => %{"message" => "A", "errorCode" => "B"}}, nil,
       inspect(%{"Exception" => %{"message" => "A", "errorCode" => "B"}})},
      {%{"error_description" => "A"}, nil, inspect(%{"error_description" => "A"})}
    ]

    for {body, expected_code, expected_message} <- cases do
      err = Error.from_response(%Req.Response{status: 400, body: body})
      assert %Error{status: 400} = err
      assert err.code == expected_code
      assert err.message == expected_message
    end

    assert %Error{
             status: nil,
             code: nil,
             message: "\"not a response\"",
             response: "not a response"
           } = Error.from_response("not a response")

    assert %Error{status: 400, code: nil, message: "just a string"} =
             Error.from_response(%Req.Response{status: 400, body: "just a string"})

    err = Error.from_response(%Req.Response{status: 400, body: %{"error" => %{"message" => 123}}})
    assert err.status == 400
    assert err.message == "123"

    json_body = Jason.encode!(%{"error" => %{"message" => "Encoded JSON error", "code" => "E1"}})

    assert %Error{status: 400, code: "E1", message: "Encoded JSON error"} =
             Error.from_response(%Req.Response{status: 400, body: json_body})
  end
end
