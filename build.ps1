[CmdletBinding()]
param (
  [Parameter(Mandatory = $true,
    Position = 0,
    HelpMessage = "Path to a JSON installer configuration file.")]
  [Alias("PSPath")]
  [ValidateNotNullOrEmpty()]
  [string]
  $ConfigFile,

  [Parameter(HelpMessage = "Path to MSYS2 installation. MSYS2 will be downloaded and installed to this path if it doesn't exist.")]
  [ValidatePattern('[\\\/]msys64$')]
  [string]
  $MSYS2Path = '.\build\msys64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. "$PSScriptRoot\common.ps1"

Write-Host "Building from $ConfigFile"

$suffix = [io.path]::GetFileNameWithoutExtension($ConfigFile)

$tools = (Get-Content '.\tools.json' | ConvertFrom-Json).tools
$config = Get-Content $ConfigFile | ConvertFrom-Json
$bitness = $config.bitness
$mingw_arch = $config.mingw_arch
$installers = $config.installers

($installers + $tools) | ForEach-Object {
  $_ | Add-Member -NotePropertyName 'shortName' -NotePropertyValue ($_.name -replace '[^a-zA-Z0-9]', '')

  Write-Host "Downloading $($_.name): " -NoNewline
  curl.exe --fail --silent --show-error --url "$($_.href)" --location --output "installers/$($_.file)" --create-dirs --remote-time --time-cond "installers/$($_.file)"

  # Display versions of packaged installers, for information only. We try to
  # extract it from:
  # 1. The file name
  # 2. The download URL
  # 3. The version metadata in the file
  #
  # This fails for MSYS2, because there is no version number (only a timestamp)
  # and the version that gets reported is 7-zip SFX version.
  $version = ''
  $versionRegEx = '([0-9]+\.)+[0-9]+'
  if ($_.file -match $versionRegEx -or $_.href -match $versionRegEx) {
    $version = $Matches[0]
  } else {
    $version = (Get-ChildItem ".\installers\$($_.file)").VersionInfo.ProductVersion
  }

  if ($version) {
    Write-Host $version
  } else {
    Write-Host $_.file
  }
}

mkdirp "build"
mkdirp "bin"

if (-not (Test-Path $MSYS2Path)) {
  Write-Host 'Extracting MSYS2'
  & .\installers\msys2.exe -y "-o$(Resolve-Path (Split-Path $MSYS2Path -Parent))"
}

if (-not (Test-Path build\NSIS)) {
  Write-Host 'Extracting NSIS'
  Expand-Archive '.\installers\nsis.zip' -DestinationPath '.\build'
  Rename-Item (Resolve-Path '.\build\nsis-*').Path 'NSIS'
}

function msys {
  param ([string] $cmd)

  & "$MSYS2Path\usr\bin\bash" -lc "$cmd"
}

# Preserve the current working directory
$env:CHERE_INVOKING = 'yes'
# Start MINGW32/64 environment
$env:MSYSTEM = "MINGW$bitness"

if (-not (Test-Path ".\build\openocd-install\mingw$bitness")) {
  # First run setup
  msys 'uname -a'
  # Core update
  msys 'pacman --noconfirm -Syuu'
  # Normal update
  msys 'pacman --noconfirm -Suu'

  msys "pacman -S --noconfirm --needed autoconf automake git libtool make mingw-w64-${mingw_arch}-toolchain mingw-w64-${mingw_arch}-libusb p7zip pkg-config wget"

  # Keep it clean
  if (Test-Path .\build\openocd) {
    Remove-Item .\build\openocd -Recurse -Force
  }

  msys "cd build && ../build-openocd.sh $bitness $mingw_arch"
}

if (-not (Test-Path ".\build\libusb")) {
  msys '7z x -obuild/libusb ./installers/libusb.7z'
}

@"
!include "MUI2.nsh"

Name "Pico setup for Windows"
Caption "Pico setup for Windows"
OutFile "bin\pico-setup-windows-$suffix.exe"
Unicode True

InstallDir "`$DOCUMENTS\Pico"

;Get installation folder from registry if available
InstallDirRegKey HKCU "Software\pico-setup-windows" ""

!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "Pico setup for Windows"

!define MUI_FINISHPAGE_RUN_TEXT "Clone and build Pico repos"
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION RunBuild

!define MUI_FINISHPAGE_SHOWREADME "`$INSTDIR\ReadMe.txt"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Show ReadMe"

!define MUI_FINISHPAGE_NOAUTOCLOSE

!insertmacro MUI_PAGE_WELCOME
;!insertmacro MUI_PAGE_LICENSE "`${NSISDIR}\Docs\Modern UI\License.txt"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

Section

  InitPluginsDir
  File /oname=`$TEMP\RefreshEnv.cmd RefreshEnv.cmd
  File /oname=`$PLUGINSDIR\git.inf git.inf

SectionEnd

$($installers | ForEach-Object {
@"

Section "$($_.name)" Sec$($_.shortName)

  SetOutPath "`$TEMP"
  File "installers\$($_.file)"
  StrCpy `$0 "`$TEMP\$($_.file)"
  ExecWait '$($_.exec)' `$1
  DetailPrint "$($_.name) returned `$1"
  Delete /REBOOTOK "`$0"

SectionEnd

LangString DESC_Sec$($_.shortName) `${LANG_ENGLISH} "$($_.name)"

"@
})

Section "VS Code Extensions" SecCodeExts

  ReadEnvStr `$0 COMSPEC
  nsExec::ExecToLog '"`$0" /c call "`$TEMP\RefreshEnv.cmd" && code --install-extension marus25.cortex-debug'
  Pop `$1
  nsExec::ExecToLog '"`$0" /c call "`$TEMP\RefreshEnv.cmd" && code --install-extension ms-vscode.cmake-tools'
  Pop `$1
  nsExec::ExecToLog '"`$0" /c call "`$TEMP\RefreshEnv.cmd" && code --install-extension ms-vscode.cpptools'
  Pop `$1

SectionEnd

LangString DESC_SecCodeExts `${LANG_ENGLISH} "Recommended extensions for Visual Studio Code: C/C++, CMake-Tools, and Cortex-Debug"

Section "OpenOCD" SecOpenOCD

  SetOutPath "`$INSTDIR\tools\openocd-picoprobe"
  File "build\openocd-install\mingw$bitness\bin\*.*"
  File "build\libusb\mingw$bitness\dll\libusb-1.0.dll"
  SetOutPath "`$INSTDIR\tools\openocd-picoprobe\scripts"
  File /r "build\openocd-install\mingw$bitness\share\openocd\scripts\*.*"

SectionEnd

LangString DESC_SecOpenOCD `${LANG_ENGLISH} "Open On-Chip Debugger with picoprobe support"

Section /o "Zadig" SecZadig

  SetOutPath "`$INSTDIR\tools"
  File "installers\zadig.exe"

SectionEnd

LangString DESC_SecZadig `${LANG_ENGLISH} "Zadig is a Windows application that installs generic USB drivers. Used with picoprobe."

Section "Pico environment" SecPico

  SetOutPath "`$INSTDIR"
  File "pico-env.cmd"
  File "pico-setup.cmd"
  File "docs\ReadMe.txt"

  CreateShortcut "`$INSTDIR\Developer Command Prompt for Pico.lnk" "cmd.exe" '/k "`$INSTDIR\pico-env.cmd"'

  ; Unconditionally create a shortcut for VS Code -- in case the user had it
  ; installed already, or if they install it later
  CreateShortcut "`$INSTDIR\Visual Studio Code for Pico.lnk" "cmd.exe" '/c call "`$INSTDIR\pico-env.cmd" && code'

  ; SetOutPath is needed here to set the working directory for the shortcut
  SetOutPath "`$INSTDIR\pico-project-generator"
  CreateShortcut "`$INSTDIR\Pico Project Generator.lnk" "cmd.exe" '/c call "`$INSTDIR\pico-env.cmd" && python "`$INSTDIR\pico-project-generator\pico_project.py" --gui'

  ; Reset working dir for pico-setup.cmd launched from the finish page
  SetOutPath "`$INSTDIR"

SectionEnd

LangString DESC_SecPico `${LANG_ENGLISH} "Scripts for cloning the Pico SDK and tools repos, and for setting up your Pico development environment."

Section "Download documents and files" SecDocs

  SetOutPath "`$INSTDIR"
  File "common.ps1"
  File "pico-docs.ps1"

SectionEnd

Function RunBuild

  ReadEnvStr `$0 COMSPEC
  Exec '"`$0" /k call "`$TEMP\RefreshEnv.cmd" && del "`$TEMP\RefreshEnv.cmd" && call "`$INSTDIR\pico-setup.cmd"'

FunctionEnd

LangString DESC_SecDocs `${LANG_ENGLISH} "Adds a script to download the latest Pico documents, design files, and UF2 files."

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT `${SecCodeExts} `$(DESC_SecCodeExts)
  !insertmacro MUI_DESCRIPTION_TEXT `${SecOpenOCD} `$(DESC_SecOpenOCD)
  !insertmacro MUI_DESCRIPTION_TEXT `${SecZadig} `$(DESC_SecZadig)
  !insertmacro MUI_DESCRIPTION_TEXT `${SecPico} `$(DESC_SecPico)
  !insertmacro MUI_DESCRIPTION_TEXT `${SecDocs} `$(DESC_SecDocs)
$($installers | ForEach-Object {
  "  !insertmacro MUI_DESCRIPTION_TEXT `${Sec$($_.shortName)} `$(DESC_Sec$($_.shortName))`n"
})
!insertmacro MUI_FUNCTION_DESCRIPTION_END
"@ | Set-Content ".\pico-setup-windows-$suffix.nsi"

.\build\NSIS\makensis ".\pico-setup-windows-$suffix.nsi"

# Package OpenOCD separately as well

$tempPath = '.\build\openocd-package'
if (Test-Path $tempPath) {
  Remove-Item $tempPath -Recurse -Force
}
mkdirp $tempPath

# Copy openocd.exe and required DLLs to a temp dir so we can run it to
# determine the version.
Copy-Item ".\build\openocd-install\mingw$bitness\bin\openocd.exe" $tempPath
Copy-Item ".\build\libusb\MinGW$bitness\dll\libusb-1.0.dll" $tempPath

$version = (cmd /c "$tempPath\openocd.exe" --version '2>&1')[0]
if (-not ($version -match 'Open On-Chip Debugger (?<version>[a-zA-Z0-9\.\-+]+) \((?<timestamp>[0-9\-:]+)\)')) {
  Write-Error 'Could not determine openocd version'
}

$filename = 'openocd-picoprobe-{0}-{1}-{2}.zip' -f
  ($Matches.version -replace '-dirty$', ''),
  ($Matches.timestamp -replace '[:-]', ''),
  $suffix

Write-Host "Saving OpenOCD package to $filename"
Compress-Archive "$tempPath\*", ".\build\openocd-install\mingw$bitness\share\openocd\scripts" "bin\$filename" -Force
