# silent ignore errors
$ErrorActionPreference = "SilentlyContinue"

# OUTPUT FILE DIR
$outputDir = "C:\Temp"
if (-not (Test-Path -Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp" | Out-Null
}

$RunAsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $RunAsAdmin) {
    Write-Host "Running with Administrator privileges."
    powershell -Command "Start-Process PowerShell -ArgumentList '-NoExit', '-File', '$($MyInvocation.MyCommand.Path)' -Verb RunAs"
    exit
}
# Run as Administrator


# STEPPING THROUGH NEW WAY TO INF

$driverRoot = "B:\src_b2\WORK\NewWay2inf\asuschipset\Driversonly"

#region Step 1: Enumerate All INFs Recursively

# Collect every INF found under a root driver directory
Write-Host "Enumerating all INF files under $driverRoot..."
Write-Host "Scanning for INF files..."
$allInfs = Get-ChildItem -Path $driverRoot -Recurse -Filter "*.inf" |
    Select-Object FullName, DirectoryName, Name, LastWriteTime, Length
Write-Host "INF enumeration complete. Found $($allInfs.Count) files."
Write-Host "Sample INF: $($allInfs[0].FullName)"

# Export to CSV for reference
$allInfs | Export-Csv -Path "$outputDir\AllINFs.csv" -NoTypeInformation
Write-Host "Found $($allInfs.Count) INF files"
#endregion
Write-Host "Step 1 complete. All INFs enumerated and exported to $outputDir\AllINFs.csv"

#region Step 2: Use PnPUtil to Stage & Rank Applicability
# PnPUtil itself has the best built-in method-/add-driver with /install will only apply matching drivers, but for analysis without installing, use the rank/identify approach:
# Dry-run: attempt to add each INF to the driver store (staged only, not installed)
# /add-driver stages it; it won't install unless hardware is present
Write-Host "Starting Step 2: Staging drivers with PnPUtil..."
pause

Write-Host "Staging drivers..."
$stagingResults = foreach ($inf in $allInfs) {
    $result = pnputil /add-driver "$($inf.FullName)" 2>&1
    [PSCustomObject]@{
        INF        = $inf.FullName
        Result     = $result -join " "
        Applicable = $result -match "Driver package added successfully"
    }
}
Write-Host "Staging complete. Review results for applicability."
$stagingResults | Export-Csv -Path "C:\Temp\StagedDriverResults.csv" -NoTypeInformation
#endregion
Write-Host "Step 2 complete. Staging results exported to C:\Temp\StagedDriverResults.csv"
pause

#region Step 3: Parse INF Metadata Without Installing (Preferred for Analysis)
# Read the INF directly to extract [Manufacturer], [Models], and hardware IDs, then compare against devices on your system:
# Get all hardware IDs present on THIS system
$systemHWIDs = Get-PnpDevice | ForEach-Object {
    (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
} | Where-Object { $_ } | Sort-Object -Unique
# Parse each INF for hardware IDs in [Models] sections
$results = foreach ($inf in $allInfs) {
    $content = Get-Content $inf.FullName -ErrorAction SilentlyContinue
    
    # Extract all hardware ID-like strings (HID\, PCI\, USB\, ACPI\, etc.)
    $infHWIDs = $content | Select-String -Pattern '\b(PCI\\|USB\\|ACPI\\|HID\\|HDAUDIO\\|ROOT\\|STORAGE\\|SCSI\\)[^\s,]+' -AllMatches |
        ForEach-Object { $_.Matches.Value } | Sort-Object -Unique

    # Find overlap with system hardware IDs (avoid using automatic $matches variable)
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
$results | Export-Csv -Path "C:\Temp\INF_Applicability.csv" -NoTypeInformation
# Summary
$results | Group-Object Applicable | Select-Object Name, Count
#endregion

#region Step 4: Use pnputil /enum-drivers Post-Staging to Confirm
#After staging, this lists only what Windows accepted into the DriverStore:
pnputil /enum-drivers /class * > "C:\Temp\StagedDriverStore.txt"

#endregion


#region Step 5: Cross-Reference & Rank by Best Match
# Load results and sort by match quality
$ranked = Import-Csv "C:\Temp\INF_Applicability.csv" |
    Where-Object { $_.Applicable -eq "True" } |
    Sort-Object { [int]$_.MatchCount } -Descending

$ranked | Format-Table INF, MatchCount, MatchedHWIDs -AutoSize
#endregion

#region STEP 6 Cleanup (If You Staged Drivers)
# Remove staged drivers that didn't match
$nonApplicable = Import-Csv "C:\Temp\INF_Applicability.csv" |
    Where-Object { $_.Applicable -eq "False" }

foreach ($entry in $nonApplicable) {
    # Get the oemXX.inf name from the driver store if it was staged
    pnputil /delete-driver $entry.INF /uninstall 2>$null
}
#endregion

write-host "Done!"