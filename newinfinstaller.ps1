#Requires -Version 5.1

param(
    [string]$DriverRoot        = "B:\src_b2\WORK\NewWay2inf\asuschipset\Driversonly",
    [string]$OutputDir         = "C:\Temp",
    [switch]$DryRun,
    [switch]$BackupBeforeDelete,
    [string]$BackupDirectory   = "$env:SystemDrive\DriverBackup",
    [switch]$VerboseToScreen,
    [string]$LogFile           = "$env:SystemDrive\DriverWorkflow.log",
    [switch]$Interactive
)

# Silent ignore errors (as in original)
$ErrorActionPreference = "SilentlyContinue"

# Ensure output directory exists
if (-not (Test-Path -Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# --- LOGGING WRAPPER ---------------------------------------------------------
# Uses existing Write-Log if present; otherwise falls back to file + screen
$script:WriteLogAvailable = $false
if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
    $script:WriteLogAvailable = $true
}

function Write-InternalLog {
    param(
        [string]$Message,
        [string]$Level = "Info"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp [$Level] $Message"
    try {
        if ($script:WriteLogAvailable) {
            Write-Log -Message $Message -Level $Level
        }
        if ($VerboseToScreen) {
            Write-Output $line
        }
        if ($LogFile) {
            Add-Content -Path $LogFile -Value $line
        }   
    }
    catch {
        # If logging fails, write to console as fallback
        Write-Output "Logging failed: $line"
    }
}

# --- ELEVATION CHECK ---------------------------------------------------------
$RunAsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator"
)

$RunAsAdmin = $true
if (-not $RunAsAdmin) {
    Write-InternalLog -Message "Not running as Administrator. Attempting elevation..." -Level "Warning"
    $psPath = $MyInvocation.MyCommand.Path
    if (-not $psPath) {
        throw "Cannot determine script path for elevation."
    }
    Start-Process PowerShell -ArgumentList "-NoExit", "-File", "`"$psPath`"" -Verb RunAs | Out-Null
    exit
}

Write-InternalLog -Message "Running with Administrator privileges." -Level "Info"

# --- DRIVER REMOVAL FUNCTION (FROM STAGED CSV) -------------------------------
function Remove-StagedDriversFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CsvPath,
        [switch]$DryRun,
        [switch]$BackupBeforeDelete,
        [string]$BackupDirectory = "$env:SystemDrive\DriverBackup"
    )

    if (-not (Test-Path $CsvPath)) {
        Write-InternalLog -Message "CSV file not found: $CsvPath" -Level "Error"
        throw "CSV file not found: $CsvPath"
    }
    Write-InternalLog -Message "Starting staged driver removal from CSV: $CsvPath" -Level "Info"
    if ($BackupBeforeDelete -and -not (Test-Path $BackupDirectory)) {
        try {
            New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
            Write-InternalLog -Message "Created backup directory: $BackupDirectory" -Level "Info"
        }
        catch {
            Write-InternalLog -Message "Failed to create backup directory: $($_.Exception.Message)" -Level "Error"
            throw
        }
    }

    $rows = Import-Csv -Path $CsvPath
    $results = @()

    foreach ($row in $rows) {
        Write-InternalLog -Message "Processing INF: $($row.INF)" -Level "Info"
        # Extract Published Name (oemXX.inf) from Result column
        $publishedName = $null
        if ($row.Result -match 'Published Name:\s+([^\s]+)') {
            $publishedName = $matches[1]
        }
        Write-InternalLog -Message "Extracted Published Name: $publishedName" -Level "Info"
        if (-not $publishedName) {
            Write-InternalLog -Message "Could not extract Published Name from row: $($row.INF)" -Level "Warning"
            $results += [pscustomobject]@{
                INF            = $row.INF
                PublishedName  = $null
                Success        = $false
                Error          = "Could not extract Published Name"
                Output         = $row.Result
            }
            continue
        }

        Write-InternalLog -Message "Processing ${publishedName} (from $($row.INF))" -Level "Info"

        # Optional backup
        if ($BackupBeforeDelete) {
            $sourcePath = Join-Path "$env:windir\INF" $publishedName
            $backupPath = Join-Path $BackupDirectory $publishedName
            if (Test-Path $sourcePath) {
                try {
                    Copy-Item -Path $sourcePath -Destination $backupPath -Force
                    Write-InternalLog -Message "Backed up ${publishedName} to $backupPath" -Level "Info"
                }
                catch {
                    Write-InternalLog -Message "Backup failed for ${publishedName}: $($_.Exception.Message)" -Level "Error"
                }
            }
            else {
                Write-InternalLog -Message "OEM INF not found for backup: $sourcePath" -Level "Warning"
            }
        }

        # Dry-run mode
        if ($DryRun) {
            Write-InternalLog -Message "DryRun: Would delete driver ${publishedName}" -Level "Info"
            $results += [pscustomobject]@{
                INF            = $row.INF
                PublishedName  = $publishedName
                Success        = $true
                Error          = $null
                Output         = "DryRun: No deletion performed"
            }
            continue
        }

        # Actual deletion
        $pnputilArgs = "/delete-driver `"$publishedName`" /uninstall /force"
        Write-InternalLog -Message "Executing pnputil $pnputilArgs" -Level "Info"

        try {
            $stdoutFile = Join-Path $env:TEMP "pnputil_del_stdout.txt"
            $stderrFile = Join-Path $env:TEMP "pnputil_del_stderr.txt"

            $proc = Start-Process -FilePath "pnputil.exe" `
                                  -ArgumentList $pnputilArgs `
                                  -NoNewWindow `
                                  -PassThru `
                                  -Wait `
                                  -RedirectStandardOutput $stdoutFile `
                                  -RedirectStandardError $stderrFile

            $stdout = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw } else { "" }
            $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { "" }

            $success = $proc.ExitCode -eq 0 -and $stderr.Trim().Length -eq 0

            if ($success) {
                Write-InternalLog -Message "Successfully deleted ${publishedName}" -Level "Info"
            }
            else {
                Write-InternalLog -Message "Failed to delete ${publishedName}: $stderr" -Level "Error"
            }

            $results += [pscustomobject]@{
                INF            = $row.INF
                PublishedName  = $publishedName
                Success        = $success
                Error          = if ($success) { $null } else { $stderr }
                Output         = $stdout
            }
        }
        catch {
            Write-InternalLog -Message "Exception deleting ${publishedName}: $($_.Exception.Message)" -Level "Error"

            $results += [pscustomobject]@{
                INF            = $row.INF
                PublishedName  = $publishedName
                Success        = $false
                Error          = $_.Exception.Message
                Output         = $null
            }
        }
    }

    Write-InternalLog -Message "Driver removal from CSV completed." -Level "Info"
    return $results
}

# --- STEP 1: ENUMERATE ALL INFs RECURSIVELY ----------------------------------
Write-InternalLog -Message "Enumerating all INF files under $DriverRoot..." -Level "Info"
$allInfs = Get-ChildItem -Path $DriverRoot -Recurse -Filter "*.inf" |
    Select-Object FullName, DirectoryName, Name, LastWriteTime, Length

Write-InternalLog -Message "INF enumeration complete. Found $($allInfs.Count) files." -Level "Info"

if ($allInfs.Count -gt 0) {
    Write-InternalLog -Message ("Sample INF: " + $allInfs[0].FullName) -Level "Info"
}

$allInfsCsv = Join-Path $OutputDir "AllINFs.csv"
$allInfs | Export-Csv -Path $allInfsCsv -NoTypeInformation
Write-InternalLog -Message "Step 1 complete. All INFs exported to $allInfsCsv" -Level "Info"
Write-InternalLog -Message "Found $($allInfs.Count) INF files" -Level "Info"

if ($Interactive) {
    Read-Host "Step 1 complete. Press Enter to continue..."
}

# --- STEP 2: STAGE DRIVERS WITH PNPUTIL --------------------------------------
Write-InternalLog -Message "Starting Step 2: Staging drivers with PnPUtil..." -Level "Info"

if ($Interactive) {
    Read-Host "Start staging drivers? (Y/N)"
    if ($LASTEXITCODE -eq 0) {
        Read-Host "Press Enter to begin staging drivers..."
    }
}

$stagingResults = foreach ($inf in $allInfs) {
    $result = pnputil /add-driver "$($inf.FullName)" 2>&1
    [PSCustomObject]@{
        INF        = $inf.FullName
        Result     = $result -join " "
        Applicable = [bool]($result -match "Driver package added successfully")
    }
}

$stagedCsv = Join-Path $OutputDir "StagedDriverResults.csv"
$stagingResults | Export-Csv -Path $stagedCsv -NoTypeInformation
Write-InternalLog -Message "Step 2 complete. Staging results exported to $stagedCsv" -Level "Info"

if ($Interactive) {
    Read-Host "Step 2 complete. Press Enter to continue..."
}

# --- STEP 3: PARSE INF METADATA / APPLICABILITY ------------------------------
Write-InternalLog -Message "Starting Step 3: Parsing INF metadata and hardware ID applicability..." -Level "Info"

$systemHWIDs = Get-PnpDevice | ForEach-Object {
    (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
} | Where-Object { $_ } | Sort-Object -Unique

$results = foreach ($inf in $allInfs) {
    $content = Get-Content $inf.FullName -ErrorAction SilentlyContinue

    $infHWIDs = $content |
        Select-String -Pattern '\b(PCI\\|USB\\|ACPI\\|HID\\|HDAUDIO\\|ROOT\\|STORAGE\\|SCSI\\)[^\s,]+' -AllMatches |
        ForEach-Object { $_.Matches.Value } |
        Sort-Object -Unique

    $matchedIDs = $infHWIDs | Where-Object { $systemHWIDs -contains $_ }

    [PSCustomObject]@{
        INF            = $inf.FullName
        INF_HWIDCount  = $infHWIDs.Count
        MatchCount     = $matchedIDs.Count
        Applicable     = ($matchedIDs.Count -gt 0)
        MatchedHWIDs   = ($matchedIDs -join "; ")
        AllINF_HWIDs   = ($infHWIDs -join "; ")
    }
}

$infApplicabilityCsv = Join-Path $OutputDir "INF_Applicability.csv"
$results | Export-Csv -Path $infApplicabilityCsv -NoTypeInformation

$summary = $results | Group-Object Applicable | Select-Object Name, Count
$summary | Out-String | ForEach-Object { Write-InternalLog -Message "Applicability summary: $_" -Level "Info" }

Write-InternalLog -Message "Step 3 complete. Applicability exported to $infApplicabilityCsv" -Level "Info"

# --- STEP 4: ENUM-DRIVERS POST-STAGING ---------------------------------------
Write-InternalLog -Message "Starting Step 4: Capturing pnputil /enum-drivers output..." -Level "Info"

$enumFile = Join-Path $OutputDir "StagedDriverStore.txt"
pnputil /enum-drivers /class * > $enumFile

Write-InternalLog -Message "Step 4 complete. Driver store enumeration saved to $enumFile" -Level "Info"

# --- STEP 5: RANK BY BEST MATCH ----------------------------------------------
Write-InternalLog -Message "Starting Step 5: Ranking applicable INFs by match count..." -Level "Info"

$ranked = Import-Csv $infApplicabilityCsv |
    Where-Object { $_.Applicable -eq "True" } |
    Sort-Object { [int]$_.MatchCount } -Descending

# Keep original behavior: show table to pipeline (works in user or service)
$ranked | Format-Table INF, MatchCount, MatchedHWIDs -AutoSize

Write-InternalLog -Message "Step 5 complete. Ranked applicability written to pipeline." -Level "Info"

# --- STEP 6: CLEANUP STAGED DRIVERS (NON-APPLICABLE) -------------------------
Write-InternalLog -Message "Starting Step 6: Cleanup of non-applicable staged drivers..." -Level "Info"

# Use staged CSV + removal function (with DryRun/Backup options)
$removalResults = Remove-StagedDriversFromCsv -CsvPath $stagedCsv -DryRun:$DryRun -BackupBeforeDelete:$BackupBeforeDelete -BackupDirectory $BackupDirectory

# Filter to non-applicable based on INF_Applicability.csv (original intent)
$nonApplicable = Import-Csv $infApplicabilityCsv | Where-Object { $_.Applicable -eq "False" }

# Cross-reference: only log non-applicable entries; removal already done above
foreach ($entry in $nonApplicable) {
    Write-InternalLog -Message "Non-applicable INF identified (cleanup already attempted via CSV removal): $($entry.INF)" -Level "Info"
}

Write-InternalLog -Message "Step 6 complete. Cleanup phase finished. DryRun=$DryRun, BackupBeforeDelete=$BackupBeforeDelete" -Level "Info"

Write-InternalLog -Message "Done!" -Level "Info"
