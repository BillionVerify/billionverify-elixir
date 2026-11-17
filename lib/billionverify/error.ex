defmodule BillionVerify.Error do
  @moduledoc """
  The error returned (or raised by the `!` functions) by every operation.

  `type` tells you what went wrong:

    * `:authentication` - HTTP 401, or an empty API key
    * `:validation` - HTTP 400, or a request rejected locally before it was sent
    * `:insufficient_credits` - HTTP 402
    * `:not_found` - HTTP 404
    * `:rate_limit` - HTTP 429 (see `retry_after`, in seconds)
    * `:timeout` - the request or a wait timed out
    * `:network` - the connection failed
    * `:api` - any other error status (409, 500, ...) or an unreadable response

  `code` is the API's error code (for example `"INSUFFICIENT_CREDITS"`), `status`
  the HTTP status (0 when no response was received) and `details` any extra
  context the API sent.
  """

  defexception [:type, :message, :code, :status, :details, :retry_after]

  @type type ::
          :authentication
          | :validation
          | :insufficient_credits
          | :not_found
          | :rate_limit
          | :timeout
          | :network
          | :api

  @type t :: %__MODULE__{
          type: type(),
          message: String.t(),
          code: String.t(),
          status: non_neg_integer(),
          details: term(),
          retry_after: non_neg_integer() | nil
        }

  @doc false
  @spec new(type(), String.t(), keyword()) :: t()
  def new(type, message, opts \\ []) do
    {code, status} = defaults(type)

    %__MODULE__{
      type: type,
      message: message,
      code: Keyword.get(opts, :code) || code,
      status: Keyword.get(opts, :status) || status,
      details: Keyword.get(opts, :details),
      retry_after: Keyword.get(opts, :retry_after)
    }
  end

  defp defaults(:authentication), do: {"INVALID_API_KEY", 401}
  defp defaults(:validation), do: {"INVALID_REQUEST", 400}
  defp defaults(:insufficient_credits), do: {"INSUFFICIENT_CREDITS", 402}
  defp defaults(:not_found), do: {"NOT_FOUND", 404}
  defp defaults(:rate_limit), do: {"RATE_LIMIT_EXCEEDED", 429}
  defp defaults(:timeout), do: {"TIMEOUT", 504}
  defp defaults(:network), do: {"NETWORK_ERROR", 0}
  defp defaults(:api), do: {"UNKNOWN_ERROR", 0}

  @impl true
  def message(%__MODULE__{code: code, message: message}), do: "#{code}: #{message}"
end
