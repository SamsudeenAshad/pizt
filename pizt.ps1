<#
.SYNOPSIS
    pizt - an AI terminal command agent for Windows PowerShell and cmd.

.DESCRIPTION
    Describe what you want in plain English; pizt asks an LLM for the exact
    command, streams its thinking live, shows the command with a one-line
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
    Disable the live streaming display and use a single blocking request.

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
    BaseUrl = 'https://integrate.api.nvidia.com/v1/chat/completions'
    Model   = 'z-ai/glm-5.2'
    ApiKey  = $env:PIZT_API_KEY
}

$script:PiztEsc = [char]27
function Write-PiztColor {
    param([string]$Code, [string]$Text, [switch]$NoNewline)
    $s = if ($env:NO_COLOR) { $Text } else { "$($script:PiztEsc)[$Code`m$Text$($script:PiztEsc)[0m" }
    if ($NoNewline) { Write-Host -NoNewline $s } else { Write-Host $s }
}

function Get-PiztSystemPrompt {
    param([string]$TargetShell)

    $shellName = if ($TargetShell -eq 'cmd') { 'Windows Command Prompt (cmd.exe)' } else { 'Windows PowerShell' }

    @"
You are pizt, a command-line assistant. The user describes a task in natural
language and you reply with a single command for $shellName on Windows.

Rules:
- Return ONLY a command that is valid and idiomatic for $shellName.
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

# --- Blocking (non-streaming) request ---------------------------------------
function Invoke-PiztModel {
    param([string]$UserPrompt, [string]$TargetShell)

    $headers = @{
        'Authorization' = "Bearer $($script:PiztConfig.ApiKey)"
        'Content-Type'  = 'application/json'
        'Accept'        = 'application/json'
    }
    try {
        # This model is a slow reasoner (can take 60-90s), so allow plenty of time.
        $resp = Invoke-RestMethod -Uri $script:PiztConfig.BaseUrl -Method Post `
            -Headers $headers -Body (Get-PiztRequestBody $UserPrompt $TargetShell $false) `
            -TimeoutSec 300 -ErrorAction Stop
    }
    catch {
        throw "Request to the model failed: $($_.Exception.Message)"
    }
    $content = $resp.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'The model returned an empty response.' }
    return $content
}

# --- Streaming request (SSE via HttpClient) ---------------------------------
# Streams reasoning + content live (dimmed) so the slow model shows progress,
# and returns the accumulated answer content for parsing.
function Invoke-PiztModelStream {
    param([string]$UserPrompt, [string]$TargetShell)

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    }

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(300)
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $script:PiztConfig.BaseUrl)
    $req.Headers.TryAddWithoutValidation('Authorization', "Bearer $($script:PiztConfig.ApiKey)") | Out-Null
    $req.Headers.TryAddWithoutValidation('Accept', 'text/event-stream') | Out-Null
    $req.Content = [System.Net.Http.StringContent]::new(
        (Get-PiztRequestBody $UserPrompt $TargetShell $true),
        [System.Text.Encoding]::UTF8, 'application/json')

    $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        $errText = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $client.Dispose()
        throw "HTTP $([int]$resp.StatusCode): $errText"
    }

    $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [System.IO.StreamReader]::new($stream)
    $content = [System.Text.StringBuilder]::new()
    $sawAnything = $false
    try {
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
                Write-PiztColor '90' $reason.Value -NoNewline
                $sawAnything = $true
            }
            if ($delta.content) {
                [void]$content.Append($delta.content)
                Write-PiztColor '90' $delta.content -NoNewline
                $sawAnything = $true
            }
        }
    }
    finally {
        $reader.Dispose(); $stream.Dispose(); $client.Dispose()
    }
    if ($sawAnything) { Write-Host '' }  # close the dimmed stream line

    $text = $content.ToString()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'The model returned an empty response.' }
    return $text
}

function ConvertFrom-PiztResponse {
    param([string]$Text)

    $cmd = $null; $why = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*CMD:\s*(.+)$') { $cmd = $Matches[1].Trim() }
        elseif ($line -match '^\s*WHY:\s*(.+)$') { $why = $Matches[1].Trim() }
    }
    # Fallback: if the model ignored the format, use the first non-empty line.
    if (-not $cmd) {
        $first = ($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($first) { $cmd = $first.Trim('`', ' ', '"') }
    }
    [PSCustomObject]@{ Command = $cmd; Why = $why }
}

function Set-PiztClipboard {
    param([string]$Text)
    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $Text -ErrorAction Stop
            return $true
        }
    }
    catch { }
    return $false
}

function Invoke-Pizt {
    [CmdletBinding()]
    param(
        [string[]]$Prompt,
        [string]$Shell = 'powershell',
        [switch]$Yes,
        [switch]$Edit,
        [switch]$DryRun,
        [switch]$NoStream
    )

    $promptText = ($Prompt -join ' ').Trim()
    if (-not $promptText) {
        Write-PiztColor '90' 'Usage: pizt <what you want to do>   e.g.  pizt list files by size'
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:PiztConfig.ApiKey)) {
        Write-PiztColor '31' 'pizt: no API key. Set it first, e.g.  $env:PIZT_API_KEY = ''nvapi-...'''
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
                Write-PiztColor '90' "(streaming unavailable, falling back: $($_.Exception.Message))"
                $raw = Invoke-PiztModel -UserPrompt $promptText -TargetShell $Shell
            }
        }
    }
    catch {
        Write-PiztColor '31' "pizt: $($_.Exception.Message)"
        return
    }

    $parsed = ConvertFrom-PiztResponse -Text $raw
    if (-not $parsed.Command -or $parsed.Command -eq 'NONE') {
        Write-PiztColor '33' 'pizt: no command produced.'
        if ($parsed.Why) { Write-PiztColor '90' "  $($parsed.Why)" }
        return
    }

    $command = $parsed.Command
    $copied = Set-PiztClipboard -Text $command

    Write-Host ''
    Write-Host ('  ' + $(if ($env:NO_COLOR) { "[$Shell]" } else { "$($script:PiztEsc)[36m[$Shell]$($script:PiztEsc)[0m" }) + '  ' + `
        $(if ($env:NO_COLOR) { $command } else { "$($script:PiztEsc)[1m$command$($script:PiztEsc)[0m" }))
    if ($parsed.Why) { Write-PiztColor '90' "  # $($parsed.Why)" }
    if ($copied) { Write-PiztColor '90' '  (copied to clipboard)' }
    Write-Host ''

    if ($DryRun) { return }

    # -Edit: let the user rewrite the command before confirming.
    if ($Edit) {
        $edited = Read-Host "Edit command (blank keeps it)`n>"
        if ($edited.Trim()) { $command = $edited.Trim(); Set-PiztClipboard -Text $command | Out-Null }
    }

    if (-not $Yes) {
        $answer = Read-Host 'Run this? [y]es / [N]o / [e]dit'
        if ($answer -match '^(e|edit)$') {
            $edited = Read-Host "Edit command (blank keeps it)`n>"
            if ($edited.Trim()) { $command = $edited.Trim(); Set-PiztClipboard -Text $command | Out-Null }
            $answer = Read-Host 'Run this? [y/N]'
        }
        if ($answer -notmatch '^(y|yes)$') {
            Write-PiztColor '90' 'cancelled.'
            return
        }
    }

    if ($Shell -eq 'cmd') { & cmd.exe /c $command }
    else { Invoke-Expression $command }
}

# ---------------------------------------------------------------------------
# Entry point: when this file is executed directly (not dot-sourced), run.
# When dot-sourced, it just defines Invoke-Pizt / the `pizt` alias.
# ---------------------------------------------------------------------------
Set-Alias -Name pizt -Value Invoke-Pizt -Scope Global -ErrorAction SilentlyContinue

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Pizt -Prompt $Prompt -Shell $Shell -Yes:$Yes -Edit:$Edit -DryRun:$DryRun -NoStream:$NoStream
}
