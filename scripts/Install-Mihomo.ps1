param(
    [Parameter(Mandatory = $true)]
    [string]$Archive
)
$ErrorActionPreference = 'Stop'
$expectedHash = 'cd6738d4648cc1a5f48049a1343b697ab510889d648f045c5c780fc1ab443a79'
$zipPath = (Resolve-Path -LiteralPath $Archive).Path
if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ine $expectedHash) {
    throw 'Archive does not match the official Mihomo v1.19.34 Windows AMD64 compatible release.'
}
$coreDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'app.routepilot.desktop\core'
$destination = Join-Path $coreDir 'mihomo.exe'
if (Test-Path -LiteralPath $destination) {
    throw "An engine already exists at $destination. Leave it unchanged or explicitly replace it after stopping RoutePilot."
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entries = @($zip.Entries | Where-Object { $_.Name -like 'mihomo*.exe' })
    if ($entries.Count -ne 1) { throw 'Expected exactly one Mihomo executable.' }
    New-Item -ItemType Directory -Path $coreDir -Force | Out-Null
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $destination, $false)
} finally {
    $zip.Dispose()
}
Write-Output "Installed verified Mihomo at $destination"
