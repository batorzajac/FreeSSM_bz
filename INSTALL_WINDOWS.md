# Instrukcja instalacji FreeSSM (Windows)

Ten projekt zawiera skrypt instalacyjny dla systemu Windows ([install.ps1](install.ps1)) wraz z plikiem pomocniczym ([install.bat](install.bat)).

## Wymagania wstępne

Aplikacja FreeSSM bazuje na C++ oraz bibliotece Qt. Do jej skompilowania wymagane są:
1. **Qt 5.x** (zalecana wersja: **5.15.2 MinGW 32-bit** ze względu na biblioteki J2534 Pass-Thru).
2. **Kompilator MinGW** (g++, mingw32-make).
3. **Python 3** (opcjonalnie, jeśli chcesz, aby skrypt pobrał i skonfigurował środowisko Qt automatycznie).

---

## Szybki start

### Opcja 1: Automatyczna instalacja zależności i kompilacja (zalecane)
Jeśli nie masz jeszcze zainstalowanego Qt ani MinGW:
```powershell
.\install.ps1 -AutoInstallPrereqs
```
Skrypt automatycznie pobierze narzędzie `aqtinstall`, ściągnie Qt 5.15.2 MinGW 32-bit do katalogu `C:\Qt`, skompiluje projekt i zainstaluje go w `C:\FreeSSM`.

---

### Opcja 2: Kompilacja z już zainstalowanym środowiskiem Qt/MinGW
Jeśli posiadasz już zainstalowane Qt w standardowej lokalizacji (np. `C:\Qt` lub w zmiennej środowiskowej `PATH`):
```powershell
.\install.ps1
```
Lub z poziomu wiersza poleceń / dwuklik:
```cmd
install.bat
```

---

### Opcja 3: Wskazanie własnych ścieżek
```powershell
.\install.ps1 -QtPath "C:\Qt\5.15.2\mingw81_32\bin" -MinGWPath "C:\Qt\Tools\mingw810_32\bin" -InstallDir "C:\FreeSSM"
```

---

## Dostępne parametry skryptu

| Parametr | Typ | Domyślnie | Opis |
|---|---|---|---|
| `-InstallDir` | String | `C:\FreeSSM` | Ścieżka docelowa instalacji programu. |
| `-QtPath` | String | (autodetekcja) | Ścieżka do folderu `bin` Qt (zawierającego `qmake.exe`). |
| `-MinGWPath` | String | (autodetekcja) | Ścieżka do folderu `bin` MinGW (zawierającego `g++.exe` i `mingw32-make.exe`). |
| `-Architecture` | ValidateSet("32", "64") | `32` | Architektura binarna (`32` zalecana dla zgodności z J2534 DLL). |
| `-AutoInstallPrereqs` | Switch | `$false` | Automatycznie instaluje Qt 5.15.2 i MinGW przez `aqtinstall`. |
| `-SmallResolution` | Switch | `$false` | Kompiluje interfejs zoptymalizowany pod małe ekrany/netbooki. |
| `-NoShortcuts` | Switch | `$false` | Pomija tworzenie skrótów na Pulpicie i w Menu Start. |
| `-Clean` | Switch | `$false` | Czyści pliki obiektowe i makefile przed kompilacją. |
| `-SkipBuild` | Switch | `$false` | Pomija kompilację (instalacja gotowych plików binarnych). |
| `-DebugMode` | Switch | `$false` | Szczegółowe logowanie diagnostyczne. |

---

## Co robi instalator?

1. Wykrywa środowisko kompilacji (Qt 5 + MinGW).
2. Generuje pliki tłumaczeń (`.qm`) za pomocą `lrelease`.
3. Kompiluje FreeSSM wielowątkowo (`mingw32-make release -j`).
4. Kopiuje pliki wykonywalne, definicje XML (`definitions/`), dokumentację (`doc/`), ikony oraz czcionki do folderu docelowego (`C:\FreeSSM`).
5. Uruchamia `windeployqt` i kopiuje niezbędne biblioteki runtime (DLL), gwarantując działanie aplikacji w trybie autonomicznym.
6. Tworzy skróty w **Menu Start** oraz na **Pulpicie**.
7. Tworzy deinstalator (`uninstall.ps1` i `uninstall.bat`) oraz rejestruje aplikację w panelu **Aplikacje i funkcje** systemu Windows.
8. Zapisuje pełny log z instalacji w podfolderze `logs/`.
