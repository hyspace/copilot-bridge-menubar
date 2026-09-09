# Activity and request billing

## Presentation

The view follows the contribution-calendar pattern: seven weekday rows, week
columns, month labels and four green intensity levels. We evaluated
[SwiftHeatmapKit](https://github.com/rouzbeh-abadi/SwiftHeatmapKit/tree/ce9be2441c54904c17397bd1f166acf015007189)
as a reference, then used a small native SwiftUI component for per-day billing,
missing-data states and hover/focus behavior. No library source is bundled.

The grid displays 26 calendar weeks, leaving future dates empty. Dates use the
local Gregorian calendar and calendar-day arithmetic, including daylight-saving
transitions. Labels are English.

Color represents reported input plus output tokens relative to the busiest
visible day. Cached tokens are already included in input. A dashed border marks
incomplete token or billing data.

Hover, click or keyboard-focus a day to inspect tokens and **credits used**.
Pointer tracking covers the complete grid rectangle: horizontal and vertical
gutters are assigned to the nearest day, so crossing a visual gap does not reset
the detail panel. Tile sizes, spacing and positions remain unchanged.

## Request usage: tokens and credits

The bridge observes upstream responses before any client-protocol translation.
Copilot's server-reported billing extension is:

```text
usage.copilot_usage.total_nano_aiu
credits = total_nano_aiu / 1_000_000_000
```

This is the conversion used in
[Microsoft's Copilot implementation](https://raw.githubusercontent.com/microsoft/vscode/main/extensions/copilot/src/platform/networking/common/openai.ts).
It is not a token-price estimate. The private supervisor event carries the raw
number as `nanoAiu`; the app aggregates those units and converts them for display.

- Token counters and billing are independent. Billing-only responses are retained.
- SSE frames carry snapshots: the latest reported value replaces the previous
  value, rather than being added again for each frame. Missing fields in later
  frames do not erase earlier observations.
- Each real upstream attempt has a separate event ID, including retries and
  internal model requests. Retry bodies are observed for at most one second or
  4 MiB, then cancelled if necessary. Unreported charges remain unknown.
- An event is emitted at most once per attempt, and the database deduplicates IDs.
  Charges reported by failed or interrupted attempts are retained.
- An explicit zero is a known zero. Missing, invalid or unsupported numeric
  values are not changed into zero-cost requests.
- Daily values are grouped by the upstream attempt's local start date, matching
  the token accounting timestamp.
- Supervised Chat streaming requests ask for `stream_options.include_usage`.
  The observer reads the final usage-only chunk after `finish_reason`, rather
  than treating the first stop marker as the end of accounting.
  Microsoft's [Copilot stream definition](https://github.com/microsoft/vscode/blob/0af2bfdddee61954b27fdb831f7a8b20a139126b/extensions/copilot/src/platform/networking/common/fetch.ts#L334-L347)
  says its proxy already enables usage. The explicit option is compatibility
  hardening, not proof that a missing option caused past Copilot omissions.
  An interrupted stream can still end before the final usage chunk arrives.
- A completion event can repeat the generated output before its usage object.
  The parser now accepts the same 8M-character frame budget as the Responses
  normalizer, rather than silently discarding events above 256 KiB. Exceeding
  that bounded budget is diagnosed, not changed into zero usage.
- Supported aliases include Responses/Chat usage, sibling envelope usage,
  cache-read fields and exact `total_tokens` arithmetic when one side is absent.
  Native Anthropic cache reads/writes are included in total input; OpenAI cached
  input is not added twice.
- Cancellation after a protocol completion is not a failed request. Counters
  observed before an interrupted stream ends are retained as partial, not
  presented as complete token coverage.
  Initial/placeholder usage is not promoted to a complete report merely because
  a stop marker arrives; the protocol's final usage must actually be observed.
  A failed or length-limited generation can still report exact final token usage:
  request outcome and token-report completeness are tracked independently.

The detail panel shows token and credit coverage separately, such as
**Tokens: 3/4 requests · Credits: 2/4**. A partial sum is labeled
**reported credits used**. When every charge
is missing, it says **Credits unreported**. It does not estimate the missing part.
Logs explain missing token usage using bounded, predefined reasons (unreported,
partial, interrupted, parser limit or invalid JSON), never response content.

### CC Switch reference

We reviewed CC Switch's
[proxy usage parser](https://github.com/farion1231/cc-switch/blob/f3b18df12007d0fd79fd8ad8d310880664015197/src-tauri/src/proxy/usage/parser.rs),
[streaming conversion](https://github.com/farion1231/cc-switch/blob/f3b18df12007d0fd79fd8ad8d310880664015197/src-tauri/src/proxy/providers/streaming.rs)
and [Codex session usage importer](https://github.com/farion1231/cc-switch/blob/f3b18df12007d0fd79fd8ad8d310880664015197/src-tauri/src/services/session_usage_codex.rs).
These are design references, not copied or bundled source.

CC Switch also reads exact token counters from client session logs and handles
cross-source/replayed snapshots. This app does not add client-session totals to
upstream attempt totals: without reliable cross-source request identities that
would double count some requests and misattribute retries. No session content is
scanned, and no tokenizer/character estimate is substituted for reported usage.
Standalone CLI requests are not recorded by this app's private supervisor
channel. Previously discarded counters cannot be reconstructed from aggregates.

## Account balance is separate

The balance card queries the bridge's `/usage` endpoint for GitHub's account-wide
remaining quota. Other clients can affect this balance. It is never used as the
source of a day's request costs, and no balance-difference calculation is made.

The primary amount is **credits used**, on the left; the **remaining percentage**
is on the right. Hover the percentage to see the exact remaining amount.
If only an amount is known but no limit/percentage is provided, the percentage
stays unknown rather than being invented. The bar has a gray used segment on the left and a green remaining
segment on the right. It uses the provider's percentage when available, otherwise
a valid remaining-to-limit ratio. Rounded percentages do not overwrite amounts.
GitHub's `credits_used` is preferred. For a limited quota without reported usage,
limit minus remaining is shown as **derived**; absent or inconsistent values stay
unknown. Unlimited quota does not imply zero consumption and has no percentage bar.
**Refresh usage** fetches quota only. Device authorization is separate in Settings.

The last successful quota observation is cached with its original timestamp.
A failed refresh does not make the old balance look newly updated. Legacy quotas
measured in premium interactions or chat requests retain those units.

## Storage and compatibility

The existing `totals` table gains `nano_aiu` and `credit_reports` columns through
an additive, transactional migration. Missing billing is tracked independently
as `requests - credit_reports`. Historical token rows remain intact, with zero
billing reports: their old costs are unknown, not free.

Old events without `nanoAiu` remain readable. Existing `quota_history` data stays
available for balance caching; it is not converted into request charges. Daily
aggregates retain 730 days and deduplication IDs retain two days.

The interface refreshes when usage totals change or the local day rolls over.
Hovering never queries the database or contacts GitHub. Prompts, response text
and account credentials are not stored in the usage database.
