@echo off
setlocal enabledelayedexpansion
set "PATH=%SystemRoot%\System32;%PATH%"

:: HomeLibre Installer Build Script

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "BIN_DIR=%ROOT_DIR%\Program\Out\Bin"
set "BIN64_DIR=%ROOT_DIR%\Program\Out\Bin64"
set "COMMON_DIR=%SCRIPT_DIR%Common"
set "X86_DIR=%SCRIPT_DIR%x86"
set "X64_DIR=%SCRIPT_DIR%x64"
set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

set "BDS=C:\Program Files (x86)\Embarcadero\Studio\37.0"
set "BDSCOMMONDIR=C:\Users\Public\Documents\Embarcadero\Studio\37.0"
set "MSBUILD=C:\Windows\Microsoft.NET\Framework\v4.0.30319\msbuild.exe"
set "GROUPPROJ=%ROOT_DIR%\Program\MHL.groupproj"

set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=all"

if not exist "%MSBUILD%" (
    echo ERROR: MSBuild not found at "%MSBUILD%"
    exit /b 1
)

if not exist "%GROUPPROJ%" (
    echo ERROR: Project group not found at "%GROUPPROJ%"
    exit /b 1
)

if not exist "%ISCC%" (
    echo ERROR: Inno Setup compiler not found at "%ISCC%"
    exit /b 1
)

if /i "%TARGET%"=="x86" call :build_platform Win32
if errorlevel 1 exit /b 1
if /i "%TARGET%"=="x64" call :build_platform Win64
if errorlevel 1 exit /b 1
if /i "%TARGET%"=="all" (
    call :build_platform Win32
    if errorlevel 1 exit /b 1
    call :build_platform Win64
    if errorlevel 1 exit /b 1
)

if not exist "%BIN_DIR%\HomeLibRu.exe" (
    if /i not "%TARGET%"=="x64" (
        echo ERROR: %BIN_DIR%\HomeLibRu.exe missing after build.
        exit /b 1
    )
)
if /i "%TARGET%"=="x64" (
    if not exist "%BIN64_DIR%\HomeLibRu.exe" (
        echo ERROR: %BIN64_DIR%\HomeLibRu.exe missing after build.
        exit /b 1
    )
)
if /i "%TARGET%"=="all" (
    if not exist "%BIN64_DIR%\HomeLibRu.exe" (
        echo ERROR: %BIN64_DIR%\HomeLibRu.exe missing after build.
        exit /b 1
    )
)

echo.
echo === Collecting Common redistributables ===

if not exist "%COMMON_DIR%" mkdir "%COMMON_DIR%"

copy /y "%SCRIPT_DIR%GenreLists\genres_fb2*.glst"    "%COMMON_DIR%\" >nul
if errorlevel 1 (
    echo ERROR: could not stage genres_fb2 lists from GenreLists\
    exit /b 1
)
copy /y "%SCRIPT_DIR%GenreLists\genres_nonfb2*.glst" "%COMMON_DIR%\" >nul
if errorlevel 1 (
    echo ERROR: could not stage genres_nonfb2 lists from GenreLists\
    exit /b 1
)

call "%ROOT_DIR%\Program\copy_help.cmd" "%COMMON_DIR%"
if errorlevel 1 exit /b 1
copy /y "%SCRIPT_DIR%HomeLibRu.url" "%COMMON_DIR%\" >nul
if errorlevel 1 exit /b 1
copy /y "%ROOT_DIR%\LICENSE" "%COMMON_DIR%\LICENSE" >nul
if errorlevel 1 exit /b 1
copy /y "%ROOT_DIR%\NOTICE" "%COMMON_DIR%\NOTICE" >nul
if errorlevel 1 exit /b 1
copy /y "%SCRIPT_DIR%Licenses\License.txt"    "%COMMON_DIR%\" >nul
copy /y "%SCRIPT_DIR%Licenses\License_uk.txt" "%COMMON_DIR%\" >nul

copy /y "%BIN_DIR%\collections.ini" "%COMMON_DIR%\" >nul

for %%C in (fb2lrf) do (
    if exist "%BIN_DIR%\converters\%%C" (
        robocopy "%BIN_DIR%\converters\%%C" "%COMMON_DIR%\converters\%%C" /s /e /njh /njs /ndl /nc /ns /np >nul
    )
)

echo   Common files collected.

if /i "%TARGET%"=="x86" goto :collect_x86
if /i "%TARGET%"=="all" goto :collect_x86
goto :skip_x86

:collect_x86
echo.
echo === Collecting x86 DLLs ===
if not exist "%X86_DIR%" mkdir "%X86_DIR%"

if exist "%BIN_DIR%\SQLite\x32\sqlite3.dll" (
    copy /y "%BIN_DIR%\SQLite\x32\sqlite3.dll" "%X86_DIR%\" >nul
) else (
    copy /y "%BIN_DIR%\sqlite3.dll" "%X86_DIR%\" >nul
)

echo   x86 DLLs collected.
:skip_x86

if /i "%TARGET%"=="x64" goto :collect_x64
if /i "%TARGET%"=="all" goto :collect_x64
goto :skip_x64

:collect_x64
echo.
echo === Collecting x64 DLLs ===
if not exist "%X64_DIR%" mkdir "%X64_DIR%"

if exist "%BIN_DIR%\SQLite\x64\sqlite3.dll" (
    copy /y "%BIN_DIR%\SQLite\x64\sqlite3.dll" "%X64_DIR%\" >nul
) else (
    copy /y "%BIN64_DIR%\sqlite3.dll" "%X64_DIR%\" >nul
)

echo   x64 DLLs collected.
:skip_x64

if not exist "%SCRIPT_DIR%Out" mkdir "%SCRIPT_DIR%Out"

if /i "%TARGET%"=="x86" goto :build_x86
if /i "%TARGET%"=="all" goto :build_x86
goto :skip_build_x86

:build_x86
echo.
echo === Building x86 installer ===
"%ISCC%" "%SCRIPT_DIR%Setup_Script_MyHomeLib.iss"
if errorlevel 1 (
    echo ERROR: x86 installer build failed!
    exit /b 1
)
:skip_build_x86

if /i "%TARGET%"=="x64" goto :build_x64
if /i "%TARGET%"=="all" goto :build_x64
goto :skip_build_x64

:build_x64
echo.
echo === Building x64 installer ===
"%ISCC%" "%SCRIPT_DIR%Setup_Script_MyHomeLib_x64.iss"
if errorlevel 1 (
    echo ERROR: x64 installer build failed!
    exit /b 1
)
:skip_build_x64

echo.
echo === Done ===
echo.
for %%F in ("%SCRIPT_DIR%Out\Setup_HomeLibRu_*.exe") do (
    echo   Created: %%~nxF
)
echo.
exit /b 0

:build_platform
echo.
echo === Building %~1 binaries ===
"%MSBUILD%" "%GROUPPROJ%" /t:Build /p:Config=Release /p:Platform=%~1 /nologo /v:minimal
if errorlevel 1 (
    echo ERROR: %~1 build failed!
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT_DIR%\scripts\prepare-runtime.ps1" -Platform %~1 -Copy -Force
if errorlevel 1 exit /b 1
exit /b 0
