param(
    [string]$Python = "python",
    [string]$TectonicExe = "",
    [string]$InnoCompiler = "",
    [string]$ReleaseDirectory = "",
    [switch]$SkipDependencyInstall
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}
Set-Location $PSScriptRoot

function Assert-LastExit($step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$step failed with exit code $LASTEXITCODE"
    }
}

if (-not $SkipDependencyInstall) {
    & $Python -m pip install --disable-pip-version-check -r requirements-dev.txt
    Assert-LastExit "pip install"
}
& $Python -m pytest -q
Assert-LastExit "pytest"

if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'Release' }
$outputDir = [System.IO.Path]::GetFullPath($ReleaseDirectory)
$buildStage = Join-Path $PSScriptRoot 'build\release'
New-Item -ItemType Directory -Path $buildStage, $outputDir -Force | Out-Null
$exeHash = 'A0A9A5EAF1A940D9A615AD78D35225CA59420C7984576C6402FFFB3E9FB05CEB'
if (-not $TectonicExe) {
    $zip = Join-Path $buildStage 'tectonic-x64.zip'
    $uri = 'https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%400.16.9/tectonic-0.16.9-x86_64-pc-windows-msvc.zip'
    Invoke-WebRequest -Uri $uri -OutFile $zip -UseBasicParsing
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne '131A24604785A9600989A3D91225F597DF52AC06F00AEFFE86FD529F99EE5CDD') {
        throw 'Tectonic archive SHA-256 mismatch'
    }
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $buildStage 'tectonic') -Force
    $TectonicExe = Join-Path $buildStage 'tectonic\tectonic.exe'
}
if ((Get-FileHash -LiteralPath $TectonicExe -Algorithm SHA256).Hash -ne $exeHash) { throw 'Tectonic executable SHA-256 mismatch' }
$env:GAOWENJIAN_TECTONIC = (Resolve-Path -LiteralPath $TectonicExe).Path
$env:GAOWENJIAN_BUILD_STAGE = $buildStage
$architecture = & $Python -c "import platform; print(platform.machine())"
Assert-LastExit 'architecture check'
if ($architecture -ne 'AMD64') { throw "Expected x64 CPython, got $architecture" }
& $Python prepare_package.py $buildStage
Assert-LastExit 'package metadata'
& $Python -m PyInstaller --noconfirm --clean --distpath dist --workpath build/freeze gaowenjian.spec
Assert-LastExit 'PyInstaller'

if (-not $InnoCompiler) {
    $found = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($found) { $InnoCompiler = $found.Source }
    else { $InnoCompiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
}
if (-not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) { throw 'Inno Setup 6 ISCC.exe was not found. Pass -InnoCompiler.' }
$releaseVersion = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\VERSION')).Trim()
$windowsVersion = & $Python -c "from runpy import run_path; print(run_path('src/gaowenjian/version.py')['VERSION_LABEL'])"
Assert-LastExit 'Windows version check'
$windowsMarketing, $windowsBuild = $windowsVersion -split '\+', 2
if ($windowsMarketing -ne $releaseVersion -or $windowsBuild -notmatch '^\d+$') { throw "Windows version $windowsVersion disagrees with VERSION $releaseVersion" }
$program = (Resolve-Path -LiteralPath 'dist\GaoWenJian').Path
$appIcon = Join-Path $buildStage 'app.ico'
$parameters = @('/Qp', "/DAppVersion=$releaseVersion", "/DWindowsBuild=$windowsBuild", "/DBuildDirectory=$program", "/DReleaseDirectory=$outputDir", "/DAppIcon=$appIcon", 'setup.iss')
& $InnoCompiler @parameters
Assert-LastExit 'Inno Setup'
$filename = "GaoWenJian-Windows-$releaseVersion-build$windowsBuild-x64-Setup.exe"
$installer = Join-Path $outputDir $filename
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$installer.sha256", "$hash  $filename`n", [Text.UTF8Encoding]::new($false))
Write-Output $installer
Write-Output "$installer.sha256"
