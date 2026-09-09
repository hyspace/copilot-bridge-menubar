# Contributing

Use a fork and a pull request. Keep UI, pure core logic, and backend observation
separate. Add a regression test for every lifecycle, accounting or parser fix.
Run the commands in README before opening a PR.

- Never include real credentials, prompts, device codes, personal quota snapshots or local logs.
- Never kill a development machine's existing bridge. Tests use random non-4142 ports and temporary HOME.
- Keep the upstream submodule pinned. Commit general bridge fixes to the CLI fork, test them there, then update the submodule reference.
- Support Codex App only. Do not add arbitrary shell execution, raw token logging or public-LAN defaults.
- Never rewrite Codex config on launch, service start, quit or upgrade. Only the explicit routing switch may change it, through the verified transaction manager.
- Use small commits and describe user-visible behavior, failure handling and testing.
- New external actions must be pinned; dependency updates go through normal review.

Please keep discussion respectful and technical. Harassment, threats and disclosure
of others' private information are not acceptable.
