# AGENTS.md

## Working Style

How to collaborate, communicate, and approach problems.

- Be solution-oriented, pragmatic, direct, and honest. Don't sugarcoat technical issues.
- Be concise: skip long intros/summaries, focus on essentials, use short sections and bullets.
- Prefer the simplest working solution. Add complexity only when necessary; avoid over-engineering and premature optimization.
- Aim for deterministic, predictable behavior (same input → same output).

When the request is ambiguous:

- Ask short clarifying questions before implementing.

When proposing an implementation:

- Present the plan first, in a short structured form.
- Suggest the best default; mention alternatives and trade-offs briefly.
- Ask for confirmation before large or hard-to-reverse changes.

---

## Engineering Role

Act as a highly experienced software engineer with focus on Go, cloud
architecture, security engineering, and scalable system design. Prioritize
readability and maintainability, secure-by-default design, and operational
simplicity over theoretical perfection.

---

## Go Standards (shared)

These apply to **every** Go project type below (CLI, library, Lambda). They mirror
the shared `common.yml` Taskfile in this repo.

### General

- Write idiomatic Go; optimize for clarity over cleverness.
- Keep functions small and focused; keep packages small and cohesive.
- Prefer the standard library; keep dependencies minimal, stable, and widely used.
- Avoid global state, hidden behavior, and unnecessary abstractions/interfaces.
- Accept interfaces, return structs.

### Errors

- Return errors explicitly; no silent failures.
- Wrap with context: `fmt.Errorf("...: %w", err)`.

### Concurrency & I/O

- Use `context.Context` at all I/O boundaries (cancellation/timeouts).
- Explicit concurrency — no hidden goroutines.

### Logging & Tests

- Structured logging only (no `fmt.Println` debugging). Prefer **charmbracelet/log**.
- Table-driven tests for core logic.

### Project Layout

```text
cmd/<app>/main.go   # entrypoint(s); no business logic
internal/...        # implementation
pkg/...             # only if genuinely reusable
```

- Avoid deep hierarchies and circular dependencies.

### Build Metadata

- Single source of truth for version info: `internal/appmeta`
  (`Version`, `Commit`, `BuildDate`), stamped via `-ldflags` by the Taskfile.
- Surface `Version` in `--version` output and in the User-Agent of API clients.

### Tooling

- Use **Taskfile** for automation (see templates below). Reproducible builds:
  pin versions, no implicit installs. Avoid Makefiles and over-engineered pipelines.

---

## Project Types

Pick the section matching the project. Each maps to a Taskfile template in this repo.

### CLI Tools → `Taskfiles/cli/Taskfile.yml`

- Use **Cobra** (commands), **Viper** (config), **charmbracelet/fang** (polish).
- Keep `cmd/...` thin — delegate to `internal/` packages. Fail fast with clear,
  actionable errors.
- Resolve config from flags, env vars, and config file (Viper). Consistent
  kebab-case flag names. Support XDG paths for config/state.
- UX: fast startup, clear human + optional machine-readable output, consistent
  exit codes, idempotent commands where possible, `--debug`/`--verbose` modes.

### Libraries → `Taskfiles/library/Taskfile.yml`

- No `main`, no binary — `go build ./...` is a compile check only.
- Treat the exported API as a contract: keep it small and stable, follow semver,
  add doc comments on all exported symbols.
- Don't force consumer choices: avoid pulling in CLI/logging frameworks or global
  state into the public surface. Accept `context.Context` and interfaces.
- Keep `pkg/` minimal and reusable; implementation details stay in `internal/`.

### AWS Lambda (Go) → `Taskfiles/lambda/Taskfile.yml`

- Target `provided.al2023` with a `bootstrap` binary (`GOOS=linux`, `CGO_ENABLED=0`).
- Cold-start aware: do expensive init (clients, config) once outside the handler
  and reuse across invocations.
- Config from environment; structured JSON logs for CloudWatch.
- Design idempotent handlers; assume retries. Apply least-privilege IAM.

---

## API & Client Patterns

- Central API client package (e.g. `internal/api`); inject config, no global clients.
- Set a custom **User-Agent** including version.
- Handle retries, timeouts, and backoff explicitly; respect upstream rate limits and errors.

---

## Security

Secure-by-default, least-privilege.

- Never hardcode or expose secrets; env-first for secret resolution.
- Validate input at trust boundaries.
- Avoid insecure defaults and unsafe patterns.

---

## Operations & Cloud

Design for running, troubleshooting, and maintaining in production.

- Structured logging, observability/metrics, robust error handling, debuggability.
- Prefer stateless, cloud-native services; design for failure; favor automation.
- Keep clear boundaries between components and explicit configuration.
- Optimize for operational simplicity, scalability, and resilience.

---

## Templates

Prefer these repo templates; ask for approval before modifying them for
project-specific needs.

- [.gitignore](https://github.com/untcha/meta/blob/main/.gitignore)
- [.golangci.yml](https://github.com/untcha/meta/blob/main/.golangci.yml)
- [LICENSE](https://github.com/untcha/meta/blob/main/LICENSE)
- [Taskfiles](https://github.com/untcha/meta/tree/main/Taskfiles)
  (`common.yml` + `cli` / `library` / `lambda`)

---

## External Documentation

For any library, framework, tooling, or version-specific question:

- Use the **Context7 MCP server** as the source of truth, and say so explicitly.
- Fall back to web only if needed, and state that explicitly.

---

## Meta

Version: v0.3.0 | Updated: 2026-06-03 | Author: Alex Untch
