defmodule BillionVerify.HTTP do
  @moduledoc false

  alias BillionVerify.Error

  @retry_statuses [429, 500, 502, 503]
  @redirect_statuses [301, 302, 303, 307, 308]

  @type response :: %{status: non_neg_integer(), headers: map(), body: binary()}

  # Sends a request and returns the raw response for 2xx, a typed error otherwise.
  # Retries 429, 500, 502 and 503 until `client.retries` attempts have been made.
  @spec request(BillionVerify.t(), atom(), String.t(), keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def request(client, method, path, opts \\ []) do
    do_request(client, method, path, opts, 1)
  end

  # Sends a request and unwraps the `{success, code, message, data}` envelope.
  @spec json(BillionVerify.t(), atom(), String.t(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def json(client, method, path, opts \\ []) do
    with {:ok, response} <- request(client, method, path, opts) do
      decode_success(response, path)
    end
  end

  # Downloads a body, following a redirect without sending the API key to another host.
  @spec download(BillionVerify.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def download(client, path, opts \\ []) do
    with {:ok, response} <- request(client, :get, path, Keyword.put(opts, :follow, false)) do
      case response do
        %{status: status} when status in @redirect_statuses ->
          follow_redirect(client, response, path, opts)

        %{body: body} ->
          {:ok, body}
      end
    end
  end

  defp follow_redirect(client, response, path, opts) do
    case response.headers |> Map.get("location", []) |> List.first() do
      nil ->
        {:error, Error.new(:api, "redirect without a Location header", status: response.status)}

      location ->
        target = URI.merge(URI.merge(URI.parse(client.base_url), path), location)
        request_url(client, target, opts)
    end
  end

  # The second hop never carries the API key: the redirect points at pre-signed
  # storage, which may be another host.
  defp request_url(client, %URI{} = target, opts) do
    timeout = Keyword.get(opts, :timeout, client.timeout)

    req_opts =
      Keyword.merge(client.req_options,
        method: :get,
        url: URI.to_string(target),
        headers: [{"user-agent", user_agent()}],
        receive_timeout: timeout,
        retry: false,
        redirect: true,
        decode_body: false
      )

    case safe_req(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{} = response} ->
        {:error, build_error(to_response(response))}

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_request(client, method, path, opts, attempt) do
    timeout = Keyword.get(opts, :timeout, client.timeout)
    auth? = Keyword.get(opts, :auth, true)

    headers =
      [{"user-agent", user_agent()}, {"accept", "application/json"}] ++
        if(auth?, do: auth_headers(client), else: [])

    {headers, body_opts} = body_options(headers, opts)

    req_opts =
      client.req_options
      |> Keyword.merge(
        method: method,
        url: client.base_url <> path,
        headers: headers,
        receive_timeout: timeout,
        retry: false,
        redirect: false,
        decode_body: false
      )
      |> Keyword.merge(body_opts)
      |> put_params(Keyword.get(opts, :params))

    case safe_req(req_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, to_response(response)}

      {:ok, %Req.Response{status: status} = response}
      when status in @redirect_statuses and method == :get ->
        if Keyword.get(opts, :follow, true) do
          {:error, build_error(to_response(response))}
        else
          {:ok, to_response(response)}
        end

      {:ok, %Req.Response{status: status} = response} ->
        response = to_response(response)

        if attempt < client.retries and status in @retry_statuses do
          client.sleep.(backoff_ms(response, attempt))
          do_request(client, method, path, opts, attempt + 1)
        else
          {:error, build_error(response)}
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  defp put_params(req_opts, nil), do: req_opts
  defp put_params(req_opts, []), do: req_opts
  defp put_params(req_opts, params), do: Keyword.put(req_opts, :params, params)

  defp body_options(headers, opts) do
    cond do
      Keyword.has_key?(opts, :json) ->
        {[{"content-type", "application/json"} | headers],
         [body: JSON.encode!(Keyword.fetch!(opts, :json))]}

      Keyword.has_key?(opts, :multipart) ->
        {headers, [form_multipart: Keyword.fetch!(opts, :multipart)]}

      true ->
        {headers, []}
    end
  end

  defp safe_req(req_opts) do
    case Req.request(req_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} when reason in [:timeout, :connect_timeout] ->
        {:error, Error.new(:timeout, "Request timed out")}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, Error.new(:network, "Network error: #{inspect(reason)}")}

      {:error, %{__exception__: true} = exception} ->
        {:error, Error.new(:network, "Network error: " <> sanitize(Exception.message(exception)))}
    end
  rescue
    exception in [ArgumentError, File.Error] ->
      {:error, Error.new(:validation, sanitize(Exception.message(exception)))}
  end

  # Error messages end up in logs: never let a URL's query string (a pre-signed
  # download address carries its signature there) or fragment into one.
  @doc false
  @spec sanitize(String.t()) :: String.t()
  def sanitize(message) do
    Regex.replace(~r{(https?://[^\s?#"'<>]*)[?#][^\s"'<>]*}i, message, "\\1")
  end

  defp to_response(%Req.Response{status: status, headers: headers, body: body}) do
    %{status: status, headers: headers, body: to_binary(body)}
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(nil), do: ""
  defp to_binary(other), do: IO.iodata_to_binary(other)

  defp backoff_ms(%{status: 429} = response, attempt) do
    case retry_after(response) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1000
      _ -> exponential(attempt)
    end
  end

  defp backoff_ms(_response, attempt), do: exponential(attempt)

  defp exponential(attempt), do: Integer.pow(2, attempt) * 1000

  defp retry_after(%{headers: headers}) do
    with [value | _] <- Map.get(headers, "retry-after", []),
         {seconds, ""} <- Integer.parse(String.trim(value)) do
      seconds
    else
      _ -> nil
    end
  end

  defp auth_headers(client), do: [{"bv-api-key", client.api_key}]

  defp user_agent, do: "billionverify-elixir/" <> BillionVerify.version()

  defp decode_success(%{body: ""}, _path), do: {:ok, nil}

  defp decode_success(%{status: status, body: body}, path) do
    case JSON.decode(body) do
      {:ok, %{"data" => data}} ->
        {:ok, data}

      {:ok, other} ->
        {:ok, other}

      {:error, _} ->
        {:error,
         Error.new(:api, "invalid JSON in response from #{path}",
           code: "INVALID_RESPONSE",
           status: status
         )}
    end
  end

  defp build_error(%{status: status, body: body} = response) do
    {message, code, details} = decode_error(body)
    message = message || reason_phrase(status)

    case status do
      400 ->
        Error.new(:validation, message, code: code, details: details)

      401 ->
        Error.new(:authentication, message, code: code, details: details)

      402 ->
        Error.new(:insufficient_credits, message, code: code, details: details)

      404 ->
        Error.new(:not_found, message, code: code, details: details)

      429 ->
        Error.new(:rate_limit, message,
          code: code,
          details: details,
          retry_after: retry_after(response) || 0
        )

      _ ->
        Error.new(:api, message, code: code, details: details, status: status)
    end
  end

  defp decode_error(body) do
    case JSON.decode(body) do
      {:ok, %{} = decoded} ->
        error = if is_map(decoded["error"]), do: decoded["error"], else: %{}

        message = error["message"] || decoded["message"]
        code = error["code"]
        details = error["details"] || error["description"]
        {blank_to_nil(message), blank_to_nil(code), details}

      _ ->
        {nil, nil, nil}
    end
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp reason_phrase(status), do: "HTTP #{status}"
end
