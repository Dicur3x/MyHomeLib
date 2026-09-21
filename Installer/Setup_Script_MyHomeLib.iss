; ****************************************************************************
;
; InnoSetup script for HomeLib Ru (Win32)
;
; Copyright: ©2008-2026 Oleksiy Penkov (aka Koreec)
;
; Author: Oleksiy Penkov   oleksiy.penkov@gmail.com
;
; Created                  22.05.2023
; Description
;
;
;*****************************************************************************

[Setup]
#define SourceFolder = '..\Program\Out\Bin\'
#define AppURL = 'https://github.com/Dicur3x/MyHomeLib'
#define protected Major
#define protected Minor
#define protected Revision
#define protected Build
#define protected MyAppName = 'HomeLib Ru'
#define protected AppExeName = 'HomeLibRu.exe'
#define ReleaseVersion = '2.7.0_pre5.02'
#define protected FullSourcePath = SourceFolder + AppExeName

#define AppVersion GetVersionComponents(FullSourcePath, Major, Minor, Revision, Build)
#define protected ShortVersion = Str(Major) +'.' + Str(Minor) +'.' + Str(Revision)
#define LibFolder = 'x86\'

OutputBaseFilename = {#'Setup_HomeLibRu_' + ReleaseVersion}


#include "common.iss"
