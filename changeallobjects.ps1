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

Add-Type -AssemblyName System.IO.Compression.FileSystem

$ObjectTypes = @("AV", "BV", "AI", "BI", "AO", "BO")
$Pattern = '(?i)\b(?<Type>AV|BV|AI|BI|AO|BO)-(?<Number>\d+)\b'

$ObjectMap = @{}
$Counters = @{}

foreach ($type in $ObjectTypes) {
    $Counters[$type] = 0
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$folder = [System.IO.Path]::GetDirectoryName($VisioFile)
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($VisioFile)

$backupFile = Join-Path $folder "$baseName`_BACKUP_$timestamp.vsdx"
$tempFolder = Join-Path $env:TEMP "VisioObjectRenumber_$timestamp"
$newFile = Join-Path $folder "$baseName`_RENAMED_$timestamp.vsdx"
$mapFile = Join-Path $folder "ObjectRenumberMap_$timestamp.csv"

function Add-Objects-ToMap {
    param (
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $matches = [regex]::Matches($Text, $Pattern)

    foreach ($match in $matches) {
        $oldValue = $match.Value.ToUpper()
        $type = $match.Groups["Type"].Value.ToUpper()

        if (-not $ObjectMap.ContainsKey($oldValue)) {
            $newValue = "$type-$($Counters[$type])"
            $ObjectMap[$oldValue] = $newValue
            $Counters[$type]++
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

        $oldValue = $match.Value.ToUpper()

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
    Write-Host "Scanning XML for object values..."

    $xmlFiles = Get-ChildItem $tempFolder -Recurse -File |
        Where-Object {
            $_.Extension -in ".xml", ".rels"
        } |
        Sort-Object FullName

    foreach ($file in $xmlFiles) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        Add-Objects-ToMap -Text $content
    }

    Write-Host ""
    Write-Host "Unique objects found: $($ObjectMap.Count)"

    if ($ObjectMap.Count -eq 0) {
        Write-Host ""
        Write-Host "No AV/BV/AI/BI/AO/BO values were found." -ForegroundColor Yellow
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
            $matchesBefore = [regex]::Matches($oldContent, $Pattern).Count
            [System.IO.File]::WriteAllText($file.FullName, $newContent, [System.Text.Encoding]::UTF8)
            $filesChanged++
            $totalReplacements += $matchesBefore
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
    if (Test-Path $tempFolder) {
        Remove-Item $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Script finished."
}