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

The detail panel shows billing coverage, such as **Billing reported for 3 of 4
requests**. A partial sum is labeled **reported credits used**. When every charge
is missing, it says **Credits unreported**. It does not estimate the missing part.

## Account balance is separate

The balance card queries the bridge's `/usage` endpoint for GitHub's account-wide
remaining quota. Other clients can affect this balance. It is never used as the
source of a day's request costs, and no balance-difference calculation is made.

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
