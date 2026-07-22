@{
    RootModule        = 'pizt.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '89c32f20-615a-43fc-b90d-39856fcdc84d'
    Author            = 'Samsudeen Ashad'
    CompanyName       = 'Community'
    Copyright         = '(c) 2026 Samsudeen Ashad. MIT License.'
    Description       = 'AI terminal-command agent for Windows PowerShell and cmd.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @('Invoke-Pizt')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('pizt')
    FileList          = @('pizt.psm1', 'pizt.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md')

    PrivateData = @{
        PSData = @{
            Tags         = @('AI', 'Terminal', 'PowerShell', 'Windows', 'NVIDIA')
            LicenseUri   = 'https://github.com/SamsudeenAshad/pizt/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/SamsudeenAshad/pizt'
            ReleaseNotes = 'Strict response validation, safer streaming, reliable exit codes, tests, and CI.'
        }
    }
}
