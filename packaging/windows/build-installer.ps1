# Builds the Windows installer (K-252): a release build of the app, then the
# Inno Setup compile of packaging/windows/lumit.iss. Output lands in
# packaging/windows/dist/.
#
# Needs Inno Setup 6 on the PATH (or in its default location):
#   winget install JRSoftware.InnoSetup

$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\..\.."

Push-Location "$root\flutter_ui"
try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }
} finally {
    Pop-Location
}

$iscc = Get-Command iscc -ErrorAction SilentlyContinue
if ($null -eq $iscc) {
    $default = "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe"
    if (Test-Path $default) { $iscc = $default }
    else {
        Write-Error ("Inno Setup not found. Install it with: " +
            "winget install JRSoftware.InnoSetup")
        exit 1
    }
} else {
    $iscc = $iscc.Source
}

& $iscc "$PSScriptRoot\lumit.iss"
if ($LASTEXITCODE -ne 0) { throw "iscc failed" }
Write-Host "Installer written to $PSScriptRoot\dist"
