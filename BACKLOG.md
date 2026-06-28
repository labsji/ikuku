# BACKLOG.md — Kiro Web Automation Queue

Items for the autonomous agent to implement on schedule.
Pick top unchecked item, implement per SPEC.md conventions, open PR, mark done.

## bind repo

### Priority 1 (next cycle)

- [ ] SPEC-008: Ollama model selection — `bind_llm.model` config should be passed to Ollama API. Currently hardcoded to llama3.2 in prompt but not in actual API call params.
- [ ] SPEC-009: List command output — `list items` should return formatted output (name, group) not raw Python repr. Currently returns empty string on success.
- [ ] SPEC-010: Count command output — `count items` should return the number as summary text ("17 items") not just the raw number in output field.

### Priority 2

- [ ] SPEC-011: Error messages for invalid DocType — when user types `create foobar`, return helpful error ("Unknown DocType: foobar. Available: Customer, Item, ...") instead of generic parse failure.
- [ ] SPEC-012: Multi-command input — support multiple DSL commands separated by newlines in a single agent input. Parse each, show all cards, Apply executes sequentially.
- [ ] SPEC-013: Export command — `export company <name>` as a DSL verb that calls `bind.api.export_company` and returns seed.repl content.

### Priority 3

- [ ] Add test: `test_spec009_list_output` — verify list returns formatted text
- [ ] Add test: `test_spec010_count_output` — verify count returns "N items"
- [ ] Add test: `test_spec011_invalid_doctype` — verify helpful error message
- [ ] README: add "Supported DocTypes" section with the full list
- [ ] README: add "Configuration" section explaining `bind_llm` options

## ikuku repo

### Priority 1

- [ ] SPEC-I08: Offline detection — if no internet on first boot, skip gitea user creation and auth registration gracefully. Show message: "Offline mode — some features unavailable."
- [ ] SPEC-I09: Progress indicator — during first boot (bench init takes 10-15 min), show periodic status updates to stdout so user knows it's not hung.
- [ ] SPEC-I10: ERPNext default apps — only install erpnext (not wiki, lms). The `IKUKU_APPS` env in docker-compose.yml still says `wiki,lms,erpnext`.

### Priority 2

- [ ] SPEC-I11: Unattended install — support `ikuku-lite.exe /S` silent mode end-to-end (no user interaction required).
- [ ] SPEC-I12: Health check after boot — `init.sh` should verify ERPNext responds before printing "ready" message.
- [ ] Fix: docker-compose `IKUKU_APPS` env should match init.sh default (erpnext only).

### Priority 3

- [ ] README: troubleshooting section (common issues: port in use, WSL not found, podman error)
- [ ] README: "What's included" diagram (MariaDB + Redis + Frappe + ERPNext + bind + Gitea)
- [ ] Add `.github/ISSUE_TEMPLATE/bug_report.yml` for structured bug reports

---

## Rules for the automation agent

1. Pick ONE item per run
2. Create a feature branch: `auto/<spec-number>` or `auto/<short-description>`
3. Implement following SPEC.md style (add SPEC comment in code, add test if testable)
4. Run `PYTHONPATH=. python3 bind/dsl/test_parser.py` — all tests must pass
5. Open PR with title: `[SPEC-NNN] description` or `[fix] description`
6. Mark the item `[x]` in the PR's changes to BACKLOG.md
7. Do NOT merge — human reviews and merges
