@echo off
setlocal
:: ============================================================================
:: Runs every post-build deployment step through one command.
::
:: Delphi 13 treats a multi-line PostBuildEvent as one command and appends the
:: second line to the first one's arguments.  Keeping the project event on one
:: line and sequencing the real work here works both in the IDE and MSBuild.
::
:: Usage: post_build.cmd <destination-folder> <platform>
:: ============================================================================

call "%~dp0copy_help.cmd" "%~1"
if errorlevel 1 exit /b 1

call "%~dp0copy_icons.cmd" "%~1" "%~2"
if errorlevel 1 exit /b 1

exit /b 0
