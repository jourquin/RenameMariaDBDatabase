<#
.SYNOPSIS
    Safely "renames" a MariaDB or MySQL database on Windows by dumping and restoring it.

.DESCRIPTION
    MariaDB and MySQL do not support a direct RENAME DATABASE command.

    This PowerShell script:
      1. Prompts once for the database password.
      2. Creates a temporary client option file.
      3. Creates the new database.
      4. Dumps the old database, including routines, triggers, and events.
      5. Imports the dump into the new database.
      6. Shows a simple table-count comparison.
      7. Optionally copies database, table, and column-level grants.
      8. Optionally deletes generated SQL files.
      9. Leaves the old database untouched unless you explicitly use -DropOldDatabase.

.REQUIREMENTS
    - PowerShell
    - mariadb.exe or mysql.exe
    - mariadb-dump.exe or mysqldump.exe
    - The client tools must be in PATH, unless you pass -ClientExe and -DumpExe manually.

.EXAMPLE
    .\rename-mariadb-database.ps1 -OldDb oldname -NewDb newname -User root

.EXAMPLE
    .\rename-mariadb-database.ps1 -OldDb oldname -NewDb newname -User root -CopyGrants

.EXAMPLE
    .\rename-mariadb-database.ps1 -OldDb oldname -NewDb newname -User root -DeleteSqlFiles

.EXAMPLE
    .\rename-mariadb-database.ps1 -OldDb oldname -NewDb newname -User root -Host localhost -Port 3306

.EXAMPLE
    .\rename-mariadb-database.ps1 `
      -OldDb oldname `
      -NewDb newname `
      -User root `
      -CopyGrants `
      -GrantsFile "C:\Temp\oldname-to-newname-grants.sql"

.EXAMPLE
    .\rename-mariadb-database.ps1 `
      -OldDb oldname `
      -NewDb newname `
      -User root `
      -ClientExe "C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe" `
      -DumpExe "C:\Program Files\MySQL\MySQL Server 8.4\bin\mysqldump.exe"

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

    [Alias("Host")]
    [string]$DbHost = "localhost",

    [int]$Port = 3306,

    [string]$DumpFile = "",

    [string]$GrantsFile = "",

    [string]$ClientExe = "",

    [string]$DumpExe = "",

    [switch]$CopyGrants,

    [switch]$DeleteSqlFiles,

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
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

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

    # MariaDB/MySQL identifiers are quoted with backticks. Embedded backticks are doubled.
    return '`' + ($Name -replace '`', '``') + '`'
}

function Quote-SqlString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    # SQL string literals are quoted with single quotes. Embedded single quotes are doubled.
    return "'" + ($Value -replace "'", "''") + "'"
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
        throw "Command failed with exit code ${LASTEXITCODE}: $Exe $($Arguments -join ' ')"
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

    # Windows PowerShell 5.1 does not expose ProcessStartInfo.ArgumentList.
    # Start-Process with -RedirectStandardInput is compatible with Windows PowerShell 5.1
    # and avoids loading large SQL dump files into memory.
    $process = Start-Process `
        -FilePath $Exe `
        -ArgumentList $Arguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardInput $InputFile

    if ($process.ExitCode -ne 0) {
        throw "Command failed with exit code $($process.ExitCode): $Exe $($Arguments -join ' ')"
    }
}

function Invoke-NativeRedirectInputOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$InputFile,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile
    )

    $errorFile = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process `
            -FilePath $Exe `
            -ArgumentList $Arguments `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardInput $InputFile `
            -RedirectStandardOutput $OutputFile `
            -RedirectStandardError $errorFile

        if ($process.ExitCode -ne 0) {
            $errorText = ""
            if (Test-Path $errorFile) {
                $errorText = Get-Content -Path $errorFile -Raw
            }

            if ([string]::IsNullOrWhiteSpace($errorText)) {
                throw "Command failed with exit code $($process.ExitCode): $Exe $($Arguments -join ' ')"
            }
            else {
                throw "Command failed with exit code $($process.ExitCode): $Exe $($Arguments -join ' ')`n$errorText"
            }
        }
    }
    finally {
        if (Test-Path $errorFile) {
            Remove-Item -LiteralPath $errorFile -Force
        }
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

function Test-FileHasContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $content = Get-Content -Path $Path -Raw
    return -not [string]::IsNullOrWhiteSpace($content)
}

function Remove-GeneratedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (Test-Path $Path) {
        Write-Host "Deleting $Description '$Path'..."
        Remove-Item -LiteralPath $Path -Force
        Write-Host "$Description deleted."
    }
    else {
        Write-Host "$Description '$Path' was not found; nothing to delete."
    }
}

if ([string]::IsNullOrWhiteSpace($ClientExe)) {
    $ClientExe = Resolve-Executable @("mariadb.exe", "mysql.exe")
}
else {
    $ClientExe = Resolve-Executable @($ClientExe)
}

if ([string]::IsNullOrWhiteSpace($DumpExe)) {
    $DumpExe = Resolve-Executable @("mariadb-dump.exe", "mysqldump.exe")
}
else {
    $DumpExe = Resolve-Executable @($DumpExe)
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ([string]::IsNullOrWhiteSpace($DumpFile)) {
    $DumpFile = Join-Path (Get-Location) "$OldDb-$timestamp.sql"
}

if ([string]::IsNullOrWhiteSpace($GrantsFile)) {
    $GrantsFile = Join-Path (Get-Location) "$OldDb-to-$NewDb-grants-$timestamp.sql"
}
elseif (-not $CopyGrants) {
    Write-Warning "-GrantsFile was provided but -CopyGrants is not enabled; the grants file will not be generated."
}

$OldDbQuoted = Quote-Identifier $OldDb
$NewDbQuoted = Quote-Identifier $NewDb
$OldDbLiteral = Quote-SqlString $OldDb
$NewDbLiteral = Quote-SqlString $NewDb
$NewDbIdentifierLiteral = Quote-SqlString $NewDbQuoted
$GrantsFileCreated = $false

$sqlTableCountTemplate = @'
SELECT table_schema, COUNT(*) AS tables
FROM information_schema.tables
WHERE table_schema IN (__OLD_DB_LITERAL__, __NEW_DB_LITERAL__)
GROUP BY table_schema;
'@

$sqlTableCount = $sqlTableCountTemplate.
    Replace("__OLD_DB_LITERAL__", $OldDbLiteral).
    Replace("__NEW_DB_LITERAL__", $NewDbLiteral)

$sqlCopyGrantsTemplate = @'
SET SESSION group_concat_max_len = 1048576;

SELECT grant_statement
FROM (
  SELECT
    1 AS sort_order,
    GRANTEE AS grantee_sort,
    '' AS object_sort,
    '' AS privilege_sort,
    IS_GRANTABLE AS grantable_sort,
    CONCAT(
      'GRANT ',
      GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', '),
      ' ON ',
      __NEW_DB_IDENTIFIER_LITERAL__,
      '.* TO ',
      GRANTEE,
      IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
      ';'
    ) AS grant_statement
  FROM information_schema.SCHEMA_PRIVILEGES
  WHERE TABLE_SCHEMA = __OLD_DB_LITERAL__
  GROUP BY GRANTEE, IS_GRANTABLE

  UNION ALL

  SELECT
    2 AS sort_order,
    GRANTEE AS grantee_sort,
    TABLE_NAME AS object_sort,
    '' AS privilege_sort,
    IS_GRANTABLE AS grantable_sort,
    CONCAT(
      'GRANT ',
      GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', '),
      ' ON ',
      __NEW_DB_IDENTIFIER_LITERAL__,
      '.`',
      REPLACE(TABLE_NAME, '`', '``'),
      '` TO ',
      GRANTEE,
      IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
      ';'
    ) AS grant_statement
  FROM information_schema.TABLE_PRIVILEGES
  WHERE TABLE_SCHEMA = __OLD_DB_LITERAL__
  GROUP BY GRANTEE, TABLE_NAME, IS_GRANTABLE

  UNION ALL

  SELECT
    3 AS sort_order,
    GRANTEE AS grantee_sort,
    TABLE_NAME AS object_sort,
    PRIVILEGE_TYPE AS privilege_sort,
    IS_GRANTABLE AS grantable_sort,
    CONCAT(
      'GRANT ',
      PRIVILEGE_TYPE,
      ' (',
      GROUP_CONCAT(CONCAT('`', REPLACE(COLUMN_NAME, '`', '``'), '`') ORDER BY COLUMN_NAME SEPARATOR ', '),
      ') ON ',
      __NEW_DB_IDENTIFIER_LITERAL__,
      '.`',
      REPLACE(TABLE_NAME, '`', '``'),
      '` TO ',
      GRANTEE,
      IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
      ';'
    ) AS grant_statement
  FROM information_schema.COLUMN_PRIVILEGES
  WHERE TABLE_SCHEMA = __OLD_DB_LITERAL__
  GROUP BY GRANTEE, TABLE_NAME, PRIVILEGE_TYPE, IS_GRANTABLE
) AS generated_grants
ORDER BY sort_order, grantee_sort, object_sort, privilege_sort, grantable_sort;
'@

$sqlCopyGrants = $sqlCopyGrantsTemplate.
    Replace("__OLD_DB_LITERAL__", $OldDbLiteral).
    Replace("__NEW_DB_IDENTIFIER_LITERAL__", $NewDbIdentifierLiteral)

$securePassword = Read-Host "Database password for $User" -AsSecureString
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
host=$DbHost
port=$Port
"@ | Set-Content -Path $defaultsFile -Encoding ASCII -NoNewline

    Protect-TempFileBestEffort -Path $defaultsFile

    $defaultsArg = "--defaults-extra-file=$defaultsFile"

    Write-Host "Creating database '$NewDb'..."
    Invoke-Native -Exe $ClientExe -Arguments @(
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
    Invoke-NativeRedirectInput -Exe $ClientExe -Arguments @(
        $defaultsArg,
        $NewDb
    ) -InputFile $DumpFile

    Write-Host "Comparing table counts..."
    Invoke-Native -Exe $ClientExe -Arguments @(
        $defaultsArg,
        "-e",
        $sqlTableCount
    )

    if ($CopyGrants) {
        Write-Host "Generating grants file '$GrantsFile'..."

        $grantQueryFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $grantQueryFile -Value $sqlCopyGrants -Encoding ASCII

            Invoke-NativeRedirectInputOutput -Exe $ClientExe -Arguments @(
                $defaultsArg,
                "--batch",
                "--raw",
                "--skip-column-names"
            ) -InputFile $grantQueryFile -OutputFile $GrantsFile
        }
        finally {
            if (Test-Path $grantQueryFile) {
                Remove-Item -LiteralPath $grantQueryFile -Force
            }
        }

        $GrantsFileCreated = $true

        if (Test-FileHasContent -Path $GrantsFile) {
            Write-Host "Applying copied grants from '$GrantsFile'..."
            Invoke-NativeRedirectInput -Exe $ClientExe -Arguments @(
                $defaultsArg
            ) -InputFile $GrantsFile
            Write-Host "Copied grants applied."
        }
        else {
            Write-Host "No database, table, or column-level grants found for '$OldDb'."
        }
    }

    if ($DropOldDatabase) {
        Write-Warning "Dropping old database '$OldDb'..."
        Invoke-Native -Exe $ClientExe -Arguments @(
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

    if ($DeleteSqlFiles) {
        Remove-GeneratedFile -Path $DumpFile -Description "dump file"

        if ($GrantsFileCreated) {
            Remove-GeneratedFile -Path $GrantsFile -Description "grants file"
        }
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
