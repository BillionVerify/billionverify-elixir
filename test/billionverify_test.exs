defmodule BillionVerifyTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias BillionVerify.Error

  @stub __MODULE__

  setup do
    test = self()

    client =
      BillionVerify.new(
        api_key: "bv_test_key",
        base_url: "https://api.test",
        sleep: fn ms -> send(test, {:slept, ms}) end,
        req_options: [plug: {Req.Test, @stub}]
      )

    %{client: client}
  end

  defp envelope(conn, data, status \\ 200) do
    conn
    |> put_status(status)
    |> Req.Test.json(%{success: true, code: "0", message: "Success", data: data})
  end

  defp failure(conn, status, code, message) do
    conn
    |> put_status(status)
    |> Req.Test.json(%{
      success: false,
      code: "#{status}0",
      message: message,
      error: %{code: code, message: message}
    })
  end

  defp body_of(conn) do
    {:ok, body, conn} = read_body(conn)
    {body, conn}
  end

  defp json_body(conn) do
    {body, conn} = body_of(conn)
    {JSON.decode!(body), conn}
  end

  describe "new/1" do
    test "rejects an empty API key" do
      assert_raise Error, ~r/API key is required/, fn -> BillionVerify.new(api_key: "") end
      assert_raise Error, fn -> BillionVerify.new([]) end
    end

    test "drops a trailing slash and /v1 from the base URL" do
      assert BillionVerify.new(api_key: "k", base_url: "https://x.test/v1/").base_url ==
               "https://x.test"

      assert BillionVerify.new(api_key: "k", base_url: "https://x.test/").base_url ==
               "https://x.test"

      assert BillionVerify.new(api_key: "k").base_url == "https://api.billionverify.com"
    end
  end

  describe "verify/3" do
    test "posts the email with the right headers and unwraps the envelope", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/verify/single"
        assert get_req_header(conn, "bv-api-key") == ["bv_test_key"]
        assert hd(get_req_header(conn, "content-type")) =~ "application/json"
        assert hd(get_req_header(conn, "user-agent")) == "billionverify-elixir/1.0.0"
        {body, conn} = json_body(conn)
        assert body == %{"email" => "user@example.com"}
        envelope(conn, %{"email" => "user@example.com", "status" => "valid", "credits_used" => 1})
      end)

      assert {:ok, %{"status" => "valid", "credits_used" => 1}} =
               BillionVerify.verify(client, "user@example.com")
    end

    test "sends only the options that were given", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        {body, conn} = json_body(conn)

        assert body == %{
                 "email" => "a@b.co",
                 "check_smtp" => false,
                 "force_refresh" => true,
                 "include_domain_reputation" => true
               }

        envelope(conn, %{"status" => "unknown"})
      end)

      assert {:ok, _} =
               BillionVerify.verify(client, "a@b.co",
                 check_smtp: false,
                 force_refresh: true,
                 include_domain_reputation: true
               )
    end

    test "verify!/3 returns the data and raises on error", %{client: client} do
      Req.Test.expect(@stub, 1, fn conn -> envelope(conn, %{"status" => "valid"}) end)
      assert %{"status" => "valid"} = BillionVerify.verify!(client, "a@b.co")

      Req.Test.expect(@stub, 1, fn conn -> failure(conn, 401, "INVALID_API_KEY", "bad key") end)

      assert_raise Error, ~r/INVALID_API_KEY: bad key/, fn ->
        BillionVerify.verify!(client, "a@b.co")
      end
    end
  end

  describe "verify_batch/3" do
    test "posts the emails", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/verify/bulk"
        {body, conn} = json_body(conn)
        assert body["emails"] == ["a@b.co", "c@d.co"]

        envelope(conn, %{
          "results" => [],
          "total_emails" => 2,
          "deliverability_buckets" => %{"unknown" => 0}
        })
      end)

      assert {:ok, %{"total_emails" => 2}} =
               BillionVerify.verify_batch(client, ["a@b.co", "c@d.co"])
    end

    test "rejects more than 50 addresses without sending", %{client: client} do
      emails = for i <- 1..51, do: "u#{i}@example.com"

      assert {:error, %Error{type: :validation, status: 400}} =
               BillionVerify.verify_batch(client, emails)
    end
  end

  describe "disposable" do
    test "POST variant", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/verify/disposable"
        {body, conn} = json_body(conn)
        assert body == %{"email" => "x@mailinator.com"}
        envelope(conn, %{"domain" => "mailinator.com", "is_disposable" => true})
      end)

      assert {:ok, %{"is_disposable" => true}} =
               BillionVerify.check_disposable(client, "x@mailinator.com")
    end

    test "GET variant encodes the address", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/verify/disposable"
        assert conn.query_string == "email=a%2Bb%40mailinator.com"
        envelope(conn, %{"is_disposable" => true})
      end)

      assert {:ok, _} = BillionVerify.check_disposable_via_query(client, "a+b@mailinator.com")
    end
  end

  describe "upload_file/3" do
    test "sends a multipart body with the file and the options", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/verify/file"
        assert hd(get_req_header(conn, "content-type")) =~ "multipart/form-data"
        assert get_req_header(conn, "bv-api-key") == ["bv_test_key"]
        {body, conn} = body_of(conn)
        assert body =~ ~s(name="file"; filename="emails.csv")
        assert body =~ "a@b.co\nc@d.co"
        assert body =~ ~s(name="check_smtp")
        assert body =~ ~s(name="email_column")
        assert body =~ "Email"
        assert body =~ ~s(name="preserve_original")
        envelope(conn, %{"task_id" => "job-1", "status" => "pending"})
      end)

      assert {:ok, %{"task_id" => "job-1"}} =
               BillionVerify.upload_file(client, {:data, "email\na@b.co\nc@d.co", "emails.csv"},
                 check_smtp: true,
                 email_column: "Email",
                 preserve_original: false
               )
    end

    test "reads a file from a path", %{client: client} do
      path = Path.join(System.tmp_dir!(), "bv-upload-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "a@b.co\n")
      on_exit(fn -> File.rm(path) end)

      Req.Test.stub(@stub, fn conn ->
        {body, conn} = body_of(conn)
        assert body =~ ~s(filename="#{Path.basename(path)}")
        envelope(conn, %{"task_id" => "job-2"})
      end)

      assert {:ok, %{"task_id" => "job-2"}} = BillionVerify.upload_file(client, {:path, path})
    end

    test "a missing file is a validation error", %{client: client} do
      assert {:error, %Error{type: :validation}} =
               BillionVerify.upload_file(client, {:path, "/nope/missing.csv"})
    end
  end

  describe "file job status" do
    test "gets a job", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/verify/file/7143874e"
        assert conn.query_string == ""
        envelope(conn, %{"task_id" => "7143874e", "status" => "processing", "progress" => 66})
      end)

      assert {:ok, %{"progress" => 66}} = BillionVerify.get_file_job_status(client, "7143874e")
    end

    test "long polling passes the timeout", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.query_string == "timeout=30"
        envelope(conn, %{"status" => "completed"})
      end)

      assert {:ok, _} = BillionVerify.get_file_job_status(client, "j", timeout_seconds: 30)
    end

    test "rejects a timeout outside 0..300 without sending", %{client: client} do
      assert {:error, %Error{type: :validation}} =
               BillionVerify.get_file_job_status(client, "j", timeout_seconds: 301)

      assert {:error, %Error{type: :validation}} =
               BillionVerify.get_file_job_status(client, "j", timeout_seconds: -1)
    end

    test "escapes the job id", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/verify/file/a%2Fb"
        envelope(conn, %{"status" => "pending"})
      end)

      assert {:ok, _} = BillionVerify.get_file_job_status(client, "a/b")
    end
  end

  describe "download_file_results/3" do
    test "sends the filters that are true", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/verify/file/j1/results"
        assert URI.decode_query(conn.query_string) == %{"valid" => "true", "risky" => "true"}

        conn
        |> put_resp_content_type("text/csv")
        |> send_resp(200, "email,status\na@b.co,valid\n")
      end)

      assert {:ok, "email,status\na@b.co,valid\n"} =
               BillionVerify.download_file_results(client, "j1",
                 valid: true,
                 risky: true,
                 invalid: false
               )
    end

    test "follows the 307 to another host without sending the API key", %{client: client} do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        case conn.host do
          "api.test" ->
            assert get_req_header(conn, "bv-api-key") == ["bv_test_key"]

            conn
            |> put_resp_header("location", "https://storage.example/results_j1.csv?signature=abc")
            |> send_resp(307, "")

          "storage.example" ->
            send(test, {:storage_headers, conn.req_headers, conn.query_string})
            send_resp(conn, 200, "email,status\nz@y.co,valid\n")
        end
      end)

      assert {:ok, "email,status\nz@y.co,valid\n"} =
               BillionVerify.download_file_results(client, "j1")

      assert_received {:storage_headers, headers, "signature=abc"}
      refute List.keyfind(headers, "bv-api-key", 0)
      refute List.keyfind(headers, "authorization", 0)
    end

    test "writes to output_path", %{client: client} do
      path = Path.join(System.tmp_dir!(), "bv-out-#{System.unique_integer([:positive])}.csv")
      on_exit(fn -> File.rm(path) end)
      Req.Test.stub(@stub, fn conn -> send_resp(conn, 200, "a,b\n") end)

      assert {:ok, ^path} = BillionVerify.download_file_results(client, "j1", output_path: path)
      assert File.read!(path) == "a,b\n"
    end

    test "404 is a not_found error", %{client: client} do
      Req.Test.stub(@stub, fn conn -> failure(conn, 404, "JOB_NOT_FOUND", "no such job") end)

      assert {:error, %Error{type: :not_found, code: "JOB_NOT_FOUND"}} =
               BillionVerify.download_file_results(client, "x")
    end
  end

  describe "resume_job/3" do
    test "posts to the jobs route", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/jobs/j9/resume"
        envelope(conn, %{"task_id" => "j9", "status" => "processing"})
      end)

      assert {:ok, %{"status" => "processing"}} = BillionVerify.resume_job(client, "j9")
    end
  end

  describe "wait_for_file_job/3" do
    test "polls until a final state", %{client: client} do
      Req.Test.expect(@stub, 2, fn conn -> envelope(conn, %{"status" => "processing"}) end)

      Req.Test.expect(@stub, 1, fn conn ->
        envelope(conn, %{"status" => "completed_with_warning"})
      end)

      assert {:ok, %{"status" => "completed_with_warning"}} =
               BillionVerify.wait_for_file_job(client, "j", poll_interval: 7)

      assert_received {:slept, 7}
      assert_received {:slept, 7}
      refute_received {:slept, _}
    end

    test "stops on paused", %{client: client} do
      Req.Test.stub(@stub, fn conn -> envelope(conn, %{"status" => "paused"}) end)
      assert {:ok, %{"status" => "paused"}} = BillionVerify.wait_for_file_job(client, "j")
    end

    test "times out", %{client: client} do
      Req.Test.stub(@stub, fn conn -> envelope(conn, %{"status" => "processing"}) end)

      assert {:error, %Error{type: :timeout}} =
               BillionVerify.wait_for_file_job(client, "j", max_wait: 0)
    end
  end

  describe "credits and health" do
    test "get_credits/2", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/credits"
        envelope(conn, %{"credits_balance" => 9500})
      end)

      assert {:ok, %{"credits_balance" => 9500}} = BillionVerify.get_credits(client)
    end

    test "health_check/2 has no auth header and no envelope", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/health"
        assert get_req_header(conn, "bv-api-key") == []
        Req.Test.json(conn, %{status: "ok", time: 1_705_319_400})
      end)

      assert {:ok, %{"status" => "ok", "time" => 1_705_319_400}} =
               BillionVerify.health_check(client)
    end

    test "a base URL with /v1 still reaches /health" do
      client =
        BillionVerify.new(
          api_key: "k",
          base_url: "https://api.test/v1",
          req_options: [plug: {Req.Test, @stub}]
        )

      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/health"
        Req.Test.json(conn, %{status: "ok", time: 1})
      end)

      assert {:ok, _} = BillionVerify.health_check(client)
    end
  end

  describe "webhooks" do
    test "create", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/webhooks"
        {body, conn} = json_body(conn)

        assert body == %{
                 "url" => "https://app.test/hook",
                 "events" => ["file.completed", "file.failed"]
               }

        envelope(conn, %{"id" => "w1", "secret" => "s3cret", "is_active" => true})
      end)

      assert {:ok, %{"id" => "w1", "secret" => "s3cret"}} =
               BillionVerify.create_webhook(client, "https://app.test/hook", [
                 "file.completed",
                 "file.failed"
               ])
    end

    test "list returns the webhooks array", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        envelope(conn, %{"webhooks" => [%{"id" => "w1"}, %{"id" => "w2"}], "total" => 2})
      end)

      assert {:ok, [%{"id" => "w1"}, %{"id" => "w2"}]} = BillionVerify.list_webhooks(client)
    end

    test "delete", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v1/webhooks/w1"
        envelope(conn, %{"message" => "Webhook deleted successfully", "webhook_id" => "w1"})
      end)

      assert {:ok, %{"webhook_id" => "w1"}} = BillionVerify.delete_webhook(client, "w1")
    end
  end

  describe "verify_webhook_signature/5" do
    @secret "5c609e6893ab3b65ce8940549a030bc1"
    @body ~s({"event":"file.completed","data":{"job_id":"j1"}})

    defp sign(body, ts, secret) do
      "sha256=" <>
        Base.encode16(:crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}"), case: :lower)
    end

    test "accepts a correct signature" do
      ts = "1700000000"
      sig = sign(@body, ts, @secret)
      assert BillionVerify.verify_webhook_signature(@body, sig, ts, @secret, now: 1_700_000_100)
    end

    test "rejects a tampered body, a wrong secret and a malformed signature" do
      ts = "1700000000"
      sig = sign(@body, ts, @secret)

      refute BillionVerify.verify_webhook_signature(@body <> " ", sig, ts, @secret,
               now: 1_700_000_000
             )

      refute BillionVerify.verify_webhook_signature(@body, sig, ts, "other", now: 1_700_000_000)

      refute BillionVerify.verify_webhook_signature(@body, "sha256=abc", ts, @secret,
               now: 1_700_000_000
             )

      refute BillionVerify.verify_webhook_signature(@body, "", ts, @secret, now: 1_700_000_000)
    end

    test "rejects a signature made without the timestamp" do
      bare = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @secret, @body), case: :lower)

      refute BillionVerify.verify_webhook_signature(@body, bare, "1700000000", @secret,
               now: 1_700_000_000
             )
    end

    test "rejects an old timestamp unless tolerance is 0" do
      ts = "1700000000"
      sig = sign(@body, ts, @secret)
      refute BillionVerify.verify_webhook_signature(@body, sig, ts, @secret, now: 1_700_000_301)
      assert BillionVerify.verify_webhook_signature(@body, sig, ts, @secret, now: 1_700_000_300)

      assert BillionVerify.verify_webhook_signature(@body, sig, ts, @secret,
               now: 1_800_000_000,
               tolerance: 0
             )
    end

    test "rejects an unparsable timestamp" do
      refute BillionVerify.verify_webhook_signature(
               @body,
               sign(@body, "abc", @secret),
               "abc",
               @secret
             )
    end
  end

  describe "domain search" do
    test "create validates max_emails and sends options", %{client: client} do
      assert {:error, %Error{type: :validation}} =
               BillionVerify.create_domain_search(client, "example.com", 0)

      assert {:error, %Error{type: :validation}} =
               BillionVerify.create_domain_search(client, "example.com", 201)

      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/domain/search"
        {body, conn} = json_body(conn)

        assert body == %{
                 "domain" => "example.com",
                 "max_emails" => 20,
                 "include_role_based" => false,
                 "max_pages" => 100
               }

        envelope(
          conn,
          %{"search_id" => "s1", "status" => "queued", "credits_reserved" => 100},
          202
        )
      end)

      assert {:ok, %{"search_id" => "s1"}} =
               BillionVerify.create_domain_search(client, "example.com", 20,
                 include_role_based: false,
                 max_pages: 100
               )
    end

    test "get and wait", %{client: client} do
      Req.Test.expect(@stub, 1, fn conn ->
        assert conn.request_path == "/v1/domain/search/s1"
        envelope(conn, %{"status" => "running"})
      end)

      Req.Test.expect(@stub, 1, fn conn ->
        envelope(conn, %{"status" => "completed", "result" => %{"emails" => []}})
      end)

      assert {:ok, %{"status" => "completed"}} =
               BillionVerify.wait_for_domain_search(client, "s1", poll_interval: 3)

      assert_received {:slept, 3}
    end

    test "get_domain_search/3 404", %{client: client} do
      Req.Test.stub(@stub, fn conn -> failure(conn, 404, "NOT_FOUND", "Search not found") end)
      assert {:error, %Error{type: :not_found}} = BillionVerify.get_domain_search(client, "zz")
    end
  end

  describe "batch domain search" do
    test "create uploads the CSV with the options", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/domain/search/batch"
        assert conn.method == "POST"
        {body, conn} = body_of(conn)
        assert body =~ ~s(name="file"; filename="domains.csv")
        assert body =~ "example.com"
        assert body =~ ~s(name="max_emails")
        assert body =~ ~s(name="include_role_based")
        assert body =~ ~s(name="max_pages")
        assert body =~ ~s(name="column_map")
        assert body =~ ~s({"domain":"Company Website"})
        envelope(conn, %{"batch_id" => "b1", "status" => "queued"}, 202)
      end)

      assert {:ok, %{"batch_id" => "b1"}} =
               BillionVerify.create_domain_search_batch(
                 client,
                 {:data, "domain\nexample.com\n", "domains.csv"},
                 max_emails: 50,
                 include_role_based: false,
                 max_pages: 10,
                 column_map: %{"domain" => "Company Website"}
               )
    end

    test "create validates max_emails", %{client: client} do
      assert {:error, %Error{type: :validation}} =
               BillionVerify.create_domain_search_batch(client, {:data, "d", "d.csv"},
                 max_emails: 500
               )
    end

    test "list passes the query", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/domain/search/batch"

        assert URI.decode_query(conn.query_string) == %{
                 "limit" => "5",
                 "status" => "completed",
                 "cursor" => "c1"
               }

        envelope(conn, %{
          "items" => [%{"batch_id" => "b1"}],
          "has_more" => true,
          "next_cursor" => "c2"
        })
      end)

      assert {:ok, %{"items" => [_], "has_more" => true, "next_cursor" => "c2"}} =
               BillionVerify.list_domain_search_batches(client,
                 limit: 5,
                 status: "completed",
                 cursor: "c1"
               )
    end

    test "get", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/domain/search/batch/b1"
        envelope(conn, %{"batch_id" => "b1", "progress" => %{"processed" => 3}})
      end)

      assert {:ok, %{"progress" => %{"processed" => 3}}} =
               BillionVerify.get_domain_search_batch(client, "b1")
    end

    test "download returns the CSV, and 409 is an api error", %{client: client} do
      Req.Test.expect(@stub, 1, fn conn ->
        assert conn.request_path == "/v1/domain/search/batch/b1/results"

        conn
        |> put_resp_content_type("text/csv")
        |> send_resp(200, "row_no,domain\n1,example.com\n")
      end)

      assert {:ok, "row_no,domain\n1,example.com\n"} =
               BillionVerify.download_domain_search_batch_results(client, "b1")

      Req.Test.expect(@stub, 1, fn conn ->
        failure(conn, 409, "RESULTS_NOT_READY", "not finished")
      end)

      assert {:error, %Error{type: :api, status: 409, code: "RESULTS_NOT_READY"}} =
               BillionVerify.download_domain_search_batch_results(client, "b1")
    end
  end

  describe "error mapping" do
    for {status, type, code} <- [
          {400, :validation, "INVALID_REQUEST"},
          {401, :authentication, "INVALID_API_KEY"},
          {402, :insufficient_credits, "INSUFFICIENT_CREDITS"},
          {404, :not_found, "JOB_NOT_FOUND"},
          {409, :api, "CONFLICT"},
          {413, :api, "TOO_LARGE"}
        ] do
      test "#{status} becomes #{type}", %{client: client} do
        Req.Test.stub(@stub, fn conn -> failure(conn, unquote(status), unquote(code), "boom") end)
        assert {:error, %Error{} = error} = BillionVerify.get_credits(client)
        assert error.type == unquote(type)
        assert error.status == unquote(status)
        assert error.code == unquote(code)
        assert error.message == "boom"
        refute_received {:slept, _}
      end
    end

    test "falls back to the top-level message and an HTTP status text", %{client: client} do
      Req.Test.expect(@stub, 1, fn conn ->
        conn |> put_status(400) |> Req.Test.json(%{success: false, message: "Invalid request"})
      end)

      assert {:error, %Error{message: "Invalid request", code: "INVALID_REQUEST"}} =
               BillionVerify.get_credits(client)

      Req.Test.expect(@stub, 1, fn conn -> send_resp(conn, 418, "teapot") end)

      assert {:error, %Error{type: :api, status: 418, message: "HTTP 418", code: "UNKNOWN_ERROR"}} =
               BillionVerify.get_credits(client)
    end

    test "details are kept", %{client: client} do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> put_status(400)
        |> Req.Test.json(%{
          error: %{code: "INVALID_REQUEST", message: "bad", details: "field email"}
        })
      end)

      assert {:error, %Error{details: "field email"}} = BillionVerify.get_credits(client)
    end

    test "invalid JSON in a success response", %{client: client} do
      Req.Test.stub(@stub, fn conn -> send_resp(conn, 200, "<html>") end)

      assert {:error, %Error{type: :api, code: "INVALID_RESPONSE"}} =
               BillionVerify.get_credits(client)
    end

    test "a timeout and a network failure", %{client: client} do
      Req.Test.expect(@stub, 1, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Error{type: :timeout, code: "TIMEOUT", status: 504}} =
               BillionVerify.get_credits(client)

      Req.Test.expect(@stub, 1, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{type: :network, code: "NETWORK_ERROR", status: 0}} =
               BillionVerify.get_credits(client)
    end
  end

  describe "retries" do
    test "429 waits for Retry-After and then succeeds", %{client: client} do
      Req.Test.expect(@stub, 1, fn conn ->
        conn
        |> put_resp_header("retry-after", "4")
        |> failure(429, "RATE_LIMIT_EXCEEDED", "slow down")
      end)

      Req.Test.expect(@stub, 1, fn conn -> envelope(conn, %{"credits_balance" => 1}) end)

      assert {:ok, %{"credits_balance" => 1}} = BillionVerify.get_credits(client)
      assert_received {:slept, 4000}
    end

    test "503 backs off exponentially", %{client: client} do
      Req.Test.expect(@stub, 2, fn conn -> failure(conn, 503, "UNAVAILABLE", "down") end)
      Req.Test.expect(@stub, 1, fn conn -> envelope(conn, %{"ok" => true}) end)

      assert {:ok, %{"ok" => true}} = BillionVerify.get_credits(client)
      assert_received {:slept, 2000}
      assert_received {:slept, 4000}
    end

    test "gives up after the configured attempts and returns the last error", %{client: client} do
      Req.Test.expect(@stub, 3, fn conn -> failure(conn, 500, "INTERNAL", "oops") end)

      assert {:error, %Error{type: :api, status: 500, code: "INTERNAL"}} =
               BillionVerify.get_credits(client)

      assert_received {:slept, 2000}
      assert_received {:slept, 4000}
      refute_received {:slept, _}
    end

    test "429 that never clears becomes a rate_limit error with retry_after", %{client: client} do
      client = %{client | retries: 2}

      Req.Test.expect(@stub, 2, fn conn ->
        conn
        |> put_resp_header("retry-after", "9")
        |> failure(429, "RATE_LIMIT_EXCEEDED", "slow down")
      end)

      assert {:error, %Error{type: :rate_limit, status: 429, retry_after: 9}} =
               BillionVerify.get_credits(client)

      assert_received {:slept, 9000}
    end

    test "429 without Retry-After reports retry_after 0", %{client: client} do
      client = %{client | retries: 1}
      Req.Test.stub(@stub, fn conn -> failure(conn, 429, "RATE_LIMIT_EXCEEDED", "slow down") end)

      assert {:error, %Error{type: :rate_limit, retry_after: 0}} =
               BillionVerify.get_credits(client)
    end

    test "does not retry 4xx or timeouts", %{client: client} do
      Req.Test.expect(@stub, 1, fn conn ->
        failure(conn, 402, "INSUFFICIENT_CREDITS", "no credits")
      end)

      assert {:error, %Error{type: :insufficient_credits}} =
               BillionVerify.verify(client, "a@b.co")

      refute_received {:slept, _}
    end

    test "uploads are retried with their body intact", %{client: client} do
      Req.Test.expect(@stub, 1, fn conn -> failure(conn, 502, "BAD_GATEWAY", "x") end)

      Req.Test.expect(@stub, 1, fn conn ->
        {body, conn} = body_of(conn)
        assert body =~ "a@b.co"
        envelope(conn, %{"task_id" => "j"})
      end)

      assert {:ok, %{"task_id" => "j"}} =
               BillionVerify.upload_file(client, {:data, "a@b.co", "e.txt"})
    end
  end
end
