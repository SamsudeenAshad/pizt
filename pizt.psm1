#Requires -Version 5.1

# Load the existing script in module scope. Its direct-execution entry point is
# skipped when dot-sourced, so importing the module never contacts the API.
. (Join-Path $PSScriptRoot 'pizt.ps1')

Export-ModuleMember -Function Invoke-Pizt -Alias pizt
