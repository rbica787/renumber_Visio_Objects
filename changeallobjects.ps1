# changeallobjects.ps1
# Renumber Alerton VisualLogic object values directly inside the VSDX XML
# Changes AV-#, BV-#, AI-#, BI-#, AO-#, BO-#
# Leaves BR-# unchanged

$VisioFile = Read-Host "Enter the full path to the Visio file (.vsdx)"
$VisioFile = $VisioFile.Trim('"')

while (-not (Test-Path $VisioFile)) {
    Write-Host "File not found. Please enter a valid path." -ForegroundColor Red
    $VisioFile = Read-Host "Enter the full path to the Visio file (.vsdx)"
    $VisioFile = $VisioFile.Trim('"')
}

if ([System.IO.Path]::GetExtension($VisioFile).ToLower() -ne ".vsdx") {
    Write-Host "This script only works on .vsdx files." -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "IMPORTANT: Make sure this Visio file is closed before continuing."
$continue = Read-Host "Type YES to continue"

if ($continue -ne "YES") {
    Write-Host "Canceled."
    exit
}

# ------------------------------------------------------------
# USER OPTIONS
# ------------------------------------------------------------

Write-Host ""
$reserveMicrosets = Read-Host "Reserve microset setpoints? Type YES or NO"

$ReserveMicrosetsEnabled = $false
if ($reserveMicrosets.ToUpper() -eq "YES") {
    $ReserveMicrosetsEnabled = $true
    Write-Host "Microset setpoints will be reserved:"
    Write-Host "Ignoring AV-90 through AV-110"
    Write-Host "Ignoring BV-40"
    Write-Host "Ignoring BV-64 through BV-87"
}

Write-Host ""
$designateChangeRange = Read-Host "Would you like to designate the range of values to change? Type YES or NO"

$UseChangeRange = $false
$ChangeMin = $null
$ChangeMax = $null

if ($designateChangeRange.ToUpper() -eq "YES") {
    $UseChangeRange = $true
    $ChangeMin = [int](Read-Host "Enter the LOWEST existing object number to change")
    $ChangeMax = [int](Read-Host "Enter the HIGHEST existing object number to change")
    Write-Host "Only existing values numbered $ChangeMin through $ChangeMax will be changed."
}

Write-Host ""
$designateAssignRange = Read-Host "Would you like to designate the range of values to assign to? Type YES or NO"

$AssignStart = 0
$AssignEnd = $null
$UseAssignEnd = $false

if ($designateAssignRange.ToUpper() -eq "YES") {
    $AssignStart = [int](Read-Host "Enter the FIRST new number to assign")

    $assignEndInput = Read-Host "Enter the LAST new number to assign, or press ENTER for no limit"

    if (-not [string]::IsNullOrWhiteSpace($assignEndInput)) {
        $AssignEnd = [int]$assignEndInput
        $UseAssignEnd = $true
    }

    if ($UseAssignEnd) {
        Write-Host "New values will be assigned from $AssignStart through $AssignEnd."
    }
    else {
        Write-Host "New values will start at $AssignStart with no upper limit."
    }
}
else {
    Write-Host "New values will start at 0."
}

# ------------------------------------------------------------
# SETUP
# ------------------------------------------------------------

Add-Type -AssemblyName System.IO.Compression.FileSystem

$ObjectTypes = @("AV", "BV", "AI", "BI", "AO", "BO")
$Pattern = '(?i)\b(?<Type>AV|BV|AI|BI|AO|BO)-(?<Number>\d+)\b'

$ObjectMap = @{}
$ExistingObjects = @{}
$AssignedNewObjects = @{}
$Counters = @{}

foreach ($type in $ObjectTypes) {
    $Counters[$type] = $AssignStart
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$folder = [System.IO.Path]::GetDirectoryName($VisioFile)
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($VisioFile)

$backupFile = Join-Path $folder "$baseName`_BACKUP_$timestamp.vsdx"
$tempRoot = [System.IO.Path]::GetTempPath()
$tempFolder = Join-Path $tempRoot "VisioObjectRenumber_$timestamp"
$newFile = Join-Path $folder "$baseName`_RENAMED_$timestamp.vsdx"
$mapFile = Join-Path $folder "ObjectRenumberMap_$timestamp.csv"

function Is-Reserved-Microset {
    param (
        [string]$Type,
        [int]$Number
    )

    $Type = $Type.ToUpper()

    if (-not $ReserveMicrosetsEnabled) {
        return $false
    }

    if ($Type -eq "AV" -and $Number -ge 90 -and $Number -le 110) {
        return $true
    }

    if ($Type -eq "BV" -and $Number -eq 40) {
        return $true
    }

    if ($Type -eq "BV" -and $Number -ge 64 -and $Number -le 87) {
        return $true
    }

    return $false
}

function Should-Skip-Object {
    param (
        [string]$Type,
        [int]$Number
    )

    $Type = $Type.ToUpper()

    if (Is-Reserved-Microset -Type $Type -Number $Number) {
        return $true
    }

    if ($UseChangeRange) {
        if ($Number -lt $ChangeMin -or $Number -gt $ChangeMax) {
            return $true
        }
    }

    return $false
}

function Add-All-Existing-Objects {
    param (
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $matches = [regex]::Matches($Text, $Pattern)

    foreach ($match in $matches) {
        $type = $match.Groups["Type"].Value.ToUpper()
        $number = [int]$match.Groups["Number"].Value
        $value = "$type-$number"

        if (-not $ExistingObjects.ContainsKey($value)) {
            $ExistingObjects[$value] = $true
        }
    }
}

function Get-Next-Available-Value {
    param (
        [string]$Type,
        [string]$OldValue
    )

    $Type = $Type.ToUpper()

    while ($true) {
        if ($UseAssignEnd -and $Counters[$Type] -gt $AssignEnd) {
            throw "Assignment range exceeded for $Type. Not enough available numbers between $AssignStart and $AssignEnd."
        }

        $candidateNumber = $Counters[$Type]
        $candidateValue = "$Type-$candidateNumber"

        $existsAlready = $ExistingObjects.ContainsKey($candidateValue)
        $alreadyAssigned = $AssignedNewObjects.ContainsKey($candidateValue)
        $isReserved = Is-Reserved-Microset -Type $Type -Number $candidateNumber

        if (
            (-not $existsAlready -or $candidateValue -eq $OldValue) -and
            (-not $alreadyAssigned) -and
            (-not $isReserved)
        ) {
            $AssignedNewObjects[$candidateValue] = $true
            $Counters[$Type]++
            return $candidateValue
        }

        Write-Host "Skipping $candidateValue because it already exists or is reserved."
        $Counters[$Type]++
    }
}

function Add-Objects-ToMap {
    param (
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $matches = [regex]::Matches($Text, $Pattern)

    foreach ($match in $matches) {
        $type = $match.Groups["Type"].Value.ToUpper()
        $number = [int]$match.Groups["Number"].Value
        $oldValue = "$type-$number"

        if (Should-Skip-Object -Type $type -Number $number) {
            continue
        }

        if (-not $ObjectMap.ContainsKey($oldValue)) {
            $newValue = Get-Next-Available-Value -Type $type -OldValue $oldValue
            $ObjectMap[$oldValue] = $newValue
        }
    }
}

function Replace-Objects-InText {
    param (
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    return [regex]::Replace($Text, $Pattern, {
        param($match)

        $type = $match.Groups["Type"].Value.ToUpper()
        $number = [int]$match.Groups["Number"].Value
        $oldValue = "$type-$number"

        if ($ObjectMap.ContainsKey($oldValue)) {
            return $ObjectMap[$oldValue]
        }

        return $match.Value
    })
}

try {
    Write-Host ""
    Write-Host "Creating backup..."
    Copy-Item $VisioFile $backupFile -Force
    Write-Host "Backup created:"
    Write-Host $backupFile

    Write-Host ""
    Write-Host "Extracting VSDX..."
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($VisioFile, $tempFolder)

    Write-Host ""
    Write-Host "Scanning XML files..."

    $xmlFiles = Get-ChildItem $tempFolder -Recurse -File |
        Where-Object {
            $_.Extension -in ".xml", ".rels"
        } |
        Sort-Object FullName

    Write-Host "Building list of all existing AV/BV/AI/BI/AO/BO values..."

    foreach ($file in $xmlFiles) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        Add-All-Existing-Objects -Text $content
    }

    Write-Host "Existing object values found: $($ExistingObjects.Count)"

    Write-Host ""
    Write-Host "Creating renumbering map..."

    foreach ($file in $xmlFiles) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        Add-Objects-ToMap -Text $content
    }

    Write-Host ""
    Write-Host "Unique objects selected for renumbering: $($ObjectMap.Count)"

    if ($ObjectMap.Count -eq 0) {
        Write-Host ""
        Write-Host "No eligible AV/BV/AI/BI/AO/BO values were found." -ForegroundColor Yellow
        Write-Host "Nothing was changed."
        exit
    }

    Write-Host ""
    Write-Host "Object mapping:"
    Write-Host "----------------"

    $ObjectMap.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object {
            Write-Host "$($_.Key) -> $($_.Value)"
        }

    Write-Host ""
    Write-Host "Replacing object values inside XML..."

    $filesChanged = 0
    $totalReplacements = 0

    foreach ($file in $xmlFiles) {
        $oldContent = [System.IO.File]::ReadAllText($file.FullName)
        $newContent = Replace-Objects-InText -Text $oldContent

        if ($newContent -ne $oldContent) {
            $beforeMatches = [regex]::Matches($oldContent, $Pattern)

            foreach ($m in $beforeMatches) {
                $type = $m.Groups["Type"].Value.ToUpper()
                $number = [int]$m.Groups["Number"].Value
                $oldValue = "$type-$number"

                if ($ObjectMap.ContainsKey($oldValue)) {
                    $totalReplacements++
                }
            }

            [System.IO.File]::WriteAllText($file.FullName, $newContent, [System.Text.Encoding]::UTF8)
            $filesChanged++
        }
    }

    Write-Host ""
    Write-Host "Files changed: $filesChanged"
    Write-Host "Total object references replaced: $totalReplacements"

    Write-Host ""
    Write-Host "Creating revised VSDX file..."

    if (Test-Path $newFile) {
        Remove-Item $newFile -Force
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempFolder, $newFile)

    $ObjectMap.GetEnumerator() |
        Sort-Object Name |
        Select-Object `
            @{Name="OldValue";Expression={$_.Key}},
            @{Name="NewValue";Expression={$_.Value}} |
        Export-Csv $mapFile -NoTypeInformation

    Write-Host ""
    Write-Host "================================="
    Write-Host "Renumbering complete."
    Write-Host "================================="
    Write-Host "Original file was NOT overwritten:"
    Write-Host $VisioFile
    Write-Host ""
    Write-Host "New revised file:"
    Write-Host $newFile
    Write-Host ""
    Write-Host "Backup file:"
    Write-Host $backupFile
    Write-Host ""
    Write-Host "Mapping CSV:"
    Write-Host $mapFile
}
catch {
    Write-Host ""
    Write-Host "An error occurred:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    Write-Host ""

    try {
        if ([System.IO.Directory]::Exists($tempFolder)) {
            [System.IO.Directory]::Delete($tempFolder, $true)
        }
    }
    catch {
        Write-Host "Temporary extraction folder could not be removed."
        Write-Host $tempFolder
    }

    Write-Host "Script finished."
}
