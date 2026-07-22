# pizt production-readiness task

## Objective

Prepare the `pizt` PowerShell command agent for a reliable v0.2 release without
changing its core workflow: generate one Windows command, show it, require
confirmation by default, and then execute it.

## Scope

- Audit the current implementation, documentation, and external API contract.
- Prevent malformed or unsafe model responses from reaching command execution.
- Make HTTP, configuration, terminal output, and exit behavior predictable.
- Add repeatable tests for Windows PowerShell 5.1 and PowerShell 7.
- Add continuous integration and accurate contributor documentation.

## Acceptance criteria

- [x] Only an exact, validated `CMD`/`WHY` response can become executable.
- [x] Raw streamed model text and control characters cannot alter the terminal.
- [x] `PIZT_API_KEY` is read when a command is invoked, not only at load time.
- [x] Streaming request objects are disposed on success and failure.
- [x] Invalid input, API failures, and command failures produce useful errors.
- [x] Direct script use returns a non-zero exit code after an actual error.
- [x] `powershell` and `cmd` are validated consistently in every entry path.
- [x] Automated tests cover response parsing, request construction, and the
      no-execution safety paths.
- [x] CI is configured to run on Windows PowerShell 5.1 and PowerShell 7.
- [x] README setup, behavior, safety, and development instructions match code.

## Audit summary

The v0.1 implementation has a clear confirmation-first design, but its fallback
parser accepts the first non-empty line of any malformed model response. That is
the highest-risk defect because unvalidated text can become executable. Other
release blockers are stale API-key state after dot-sourcing, inconsistent shell
parameter validation, incomplete HTTP disposal, raw reasoning/output streaming,
ANSI assumptions on Windows PowerShell 5.1, weak process exit signaling, and the
absence of tests or CI. The README also refers to a fallback API key that does
not exist in the source.

## Current status

Implementation is complete and locally verified. All 29 Pester tests pass in
PowerShell 7, static analysis reports zero errors and zero PowerShell 5.1 syntax
compatibility findings, direct-script failure status was verified, and the CI
workflow YAML parses successfully. The actual Windows CI matrix will run after
these changes are pushed. Detailed work is tracked in `subtask.md`.

## Continuation acceptance criteria

- [x] PowerShell-targeted native commands propagate their final exit status.
- [x] Pure PowerShell commands preserve the caller's existing `LASTEXITCODE`.
- [x] A valid v0.2 module manifest supports `Import-Module` on PowerShell 5.1+.
- [x] Module imports export only `Invoke-Pizt` and the `pizt` alias.
- [x] Module import performs no API request or other external side effect.
- [x] Release changes and module usage are documented.
