# Builds the two Nexus Mods archives into dist/, laid out as installed in the game folder.
#   LMRInvestigations-<ver>.zip                main file: the mod
#   LMRInvestigations-LegalitySuite-<ver>.zip  optional file: the test suite
# Usage: powershell -File tools/package.ps1 -Version 2.0.0
param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force $dist | Out-Null

function Build($name, $files) {
    $zip = Join-Path $dist "$name-$Version.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    $z = [IO.Compression.ZipFile]::Open($zip, "Create")
    try {
        # explicit entry names keep "/" separators (PowerShell 5 zips otherwise use "\")
        foreach ($f in $files.GetEnumerator()) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, (Join-Path $root $f.Key), $f.Value)
        }
    } finally { $z.Dispose() }
    Write-Output $zip
}

Build "LMRInvestigations" ([ordered]@{
    "LMRInvestigations.lua" = "reframework/autorun/LMRInvestigations.lua"
})
Build "LMRInvestigations-LegalitySuite" ([ordered]@{
    "LMRI_LegalityTest.lua"        = "reframework/autorun/LMRI_LegalityTest.lua"
    "LMRI_Logic.lua"               = "reframework/data/LMRI_Logic.lua"
    "LMRI_SpOfferProbe.lua"        = "reframework/data/LMRI_SpOfferProbe.lua"
    "data/LMRI_Grounding_Data.lua" = "reframework/data/LMRI_Grounding_Data.lua"
})
