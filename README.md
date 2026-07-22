# pizt

An AI terminal-command agent for **Windows PowerShell** and **cmd**.

Describe what you want in plain English — pizt asks an LLM for the exact
command, shows it with a one-line explanation, and (after you confirm) runs it.

```
PS> pizt list every pdf modified in the last week

  [powershell]  Get-ChildItem -Filter *.pdf -Recurse | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) }
  # Finds all PDF files changed within the last 7 days.

Run this? [y/N]:
```

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+ (`pwsh`).
- An API key for the NVIDIA-hosted endpoint (OpenAI-compatible), model `z-ai/glm-5.2`.

## Setup

Create an API key in the [NVIDIA API catalog](https://build.nvidia.com/z-ai/glm-5.2)
and set it in `PIZT_API_KEY`. No key is included in this repository.

```powershell
$env:PIZT_API_KEY = 'nvapi-...'      # for this session
setx PIZT_API_KEY "nvapi-..."        # persist for future sessions
```

Load pizt into your session by dot-sourcing it:

```powershell
. .\pizt.ps1
```

To have it available in every terminal, add that line to your profile
(`notepad $PROFILE`).

## Usage

```powershell
pizt <what you want to do>
```

| Option        | Description                                                     |
|---------------|-----------------------------------------------------------------|
| `-Shell cmd`  | Target and run in **cmd.exe** instead of PowerShell.            |
| `-Edit`       | Open the command for editing before the run/confirm step.       |
| `-DryRun`     | Print the command but never run it.                             |
| `-Yes`        | Skip the confirmation prompt and run immediately.               |
| `-NoStream`   | Use one blocking request instead of a streaming request.        |

The generated command is **copied to your clipboard** automatically. At the
confirm prompt you can also press **`e`** to edit the command inline before
running it.

### Examples

```powershell
pizt show my ip configuration
pizt -Shell cmd list running services
pizt -Edit kill the process listening on port 3000
pizt -DryRun show disk usage
pizt -Yes create a folder called build
```

You can also run it without loading it first:

```powershell
.\pizt.ps1 -Shell cmd show disk usage
```

## How it works

pizt sends your request plus a shell-specific system prompt to the model, which
replies in a strict two-line format:

```
CMD: <the command>
WHY: <one-line explanation>
```

pizt uses NVIDIA's OpenAI-compatible chat-completions endpoint. During a
streaming request it shows a bounded progress indicator, but it does not print
raw reasoning or response content. The completed response must match the exact
two-line format; malformed, multiline, oversized, or control-character-bearing
responses are refused rather than treated as commands.

After validation, pizt copies the command to the clipboard and — unless
`-DryRun` — asks for confirmation (or lets you edit it) before executing it in
the chosen shell (`Invoke-Expression` for PowerShell, `cmd /d /c` for cmd).

## Notes & safety

- **Always read the command before confirming.** The model can be wrong, and
  `-Yes` runs whatever it produces with no review.
- API, parsing, and execution failures return a non-zero status when
  `pizt.ps1` is run directly. Declining a command is a successful cancellation.
- The model is a slow reasoner; a single request can take 60–90 seconds.
- Commands are generated for **Windows**. Running under `pwsh` on macOS/Linux
  will still target Windows syntax.

## Development

The regression suite uses Pester 5:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Invoke-Pester -Path .\tests -Output Detailed
```

CI runs the same suite on Windows PowerShell 5.1 and PowerShell 7 and performs
PowerShell static analysis. The release checklist and audit are in
[`task.md`](task.md) and [`subtask.md`](subtask.md).
