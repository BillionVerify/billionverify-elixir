defmodule BillionVerify do
  @moduledoc """
  Client for the [BillionVerify](https://billionverify.com) email verification API.

      client = BillionVerify.new(api_key: System.fetch_env!("BILLIONVERIFY_API_KEY"))

      {:ok, result} = BillionVerify.verify(client, "user@example.com")
      result["status"]
      #=> "valid"

  Every operation returns `{:ok, data}` or `{:error, %BillionVerify.Error{}}`, and has
  a `!` twin that returns `data` or raises the error. `data` is the decoded `data`
  field of the API response: a map with string keys, so fields the API adds later
  are never lost.

  ## Options

  `new/1` takes:

    * `:api_key` - required
    * `:base_url` - default `"https://api.billionverify.com"`; a trailing `/` or `/v1` is dropped
    * `:timeout` - per-request timeout in milliseconds, default `30_000`
    * `:retries` - total attempts for a request that gets 429, 500, 502 or 503, default `3`
    * `:sleep` - a one-argument function that waits that many milliseconds between
      attempts, default `Process.sleep/1`
    * `:req_options` - extra options merged into every `Req` request (for example
      `plug: {Req.Test, MyStub}` in tests)

  Every operation also accepts `timeout: ms` to override the client timeout for that call.
  """

  alias BillionVerify.{Error, HTTP}

  @version "1.0.0"
  @default_base_url "https://api.billionverify.com"
  @terminal_file_states ~w(completed completed_with_warning failed cancelled paused)
  @terminal_search_states ~w(completed completed_with_warning failed)
  @result_filters ~w(valid invalid catchall role unknown disposable risky)a

  defstruct api_key: nil,
            base_url: @default_base_url,
            timeout: 30_000,
            retries: 3,
            sleep: &Process.sleep/1,
            req_options: []

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: pos_integer(),
          retries: pos_integer(),
          sleep: (non_neg_integer() -> any()),
          req_options: keyword()
        }

  @type result(data) :: {:ok, data} | {:error, Error.t()}

  @type file ::
          {:path, Path.t()}
          | {:data, binary(), filename :: String.t()}

  @doc "The SDK version."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Builds a client.

  Raises a `BillionVerify.Error` of type `:authentication` when the API key is empty.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    api_key = Keyword.get(opts, :api_key)

    if not (is_binary(api_key) and String.trim(api_key) != "") do
      raise Error.new(:authentication, "API key is required")
    end

    %__MODULE__{
      api_key: api_key,
      base_url: normalize_base_url(Keyword.get(opts, :base_url, @default_base_url)),
      timeout: Keyword.get(opts, :timeout, 30_000),
      retries: Keyword.get(opts, :retries, 3),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  defp normalize_base_url(url) do
    url |> String.trim_trailing("/") |> String.replace_suffix("/v1", "")
  end

  # -- Verification ---------------------------------------------------------

  @doc """
  Verifies one email address (`POST /v1/verify/single`).

  Options: `:check_smtp`, `:force_refresh`, `:include_domain_reputation` (booleans,
  sent only when given).
  """
  @spec verify(t(), String.t(), keyword()) :: result(map())
  def verify(client, email, opts \\ []) do
    body =
      [email: email]
      |> put_given(opts, [:check_smtp, :force_refresh, :include_domain_reputation])
      |> Map.new()

    HTTP.json(client, :post, "/v1/verify/single", [json: body] ++ call_opts(opts))
  end

  @doc """
  Verifies up to 50 addresses in one request (`POST /v1/verify/bulk`).

  More than 50 addresses is rejected locally with a `:validation` error; use
  `upload_file/3` for larger lists. Options are those of `verify/3`.
  """
  @spec verify_batch(t(), [String.t()], keyword()) :: result(map())
  def verify_batch(client, emails, opts \\ []) when is_list(emails) do
    if length(emails) > 50 do
      {:error,
       Error.new(
         :validation,
         "Maximum 50 emails per batch request. For larger lists, use upload_file/3."
       )}
    else
      body =
        [emails: emails]
        |> put_given(opts, [:check_smtp, :force_refresh, :include_domain_reputation])
        |> Map.new()

      HTTP.json(client, :post, "/v1/verify/bulk", [json: body] ++ call_opts(opts))
    end
  end

  @doc "Checks whether the address uses a disposable domain, free of charge (`POST /v1/verify/disposable`)."
  @spec check_disposable(t(), String.t(), keyword()) :: result(map())
  def check_disposable(client, email, opts \\ []) do
    HTTP.json(
      client,
      :post,
      "/v1/verify/disposable",
      [json: %{email: email}] ++ call_opts(opts)
    )
  end

  @doc "Same as `check_disposable/3`, with the address in the query string (`GET /v1/verify/disposable`)."
  @spec check_disposable_via_query(t(), String.t(), keyword()) :: result(map())
  def check_disposable_via_query(client, email, opts \\ []) do
    HTTP.json(
      client,
      :get,
      "/v1/verify/disposable",
      [params: [email: email]] ++ call_opts(opts)
    )
  end

  # -- File verification ----------------------------------------------------

  @doc """
  Uploads a CSV, XLSX or TXT file for asynchronous verification (`POST /v1/verify/file`).

  `file` is `{:path, "emails.csv"}` or `{:data, binary, "emails.csv"}`. Options:
  `:check_smtp`, `:email_column`, `:preserve_original`.
  """
  @spec upload_file(t(), file(), keyword()) :: result(map())
  def upload_file(client, file, opts \\ []) do
    with {:ok, file_part} <- file_part(file) do
      fields =
        [file: file_part]
        |> put_given_strings(opts, [:check_smtp, :email_column, :preserve_original])

      HTTP.json(client, :post, "/v1/verify/file", [multipart: fields] ++ call_opts(opts))
    end
  end

  @doc """
  Gets a file job's status and progress (`GET /v1/verify/file/{job_id}`).

  `:timeout_seconds` (0 to 300) turns the call into a long poll: the server answers
  when the job finishes or the time is up. The HTTP timeout is extended to match.
  """
  @spec get_file_job_status(t(), String.t(), keyword()) :: result(map())
  def get_file_job_status(client, job_id, opts \\ []) do
    case Keyword.get(opts, :timeout_seconds) do
      nil ->
        HTTP.json(client, :get, "/v1/verify/file/#{segment(job_id)}", call_opts(opts))

      seconds when is_integer(seconds) and seconds >= 0 and seconds <= 300 ->
        http_timeout = max(client.timeout, (seconds + 10) * 1000)

        HTTP.json(
          client,
          :get,
          "/v1/verify/file/#{segment(job_id)}",
          [params: [timeout: seconds]] ++ Keyword.put(call_opts(opts), :timeout, http_timeout)
        )

      _ ->
        {:error, Error.new(:validation, "Timeout must be between 0 and 300 seconds")}
    end
  end

  @doc """
  Downloads a finished job's results as CSV (`GET /v1/verify/file/{job_id}/results`).

  Filters (`:valid`, `:invalid`, `:catchall`, `:role`, `:unknown`, `:disposable`,
  `:risky`) keep only the matching rows; several filters combine with OR. Without
  filters the API redirects to the full result file, which is fetched without the
  API key.

  Returns the CSV as a binary, or with `output_path: "results.csv"` writes it there
  and returns the path.
  """
  @spec download_file_results(t(), String.t(), keyword()) :: result(binary())
  def download_file_results(client, job_id, opts \\ []) do
    params = for f <- @result_filters, Keyword.get(opts, f) == true, do: {f, "true"}

    request_opts = if params == [], do: [], else: [params: params]

    with {:ok, body} <-
           HTTP.download(
             client,
             "/v1/verify/file/#{segment(job_id)}/results",
             request_opts ++ call_opts(opts)
           ) do
      write_output(body, Keyword.get(opts, :output_path))
    end
  end

  @doc "Resumes a paused file job (`POST /v1/jobs/{job_id}/resume`). Returns the job status."
  @spec resume_job(t(), String.t(), keyword()) :: result(map())
  def resume_job(client, job_id, opts \\ []) do
    HTTP.json(client, :post, "/v1/jobs/#{segment(job_id)}/resume", call_opts(opts))
  end

  @doc """
  Polls a file job until it reaches a final state (`completed`, `completed_with_warning`,
  `failed` or `cancelled`) or stops on `paused`, and returns its status.

  Options: `:poll_interval` (ms, default `5_000`), `:max_wait` (ms, default `600_000`).
  Returns a `:timeout` error when the job is still running after `:max_wait`.
  """
  @spec wait_for_file_job(t(), String.t(), keyword()) :: result(map())
  def wait_for_file_job(client, job_id, opts \\ []) do
    wait_until(client, opts, @terminal_file_states, "File job #{job_id}", fn ->
      get_file_job_status(client, job_id, call_opts(opts))
    end)
  end

  # -- Account --------------------------------------------------------------

  @doc "Gets the credit balance (`GET /v1/credits`)."
  @spec get_credits(t(), keyword()) :: result(map())
  def get_credits(client, opts \\ []) do
    HTTP.json(client, :get, "/v1/credits", call_opts(opts))
  end

  # -- Webhooks -------------------------------------------------------------

  @doc """
  Creates a webhook (`POST /v1/webhooks`). `url` must be HTTPS; `events` are
  `"file.completed"` and `"file.failed"`. The returned `"secret"` is shown only once.
  """
  @spec create_webhook(t(), String.t(), [String.t()], keyword()) :: result(map())
  def create_webhook(client, url, events, opts \\ []) do
    HTTP.json(
      client,
      :post,
      "/v1/webhooks",
      [json: %{url: url, events: events}] ++ call_opts(opts)
    )
  end

  @doc "Lists webhooks (`GET /v1/webhooks`). Returns the list; the secret is not included."
  @spec list_webhooks(t(), keyword()) :: result([map()])
  def list_webhooks(client, opts \\ []) do
    with {:ok, data} <- HTTP.json(client, :get, "/v1/webhooks", call_opts(opts)) do
      case data do
        %{"webhooks" => webhooks} when is_list(webhooks) ->
          {:ok, webhooks}

        nil ->
          {:ok, []}

        _ ->
          {:error,
           Error.new(:api, "unexpected response from /v1/webhooks", code: "INVALID_RESPONSE")}
      end
    end
  end

  @doc "Deletes a webhook (`DELETE /v1/webhooks/{webhook_id}`)."
  @spec delete_webhook(t(), String.t(), keyword()) :: result(map() | nil)
  def delete_webhook(client, webhook_id, opts \\ []) do
    HTTP.json(client, :delete, "/v1/webhooks/#{segment(webhook_id)}", call_opts(opts))
  end

  @doc """
  Verifies a webhook delivery.

  Pass the raw request body exactly as received, the `X-Webhook-Signature` header
  (`"sha256=<hex>"`), the `X-Webhook-Timestamp` header and your webhook secret. The
  signed text is `"<timestamp>.<raw_body>"`. Returns `false` for a wrong signature
  or a timestamp more than `:tolerance` seconds from now (default `300`; `0` turns
  the time check off). `:now` (Unix seconds) is for tests.
  """
  @spec verify_webhook_signature(binary(), String.t(), String.t(), String.t(), keyword()) ::
          boolean()
  def verify_webhook_signature(raw_body, signature, timestamp, secret, opts \\ [])
      when is_binary(raw_body) and is_binary(secret) do
    tolerance = Keyword.get(opts, :tolerance, 300)
    now = Keyword.get(opts, :now, System.os_time(:second))

    with true <- is_binary(signature) and is_binary(timestamp),
         {ts, ""} <- Integer.parse(String.trim(timestamp)),
         true <- tolerance == 0 or abs(now - ts) <= tolerance do
      expected =
        "sha256=" <>
          Base.encode16(
            :crypto.mac(:hmac, :sha256, secret, [String.trim(timestamp), ".", raw_body]),
            case: :lower
          )

      byte_size(expected) == byte_size(signature) and :crypto.hash_equals(expected, signature)
    else
      _ -> false
    end
  end

  # -- Domain search --------------------------------------------------------

  @doc """
  Starts a domain search (`POST /v1/domain/search`): finds the emails published on a
  company's site. `max_emails` (1 to 200) caps the bill (5 credits per returned email).

  Options: `:include_role_based` (boolean), `:max_pages` (positive integer).
  """
  @spec create_domain_search(t(), String.t(), pos_integer(), keyword()) :: result(map())
  def create_domain_search(client, domain, max_emails, opts \\ []) do
    if is_integer(max_emails) and max_emails >= 1 and max_emails <= 200 do
      body =
        [domain: domain, max_emails: max_emails]
        |> put_given(opts, [:include_role_based, :max_pages])
        |> Map.new()

      HTTP.json(client, :post, "/v1/domain/search", [json: body] ++ call_opts(opts))
    else
      {:error, Error.new(:validation, "max_emails must be between 1 and 200")}
    end
  end

  @doc "Gets a domain search's status and, once finished, its result (`GET /v1/domain/search/{search_id}`)."
  @spec get_domain_search(t(), String.t(), keyword()) :: result(map())
  def get_domain_search(client, search_id, opts \\ []) do
    HTTP.json(client, :get, "/v1/domain/search/#{segment(search_id)}", call_opts(opts))
  end

  @doc """
  Polls a domain search until `completed`, `completed_with_warning` or `failed`.
  Options: `:poll_interval` (ms, default `5_000`), `:max_wait` (ms, default `600_000`).
  """
  @spec wait_for_domain_search(t(), String.t(), keyword()) :: result(map())
  def wait_for_domain_search(client, search_id, opts \\ []) do
    wait_until(client, opts, @terminal_search_states, "Domain search #{search_id}", fn ->
      get_domain_search(client, search_id, call_opts(opts))
    end)
  end

  @doc """
  Starts a batch domain search from a CSV of domains (`POST /v1/domain/search/batch`).

  `file` is as in `upload_file/3`. Options: `:max_emails` (1 to 200), `:include_role_based`,
  `:max_pages`, and `:column_map` (a map such as `%{"domain" => "Company Website"}`, or
  a JSON string).
  """
  @spec create_domain_search_batch(t(), file(), keyword()) :: result(map())
  def create_domain_search_batch(client, file, opts \\ []) do
    max_emails = Keyword.get(opts, :max_emails)

    cond do
      max_emails != nil and not (is_integer(max_emails) and max_emails in 1..200) ->
        {:error, Error.new(:validation, "max_emails must be between 1 and 200")}

      true ->
        with {:ok, file_part} <- file_part(file) do
          opts =
            case Keyword.get(opts, :column_map) do
              map when is_map(map) -> Keyword.put(opts, :column_map, JSON.encode!(map))
              _ -> opts
            end

          fields =
            [file: file_part]
            |> put_given_strings(opts, [:max_emails, :include_role_based, :max_pages, :column_map])

          HTTP.json(
            client,
            :post,
            "/v1/domain/search/batch",
            [multipart: fields] ++ call_opts(opts)
          )
        end
    end
  end

  @doc """
  Lists batch domain searches (`GET /v1/domain/search/batch`). Options: `:limit`
  (up to 100), `:status`, `:cursor`. The result has `"items"`, `"has_more"` and `"next_cursor"`.
  """
  @spec list_domain_search_batches(t(), keyword()) :: result(map())
  def list_domain_search_batches(client, opts \\ []) do
    params = for k <- [:limit, :status, :cursor], Keyword.get(opts, k) != nil, do: {k, opts[k]}
    request_opts = if params == [], do: [], else: [params: params]

    HTTP.json(client, :get, "/v1/domain/search/batch", request_opts ++ call_opts(opts))
  end

  @doc "Gets a batch domain search's status and progress (`GET /v1/domain/search/batch/{batch_id}`)."
  @spec get_domain_search_batch(t(), String.t(), keyword()) :: result(map())
  def get_domain_search_batch(client, batch_id, opts \\ []) do
    HTTP.json(client, :get, "/v1/domain/search/batch/#{segment(batch_id)}", call_opts(opts))
  end

  @doc """
  Downloads a finished batch's results as CSV (`GET /v1/domain/search/batch/{batch_id}/results`).
  Until the batch has finished the API answers 409, returned as an `:api` error with
  `status: 409`. `output_path: "file.csv"` writes the CSV there and returns the path.
  """
  @spec download_domain_search_batch_results(t(), String.t(), keyword()) :: result(binary())
  def download_domain_search_batch_results(client, batch_id, opts \\ []) do
    with {:ok, response} <-
           HTTP.request(
             client,
             :get,
             "/v1/domain/search/batch/#{segment(batch_id)}/results",
             call_opts(opts)
           ) do
      write_output(response.body, Keyword.get(opts, :output_path))
    end
  end

  # -- Health ---------------------------------------------------------------

  @doc "Checks the API's health (`GET /health`, no authentication). Returns `%{\"status\" => \"ok\", \"time\" => ...}`."
  @spec health_check(t(), keyword()) :: result(map())
  def health_check(client, opts \\ []) do
    HTTP.json(client, :get, "/health", [auth: false] ++ call_opts(opts))
  end

  # -- Bang variants --------------------------------------------------------

  for {name, required} <- [
        verify: 2,
        verify_batch: 2,
        check_disposable: 2,
        check_disposable_via_query: 2,
        upload_file: 2,
        get_file_job_status: 2,
        download_file_results: 2,
        resume_job: 2,
        wait_for_file_job: 2,
        get_credits: 1,
        create_webhook: 3,
        list_webhooks: 1,
        delete_webhook: 2,
        create_domain_search: 3,
        get_domain_search: 2,
        wait_for_domain_search: 2,
        create_domain_search_batch: 2,
        list_domain_search_batches: 1,
        get_domain_search_batch: 2,
        download_domain_search_batch_results: 2,
        health_check: 1
      ] do
    bang = :"#{name}!"
    args = Macro.generate_arguments(required, __MODULE__)

    @doc "Same as `#{name}/#{required + 1}`, but returns the data or raises `BillionVerify.Error`."
    def unquote(bang)(unquote_splicing(args), opts \\ []) do
      unquote(name)(unquote_splicing(args), opts) |> unwrap!()
    end
  end

  defp unwrap!({:ok, data}), do: data
  defp unwrap!({:error, %Error{} = error}), do: raise(error)

  # -- Helpers --------------------------------------------------------------

  defp call_opts(opts), do: Keyword.take(opts, [:timeout])

  defp put_given(base, opts, keys) do
    Enum.reduce(keys, base, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} when not is_nil(value) -> acc ++ [{key, value}]
        _ -> acc
      end
    end)
  end

  defp put_given_strings(fields, opts, keys) do
    Enum.reduce(keys, fields, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} when not is_nil(value) -> acc ++ [{key, to_string(value)}]
        _ -> acc
      end
    end)
  end

  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp file_part({:path, path}) do
    case File.read(path) do
      {:ok, data} ->
        {:ok, {data, filename: Path.basename(path)}}

      {:error, reason} ->
        {:error, Error.new(:validation, "Cannot read #{path}: #{:file.format_error(reason)}")}
    end
  end

  defp file_part({:data, data, filename}) when is_binary(data) and is_binary(filename) do
    {:ok, {data, filename: filename}}
  end

  defp file_part(_) do
    {:error, Error.new(:validation, "file must be {:path, path} or {:data, binary, filename}")}
  end

  defp write_output(body, nil), do: {:ok, body}

  defp write_output(body, path) do
    case File.write(path, body) do
      :ok ->
        {:ok, path}

      {:error, reason} ->
        {:error, Error.new(:validation, "Cannot write #{path}: #{:file.format_error(reason)}")}
    end
  end

  defp wait_until(client, opts, final_states, label, fetch) do
    poll_interval = Keyword.get(opts, :poll_interval, 5_000)
    max_wait = Keyword.get(opts, :max_wait, 600_000)
    started = System.monotonic_time(:millisecond)

    loop = fn loop ->
      with {:ok, status} <- fetch.() do
        cond do
          is_map(status) and status["status"] in final_states ->
            {:ok, status}

          System.monotonic_time(:millisecond) - started >= max_wait ->
            {:error, Error.new(:timeout, "#{label} did not finish within #{max_wait}ms")}

          true ->
            client.sleep.(poll_interval)
            loop.(loop)
        end
      end
    end

    loop.(loop)
  end
end
