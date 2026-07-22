# Production-readiness subtasks

## P0 — execution safety

- [x] Remove the permissive first-line parser fallback.
- [x] Require exactly one `CMD` line and one non-empty `WHY` line.
- [x] Reject multiline commands, oversized commands, and control characters.
- [x] Stop printing raw streamed reasoning and response content.
- [x] Keep confirmation enabled by default and preserve explicit dry-run mode.

## P1 — runtime reliability

- [x] Read `PIZT_API_KEY` at invocation time.
- [x] Validate `-Shell` in both the script and function entry points.
- [x] Enforce a bounded user-prompt size.
- [x] Enable TLS 1.2 for Windows PowerShell 5.1 blocking requests.
- [x] Dispose HTTP request, response, stream, reader, and client objects.
- [x] Avoid retrying blocking mode after a definitive HTTP streaming error.
- [x] Disable `cmd.exe` AutoRun processing with `/d`.
- [x] Report non-zero status for input, request, parse, and execution failures.
- [x] Avoid ANSI output where the PowerShell host does not advertise support.

## P1 — verification

- [x] Add Pester regression tests for strict parsing and request JSON.
- [x] Add orchestration tests proving invalid responses are never executed.
- [x] Run the suite in PowerShell 7 locally.
- [x] Add CI for Windows PowerShell 5.1 and PowerShell 7.
- [x] Run static analysis and inspect the final diff.

## P2 — release documentation

- [x] Remove the incorrect README claim about a baked-in fallback key.
- [x] Document strict response validation and progress-only streaming.
- [x] Document exit behavior and development/test commands.
- [x] Reconcile this checklist and `task.md` with the verified result.

## Verification snapshot

- Pester 5.7.1 on PowerShell 7: 22 passed, 0 failed.
- PSScriptAnalyzer: 0 errors.
- PowerShell 5.1 compatible-syntax analysis: 0 findings.
- Direct script without required configuration: exit status 2.
- Redirected output: no ANSI control sequences.
- Workflow YAML: parsed successfully.

## Deferred beyond v0.2

- Package/sign the script for PowerShell Gallery distribution.
- Add configurable providers/models behind a stable configuration contract.
- Add an optional policy engine for organization-specific command restrictions.
