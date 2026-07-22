BeforeAll {
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'pizt.ps1'
    $script:OriginalApiKey = [Environment]::GetEnvironmentVariable('PIZT_API_KEY')
    . $scriptPath
}

AfterAll {
    [Environment]::SetEnvironmentVariable('PIZT_API_KEY', $script:OriginalApiKey)
}

Describe 'ConvertFrom-PiztResponse' {
    It 'accepts the exact two-line response format' {
        $result = ConvertFrom-PiztResponse -Text "CMD: Get-ChildItem`r`nWHY: Lists files in the current directory."

        $result.Command | Should -BeExactly 'Get-ChildItem'
        $result.Why | Should -BeExactly 'Lists files in the current directory.'
    }

    It 'accepts NONE as an explicit refusal' {
        $result = ConvertFrom-PiztResponse -Text "CMD: NONE`nWHY: The request is unsafe."

        $result.Command | Should -BeExactly 'NONE'
    }

    It 'rejects prose before the required lines' {
        {
            ConvertFrom-PiztResponse -Text "Here is the command:`nCMD: Get-Date`nWHY: Shows the time."
        } | Should -Throw '*required two-line*'
    }

    It 'rejects markdown fences around the response' {
        $fencedResponse = '```text' + "`nCMD: Get-Date`nWHY: Shows the time.`n" + '```'

        {
            ConvertFrom-PiztResponse -Text $fencedResponse
        } | Should -Throw '*required two-line*'
    }

    It 'rejects a multiline command' {
        {
            ConvertFrom-PiztResponse -Text "CMD: Get-Date`nGet-Location`nWHY: Runs two commands."
        } | Should -Throw '*required two-line*'
    }

    It 'rejects an empty explanation' {
        {
            ConvertFrom-PiztResponse -Text "CMD: Get-Date`nWHY:   "
        } | Should -Throw '*required two-line*'
    }

    It 'rejects control characters' {
        $escape = [char]27

        {
            ConvertFrom-PiztResponse -Text "CMD: Get-Date$escape`nWHY: Shows the time."
        } | Should -Throw '*control characters*'
    }

    It 'rejects an oversized command' {
        $longCommand = 'a' * 8193

        {
            ConvertFrom-PiztResponse -Text "CMD: $longCommand`nWHY: Too large."
        } | Should -Throw '*too long*'
    }
}

Describe 'Request construction' {
    It 'builds the documented NVIDIA chat-completions shape' {
        $body = Get-PiztRequestBody -UserPrompt 'list files' -TargetShell 'cmd' -Stream $true |
            ConvertFrom-Json

        $body.model | Should -BeExactly 'z-ai/glm-5.2'
        $body.stream | Should -BeTrue
        @($body.messages).Count | Should -Be 2
        $body.messages[0].role | Should -BeExactly 'system'
        $body.messages[0].content | Should -Match 'Windows Command Prompt'
        $body.messages[1].role | Should -BeExactly 'user'
        $body.messages[1].content | Should -BeExactly 'list files'
    }

    It 'reads a changed API key without reloading the script' {
        $env:PIZT_API_KEY = 'first-test-key'
        (Get-PiztRequestHeader).Authorization | Should -BeExactly 'Bearer first-test-key'

        $env:PIZT_API_KEY = 'second-test-key'
        (Get-PiztRequestHeader).Authorization | Should -BeExactly 'Bearer second-test-key'
    }

    It 'refuses to construct authenticated headers without a key' {
        $env:PIZT_API_KEY = ''

        { Get-PiztRequestHeader } | Should -Throw '*No API key*'
    }
}

Describe 'Terminal output safety' {
    It 'replaces terminal control characters in untrusted text' {
        $unsafe = "before$([char]27)[31mafter"

        ConvertTo-PiztSafeDisplayText -Text $unsafe | Should -BeExactly 'before?[31mafter'
    }
}

Describe 'Invoke-Pizt execution gates' {
    BeforeEach {
        $env:PIZT_API_KEY = 'test-key'
        Mock Write-PiztColor { }
        Mock Write-Host { }
        Mock Copy-PiztToClipboard { return $true }
        Mock Invoke-Expression { }
    }

    It 'never executes or copies a malformed model response' {
        Mock Invoke-PiztModel { return 'Get-Date' }

        Invoke-Pizt -Prompt 'show the time' -NoStream -Yes

        Should -Invoke Invoke-Expression -Times 0 -Exactly
        Should -Invoke Copy-PiztToClipboard -Times 0 -Exactly
    }

    It 'never executes an explicit model refusal' {
        Mock Invoke-PiztModel { return "CMD: NONE`nWHY: The request is dangerous." }

        Invoke-Pizt -Prompt 'unsafe request' -NoStream -Yes

        Should -Invoke Invoke-Expression -Times 0 -Exactly
        Should -Invoke Copy-PiztToClipboard -Times 0 -Exactly
    }

    It 'reports a model request failure without reaching execution' {
        Mock Invoke-PiztModel { throw 'simulated request failure' }

        Invoke-Pizt -Prompt 'show the time' -NoStream -Yes

        Should -Invoke Invoke-Expression -Times 0 -Exactly
        Should -Invoke Write-PiztColor -Times 1 -ParameterFilter {
            $Code -eq '31' -and $Text -like '*simulated request failure*'
        }
        $script:PiztLastExitCode | Should -Be 1
    }

    It 'does not execute a valid response in dry-run mode' {
        Mock Invoke-PiztModel { return "CMD: Get-Date`nWHY: Shows the current time." }

        Invoke-Pizt -Prompt 'show the time' -NoStream -DryRun

        Should -Invoke Copy-PiztToClipboard -Times 1 -Exactly
        Should -Invoke Invoke-Expression -Times 0 -Exactly
    }

    It 'executes a valid response after an explicit yes' {
        Mock Invoke-PiztModel { return "CMD: Get-Date`nWHY: Shows the current time." }

        Invoke-Pizt -Prompt 'show the time' -NoStream -Yes

        Should -Invoke Invoke-Expression -Times 1 -Exactly -ParameterFilter {
            $Command -eq 'Get-Date'
        }
    }

    It 'reports a confirmed command failure' {
        Mock Invoke-PiztModel { return "CMD: Get-Date`nWHY: Shows the current time." }
        Mock Invoke-Expression { throw 'simulated command failure' }

        Invoke-Pizt -Prompt 'show the time' -NoStream -Yes

        Should -Invoke Write-PiztColor -Times 1 -ParameterFilter {
            $Code -eq '31' -and $Text -like '*simulated command failure*'
        }
        $script:PiztLastExitCode | Should -Be 1
    }

    It 'does not execute a valid response after cancellation' {
        Mock Invoke-PiztModel { return "CMD: Get-Date`nWHY: Shows the current time." }
        Mock Read-Host { return 'n' }

        Invoke-Pizt -Prompt 'show the time' -NoStream

        Should -Invoke Invoke-Expression -Times 0 -Exactly
    }

    It 'does not contact the model when the prompt is oversized' {
        Mock Invoke-PiztModel { throw 'must not be called' }

        Invoke-Pizt -Prompt ('x' * 8001) -NoStream -DryRun

        Should -Invoke Invoke-PiztModel -Times 0 -Exactly
    }

    It 'does not contact the model when the API key is absent' {
        $env:PIZT_API_KEY = ''
        Mock Invoke-PiztModel { throw 'must not be called' }

        Invoke-Pizt -Prompt 'show the time' -NoStream -DryRun

        Should -Invoke Invoke-PiztModel -Times 0 -Exactly
    }

    It 'rejects unsupported shells at parameter binding' {
        {
            Invoke-Pizt -Prompt 'show the time' -Shell 'bash' -NoStream -DryRun
        } | Should -Throw '*does not belong to the set*'
    }
}
