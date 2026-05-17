#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\DriverWorkflow.config.psd1"
)

$ErrorActionPreference = "SilentlyContinue"

# ---------------- CONFIG LOADING ----------------
$defaultConfig = @{
    DriverRoot        = "B:\src_b2\WORK\NewWay2inf\asuschipset\Driversonly"
    DryRunStaging     = $false
    DryRunRemoval     = $false
    BackupBeforeDelete= $false
    VerboseToScreen   = $false
}

$config = $defaultConfig.Clone()

if (Test-Path -Path $ConfigPath) {
    try {
        $fileConfig = Import-PowerShellDataFile -Path $ConfigPath
        foreach ($key in $fileConfig.Keys) {
            $config[$key] = $fileConfig[$key]
        }
    }
    catch {
        Write-Output "Failed to load config file '$ConfigPath': $($_.Exception.Message). Using defaults."
    }
}

$DriverRoot         = $config.DriverRoot
$DryRunStaging      = [bool]$config.DryRunStaging
$DryRunRemoval      = [bool]$config.DryRunRemoval
$BackupBeforeDelete = [bool]$config.BackupBeforeDelete
$VerboseToScreen    = [bool]$config.VerboseToScreen

# ---------------- OUTPUT / SESSION FOLDERS ----------------
$OutputRoot = Join-Path $PSScriptRoot "OUTPUT"
if (-not (Test-Path -Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$sessionStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$SessionDir   = Join-Path $OutputRoot $sessionStamp
New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null

$LogFile = Join-Path $SessionDir "DriverWorkflow.log"

# ---------------- LOGGING ----------------
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

    if ($script:WriteLogAvailable) {
        Write-Log -Message $Message -Level $Level
    }

    if ($VerboseToScreen) {
        Write-Output $line
    }

    Add-Content -Path $LogFile -Value $line
}

Write-InternalLog -Message "Session started. Output directory: $SessionDir" -Level "Info"

# ---------------- ELEVATION CHECK (USER MODE ONLY) ----------------
$RunAsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator"
)

if (-not $RunAsAdmin) {
    # In service mode, this should already be elevated; this block will only run in user mode
    Write-InternalLog -Message "Not running as Administrator. Attempting elevation..." -Level "Warning"
    $psPath = $MyInvocation.MyCommand.Path
    if ($psPath) {
        Start-Process PowerShell -ArgumentList "-NoExit", "-File", "`"$psPath`"", "-ConfigPath", "`"$ConfigPath`"" -Verb RunAs | Out-Null
        exit
    }
    else {
        Write-InternalLog -Message "Cannot determine script path for elevation. Continuing without elevation." -Level "Error"
    }
}
else {
    Write-InternalLog -Message "Running with Administrator privileges." -Level "Info"
}

# ---------------- HELPER: RUN PNPUTIL WITH LOGGING ----------------
function Invoke-PnpUtil {
    param(
        [Parameter(Mandatory=$true)][string]$Arguments,
        [string]$Stage = "General",
        [string]$Tag   = ""
    )

    $stdoutFile = Join-Path $SessionDir ("PnPUtil_{0}_{1}_stdout.txt" -f $Stage, ([guid]::NewGuid().ToString("N")))
    $stderrFile = Join-Path $SessionDir ("PnPUtil_{0}_{1}_stderr.txt" -f $Stage, ([guid]::NewGuid().ToString("N")))

    Write-InternalLog -Message "PnPUtil ($Stage$Tag): pnputil $Arguments" -Level "Info"

    $proc = Start-Process -FilePath "pnputil.exe" `
                          -ArgumentList $Arguments `
                          -NoNewWindow `
                          -PassThru ` 
                          -Wait `  
                          -RedirectStandardOutput $stdoutFile `
                          -RedirectStandardError  $stderrFile

    $stdout = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw } else { "" }
    $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { "" }

    if ($stdout) {
        Write-InternalLog -Message "PnPUtil ($Stage$Tag) STDOUT: $stdout" -Level "Info"
    }
    if ($stderr) {
        Write-InternalLog -Message "PnPUtil ($Stage$Tag) STDERR: $stderr" -Level "Error"
    }

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        StdOutFile = $stdoutFile
        StdErrFile = $stderrFile
    }
}

# ---------------- DRIVER REMOVAL FROM CSV ----------------
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

        $publishedName = $null
        if ($row.Result -match 'Published Name:\s+([^\s]+)') {
            $publishedName = $matches[1]
        }

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

        Write-InternalLog -Message "Processing removal for $publishedName (from $($row.INF))" -Level "Info"

        if ($BackupBeforeDelete) {
            $sourcePath = Join-Path "$env:windir\INF" $publishedName
            $backupPath = Join-Path $BackupDirectory $publishedName

            if (Test-Path $sourcePath) {
                try {
                    Copy-Item -Path $sourcePath -Destination $backupPath -Force
                    Write-InternalLog -Message "Backed up $publishedName to $backupPath" -Level "Info"
                }
                catch {
                    Write-InternalLog -Message "Backup failed for ${publishedName}: $($_.Exception.Message)" -Level "Error"
                }
            }
            else {
                Write-InternalLog -Message "OEM INF not found for backup: $sourcePath" -Level "Warning"
            }
        }

        if ($DryRun) {
            Write-InternalLog -Message "DryRunRemoval: Would delete driver ${publishedName}" -Level "Info"
            $results += [pscustomobject]@{
                INF            = $row.INF
                PublishedName  = $publishedName
                Success        = $true
                Error          = $null
                Output         = "DryRunRemoval: No deletion performed"
            }
            continue
        }

        $pnpArgs = "/delete-driver `"$publishedName`" /uninstall /force"
        $invokeResult = Invoke-PnpUtil -Arguments $pnpArgs -Stage "Removal" -Tag ("_" + $publishedName)

        $success = ($invokeResult.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($invokeResult.StdErr))

        if ($success) {
            Write-InternalLog -Message "Successfully deleted ${publishedName}" -Level "Info"
        }
        else {
            Write-InternalLog -Message "Failed to delete ${publishedName}. ExitCode=$($invokeResult.ExitCode)" -Level "Error"
        }

        $results += [pscustomobject]@{
            INF            = $row.INF
            PublishedName  = $publishedName
            Success        = $success
            Error          = if ($success) { $null } else { $invokeResult.StdErr }
            Output         = $invokeResult.StdOut
        }
    }

    Write-InternalLog -Message "Driver removal from CSV completed." -Level "Info"
    return $results
}

# ---------------- STEP 1: ENUMERATE INFs ----------------
Write-InternalLog -Message "Step 1: Enumerating all INF files under $DriverRoot..." -Level "Info"

$allInfs = Get-ChildItem -Path $DriverRoot -Recurse -Filter "*.inf" |
    Select-Object FullName, DirectoryName, Name, LastWriteTime, Length

Write-InternalLog -Message "INF enumeration complete. Found $($allInfs.Count) files." -Level "Info"

if ($allInfs.Count -gt 0) {
    Write-InternalLog -Message ("Sample INF: " + $allInfs[0].FullName) -Level "Info"
}

$allInfsCsv = Join-Path $SessionDir "AllINFs.csv"
$allInfs | Export-Csv -Path $allInfsCsv -NoTypeInformation
Write-InternalLog -Message "All INFs exported to $allInfsCsv" -Level "Info"

# ---------------- STEP 2: STAGE DRIVERS ----------------
Write-InternalLog -Message "Step 2: Staging drivers with PnPUtil. DryRunStaging=$DryRunStaging" -Level "Info"

$stagingResults = foreach ($inf in $allInfs) {
    if ($DryRunStaging) {
        Write-InternalLog -Message "DryRunStaging: Would stage driver $($inf.FullName)" -Level "Info"
        [PSCustomObject]@{
            INF        = $inf.FullName
            Result     = "DryRunStaging: No staging performed"
            Applicable = $false
        }
    }
    else {
        $pnpArgs = "/add-driver `"$($inf.FullName)`""
        $invokeResult = Invoke-PnpUtil -Arguments $pnpArgs -Stage "Staging" -Tag ("_" + $inf.Name)

        $applicable = ($invokeResult.StdOut -match "Driver package added successfully")

        [PSCustomObject]@{
            INF        = $inf.FullName
            Result     = ($invokeResult.StdOut + " " + $invokeResult.StdErr).Trim()
            Applicable = [bool]$applicable
        }
    }
}

$stagedCsv = Join-Path $SessionDir "StagedDriverResults.csv"
$stagingResults | Export-Csv -Path $stagedCsv -NoTypeInformation
Write-InternalLog -Message "Staging results exported to $stagedCsv" -Level "Info"

# ---------------- STEP 3: INF METADATA / APPLICABILITY ----------------
Write-InternalLog -Message "Step 3: Parsing INF metadata and hardware ID applicability..." -Level "Info"

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

$infApplicabilityCsv = Join-Path $SessionDir "INF_Applicability.csv"
$results | Export-Csv -Path $infApplicabilityCsv -NoTypeInformation

$summary = $results | Group-Object Applicable | Select-Object Name, Count
$summary | ForEach-Object { Write-InternalLog -Message ("Applicability summary: " + ($_ | Out-String).Trim()) -Level "Info" }

Write-InternalLog -Message "INF applicability exported to $infApplicabilityCsv" -Level "Info"

# ---------------- STEP 4: ENUM-DRIVERS ----------------
Write-InternalLog -Message "Step 4: Capturing pnputil /enum-drivers output..." -Level "Info"

$enumFile = Join-Path $SessionDir "StagedDriverStore.txt"
$enumResult = Invoke-PnpUtil -Arguments "/enum-drivers /class *" -Stage "EnumDrivers"
Set-Content -Path $enumFile -Value $enumResult.StdOut
Write-InternalLog -Message "Driver store enumeration saved to $enumFile" -Level "Info"

# ---------------- STEP 5: RANK BY BEST MATCH ----------------
Write-InternalLog -Message "Step 5: Ranking applicable INFs by match count..." -Level "Info"

$ranked = Import-Csv $infApplicabilityCsv |
    Where-Object { $_.Applicable -eq "True" } |
    Sort-Object { [int]$_.MatchCount } -Descending

$rankedCsv = Join-Path $SessionDir "INF_Applicability_Ranked.csv"
$ranked | Export-Csv -Path $rankedCsv -NoTypeInformation
Write-InternalLog -Message "Ranked applicability exported to $rankedCsv" -Level "Info"

# ---------------- STEP 6: CLEANUP NON-APPLICABLE STAGED DRIVERS ----------------
Write-InternalLog -Message "Step 6: Cleanup of non-applicable staged drivers. DryRunRemoval=$DryRunRemoval BackupBeforeDelete=$BackupBeforeDelete" -Level "Info"

$removalResults = Remove-StagedDriversFromCsv -CsvPath $stagedCsv -DryRun:$DryRunRemoval -BackupBeforeDelete:$BackupBeforeDelete -BackupDirectory (Join-Path $SessionDir "Backup")

$removalCsv = Join-Path $SessionDir "RemovalResults.csv"
$removalResults | Export-Csv -Path $removalCsv -NoTypeInformation
Write-InternalLog -Message "Removal results exported to $removalCsv" -Level "Info"

$nonApplicable = Import-Csv $infApplicabilityCsv | Where-Object { $_.Applicable -eq "False" }
foreach ($entry in $nonApplicable) {
    Write-InternalLog -Message "Non-applicable INF identified (cleanup attempted via CSV removal): $($entry.INF)" -Level "Info"
}

Write-InternalLog -Message "Workflow complete." -Level "Info"
