# Coding Standards

This document defines the conventions used across this project.  The
audience for the codebase is university students who may be reading
Ansible, bash, and 5G configuration for the first time, so clarity and
consistency are prioritised over brevity.

All contributors (human or AI-assisted) should follow these conventions
to keep the codebase approachable and uniform.

---

## General Principles

1. **Write for the reader, not the author.**  Assume the person reading
   the code is a CS/EE undergraduate encountering the 5G stack, Linux
   system administration, and Ansible for the first time.  When in
   doubt, over-explain rather than under-explain.

2. **Be consistent.**  Every file of the same type should follow the
   same structural template.  A student who learns to read one health-
   check script should be able to read all of them without adjusting to
   a different style.

3. **Keep technical debt visible.**  Use `# TODO:`, `# FIXME:`, or
   `# HACK:` comments when something is a known workaround or needs
   future attention.  Do not leave these unresolved on the `master`
   branch — resolve or document them before merging.

4. **Document the why, not just the what.**  Task names and function
   names describe *what* happens.  Comments should explain *why* it
   happens — what breaks without this step, what upstream behaviour
   it works around, or what 3GPP requirement it satisfies.

5. **Cite sources.**  When a comment references an external document,
   include a link or a bracketed reference (e.g. `[1]`) with the URL
   on a nearby line.  This lets students trace the rationale back to
   the original specification or forum post.

---

## Bash Scripts

### File header

Every script begins with:

```bash
#!/usr/bin/env bash
# script_name — One-line description of what the script does
#
# Multi-line explanation of purpose, context, and any non-obvious
# behaviour.
#
# Exit codes:
#   0 — success
#   1 — one or more checks failed
#
# Environment variables (optional):
#   VAR_NAME  — description (default: value)
```

### Strict mode

All scripts use:

```bash
set -euo pipefail
```

Exception: test scripts that need to capture a non-zero exit code may
omit `-e` (use `set -uo pipefail` instead) and handle errors
explicitly.

### Section dividers

Separate logical sections with a horizontal rule comment and a numbered
heading:

```bash
# ---------------------------------------------------------------------------
# 1. Section name
# ---------------------------------------------------------------------------
```

The divider is exactly 75 characters (the `#` plus a space plus 73
dashes).  Section numbers help students refer to specific parts of the
script in discussion ("the check in section 4 is failing").

### Helper functions

Health-check scripts share a common set of output helpers:

```bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0; FAIL=0; WARN=0

pass()  { printf "  ${GREEN}✓${RESET} %s\n" "$1"; (( ++PASS )); }
fail()  { printf "  ${RED}✗${RESET} %s\n" "$1";   (( ++FAIL )); }
warn()  { printf "  ${YELLOW}!${RESET} %s\n" "$1"; (( ++WARN )); }
header(){ printf "\n${BOLD}── %s${RESET}\n" "$1"; }
```

All health-check scripts (`check_status.sh`, test scripts) must use
these helpers so their output is visually consistent.

### Variable naming

- Use `UPPER_SNAKE_CASE` for environment-configurable variables and
  constants.
- Use `lower_snake_case` for local variables within functions.
- Prefer descriptive names (`container_state`, `amf_addr`) over
  abbreviations (`cst`, `addr`).  The reader should understand the
  variable without hunting for its assignment.

### Error messages

Error messages should be **actionable**.  Tell the student what failed,
what the expected state was, and (when possible) what to do about it:

```bash
# Good:
fail "AMF host $amf_addr: unreachable — is the core Pi powered on?"

# Bad:
fail "ping failed"
```

### Inline comments

Comment every non-obvious block.  For this project, "non-obvious" is
defined from the perspective of an undergraduate, not an experienced
sysadmin.  Prefer a brief comment explaining *why* over no comment
at all:

```bash
# UPF has no SBI interface — skip the TCP 7777 check
if [[ "$nf" == "UPF" ]]; then
  continue
fi
```

---

## Ansible Playbooks

### Play and task names

- **Play names** use the format `"Component | Action"`:
  `"Pi Setup | Harden for headless server use"`.
- **Task names** should be self-documenting — they appear in
  `ansible-playbook` terminal output, so the student sees them scroll
  by during a run.  Include enough detail that the student can
  understand what is happening without reading the YAML:

```yaml
# Good:
- name: "Deploy cpupower-governor systemd oneshot service"

# Bad:
- name: "Copy service file"
```

- When a task wraps a non-obvious command, include the command or key
  argument in parentheses:
  `"Disable VNC (raspi-config nonint do_vnc 1)"`.

### Inline comments

Add comments in these situations:

1. **Before a group of related tasks** — explain the purpose of the
   group and link to relevant docs.
2. **On non-obvious `when:` conditions** — explain what the condition
   means in plain English.
3. **On magic values** — explain what `33554432` means (`# 32 MB`),
   what `38412` is (`# NGAP`), etc.
4. **On workarounds** — explain what upstream behaviour you are
   compensating for.

Use bracketed references (`[1]`, `[2]`) with a URL on the next line
when citing Raspberry Pi docs, Ansible docs, or forum posts that
informed the task's design:

```yaml
    # raspi-config nonint convention: 0 = enable, 1 = disable
    # [1](https://www.raspberrypi.org/documentation/usage/)
```

### YAML formatting

- Two-space indentation (Ansible default).
- Quote all string values in task parameters (`mode: "0644"`, not
  `mode: 0644`).
- One blank line between tasks.
- Use `ansible.builtin.` fully-qualified collection names for all
  built-in modules.
- All `when:` conditions on the line immediately following the task
  body (not inline).

### Variables

- Variable names use `lower_snake_case` with a component prefix:
  `srsran_cpu_governor`, `open5gs_mcc`, `pi_monitor_interval`.
- Every variable defined in `group_vars/` should have an inline comment
  on the same line explaining its purpose and default.
- Boolean variables are tested with `| bool` in `when:` conditions to
  handle string-to-boolean coercion.

### Handlers

- Handlers go at the bottom of the play, after all tasks.
- Handler names describe the action: `reload systemd`, `restart rsyslog`.

### Systemd units and config files

When a playbook deploys a systemd unit or config file inline (via
`content: |`), include comments inside the deployed file explaining
each non-obvious directive.  These comments end up on the target
system where the student may read them with `cat` or `systemctl cat`.

---

## Markdown Documentation

### Audience

All documentation is written for a university-level student with basic
Linux command-line experience but no prior exposure to 5G, Ansible, or
RF engineering.  Explain domain-specific terms on first use or link to
[`GLOSSARY.md`](GLOSSARY.md).

### Structure

Each top-level doc follows this pattern where applicable:

1. **Title** (`# Heading`) — one-line summary.
2. **Introductory paragraph** — what this document covers and why the
   reader needs it.
3. **Body sections** — organised by topic, using `##` and `###`
   headings.
4. **See also** — cross-references to related docs at the bottom.

### Tables

Use tables for structured reference data: port numbers, variable
defaults, log file paths, command summaries.  Tables are easier to
scan than prose when a student is looking up a specific value.

Format: use `|---|` separator rows (no padding alignment — let the
renderer handle column width).

### Code blocks

Always specify the language for fenced code blocks (` ```bash `,
` ```yaml `, etc.) so syntax highlighting works on GitHub and in
editors.

### Cross-references

Link to other project docs with relative paths:
`[GLOSSARY.md](GLOSSARY.md)`, `[srsran/README.md](srsran/README.md)`.
Include a brief description of what the linked doc covers so the
student can decide whether to follow the link.

### Glossary policy

Any technical term that a CS/EE undergraduate might not know should
be defined in [`GLOSSARY.md`](GLOSSARY.md).  Terms are grouped by
topic (5G architecture, protocols, RF, networking/Linux, Ansible) and
sorted alphabetically within each group.

---

## Git Conventions

### Branching

- All work happens on feature branches named `feature/<short-description>`.
- Feature branches are based on `master` and merged via pull request.
- One logical change per branch.

### Commit messages

Follow this format:

```
<imperative summary of the change>

Optional body explaining motivation, trade-offs, or context.
Wrap at 72 characters.
```

- **First line:** imperative mood ("Fix", "Add", "Remove"), max 72
  characters, no trailing period.
- **Body (optional):** explain *why*, not *what* (the diff shows what).
- Reference issue numbers if applicable.

### What to commit

- Do not commit secrets, keys, or credentials.
- Do not commit editor config (`.vscode/`, `.idea/`).
- Resolve all `TODO`/`FIXME` items before merging to `master`, or
  convert them to tracked issues.

---

## See also

- [`GLOSSARY.md`](GLOSSARY.md) — term definitions referenced from docs
  and comments
- [`LOGGING.md`](LOGGING.md) — log file conventions and timestamp
  reference
