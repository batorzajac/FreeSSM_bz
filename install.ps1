<#
.SYNOPSIS
    Automatyczny skrypt kompilacji i instalacji FreeSSM dla systemu Windows.

.DESCRIPTION
    Skrypt kompiluje projekt FreeSSM ze zrodel (C++ / Qt5 / MinGW) oraz instaluje go
    w docelowej lokalizacji (domyslnie C:\FreeSSM). Tworzy skroty w Menu Start
    i na Pulpicie, wdraza biblioteki runtime Qt (windeployqt), a takze rejestruje
    deinstalator w systemie Windows (Aplikacje i funkcje).

.PARAMETER InstallDir
    Folder docelowy instalacji FreeSSM. Domyslnie: C:\FreeSSM

.PARAMETER QtPath
    Opcjonalna sciezka do katalogu bin Qt (np. C:\Qt\5.15.2\mingw81_32\bin).
    Jesli nie podano, skrypt przeszukuje PATH oraz standardowe lokalizacje C:\Qt, C:\msys64 itp.

.PARAMETER MinGWPath
    Opcjonalna sciezka do katalogu bin kompilatora MinGW (np. C:\Qt\Tools\mingw810_32\bin).
    Jesli nie podano, skrypt przeszukuje PATH oraz katalogi narzedzi Qt / MSYS2.

.PARAMETER Architecture
    Architektura kompilacji: '32' (domyslna, zalecana) lub '64'.
    UWAGA: Wersja 32-bitowa jest zalecana ze wzgledu na obsluge interfejsow diagnostycznych
    Pass-Thru J2534 (wiekszosc sterownikow DLL dla Windows jest dostepna wylacznie w wersji 32-bit).

.PARAMETER AutoInstallPrereqs
    Automatycznie pobiera i instaluje wymagane pakiety Qt 5.15.2 oraz MinGW 8.1.0 za pomoca aqtinstall (wymaga Python 3).

.PARAMETER SmallResolution
    Kompilacja ze zoptymalizowanym interfejsem dla malych rozdzielczosci ekranu (CONFIG+=small-resolution).

.PARAMETER NoShortcuts
    Pomin tworzenie skrotow na Pulpicie i w Menu Start.

.PARAMETER Clean
    Czysci poprzednie pliki tymczasowe kompilacji (make clean / del Makefile*).

.PARAMETER SkipBuild
    Pomija etap kompilacji (uzyteczne, gdy binarka jest juz skompilowana i chcemy jedynie wykonac instalacje/wdrozenie).

.PARAMETER DebugMode
    Wlacza szczegolowe logowanie diagnostyczne.

.EXAMPLE
    .\install.ps1
    Kompiluje i instaluje FreeSSM w C:\FreeSSM przy uzyciu wykrytego srodowiska Qt/MinGW.

.EXAMPLE
    .\install.ps1 -AutoInstallPrereqs
    Automatycznie pobiera Qt 5.15.2 MinGW 32-bit (jesli brak) i wykonuje pelna instalacje.

.EXAMPLE
    .\install.ps1 -InstallDir "D:\Narzedzia\FreeSSM" -SmallResolution
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\FreeSSM",
    [string]$QtPath = "",
    [string]$MinGWPath = "",
    [ValidateSet("32", "64")]
    [string]$Architecture = "32",
    [switch]$AutoInstallPrereqs,
    [switch]$SmallResolution,
    [switch]$NoShortcuts,
    [switch]$Clean,
    [switch]$SkipBuild,
    [switch]$DebugMode
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# --- Konfiguracja logowania ---
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }

$LogsDir = Join-Path $ScriptRoot "logs"
if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogsDir "install_$Timestamp.log"

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )

    $TimeStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Formatted = "[$TimeStr] [$Level] $Message"

    Add-Content -Path $LogFile -Value $Formatted -Encoding UTF8

    if ($Level -eq "DEBUG" -and -not $DebugMode) {
        return
    }

    switch ($Level) {
        "INFO"    { Write-Host "[-] $Message" -ForegroundColor Cyan }
        "WARN"    { Write-Host "[!] $Message" -ForegroundColor Yellow }
        "ERROR"   { Write-Host "[X] $Message" -ForegroundColor Red }
        "SUCCESS" { Write-Host "[+] $Message" -ForegroundColor Green }
        "DEBUG"   { Write-Host "[D] $Message" -ForegroundColor DarkGray }
    }
}

Write-Log "=== Rozpoczecie procedury instalacyjnej FreeSSM ==="
Write-Log "Katalog zrodlowy : $ScriptRoot"
Write-Log "Katalog docelowy : $InstallDir"
Write-Log "Architektura     : ${Architecture}-bit"
Write-Log "Plik logu        : $LogFile"

# --- Sprawdzenie projektu ---
$ProFile = Join-Path $ScriptRoot "FreeSSM.pro"
if (-not (Test-Path $ProFile)) {
    Write-Log "Nie znaleziono pliku projektu FreeSSM.pro w: $ScriptRoot" "ERROR"
    exit 1
}

# --- Wykrywanie Qt i MinGW ---
function Resolve-ToolPath {
    param([string]$PathToTest, [string]$Executable)
    if ([string]::IsNullOrWhiteSpace($PathToTest)) { return $null }

    if (Test-Path (Join-Path $PathToTest $Executable)) {
        return $PathToTest
    }
    if (Test-Path (Join-Path $PathToTest "bin\$Executable")) {
        return (Join-Path $PathToTest "bin")
    }
    return $null
}

function Find-Toolchain {
    param([string]$ReqArch)

    $Result = [PSCustomObject]@{
        QtBin        = $null
        MinGWBin     = $null
        QMakeExe     = $null
        MakeExe      = $null
        LReleaseExe  = $null
        WinDeployExe = $null
    }

    # 1. Recznie podane sciezki
    if ($QtPath) {
        $Resolved = Resolve-ToolPath $QtPath "qmake.exe"
        if ($Resolved) { $Result.QtBin = $Resolved }
    }
    if ($MinGWPath) {
        $Resolved = Resolve-ToolPath $MinGWPath "g++.exe"
        if ($Resolved) { $Result.MinGWBin = $Resolved }
    }

    # 2. Sprawdzenie w PATH
    if (-not $Result.QtBin) {
        $InPathQMake = Get-Command "qmake.exe" -ErrorAction SilentlyContinue
        if ($InPathQMake) {
            $Result.QtBin = Split-Path -Parent $InPathQMake.Source
            Write-Log "Znaleziono qmake w PATH: $($Result.QtBin)" "DEBUG"
        }
    }
    if (-not $Result.MinGWBin) {
        $InPathGpp = Get-Command "g++.exe" -ErrorAction SilentlyContinue
        if ($InPathGpp) {
            $Result.MinGWBin = Split-Path -Parent $InPathGpp.Source
            Write-Log "Znaleziono g++ w PATH: $($Result.MinGWBin)" "DEBUG"
        }
    }

    # 3. Przeszukiwanie standardowych katalogow C:\Qt
    if (Test-Path "C:\Qt") {
        Write-Log "Skanowanie katalogu C:\Qt..." "DEBUG"

        if (-not $Result.QtBin) {
            $Pattern = if ($ReqArch -eq "32") { "*mingw*32*" } else { "*mingw*64*" }
            $Candidates = Get-ChildItem -Path "C:\Qt" -Filter "qmake.exe" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like "*$Pattern*" } |
                Select-Object -ExpandProperty DirectoryName

            if ($Candidates) {
                $Result.QtBin = $Candidates[0]
                Write-Log "Wykryto Qt bin: $($Result.QtBin)" "DEBUG"
            }
        }

        if (-not $Result.MinGWBin) {
            $ToolPattern = if ($ReqArch -eq "32") { "*mingw*32*" } else { "*mingw*64*" }
            $MinGWCandidates = Get-ChildItem -Path "C:\Qt\Tools", "C:\Qt" -Filter "mingw32-make.exe" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like "*$ToolPattern*" } |
                Select-Object -ExpandProperty DirectoryName

            if ($MinGWCandidates) {
                $Result.MinGWBin = $MinGWCandidates[0]
                Write-Log "Wykryto MinGW bin: $($Result.MinGWBin)" "DEBUG"
            }
        }
    }

    # 4. Sprawdzenie MSYS2
    if (-not $Result.MinGWBin -or -not $Result.QtBin) {
        $MsysDir = if ($ReqArch -eq "32") { "C:\msys64\mingw32\bin" } else { "C:\msys64\mingw64\bin" }
        if (Test-Path $MsysDir) {
            if (-not $Result.QtBin -and (Test-Path (Join-Path $MsysDir "qmake.exe"))) {
                $Result.QtBin = $MsysDir
            }
            if (-not $Result.MinGWBin -and (Test-Path (Join-Path $MsysDir "g++.exe"))) {
                $Result.MinGWBin = $MsysDir
            }
        }
    }

    # Ustalanie plikow wykonywalnych
    if ($Result.QtBin) {
        $Result.QMakeExe = Join-Path $Result.QtBin "qmake.exe"
        $Result.LReleaseExe = Join-Path $Result.QtBin "lrelease.exe"
        $Result.WinDeployExe = Join-Path $Result.QtBin "windeployqt.exe"
    }

    if ($Result.MinGWBin) {
        $M32Make = Join-Path $Result.MinGWBin "mingw32-make.exe"
        $StdMake = Join-Path $Result.MinGWBin "make.exe"
        if (Test-Path $M32Make) {
            $Result.MakeExe = $M32Make
        } elseif (Test-Path $StdMake) {
            $Result.MakeExe = $StdMake
        }
    }

    return $Result
}

# --- Automatyczna instalacja zaleznosci (aqtinstall) ---
function Install-QtPrerequisites {
    param([string]$ReqArch)

    Write-Log "Uruchamianie automatycznej instalacji Qt i MinGW przez aqtinstall..." "INFO"

    $PythonCmd = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if (-not $PythonCmd) {
        Write-Log "Do automatycznej instalacji wymagany jest Python 3 w PATH." "ERROR"
        Write-Log "Zainstaluj Pythona (np. przez: winget install Python.Python.3.13) i sprobuj ponownie." "ERROR"
        exit 1
    }

    Write-Log "Instalowanie/aktualizacja narzedzia aqtinstall..." "INFO"
    $PipArgs = @("-m", "pip", "install", "--upgrade", "--quiet", "aqtinstall")
    & python.exe $PipArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Blad podczas instalacji aqtinstall przez pip." "ERROR"
        exit 1
    }

    $TargetDir = "C:\Qt"
    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    if ($ReqArch -eq "32") {
        Write-Log "Pobieranie Qt 5.15.2 (win32_mingw81) do $TargetDir..." "INFO"
        & python.exe -m aqt install-qt windows desktop 5.15.2 win32_mingw81 -O $TargetDir
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Blad pobierania pakietu Qt 5.15.2 win32_mingw81." "ERROR"
            exit 1
        }

        Write-Log "Pobieranie kompilatora MinGW 8.1.0 32-bit do $TargetDir..." "INFO"
        & python.exe -m aqt install-tool windows desktop tools_mingw qt.tools.win32_mingw810 -O $TargetDir
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Blad pobierania pakietu MinGW 8.1.0 32-bit." "ERROR"
            exit 1
        }
    } else {
        Write-Log "Pobieranie Qt 5.15.2 (win64_mingw81) do $TargetDir..." "INFO"
        & python.exe -m aqt install-qt windows desktop 5.15.2 win64_mingw81 -O $TargetDir
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Blad pobierania pakietu Qt 5.15.2 win64_mingw81." "ERROR"
            exit 1
        }

        Write-Log "Pobieranie kompilatora MinGW 8.1.0 64-bit do $TargetDir..." "INFO"
        & python.exe -m aqt install-tool windows desktop tools_mingw qt.tools.win64_mingw810 -O $TargetDir
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Blad pobierania pakietu MinGW 8.1.0 64-bit." "ERROR"
            exit 1
        }
    }

    Write-Log "Pobieranie srodowiska Qt/MinGW zakonczone pomyslnie." "SUCCESS"
}

# --- Wykrycie srodowiska ---
$Toolchain = Find-Toolchain -ReqArch $Architecture

if (-not $Toolchain.QtBin -or -not $Toolchain.MinGWBin) {
    Write-Log "Nie wykryto kompletnego srodowiska Qt i MinGW na komputerze." "WARN"
    Write-Log "Status: QtBin = '$($Toolchain.QtBin)', MinGWBin = '$($Toolchain.MinGWBin)'" "DEBUG"

    if ($AutoInstallPrereqs) {
        Install-QtPrerequisites -ReqArch $Architecture
        $Toolchain = Find-Toolchain -ReqArch $Architecture
    } else {
        Write-Host ""
        Write-Host "==========================================================================" -ForegroundColor Yellow
        Write-Host " WYMAGANE SRODOWISKO DO KOMPILACJI FREESSM:" -ForegroundColor Yellow
        Write-Host " 1. Qt 5.x dla MinGW (np. 5.15.2, zalecana wersja 32-bit dla sterownikow J2534)"
        Write-Host " 2. Kompilator MinGW (g++, mingw32-make)"
        Write-Host ""
        Write-Host " Mozesz zainstalowac srodowisko automatycznie, uruchamiajac ten skrypt z flaga:" -ForegroundColor Cyan
        Write-Host "     .\install.ps1 -AutoInstallPrereqs" -ForegroundColor White
        Write-Host ""
        Write-Host " Lub podac istniejace sciezki recznie:" -ForegroundColor Cyan
        Write-Host '     .\install.ps1 -QtPath "C:\Qt\5.15.2\mingw81_32\bin" -MinGWPath "C:\Qt\Tools\mingw810_32\bin"' -ForegroundColor White
        Write-Host "==========================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Log "Przerwano - brak wymaganego srodowiska deweloperskiego." "ERROR"
        exit 1
    }
}

if (-not (Test-Path $Toolchain.QMakeExe) -or -not (Test-Path $Toolchain.MakeExe)) {
    Write-Log "Nie mozna zlokalizowac qmake.exe lub mingw32-make.exe." "ERROR"
    exit 1
}

Write-Log "Uzywane Qt bin   : $($Toolchain.QtBin)" "INFO"
Write-Log "Uzywane MinGW bin: $($Toolchain.MinGWBin)" "INFO"

# Dodanie katalogow narzedzi do PATH dla biezacego procesu
$env:PATH = "$($Toolchain.QtBin);$($Toolchain.MinGWBin);$env:PATH"
$env:QTDIR = Split-Path -Parent $Toolchain.QtBin

# Weryfikacja wersji kompilatora i Qt
try {
    $QMakeVer = & $Toolchain.QMakeExe -version 2>&1 | Out-String
    Write-Log "qmake info: $($QMakeVer.Trim())" "DEBUG"
} catch {
    Write-Log "Blad wywolania qmake: $_" "WARN"
}

# --- Krok 1: Czyszczenie (opcjonalne) ---
if ($Clean) {
    Write-Log "Czyszczenie poprzednich plikow kompilacji..." "INFO"
    Push-Location $ScriptRoot
    try {
        if (Test-Path "Makefile") {
            & $Toolchain.MakeExe clean 2>&1 | Out-Null
            Remove-Item -Path "Makefile*", "release", "debug", "object_script.*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Pop-Location
    }
}

# --- Krok 2: Kompilacja FreeSSM ---
if (-not $SkipBuild) {
    Write-Log "Konfigurowanie projektu za pomoca qmake..." "INFO"
    Push-Location $ScriptRoot

    try {
        # Normalizacja sciezki instalacyjnej dla qmake (slashe '/')
        $InstallDirNormalized = $InstallDir.Replace('\', '/')

        $QMakeParams = @(
            "FreeSSM.pro",
            "CONFIG+=release",
            "INSTALLDIR=$InstallDirNormalized"
        )
        if ($SmallResolution) {
            $QMakeParams += "CONFIG+=small-resolution"
            Write-Log "Aktywowano profil dla malych rozdzielczosci (small-resolution)." "INFO"
        }

        Write-Log "Wykonywanie: $($Toolchain.QMakeExe) $($QMakeParams -join ' ')" "DEBUG"
        & $Toolchain.QMakeExe $QMakeParams
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Blad qmake (kod: $LASTEXITCODE)." "ERROR"
            exit 1
        }

        # Generowanie tlumaczen (.qm)
        Write-Log "Generowanie plikow tlumaczen (*.qm)..." "INFO"
        if (Test-Path $Toolchain.LReleaseExe) {
            & $Toolchain.LReleaseExe FreeSSM.pro
        } else {
            & $Toolchain.MakeExe translation
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Ostrzezenie: blad podczas generowania tlumaczen lrelease." "WARN"
        }

        # Kompilacja release
        $Cores = $env:NUMBER_OF_PROCESSORS
        if (-not $Cores -or $Cores -lt 1) { $Cores = 2 }
        Write-Log "Kompilacja aplikacji (uzycie watkow: $Cores)..." "INFO"

        & $Toolchain.MakeExe release "-j$Cores"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Kompilacja nie powiodla sie (kod bledu: $LASTEXITCODE)." "ERROR"
            exit 1
        }
        Write-Log "Kompilacja zakonczona sukcesem." "SUCCESS"
    } finally {
        Pop-Location
    }
} else {
    Write-Log "Pominieto etap kompilacji (-SkipBuild)." "INFO"
}

# --- Krok 3: Instalacja do katalogu docelowego ---
Write-Log "Instalowanie FreeSSM do katalogu: $InstallDir..." "INFO"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

Push-Location $ScriptRoot
try {
    Write-Log "Wykonywanie: $($Toolchain.MakeExe) release-install..." "INFO"
    & $Toolchain.MakeExe release-install
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Blad make release-install (kod: $LASTEXITCODE)." "WARN"
    }
} finally {
    Pop-Location
}

# Sprawdzenie obecnosci pliku wykonywalnego
$ExeTarget = Join-Path $InstallDir "FreeSSM.exe"
if (-not (Test-Path $ExeTarget)) {
    $LocalExe = Join-Path $ScriptRoot "release\FreeSSM.exe"
    if (Test-Path $LocalExe) {
        Write-Log "Kopiowanie pliku wykonywalnego z release\FreeSSM.exe..." "INFO"
        Copy-Item -Path $LocalExe -Destination $ExeTarget -Force
    } else {
        Write-Log "Nie odnaleziono FreeSSM.exe ani w $InstallDir, ani w $ScriptRoot\release!" "ERROR"
        exit 1
    }
}

# Kopiowanie zasobow towarzyszacych
$FilesToEnsure = @(
    @{ Src = (Join-Path $ScriptRoot "background.png"); Dst = (Join-Path $InstallDir "background.png") },
    @{ Src = (Join-Path $ScriptRoot "LICENSE.txt"); Dst = (Join-Path $InstallDir "LICENSE.txt") },
    @{ Src = (Join-Path $ScriptRoot "README.txt"); Dst = (Join-Path $InstallDir "README.txt") }
)
foreach ($F in $FilesToEnsure) {
    if ((Test-Path $F.Src) -and -not (Test-Path $F.Dst)) {
        Copy-Item -Path $F.Src -Destination $F.Dst -Force
    }
}

# Czcionki LiberationSans
Get-ChildItem -Path $ScriptRoot -Filter "LiberationSans*.ttf" | ForEach-Object {
    $DestFile = Join-Path $InstallDir $_.Name
    if (-not (Test-Path $DestFile)) {
        Copy-Item -Path $_.FullName -Destination $DestFile -Force
    }
}

# Katalog definicji XML
$DefsTargetDir = Join-Path $InstallDir "definitions"
if (-not (Test-Path $DefsTargetDir)) {
    New-Item -ItemType Directory -Path $DefsTargetDir -Force | Out-Null
}
Get-ChildItem -Path (Join-Path $ScriptRoot "definitions") -Filter "*.xml" | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $DefsTargetDir $_.Name) -Force
}

# Katalog dokumentacji HTML
$DocTargetDir = Join-Path $InstallDir "doc"
if (-not (Test-Path $DocTargetDir)) {
    New-Item -ItemType Directory -Path $DocTargetDir -Force | Out-Null
}
Get-ChildItem -Path (Join-Path $ScriptRoot "doc") | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $DocTargetDir $_.Name) -Recurse -Force
}

# Pliki tlumaczen (*.qm)
Get-ChildItem -Path $ScriptRoot -Filter "*.qm" | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $InstallDir $_.Name) -Force
}

# Ikona aplikacji
$IconTarget = Join-Path $InstallDir "FreeSSM.ico"
$IconSource = Join-Path $ScriptRoot "resources\icons\freessm\FreeSSM.ico"
if (Test-Path $IconSource) {
    Copy-Item -Path $IconSource -Destination $IconTarget -Force
}

# --- Krok 4: Wdrazanie zaleznosci bibliotek Qt (windeployqt) ---
if ($Toolchain.WinDeployExe -and (Test-Path $Toolchain.WinDeployExe)) {
    Write-Log "Wdrazanie bibliotek wspoldzielonych Qt za pomoca windeployqt..." "INFO"
    $DeployArgs = @(
        $ExeTarget,
        "--no-translations",
        "--compiler-runtime"
    )
    & $Toolchain.WinDeployExe $DeployArgs
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Wdrazanie bibliotek Qt zakonczone sukcesem." "SUCCESS"
    } else {
        Write-Log "windeployqt zwrocil kod: $LASTEXITCODE." "WARN"
    }
}

# Upewnienie sie co do bibliotek MinGW/GCC
$MinGWDlls = @(
    "libgcc_s_dw2-1.dll",
    "libgcc_s_seh-1.dll",
    "libstdc++-6.dll",
    "libwinpthread-1.dll"
)
foreach ($Dll in $MinGWDlls) {
    $DllSrc = Join-Path $Toolchain.MinGWBin $Dll
    if (-not (Test-Path $DllSrc)) {
        $DllSrc = Join-Path $Toolchain.QtBin $Dll
    }
    $DllDst = Join-Path $InstallDir $Dll
    if ((Test-Path $DllSrc) -and -not (Test-Path $DllDst)) {
        Copy-Item -Path $DllSrc -Destination $DllDst -Force
    }
}

# --- Krok 5: Skroty w Menu Start i na Pulpicie ---
if (-not $NoShortcuts) {
    Write-Log "Tworzenie skrotow systemowych..." "INFO"
    try {
        $WshShell = New-Object -ComObject WScript.Shell

        # Pulpit
        $DesktopDir = [Environment]::GetFolderPath('Desktop')
        $DesktopLnk = Join-Path $DesktopDir "FreeSSM.lnk"
        $ShortcutDesktop = $WshShell.CreateShortcut($DesktopLnk)
        $ShortcutDesktop.TargetPath = $ExeTarget
        $ShortcutDesktop.WorkingDirectory = $InstallDir
        $ShortcutDesktop.Description = "FreeSSM - Subaru Diagnostic and Adjustment Tool"
        if (Test-Path $IconTarget) {
            $ShortcutDesktop.IconLocation = "$IconTarget,0"
        }
        $ShortcutDesktop.Save()
        Write-Log "Utworzono skrot na Pulpicie: $DesktopLnk" "SUCCESS"

        # Menu Start
        $StartMenuPrograms = [Environment]::GetFolderPath('Programs')
        $StartMenuFolder = Join-Path $StartMenuPrograms "FreeSSM"
        if (-not (Test-Path $StartMenuFolder)) {
            New-Item -ItemType Directory -Path $StartMenuFolder -Force | Out-Null
        }
        $StartMenuLnk = Join-Path $StartMenuFolder "FreeSSM.lnk"
        $ShortcutStart = $WshShell.CreateShortcut($StartMenuLnk)
        $ShortcutStart.TargetPath = $ExeTarget
        $ShortcutStart.WorkingDirectory = $InstallDir
        $ShortcutStart.Description = "FreeSSM - Subaru Diagnostic and Adjustment Tool"
        if (Test-Path $IconTarget) {
            $ShortcutStart.IconLocation = "$IconTarget,0"
        }
        $ShortcutStart.Save()
        Write-Log "Utworzono skrot w Menu Start: $StartMenuLnk" "SUCCESS"
    } catch {
        Write-Log "Nie udalo sie utworzyc skrotow: $_" "WARN"
    }
}

# --- Krok 6: Generowanie skryptu deinstalacyjnego ---
$UninstallScriptPath = Join-Path $InstallDir "uninstall.ps1"
$UninstallBatPath = Join-Path $InstallDir "uninstall.bat"

$UninstallScriptContent = @'
# Skrypt deinstalacyjny FreeSSM
$ErrorActionPreference = "SilentlyContinue"
Write-Host "Usuwanie FreeSSM..." -ForegroundColor Yellow

# Usuwanie skrotu na Pulpicie
$DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "FreeSSM.lnk"
if (Test-Path $DesktopLnk) { Remove-Item -Path $DesktopLnk -Force }

# Usuwanie skrotow z Menu Start
$StartMenuFolder = Join-Path ([Environment]::GetFolderPath('Programs')) "FreeSSM"
if (Test-Path $StartMenuFolder) { Remove-Item -Path $StartMenuFolder -Recurse -Force }

# Usuwanie wpisu z rejestru
Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FreeSSM" -Force -ErrorAction SilentlyContinue

Write-Host "FreeSSM zostal odinstalowany." -ForegroundColor Green
'@

Set-Content -Path $UninstallScriptPath -Value $UninstallScriptContent -Encoding UTF8

$UninstallBatContent = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0uninstall.ps1`"`r`npause"
Set-Content -Path $UninstallBatPath -Value $UninstallBatContent -Encoding ASCII

# Rejestracja w Windows "Aplikacje i funkcje" (HKCU)
$RegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FreeSSM"
try {
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $RegPath -Name "DisplayName" -Value "FreeSSM"
    Set-ItemProperty -Path $RegPath -Name "DisplayVersion" -Value "1.2.5"
    Set-ItemProperty -Path $RegPath -Name "Publisher" -Value "Comer352L / FreeSSM Project"
    Set-ItemProperty -Path $RegPath -Name "InstallLocation" -Value $InstallDir
    Set-ItemProperty -Path $RegPath -Name "UninstallString" -Value "powershell.exe -ExecutionPolicy Bypass -File `"$UninstallScriptPath`""
    Set-ItemProperty -Path $RegPath -Name "DisplayIcon" -Value "$ExeTarget,0"
    Set-ItemProperty -Path $RegPath -Name "HelpLink" -Value "https://github.com/batorzajac/FreeSSM_bz"
    Write-Log "Zarejestrowano deinstalator w systemie Windows." "INFO"
} catch {
    Write-Log "Nie udalo sie zapisac wpisu w rejestrze Uninstall: $_" "DEBUG"
}

Write-Log "=== Instalacja FreeSSM zakonczona sukcesem! ===" "SUCCESS"
Write-Log "Lokalizacja aplikacji: $InstallDir" "SUCCESS"
Write-Log "Uruchomienie         : & `"$ExeTarget`"" "INFO"
