# BillionVerify for Elixir

The official Elixir client for the [BillionVerify](https://billionverify.com) email verification API: single and batch verification, file verification, credits, webhooks, domain search and batch domain search.

## Installation

Add `billionverify` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:billionverify, "~> 1.0"}
  ]
end
```

It needs Elixir 1.18 or later and uses [Req](https://hex.pm/packages/req) for HTTP.

## Quick start

```elixir
client = BillionVerify.new(api_key: System.fetch_env!("BILLIONVERIFY_API_KEY"))

{:ok, result} = BillionVerify.verify(client, "user@example.com")
result["status"]         #=> "valid"
result["is_deliverable"] #=> true
result["credits_used"]   #=> 1
```

Every operation returns `{:ok, data}` or `{:error, %BillionVerify.Error{}}`, and has a `!` twin (`verify!/3`) that returns `data` or raises. `data` is a map with string keys, exactly the `data` field of the API response, so fields added by the API later are never dropped.

Client options:

| Option | Default | Meaning |
| --- | --- | --- |
| `:api_key` | required | Your API key, sent as `BV-API-KEY` |
| `:base_url` | `https://api.billionverify.com` | A trailing `/` or `/v1` is dropped |
| `:timeout` | `30_000` | Request timeout in milliseconds |
| `:retries` | `3` | Total attempts for 429, 500, 502 and 503 |
| `:sleep` | `Process.sleep/1` | Waits between attempts, in milliseconds |
| `:req_options` | `[]` | Extra options for every `Req` request |

## Verify emails

```elixir
# One address. Options are sent only when you give them.
{:ok, result} =
  BillionVerify.verify(client, "user@example.com",
    check_smtp: true,
    force_refresh: false,
    include_domain_reputation: true
  )

# Up to 50 addresses in one request. More is rejected locally; use a file instead.
{:ok, batch} = BillionVerify.verify_batch(client, ["a@example.com", "b@example.com"])
batch["deliverability_buckets"]["strict_deliverable"]

# Disposable check, free of charge
{:ok, %{"is_disposable" => true}} = BillionVerify.check_disposable(client, "x@mailinator.com")
{:ok, _} = BillionVerify.check_disposable_via_query(client, "x@mailinator.com")
```

## Verify a file

```elixir
{:ok, job} = BillionVerify.upload_file(client, {:path, "emails.csv"}, email_column: "email")
# or from memory: {:data, binary, "emails.csv"}

# Wait for the job (polls every 5 s, up to 10 minutes by default)
{:ok, status} = BillionVerify.wait_for_file_job(client, job["task_id"])

# Or long-poll the server for up to 60 seconds
{:ok, status} = BillionVerify.get_file_job_status(client, job["task_id"], timeout_seconds: 60)

# Download the results. Filters keep only the matching rows (combined with OR).
{:ok, csv} = BillionVerify.download_file_results(client, job["task_id"], valid: true, catchall: true)
{:ok, "results.csv"} = BillionVerify.download_file_results(client, job["task_id"], output_path: "results.csv")

# A paused job can be resumed
{:ok, _} = BillionVerify.resume_job(client, job["task_id"])
```

Without filters the API redirects the download to pre-signed storage. The SDK follows that redirect itself and does not send your API key to the storage host.

## Credits

```elixir
{:ok, %{"credits_balance" => balance}} = BillionVerify.get_credits(client)
```

## Webhooks

```elixir
{:ok, webhook} =
  BillionVerify.create_webhook(client, "https://your-app.com/hooks/billionverify", [
    "file.completed",
    "file.failed"
  ])

webhook["secret"]   # shown only once: store it

{:ok, webhooks} = BillionVerify.list_webhooks(client)
{:ok, _} = BillionVerify.delete_webhook(client, webhook["id"])
```

Verify every delivery with the raw request body, the two headers and your secret:

```elixir
BillionVerify.verify_webhook_signature(
  raw_body,                      # exactly as received
  signature_header,              # X-Webhook-Signature: "sha256=<hex>"
  timestamp_header,              # X-Webhook-Timestamp
  secret
)
#=> true | false
```

The signed text is `"<timestamp>.<raw_body>"`. A timestamp more than five minutes away from now fails the check; change it with `tolerance: seconds` (`0` turns the time check off). In Phoenix, keep the raw body with a `:body_reader` in `Plug.Parsers`.

## Domain search

Find the emails published on a company's site. Each returned email costs 5 credits; `max_emails` is the cap on the bill.

```elixir
{:ok, search} = BillionVerify.create_domain_search(client, "example.com", 20, include_role_based: false)
{:ok, done} = BillionVerify.wait_for_domain_search(client, search["search_id"])
done["result"]["emails"]
```

Many domains at once, from a CSV:

```elixir
{:ok, batch} =
  BillionVerify.create_domain_search_batch(client, {:path, "domains.csv"},
    max_emails: 50,
    column_map: %{"domain" => "Company Website"}
  )

{:ok, progress} = BillionVerify.get_domain_search_batch(client, batch["batch_id"])
{:ok, page} = BillionVerify.list_domain_search_batches(client, limit: 20, status: "completed")
{:ok, csv} = BillionVerify.download_domain_search_batch_results(client, batch["batch_id"])
```

The results are available once the batch has finished; before that the API answers 409.

## Health

```elixir
{:ok, %{"status" => "ok"}} = BillionVerify.health_check(client)
```

## Errors

```elixir
case BillionVerify.verify(client, "user@example.com") do
  {:ok, result} -> result
  {:error, %BillionVerify.Error{type: :insufficient_credits}} -> :top_up
  {:error, %BillionVerify.Error{type: :rate_limit, retry_after: seconds}} -> {:retry_in, seconds}
  {:error, %BillionVerify.Error{} = error} -> {:failed, error.code, error.message}
end
```

| `type` | When |
| --- | --- |
| `:validation` | HTTP 400, or a request rejected before it was sent (more than 50 emails, a bad timeout) |
| `:authentication` | HTTP 401, or an empty API key |
| `:insufficient_credits` | HTTP 402 |
| `:not_found` | HTTP 404 |
| `:rate_limit` | HTTP 429 after the retries; `retry_after` holds the seconds |
| `:timeout` | The request or a wait timed out |
| `:network` | The connection failed |
| `:api` | Any other status (409, 500, ...); see `status` and `code` |

429, 500, 502 and 503 are retried: the wait is the `Retry-After` header when present on a 429, otherwise 2, 4, 8 ... seconds.

## Testing your code

Pass a `Req` stub in `:req_options` and a no-op `:sleep`:

```elixir
client =
  BillionVerify.new(
    api_key: "test",
    sleep: fn _ms -> :ok end,
    req_options: [plug: {Req.Test, MyApp.BillionVerifyStub}]
  )
```

## Releasing

1. Update `@version` in `mix.exs` and add the entry to `CHANGELOG.md`.
2. Run `mix format --check-formatted`, `mix compile --warnings-as-errors` and `mix test`.
3. Commit, then tag and push: `git tag v1.0.0 && git push origin main v1.0.0`.
4. Publish the package and its docs: `HEX_API_KEY=... mix hex.publish --yes`. The `release` workflow does the same from a `v*` tag when the repository secret `HEX_API_KEY` is set.

## License

MIT
