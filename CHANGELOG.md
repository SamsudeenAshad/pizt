# Changelog

All notable changes to pizt are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A PowerShell module manifest and wrapper for versioned `Import-Module` use.
- Pester regression coverage for parsing, request construction, safety gates,
  execution failures, cancellation, and native exit-code handling.
- Windows PowerShell 5.1 and PowerShell 7 CI coverage with static analysis.
- `task.md` and `subtask.md` production-readiness tracking.

### Changed

- Streaming now displays bounded progress without exposing raw model reasoning
  or unvalidated response text.
- API keys are read when each command is invoked.
- ANSI styling is limited to interactive hosts that advertise support.
- `cmd.exe` execution disables AutoRun entries with `/d`.
- Direct script execution now returns meaningful failure status codes.

### Fixed

- Malformed model output can no longer fall through to command execution.
- Streaming HTTP resources are disposed on success and failure.
- PowerShell-targeted native process failures now propagate their exit status.
- Pure PowerShell commands preserve the caller's prior `LASTEXITCODE`.
- Shell validation is consistent between script and function entry points.

### Security

- Multiline, oversized, and control-character-bearing model responses are
  rejected before clipboard or execution handling.
- Raw API error text is sanitized before terminal display.

[Unreleased]: https://github.com/SamsudeenAshad/pizt/compare/v0.1.0...HEAD
