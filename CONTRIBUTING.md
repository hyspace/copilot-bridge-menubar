# Contributing

Use a fork and a pull request. Keep UI, pure core logic, and backend observation
separate. Add a regression test for every lifecycle, accounting or parser fix.
Run the commands in README before opening a PR.

- Never include real credentials, prompts, device codes, personal quota snapshots or local logs.
- Never kill a development machine's existing bridge. Tests use random non-4142 ports and temporary HOME.
- Keep the upstream submodule pinned. Commit general bridge fixes to the CLI fork, test them there, then update the submodule reference.
- Do not add arbitrary shell execution, auto config rewriting, raw token logging or public-LAN defaults.
- Use small commits and describe user-visible behavior, failure handling and testing.
- New external actions must be pinned; dependency updates go through normal review.

Please keep discussion respectful and technical. Harassment, threats and disclosure
of others' private information are not acceptable.
