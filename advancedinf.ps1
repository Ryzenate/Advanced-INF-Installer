#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\DriverWorkflow.config.json"
)

# NF NOTES:
# $env:SESSIONNAME ("Services" for service sessions, "Console" for interactive) can help detect if running in a service context
# $PSCommandPath: Contains the full path and filename of the script being executed, whereas $PSScriptRoot only contains the directory.
#  Using $PSCommandPath allows the script to re-launch itself with elevation if needed, even when the script is invoked from a different working directory.
# $PWD: Contains the path of the current working directory (Present Working Directory). Note that this may be different from the directory
# $HOME: Contains the full path to the user's home directory (e.g., C:\Users\UserName)
# $MyInvocation.MyCommand.Path: Contains the full path and filename of the script being executed. Similar to $PSCommandPath, but works in more contexts (like when dot-sourcing the script). This is often the most reliable way to get the script's own path for re-launching with elevation.
# $PROFILE: Contains the full path to the current PowerShell profile for the user and the host application.
# $PSHOME: The full path to the PowerShell installation directory (e.g., C:\Windows\System32\WindowsPowerShell\v1.0)

$ErrorActionPreference = "SilentlyContinue"

# ---------------- LOAD CONFIG (JSON) ----------------
$defaultConfig = @{
    DriverRoot        = "C:\Drivers"
    DryRunStaging     = $true
    DryRunRemoval     = $true
    BackupBeforeDelete= $false
    VerboseToScreen   = $true
}

$config = $defaultConfig.Clone()

if (Test-Path -Path $ConfigPath) {
    try {
        $json = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        foreach ($key in $json.PSObject.Properties.Name) {
            $config[$key] = $json.$key
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
    try {
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
    catch {
        Write-Output "Logging failed: $($_.Exception.Message)"
    }
}

Write-InternalLog -Message "Session started. Output directory: $SessionDir" -Level "Info"

# ---------------- ELEVATION CHECK (USER MODE ONLY) ----------------
$RunAsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator"
)

$runningInService = $env:SESSIONNAME -eq "Services"

if (-not $RunAsAdmin -and -not $runningInService) {
    Write-InternalLog -Message "Not running as Administrator. Attempting elevation..." -Level "Warning"
    $psPath = $MyInvocation.MyCommand.Path
    if ($psPath) {
        Start-Process PowerShell -ArgumentList "-NoExit", "-File", "`"$psPath`"", "-ConfigPath", "`"$ConfigPath`"" -Verb RunAs | Out-Null
        exit
    }
}
Write-InternalLog -Message "Running with Administrator privileges." -Level "Info"

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

    if ($stdout) { Write-InternalLog -Message "PnPUtil ($Stage$Tag) STDOUT: $stdout" -Level "Info" }
    if ($stderr) { Write-InternalLog -Message "PnPUtil ($Stage$Tag) STDERR: $stderr" -Level "Error" }

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        StdOutFile = $stdoutFile
        StdErrFile = $stderrFile
    }
}

# ---------------- DRIVER REMOVAL FUNCTION ----------------
function Remove-StagedDriversFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CsvPath,

        [switch]$DryRun,

        [switch]$BackupBeforeDelete
    )

    if (-not (Test-Path $CsvPath)) {
        Write-InternalLog -Message "CSV file not found: $CsvPath" -Level "Error"
        throw "CSV file not found: $CsvPath"
    }

    Write-InternalLog -Message "Starting staged driver removal from CSV: $CsvPath" -Level "Info"

    $BackupDir = Join-Path $SessionDir "Backup"
    if ($BackupBeforeDelete -and -not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        Write-InternalLog -Message "Created backup directory: $BackupDir" -Level "Info"
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
            continue
        }

        Write-InternalLog -Message "Processing removal for $publishedName" -Level "Info"

        if ($BackupBeforeDelete) {
            $sourcePath = Join-Path "$env:windir\INF" $publishedName
            $backupPath = Join-Path $BackupDir $publishedName

            if (Test-Path $sourcePath) {
                Copy-Item -Path $sourcePath -Destination $backupPath -Force
                Write-InternalLog -Message "Backed up $publishedName to $backupPath" -Level "Info"
            }
        }

        if ($DryRun) {
            Write-InternalLog -Message "DryRunRemoval: Would delete $publishedName" -Level "Info"
            continue
        }

        $pnpArgs = "/delete-driver `"$publishedName`" /uninstall /force"
        Invoke-PnpUtil -Arguments $pnpArgs -Stage "Removal" -Tag ("_" + $publishedName)
    }

    Write-InternalLog -Message "Driver removal from CSV completed." -Level "Info"
}

# ---------------- STEP 1: ENUMERATE INFs ----------------
Write-InternalLog -Message "Step 1: Enumerating all INF files under $DriverRoot..." -Level "Info"

$allInfs = Get-ChildItem -Path $DriverRoot -Recurse -Filter "*.inf" |
    Select-Object FullName, DirectoryName, Name, LastWriteTime, Length

$allInfsCsv = Join-Path $SessionDir "AllINFs.csv"
$allInfs | Export-Csv -Path $allInfsCsv -NoTypeInformation

Write-InternalLog -Message "Found $($allInfs.Count) INFs. Exported to $allInfsCsv" -Level "Info"

# ---------------- STEP 2: STAGE DRIVERS ----------------
Write-InternalLog -Message "Step 2: Staging drivers. DryRunStaging=$DryRunStaging" -Level "Info"

$stagingResults = foreach ($inf in $allInfs) {
    if ($DryRunStaging) {
        Write-InternalLog -Message "DryRunStaging: Would stage $($inf.FullName)" -Level "Info"
        [PSCustomObject]@{
            INF        = $inf.FullName
            Result     = "DryRunStaging: No staging performed"
            Applicable = $false
        }
    }
    else {
        $invokeArgs = "/add-driver `"$($inf.FullName)`""
        $invokeResult = Invoke-PnpUtil -Arguments $invokeArgs -Stage "Staging" -Tag ("_" + $inf.Name)

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
Write-InternalLog -Message "Step 3: Parsing INF metadata..." -Level "Info"

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
Write-InternalLog -Message "INF applicability exported to $infApplicabilityCsv" -Level "Info"

# ---------------- STEP 4: ENUM-DRIVERS ----------------
Write-InternalLog -Message "Step 4: Running pnputil /enum-drivers..." -Level "Info"

$enumResult = Invoke-PnpUtil -Arguments "/enum-drivers /class *" -Stage "EnumDrivers"
$enumFile = Join-Path $SessionDir "StagedDriverStore.txt"
Set-Content -Path $enumFile -Value $enumResult.StdOut

Write-InternalLog -Message "Driver store enumeration saved to $enumFile" -Level "Info"

# ---------------- STEP 5: RANK BY BEST MATCH ----------------
Write-InternalLog -Message "Step 5: Ranking applicable INFs..." -Level "Info"

$ranked = Import-Csv $infApplicabilityCsv |
    Where-Object { $_.Applicable -eq "True" } |
    Sort-Object { [int]$_.MatchCount } -Descending

$rankedCsv = Join-Path $SessionDir "INF_Applicability_Ranked.csv"
$ranked | Export-Csv -Path $rankedCsv -NoTypeInformation

Write-InternalLog -Message "Ranked applicability exported to $rankedCsv" -Level "Info"

# ---------------- STEP 6: CLEANUP NON-APPLICABLE ----------------
Write-InternalLog -Message "Step 6: Cleanup. DryRunRemoval=$DryRunRemoval BackupBeforeDelete=$BackupBeforeDelete" -Level "Info"

Remove-StagedDriversFromCsv -CsvPath $stagedCsv -DryRun:$DryRunRemoval -BackupBeforeDelete:$BackupBeforeDelete

Write-InternalLog -Message "Workflow complete." -Level "Info"
