#Requires -Version 5.1

<#
.SYNOPSIS
    pizt - an AI terminal command agent for Windows PowerShell and cmd.

.DESCRIPTION
    Describe what you want in plain English; pizt asks an LLM for the exact
    command, streams a progress indicator, shows the command with a one-line
    explanation, copies it to the clipboard, and (after you confirm or edit)
    runs it in PowerShell or cmd.

.PARAMETER Prompt
    The natural-language request, e.g. "delete all .tmp files in this folder".
    Everything you type after the command is treated as the prompt.

.PARAMETER Shell
    Which shell the command should target and run in: powershell (default) or cmd.

.PARAMETER Yes
    Skip the confirmation and run the command immediately. Use with care.

.PARAMETER Edit
    Always open the command for editing before the run/confirm step.

.PARAMETER DryRun
    Generate and print the command but never run it (implies no confirmation).

.PARAMETER NoStream
    Disable streaming and use a single blocking request.

.EXAMPLE
    pizt list every pdf modified in the last week

.EXAMPLE
    pizt -Shell cmd show my ip configuration

.EXAMPLE
    pizt -Edit kill the process listening on port 3000
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$Prompt,

    [ValidateSet('powershell', 'cmd')]
    [string]$Shell = 'powershell',

    [switch]$Yes,

    [switch]$Edit,

    [switch]$DryRun,

    [switch]$NoStream
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# API key: read from the PIZT_API_KEY environment variable. Never hardcode a key
# here -- anything committed to the repo is effectively public. Set it with:
#   $env:PIZT_API_KEY = 'nvapi-...'   (session)   or   setx PIZT_API_KEY "nvapi-..."
$script:PiztConfig = @{
    BaseUrl         = 'https://integrate.api.nvidia.com/v1/chat/completions'
    Model           = 'z-ai/glm-5.2'
    TimeoutSec      = 300
    MaxPromptLength = 8000
}
$script:PiztLastExitCode = 0

$script:PiztEsc = [char]27
function Get-PiztApiKey {
    # Read this at request time so setting PIZT_API_KEY after dot-sourcing works.
    return $env:PIZT_API_KEY
}

function Test-PiztColorEnabled {
    if (Test-Path Env:NO_COLOR) { return $false }
    try {
        if ([Console]::IsOutputRedirected) { return $false }
    }
    catch {
        # Non-console hosts should receive plain text by default.
        return $false
    }

    # Windows PowerShell 5.1 does not consistently render ANSI sequences. Newer
    # hosts advertise virtual-terminal support explicitly.
    $supportsVirtualTerminal = $Host.UI.PSObject.Properties['SupportsVirtualTerminal']
    return ($PSVersionTable.PSVersion.Major -ge 7 -and
        $supportsVirtualTerminal -and [bool]$supportsVirtualTerminal.Value)
}

function ConvertTo-PiztSafeDisplayText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return '' }
    # Prevent an API error or other untrusted text from injecting terminal
    # control sequences. Newlines and tabs are retained for readable errors.
    return [regex]::Replace($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', '?')
}

function Write-PiztColor {
    param([string]$Code, [string]$Text, [switch]$NoNewline)
    $safeText = ConvertTo-PiztSafeDisplayText -Text $Text
    $s = if (Test-PiztColorEnabled) { "$($script:PiztEsc)[$Code`m$safeText$($script:PiztEsc)[0m" } else { $safeText }
    if ($NoNewline) { Write-Host -NoNewline $s } else { Write-Host $s }
}

function Get-PiztSystemPrompt {
    param([string]$TargetShell)

    $shellName = if ($TargetShell -eq 'cmd') { 'Windows Command Prompt (cmd.exe)' } else { 'Windows PowerShell' }

    @"
You are pizt, a command-line assistant. The user describes a task in natural
language and you reply with a single command for $shellName on Windows.

Rules:
- Return exactly one command that is valid and idiomatic for $shellName.
- Do NOT wrap the command in markdown, backticks, or quotes.
- Prefer a one-liner. If several steps are truly required, chain them.
- If the request is impossible, unclear, or dangerous, put NONE as the command
  and explain briefly in the WHY line.
- Respond in EXACTLY this format, two lines, nothing else:
CMD: <the command on a single line>
WHY: <one short sentence explaining what it does>
"@
}

function Get-PiztRequestBody {
    param([string]$UserPrompt, [string]$TargetShell, [bool]$Stream)
    @{
        model       = $script:PiztConfig.Model
        temperature = 0.2
        top_p       = 1
        max_tokens  = 1024
        stream      = $Stream
        messages    = @(
            @{ role = 'system'; content = (Get-PiztSystemPrompt -TargetShell $TargetShell) }
            @{ role = 'user';   content = $UserPrompt }
        )
    } | ConvertTo-Json -Depth 6
}

function Get-PiztRequestHeader {
    $apiKey = Get-PiztApiKey
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw 'No API key is configured. Set PIZT_API_KEY and try again.'
    }

    return @{
        'Authorization' = "Bearer $apiKey"
        'Content-Type'  = 'application/json'
        'Accept'        = 'application/json'
    }
}

# --- Blocking (non-streaming) request ---------------------------------------
function Invoke-PiztModel {
    param([string]$UserPrompt, [string]$TargetShell)

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # NVIDIA's HTTPS endpoint requires TLS 1.2 or newer. Preserve any
        # protocols already enabled for the host process.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    $headers = Get-PiztRequestHeader
    try {
        # This model is a slow reasoner (can take 60-90s), so allow plenty of time.
        $resp = Invoke-RestMethod -Uri $script:PiztConfig.BaseUrl -Method Post `
            -Headers $headers `
            -Body (Get-PiztRequestBody -UserPrompt $UserPrompt -TargetShell $TargetShell -Stream $false) `
            -TimeoutSec $script:PiztConfig.TimeoutSec -ErrorAction Stop
    }
    catch {
        throw "Request to the model failed: $($_.Exception.Message)"
    }
    $content = $resp.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'The model returned an empty response.' }
    return $content
}

# --- Streaming request (SSE via HttpClient) ---------------------------------
# Shows progress while accumulating the response. Raw model output is not
# written to the terminal until it has passed strict validation.
function Invoke-PiztModelStream {
    param([string]$UserPrompt, [string]$TargetShell)

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    }

    $client = $null
    $req = $null
    $resp = $null
    $stream = $null
    $reader = $null
    $content = [System.Text.StringBuilder]::new()
    $progressTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressAt = 0
    $showedProgress = $false
    try {
        $apiKey = Get-PiztApiKey
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            throw 'No API key is configured. Set PIZT_API_KEY and try again.'
        }

        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds($script:PiztConfig.TimeoutSec)
        $req = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Post, $script:PiztConfig.BaseUrl)
        $req.Headers.TryAddWithoutValidation('Authorization', "Bearer $apiKey") | Out-Null
        $req.Headers.TryAddWithoutValidation('Accept', 'text/event-stream') | Out-Null
        $req.Content = [System.Net.Http.StringContent]::new(
            (Get-PiztRequestBody -UserPrompt $UserPrompt -TargetShell $TargetShell -Stream $true),
            [System.Text.Encoding]::UTF8, 'application/json')

        $resp = $client.SendAsync(
            $req,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            throw "HTTP $([int]$resp.StatusCode) ($($resp.ReasonPhrase))"
        }

        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = [System.IO.StreamReader]::new($stream)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if (-not $line.StartsWith('data:')) { continue }
            $data = $line.Substring(5).Trim()
            if ($data -eq '[DONE]') { break }
            try { $obj = $data | ConvertFrom-Json } catch { continue }
            if (-not $obj.choices -or $obj.choices.Count -eq 0) { continue }
            $delta = $obj.choices[0].delta
            if (-not $delta) { continue }
            # GLM reasoning models expose the chain-of-thought here.
            $reason = $delta.PSObject.Properties['reasoning_content']
            if ($reason -and $reason.Value) {
                # Show bounded progress without exposing raw reasoning content.
                $elapsedSecond = [int]$progressTimer.Elapsed.TotalSeconds
                if ($elapsedSecond -ge ($lastProgressAt + 2)) {
                    Write-PiztColor '90' '.' -NoNewline
                    $lastProgressAt = $elapsedSecond
                    $showedProgress = $true
                }
            }
            if ($delta.content) {
                [void]$content.Append($delta.content)
            }
        }
    }
    finally {
        $progressTimer.Stop()
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($resp) { $resp.Dispose() }
        if ($req) { $req.Dispose() }
        if ($client) { $client.Dispose() }
        if ($showedProgress) { Write-Host '' }
    }

    $text = $content.ToString()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'The model returned an empty response.' }
    return $text
}

function ConvertFrom-PiztResponse {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw 'The model returned an empty response.'
    }

    $response = $Text.Trim()
    $match = [regex]::Match(
        $response,
        '\ACMD:[ \t]*(?<command>[^\r\n]+)\r?\nWHY:[ \t]*(?<why>[^\r\n]+)\z',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) {
        throw 'The model response did not match the required two-line CMD/WHY format.'
    }

    $command = $match.Groups['command'].Value.Trim()
    $why = $match.Groups['why'].Value.Trim()
    if (-not $command -or -not $why) {
        throw 'The model response contained an empty command or explanation.'
    }
    if ($command.Length -gt 8192) {
        throw 'The generated command is too long to execute safely.'
    }
    if ($command -match '[\x00-\x1F\x7F-\x9F]' -or $why -match '[\x00-\x1F\x7F-\x9F]') {
        throw 'The model response contained unsafe control characters.'
    }

    [PSCustomObject]@{ Command = $command; Why = $why }
}

function Copy-PiztToClipboard {
    param([string]$Text)
    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $Text -ErrorAction Stop
            return $true
        }
    }
    catch { return $false }
    return $false
}

function Invoke-Pizt {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
        [string[]]$Prompt,

        [ValidateSet('powershell', 'cmd')]
        [string]$Shell = 'powershell',
        [switch]$Yes,
        [switch]$Edit,
        [switch]$DryRun,
        [switch]$NoStream
    )

    $script:PiztLastExitCode = 0
    $promptText = ($Prompt -join ' ').Trim()
    if (-not $promptText) {
        Write-PiztColor '90' 'Usage: pizt <what you want to do>   e.g.  pizt list files by size'
        $script:PiztLastExitCode = 2
        return
    }

    if ($promptText.Length -gt $script:PiztConfig.MaxPromptLength) {
        Write-PiztColor '31' "pizt: prompt is too long (maximum $($script:PiztConfig.MaxPromptLength) characters)."
        $script:PiztLastExitCode = 2
        return
    }

    if ([string]::IsNullOrWhiteSpace((Get-PiztApiKey))) {
        Write-PiztColor '31' 'pizt: no API key. Set it first, e.g.  $env:PIZT_API_KEY = ''nvapi-...'''
        $script:PiztLastExitCode = 2
        return
    }

    Write-PiztColor '90' "thinking... ($($script:PiztConfig.Model), target: $Shell)"

    try {
        if ($NoStream) {
            $raw = Invoke-PiztModel -UserPrompt $promptText -TargetShell $Shell
        }
        else {
            try {
                $raw = Invoke-PiztModelStream -UserPrompt $promptText -TargetShell $Shell
            }
            catch {
                # An HTTP response means the endpoint handled the request and
                # rejected it; retrying the same request only adds cost/noise.
                if ($_.Exception.Message -match '\bHTTP [1-5][0-9]{2}\b') { throw }
                Write-PiztColor '90' "(streaming unavailable, falling back: $($_.Exception.Message))"
                $raw = Invoke-PiztModel -UserPrompt $promptText -TargetShell $Shell
            }
        }
    }
    catch {
        Write-PiztColor '31' "pizt: $($_.Exception.Message)"
        $script:PiztLastExitCode = 1
        return
    }

    try {
        $parsed = ConvertFrom-PiztResponse -Text $raw
    }
    catch {
        Write-PiztColor '31' "pizt: refused an invalid model response. $($_.Exception.Message)"
        $script:PiztLastExitCode = 1
        return
    }

    if ($parsed.Command -ieq 'NONE') {
        Write-PiztColor '33' 'pizt: no command produced.'
        if ($parsed.Why) { Write-PiztColor '90' "  $($parsed.Why)" }
        return
    }

    $command = $parsed.Command
    $copied = Copy-PiztToClipboard -Text $command

    Write-Host ''
    $useColor = Test-PiztColorEnabled
    $shellLabel = if ($useColor) { "$($script:PiztEsc)[36m[$Shell]$($script:PiztEsc)[0m" } else { "[$Shell]" }
    $displayCommand = if ($useColor) { "$($script:PiztEsc)[1m$command$($script:PiztEsc)[0m" } else { $command }
    Write-Host "  $shellLabel  $displayCommand"
    if ($parsed.Why) { Write-PiztColor '90' "  # $($parsed.Why)" }
    if ($copied) { Write-PiztColor '90' '  (copied to clipboard)' }
    Write-Host ''

    if ($DryRun) { return }

    # -Edit: let the user rewrite the command before confirming.
    if ($Edit) {
        $edited = Read-Host "Edit command (blank keeps it)`n>"
        if ($edited.Trim()) { $command = $edited.Trim(); Copy-PiztToClipboard -Text $command | Out-Null }
    }

    if (-not $Yes) {
        $answer = Read-Host 'Run this? [y]es / [N]o / [e]dit'
        if ($answer -match '^(e|edit)$') {
            $edited = Read-Host "Edit command (blank keeps it)`n>"
            if ($edited.Trim()) { $command = $edited.Trim(); Copy-PiztToClipboard -Text $command | Out-Null }
            $answer = Read-Host 'Run this? [y/N]'
        }
        if ($answer -notmatch '^(y|yes)$') {
            Write-PiztColor '90' 'cancelled.'
            return
        }
    }

    try {
        if ($Shell -eq 'cmd') {
            # /d disables cmd.exe AutoRun entries that could otherwise alter a
            # generated command before it executes.
            & cmd.exe /d /c $command
            if ($LASTEXITCODE -ne 0) {
                $script:PiztLastExitCode = $LASTEXITCODE
                Write-PiztColor '31' "pizt: command returned exit status $LASTEXITCODE."
            }
        }
        else {
            # Invoke-Expression is intentional: generated commands such as
            # Set-Location must run in the caller's session after confirmation.
            $oldErrorActionPreference = $ErrorActionPreference
            $previousNativeExitCode = $global:LASTEXITCODE
            try {
                $ErrorActionPreference = 'Stop'
                # Invoke-Expression itself reports success even when its final
                # native process fails. Null is used as a sentinel so a native
                # exit code can be distinguished from a pure PowerShell command.
                $global:LASTEXITCODE = $null
                Invoke-Expression $command
                $nativeExitCode = $global:LASTEXITCODE
                if ($null -eq $nativeExitCode) {
                    $global:LASTEXITCODE = $previousNativeExitCode
                }
                elseif ($nativeExitCode -ne 0) {
                    $script:PiztLastExitCode = $nativeExitCode
                    Write-PiztColor '31' "pizt: command returned exit status $nativeExitCode."
                }
            }
            catch {
                if ($null -eq $global:LASTEXITCODE) {
                    $global:LASTEXITCODE = $previousNativeExitCode
                }
                throw
            }
            finally {
                $ErrorActionPreference = $oldErrorActionPreference
            }
        }
    }
    catch {
        Write-PiztColor '31' "pizt: command failed: $($_.Exception.Message)"
        $script:PiztLastExitCode = 1
    }
}

# ---------------------------------------------------------------------------
# Entry point: when this file is executed directly (not dot-sourced), run.
# When dot-sourced, it just defines Invoke-Pizt / the `pizt` alias.
# ---------------------------------------------------------------------------
Set-Alias -Name pizt -Value Invoke-Pizt -Scope Script -ErrorAction SilentlyContinue

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Pizt -Prompt $Prompt -Shell $Shell -Yes:$Yes -Edit:$Edit -DryRun:$DryRun -NoStream:$NoStream
    if ($script:PiztLastExitCode -ne 0) { exit $script:PiztLastExitCode }
}
