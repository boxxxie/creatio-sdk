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
    payloads = [
      %{"errorInfo" => %{"message" => "A", "errorCode" => "123"}},
      %{"ErrorInfo" => %{"message" => "A", "errorCode" => "123"}},
      %{"responseStatus" => %{"Message" => "A", "errorCode" => "123"}},
      %{"ResponseStatus" => %{"Message" => "A", "ErrorCode" => "123"}},
      %{"success" => false, "message" => "A"},
      %{"success" => false, "errorInfo" => %{"message" => "A"}},
      %{"success" => "false", "message" => "A"},
      %{"error" => %{"message" => %{"value" => "nested"}}},
      %{"error" => "string error"},
      %{"error" => %{"message" => "msg", "code" => "123"}},
      %{"error" => %{"code" => "123"}},
      %{"error" => %{}},
      %{"error" => nil},
      %{"Success" => false, "Message" => "Failed", "ErrorCode" => "ERR"},
      %{"Message" => "Just message"},
      %{"ExceptionMessage" => "Just exception message"},
      %{"message" => %{"value" => "string value"}},
      %{"message" => "string value", "code" => "200"},
      %{}
    ]

    for body <- payloads do
      err = Error.from_response(%Req.Response{status: 400, body: body})
      assert is_struct(err, Error)
    end

    assert is_struct(Error.from_response("not a response"), Error)

    assert is_struct(
             Error.from_response(%Req.Response{status: 400, body: "just a string"}),
             Error
           )

    err = Error.from_response(%Req.Response{status: 400, body: %{"error" => %{"message" => 123}}})
    assert err.message == "123"
  end
end
