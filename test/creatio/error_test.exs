defmodule Creatio.ErrorTest do
  use ExUnit.Case, async: true

  alias Creatio.Error

  test "from_response/1 extracts status, code, message, and details across OData, OAuth, Forms, DataService, and ServiceStack payloads" do
    structured_cases = [
      {404,
       %{
         "error" => %{
           "code" => "EntityNotFound",
           "message" => "Item not found",
           "innererror" => %{"trace" => "abc"}
         }
       }, "EntityNotFound", "Item not found", %{"trace" => "abc"}},
      {400, %{"error" => "unauthorized_client", "error_description" => "Client not authorized"},
       "unauthorized_client", "Client not authorized", :any},
      {401, %{"error" => "invalid_token"}, "invalid_token", "invalid_token", :any},
      {200, %{"Code" => -1, "Message" => "User locked", "Exception" => "LockedOutException"}, -1,
       "User locked", "LockedOutException"},
      {400,
       %{
         "error" => %{
           "code" => "1001",
           "message" => %{
             "lang" => "en-US",
             "value" => "An error occurred while processing this request."
           }
         }
       }, "1001", "An error occurred while processing this request.", :any},
      {200,
       %{
         "success" => false,
         "errorInfo" => %{
           "errorCode" => "1002",
           "message" => "Database exception in SelectQuery"
         }
       }, "1002", "Database exception in SelectQuery", :is_map},
      {400,
       %{
         "responseStatus" => %{
           "ErrorCode" => "ValidationError",
           "Message" => "Field is required"
         }
       }, "ValidationError", "Field is required", :any}
    ]

    for {status, body, expected_code, expected_message, details_expectation} <- structured_cases do
      err = Error.from_response(%Req.Response{status: status, body: body})
      assert err.status == status
      assert err.code == expected_code
      assert err.message == expected_message
      assert is_binary(Exception.message(err))

      case details_expectation do
        :any -> :ok
        :is_map -> assert is_map(err.details)
        exact -> assert err.details == exact
      end
    end

    legacy_cases = [
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
      {%{"error" => %{"Message" => "A", "ErrorCode" => "B"}}, "B", "A"},
      {%{"message" => "A", "code" => "B"}, "B", "A"},
      {%{"Exception" => %{"Message" => "A", "ErrorCode" => "B"}}, "B", "A"},
      {%{"Exception" => %{"message" => "A", "errorCode" => "B"}}, "B", "A"},
      {%{"error_description" => "A"}, nil, "A"},
      {%{"Code" => 1, "Message" => "", "ExceptionMessage" => "NullReferenceException"}, 1,
       "NullReferenceException"}
    ]

    for {body, expected_code, expected_message} <- legacy_cases do
      err = Error.from_response(%Req.Response{status: 400, body: body})
      assert %Error{status: 400} = err
      assert err.code == expected_code
      assert err.message == expected_message
    end
  end

  test "from_response/1 handles plain text, empty strings, JSON-encoded strings, non-response inputs, and Exception.message/1 fallbacks" do
    plain = Error.from_response(%Req.Response{status: 502, body: "Bad Gateway"})
    assert plain.status == 502
    assert plain.message == "Bad Gateway"
    assert Exception.message(plain) == "Bad Gateway"

    empty = Error.from_response(%Req.Response{status: 404, body: ""})
    assert empty.status == 404
    assert empty.message == "HTTP 404"

    assert %Error{status: 400, code: nil, message: "just a string"} =
             Error.from_response(%Req.Response{status: 400, body: "just a string"})

    numeric_msg =
      Error.from_response(%Req.Response{status: 400, body: %{"error" => %{"message" => 123}}})

    assert numeric_msg.status == 400
    assert numeric_msg.message == "123"

    json_body = Jason.encode!(%{"error" => %{"message" => "Encoded JSON error", "code" => "E1"}})

    assert %Error{status: 400, code: "E1", message: "Encoded JSON error"} =
             Error.from_response(%Req.Response{status: 400, body: json_body})

    assert %Error{
             status: nil,
             code: nil,
             message: "\"not a response\"",
             response: "not a response"
           } = Error.from_response("not a response")

    assert Exception.message(Error.new(status: 500, code: "Err")) ==
             "Creatio error Err (HTTP 500)"

    assert Exception.message(Error.new([])) == "Creatio error"
  end

  test "ignores empty responseStatus/errorInfo, strips BOM, sanitizes response headers, and caps raw HTML messages" do
    empty_envelope = %Req.Response{
      status: 200,
      headers: %{"set-cookie" => ["BPMCSRF=secret-csrf; Path=/"]},
      body: %{
        "responseStatus" => %{},
        "success" => false,
        "Message" => "Real DataService error"
      }
    }

    err = Error.from_response(empty_envelope)
    assert err.message == "Real DataService error"
    assert err.response.headers["set-cookie"] == ["[REDACTED]"]
    refute inspect(err) =~ "secret-csrf"

    bom_json = "\uFEFF" <> Jason.encode!(%{"errorInfo" => %{}, "Message" => "BOM error"})

    assert %Error{message: "BOM error"} =
             Error.from_response(%Req.Response{status: 500, body: bom_json})

    huge_html = "<html>" <> String.duplicate("x", 2_000) <> "</html>"
    html_err = Error.from_response(%Req.Response{status: 502, body: huge_html})
    assert byte_size(html_err.message) < 600
    assert html_err.message =~ "[truncated"

    odata3_err =
      Error.from_response(%Req.Response{
        status: 200,
        body: %{
          "d" => %{
            "error" => %{
              "code" => "OData3Code",
              "message" => %{"value" => "OData3 inner failure"}
            }
          }
        }
      })

    assert %Error{status: 200, code: "OData3Code", message: "OData3 inner failure"} = odata3_err

    nested_ex_err =
      Error.from_response(%Req.Response{
        status: 200,
        body: %{
          "Code" => -1,
          "Message" => "",
          "Exception" => %{"Message" => "Nested exception message"}
        }
      })

    assert %Error{status: 200, code: -1, message: "Nested exception message"} = nested_ex_err
  end

  test "falls back past nil or blank Message, ExceptionMessage, message, and error_description fields" do
    cases = [
      {%{"Message" => nil, "ExceptionMessage" => "Detailed error"}, nil, "Detailed error"},
      {%{"Message" => "", "message" => "Actual error"}, nil, "Actual error"},
      {%{"ExceptionMessage" => "   ", "message" => %{"value" => "Nested actual"}}, nil,
       "Nested actual"},
      {%{"error" => %{"code" => "BadReq", "message" => "", "Message" => "Fallback msg"}},
       "BadReq", "Fallback msg"},
      {%{"error" => %{"code" => "BadReq", "message" => %{"value" => "   "}, "Message" => "Ok"}},
       "BadReq", "Ok"},
      {%{"error" => "invalid_grant", "error_description" => nil}, "invalid_grant",
       "invalid_grant"}
    ]

    for {body, expected_code, expected_msg} <- cases do
      err = Error.from_response(%Req.Response{status: 400, body: body})
      assert err.code == expected_code
      assert err.message == expected_msg
    end
  end
end
