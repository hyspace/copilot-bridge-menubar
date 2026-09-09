# Activity and quota observations

## Presentation

The view follows the familiar contribution-calendar pattern: seven weekday rows,
week columns, month labels and four green intensity levels. We evaluated
[SwiftHeatmapKit](https://github.com/rouzbeh-abadi/SwiftHeatmapKit/tree/ce9be2441c54904c17397bd1f166acf015007189)
as a reference. This app uses its own small SwiftUI component because each day needs
token details, credit observations, missing-data states and hover/focus behavior.
No library source is bundled or added as a dependency.

The grid displays 26 complete calendar weeks, with future dates left empty.
Dates use the local Gregorian calendar and calendar-day arithmetic, including
daylight-saving transitions. Labels are English.

Color is based on recorded input plus output tokens, relative to the largest
daily total in the visible range. Cached tokens are a subset of input.
Missing token usage remains visible in the tooltip and as a dashed tile border.
The detail panel responds to hover, click and keyboard focus. Every tile has
a complete accessibility label and a native tooltip.

## Two independent data sources

**Tokens:** metadata emitted by requests handled by the app's owned backend.
Multiple models are aggregated for each day. No prompt or response content is stored.

**Credits:** the actual GitHub quota response obtained through the owned bridge's
`/usage` endpoint. The app stores the last successful observation per local day:
remaining balance, entitlement, billing-cycle usage when returned, units, reset
information and observation time.

A credit observation is an **account-wide balance at a particular time**, not a
per-request charge or a daily spending total. Other clients can change it. No
token-to-credit conversion or interpolation is performed. Quotas expressed as
premium interactions or chat requests retain those units.

On a failed refresh, the previous balance and its original observation time remain.
Failed requests are throttled separately from successful observation timestamps.
Days before observation collection began show **Credits: not recorded**.

## Storage and compatibility

`quota_history` is an additive SQLite table. Existing `totals` and `seen` records
are left intact. Token aggregates and quota history retain 730 days; one snapshot
per day bounds quota storage. Out-of-order observations cannot overwrite a newer
snapshot for the same day.

The interface re-queries the grid when token totals change, a quota observation
is saved, or the local day rolls over. Hovering never queries the database or
contacts GitHub.
