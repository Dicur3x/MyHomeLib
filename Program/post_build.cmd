@echo off
setlocal
:: ============================================================================
:: Runs every post-build deployment step through one command.
::
:: Delphi 13 treats a multi-line PostBuildEvent as one command and appends the
:: second line to the first one's arguments.  Keeping the project event on one
:: line and sequencing the real work here works both in the IDE and MSBuild.
::
:: Usage: post_build.cmd <platform>
::
:: Delphi 13 leaves the OUTPUTDIR/DCC_ExeOutput macros empty when it expands
:: an IDE build event.  Derive the repository's fixed output directory from
:: the platform here so Help and Icons always land beside the generated EXE.
:: ============================================================================

set "PLATFORM=%~1"

if /I "%PLATFORM%"=="Win64" (
    set "DEST=%~dp0Out\Bin64"
) else if /I "%PLATFORM%"=="Win32" (
    set "DEST=%~dp0Out\Bin"
) else (
    echo ERROR: unsupported platform "%PLATFORM%" ^(expected Win32 or Win64^).
    exit /b 1
)

call "%~dp0copy_help.cmd" "%DEST%"
if errorlevel 1 exit /b 1

call "%~dp0copy_icons.cmd" "%DEST%" "%PLATFORM%"
if errorlevel 1 exit /b 1

exit /b 0
