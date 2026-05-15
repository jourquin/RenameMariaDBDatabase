\
<#
.SYNOPSIS
    Safely "renames" a MariaDB database on Windows by dumping and restoring it.

.DESCRIPTION
    MariaDB does not support a direct RENAME DATABASE command.

    This PowerShell script:
      1. Prompts once for the MariaDB password.
      2. Creates a temporary MariaDB option file.
      3. Creates the new database.
      4. Dumps the old database, including routines, triggers, and events.
      5. Imports the dump into the new database.
      6. Shows a simple table-count comparison.
      7. Leaves the old database untouched unless you explicitly use -DropOldDatabase.

.REQUIREMENTS
    - PowerShell
    - mariadb.exe
    - mariadb-dump.exe, or mysqldump.exe as a fallback
    - The MariaDB client tools must be in PATH, unless you pass -MariaDbExe and -DumpExe manually.

.EXAMPLE
    .\Rename-MariaDbDatabase.ps1 -OldDb oldname -NewDb newname -User root

.EXAMPLE
    .\Rename-MariaDbDatabase.ps1 -OldDb oldname -NewDb newname -User root -Host localhost -Port 3306

.EXAMPLE
    .\Rename-MariaDbDatabase.ps1 `
      -OldDb oldname `
      -NewDb newname `
      -User root `
      -MariaDbExe "C:\Program Files\MariaDB 11.4\bin\mariadb.exe" `
      -DumpExe "C:\Program Files\MariaDB 11.4\bin\mariadb-dump.exe"

.NOTES
    For production databases, stop application writes before running this script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OldDb,

    [Parameter(Mandatory = $true)]
    [string]$NewDb,

    [string]$User = "root",

    [string]$Host = "localhost",

    [int]$Port = 3306,

    [string]$DumpFile = "",

    [string]$MariaDbExe = "mariadb.exe",

    [string]$DumpExe = "",

    [switch]$DropOldDatabase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }

        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "Could not find any of these executables: $($Candidates -join ', ')"
}

function Quote-Identifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # MariaDB identifiers are quoted with backticks. Embedded backticks are doubled.
    return '`' + ($Name -replace '`', '``') + '`'
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE: $Exe $($Arguments -join ' ')"
    }
}

function Invoke-NativeRedirectOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    $process = Start-Process `
        -FilePath $Exe `
        -ArgumentList $Arguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $OutputFile

    if ($process.ExitCode -ne 0) {
        throw "Command failed with exit code $($process.ExitCode): $Exe $($Arguments -join ' ')"
    }
}

function Invoke-NativeRedirectInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$InputFile
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $Exe
    foreach ($arg in $Arguments) {
        [void]$processInfo.ArgumentList.Add($arg)
    }

    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $false
    $processInfo.RedirectStandardError = $false

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    [void]$process.Start()

    try {
        # SQL dump files are text files. This streams the file to mariadb.exe.
        # For typical MariaDB dumps this avoids PowerShell command-line password exposure
        # while preserving a simple Windows-native workflow.
        $reader = [System.IO.File]::OpenText($InputFile)
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                $process.StandardInput.WriteLine($line)
            }
        }
        finally {
            $reader.Close()
        }

        $process.StandardInput.Close()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0) {
            throw "Command failed with exit code $($process.ExitCode): $Exe $($Arguments -join ' ')"
        }
    }
    finally {
        $process.Dispose()
    }
}

function Protect-TempFileBestEffort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $Path /inheritance:r /grant:r "$($currentUser):F" | Out-Null
    }
    catch {
        Write-Warning "Could not restrict permissions on the temporary option file. Continuing anyway."
    }
}

$MariaDbExe = Resolve-Executable @($MariaDbExe)

if ([string]::IsNullOrWhiteSpace($DumpExe)) {
    $DumpExe = Resolve-Executable @("mariadb-dump.exe", "mysqldump.exe")
}
else {
    $DumpExe = Resolve-Executable @($DumpExe)
}

if ([string]::IsNullOrWhiteSpace($DumpFile)) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $DumpFile = Join-Path (Get-Location) "$OldDb-$timestamp.sql"
}

$OldDbQuoted = Quote-Identifier $OldDb
$NewDbQuoted = Quote-Identifier $NewDb

$securePassword = Read-Host "MariaDB password for $User" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
$plainPassword = $null
$defaultsFile = $null

try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

    $defaultsFile = [System.IO.Path]::GetTempFileName()

    @"
[client]
user=$User
password=$plainPassword
host=$Host
port=$Port
"@ | Set-Content -Path $defaultsFile -Encoding ASCII -NoNewline

    Protect-TempFileBestEffort -Path $defaultsFile

    $defaultsArg = "--defaults-extra-file=$defaultsFile"

    Write-Host "Creating database '$NewDb'..."
    Invoke-Native -Exe $MariaDbExe -Arguments @(
        $defaultsArg,
        "-e",
        "CREATE DATABASE $NewDbQuoted;"
    )

    Write-Host "Dumping '$OldDb' to '$DumpFile'..."
    Invoke-NativeRedirectOutput -Exe $DumpExe -Arguments @(
        $defaultsArg,
        "--single-transaction",
        "--routines",
        "--triggers",
        "--events",
        $OldDb
    ) -OutputFile $DumpFile

    Write-Host "Importing '$DumpFile' into '$NewDb'..."
    Invoke-NativeRedirectInput -Exe $MariaDbExe -Arguments @(
        $defaultsArg,
        $NewDb
    ) -InputFile $DumpFile

    Write-Host "Comparing table counts..."
    Invoke-Native -Exe $MariaDbExe -Arguments @(
        $defaultsArg,
        "-e",
        "SELECT table_schema, COUNT(*) AS tables FROM information_schema.tables WHERE table_schema IN ('$OldDb', '$NewDb') GROUP BY table_schema;"
    )

    if ($DropOldDatabase) {
        Write-Warning "Dropping old database '$OldDb'..."
        Invoke-Native -Exe $MariaDbExe -Arguments @(
            $defaultsArg,
            "-e",
            "DROP DATABASE $OldDbQuoted;"
        )
        Write-Host "Old database '$OldDb' dropped."
    }
    else {
        Write-Host ""
        Write-Host "Import completed. The old database '$OldDb' was NOT deleted."
        Write-Host "After verification, you can rerun with -DropOldDatabase or drop it manually."
    }

    Write-Host ""
    Write-Host "Done."
}
finally {
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ($defaultsFile -and (Test-Path $defaultsFile)) {
        Remove-Item $defaultsFile -Force
    }

    if ($plainPassword) {
        Remove-Variable plainPassword -ErrorAction SilentlyContinue
    }
}
