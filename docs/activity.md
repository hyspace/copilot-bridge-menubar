# Multi-source activity and quota data

## One token calendar

The 26-week contribution-style grid uses local Gregorian dates, including DST
transitions. Color represents **reported input + output** tokens, summed across
Codex, Copilot and Local. Cached tokens already belong to input and are not added
again. The day panel has a stable layout: date/total, then one row per source.
Missing counters say unreported/partial; a dashed tile concerns token coverage,
not unrelated billing data.

The whole grid rectangle participates in hover hit-testing. Horizontal/vertical
gutters map to the nearest valid day, retaining the original visual gaps. Hover,
click and keyboard focus do not issue database or network requests. Future dates
remain empty/non-interactive. The visual pattern was informed by SwiftHeatmapKit;
no third-party heatmap source is bundled.

## Account quotas are not request costs

Overview has three compact source rows, each expandable:

- **Codex:** account-wide primary/secondary quota windows, remaining percentages,
  reset times and additional credit balance when returned. A masked account identity
  scopes the cache; one account's quota is not shown for a newly connected account.
- **Copilot:** actual returned credit or premium-interaction units. Expanded detail
  retains used amount on the left, remaining percentage on the right, and a
  gray-used / green-remaining bar. A derived used amount is labelled derived.
- **Local:** loaded model/status/context/capability information, not a fabricated
  subscription balance.

The refresh icon reads status/quotas; it is not logout or account replacement.
Last-successful values keep their original timestamps. A stopped/offline service
is not presented as newly connected. Account quotas include other clients; the
heatmap includes only attempts observed through this Bridge. No combined credit
number or token-to-dollar estimate is created.

## Request observations

The private event channel records provider, attempt ID, start time, model, HTTP
status, outcome, input/output/cached counters and completeness. Each actual
upstream attempt—including Copilot retries and local hosted-search model calls—has
its own ID. Deduplication is by `(provider, id)`, not by model name or user turn.
Repeated/cumulative usage frames replace counters rather than being added again.

The observer supports Responses/Chat usage, sibling envelopes, final Chat usage
chunks, native cache counters and exact `total_tokens` arithmetic when one side
is absent. Native Anthropic cache reads/writes are included in input; OpenAI cache
is not double counted. No tokenizer/character estimate or client-session-log import
is added to upstream totals. CC Switch's usage/parser work was a design reference,
not copied source; blindly adding session totals would double-count some requests.

A final token report must actually be observed. Interrupted/oversized/invalid
streams remain partial or unknown, with predefined diagnostics instead of model
text in logs. Cancellation after a terminal event is not an interrupted request.
Model failure and token-report completeness are separate properties.

Copilot request charges continue to use its server field:

```text
usage.copilot_usage.total_nano_aiu
credits = total_nano_aiu / 1_000_000_000
```

These counters are stored as Copilot billing only. Codex/Local extensions with a
similar name cannot become Copilot credit usage. Explicit zero means known zero;
missing billing remains unknown. Request charges are not inferred from changes
in account quota, and are no longer mixed into all-source heatmap details.

## Migration and recovery

Older events without a provider are Copilot events. Invalid provider names are
rejected. Existing token/billing rows and dedup IDs are migrated transactionally to
`totals(day, provider, model)` and `seen(provider, id)`. Existing quota history
remains intact; new per-source quota snapshots have their own table.

Before the provider migration, a SQLite backup includes committed WAL contents.
The writer lock stays held while a separate reader snapshots the pre-migration
state, so another writer cannot change it between backup and table migration.
The backup is private, integrity/schema-checked and synced before the transaction
commits. The old `copilot_totals_legacy` and `copilot_seen_legacy` tables remain.

The first backup is `usage.sqlite.before-providers-v2.sqlite`. A pre-existing
backup is verified, never blindly overwritten. If a previous attempt stopped
before migration, a new immutable `before-providers-v2.retry-<id>.sqlite` snapshots
the **current** retry state. `schema_migrations.backup_file` records which backup
was used. Corrupt/unsafe backups fail closed, leaving the old data intact for review.

Active daily aggregates/quotas retain 730 days and dedup IDs retain two days.
**Migration backups and retained legacy tables are not automatically pruned.**
They exist for rollback and may retain older aggregates. An old app binary is not
expected to understand the new schema: quit all owners and restore a verified
pre-migration snapshot before deliberate downgrade. Do not copy/replace a live
SQLite database without accounting for its WAL.

No prompt, response text, screenshot or account credential is stored in these
tables. Local acceptance reports and production histories must not be committed
or uploaded with the source.
