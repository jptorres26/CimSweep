#Requires -Version 5.1

Set-StrictMode -Version Latest

function Get-CSFailureInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]
        $ErrorRecord
    )

    $Message = $ErrorRecord.Exception.Message
    $Category = 'Unknown'

    switch -Regex ($Message) {
        'access is denied|unauthorized|not authorized|permission|privilege' { $Category = 'Authorization'; break }
        'logon failure|authentication|credential|username or password' { $Category = 'Authentication'; break }
        'winrm|wsman|rpc server is unavailable|network path was not found|could not resolve|name resolution|connection.*failed|timed out|unreachable' { $Category = 'Transport'; break }
        'one or more tests failed|pester reported .* failed test' { $Category = 'TestFailure'; break }
        'smoke run failed' { $Category = 'SmokeFailure'; break }
        'invalid namespace' { $Category = 'NamespaceMissing'; break }
        'invalid class' { $Category = 'ClassMissing'; break }
        'cannot find path|not found' { $Category = 'NotFound'; break }
        'is not installed|Install-Module|PowerShellGet|NuGet' { $Category = 'Dependency'; break }
        'parameter set cannot be resolved|parameter.*cannot be found|cannot bind parameter' { $Category = 'ParameterBinding'; break }
        'designed for Windows hosts|#Requires -Version' { $Category = 'UnsupportedPlatform'; break }
    }

    [PSCustomObject] @{
        Category = $Category
        Message = $Message
        FullyQualifiedErrorId = $ErrorRecord.FullyQualifiedErrorId
        ScriptStackTrace = $ErrorRecord.ScriptStackTrace
    }
}

function Write-CSStructuredLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Trace', 'Info', 'Warning', 'Error')]
        [string]
        $Level,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $EventName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [AllowNull()]
        [object]
        $Data
    )

    $Record = [PSCustomObject] @{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Level = $Level
        Event = $EventName
        Message = $Message
        Data = $Data
    }

    $Json = $Record | ConvertTo-Json -Depth 10 -Compress
    Add-Content -Path $Path -Value $Json
}
