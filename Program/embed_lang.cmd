@echo off
setlocal
:: Resource paths are relative to Program even when the IDE builds from another directory.
pushd "%~dp0" || exit /b 1
:: ============================================================================
:: Pre-build step: regenerate lang.rc from Program\Lang and compile it to
:: lang.res, which HomeLibRu.dpr links.
::
:: Usage: embed_lang.cmd <BDS-directory>
::
:: lang.res MUST exist when the compiler runs, so every path through this
:: script ends with a valid one. A clone with no catalogs, or a machine with
:: no Node, produces an empty resource and a Russian-only exe -- never a
:: build failure.
:: ============================================================================

:: %%~f normalises the path, so a trailing backslash on $(BDS) collapses the
:: doubled separator instead of producing an invalid path. Comparing against
:: "\" in an IF would be the obvious fix and is a parser trap in batch.
for %%i in ("%~1\bin\brcc32.exe") do set "BRCC=%%~fi"

set "RC=%~dp0lang.rc"
set "RES=%~dp0lang.res"

:: msbuild does not necessarily inherit a PATH containing node, so fall back
:: to the default installation directory before giving up on it.
set "NODE="
for /f "delims=" %%n in ('where node.exe 2^>nul') do if not defined NODE set "NODE=%%n"
if not defined NODE if exist "%ProgramFiles%\nodejs\node.exe" set "NODE=%ProgramFiles%\nodejs\node.exe"

if defined NODE (
    "%NODE%" "%~dp0..\tools\lang\embed.js" || exit /b 1
) else (
    echo NOTE: node not found - keeping the existing lang.rc.
)

if not exist "%RC%" echo // No catalogs present.> "%RC%"

:: The dark theme is required even without Node or translation catalogs.
:: Keep an existing catalog list, but repair old empty resource stubs too.
findstr /L /C:"MHL_DARK_STYLE VCLSTYLE" "%RC%" >nul || echo MHL_DARK_STYLE VCLSTYLE "Resources\\Themes\\HomeLibRuDark.vsf">> "%RC%"

"%BRCC%" -fo"%RES%" "%RC%"
if errorlevel 1 (
    echo ERROR: brcc32 failed on "%RC%".
    exit /b 1
)

exit /b 0
