; ****************************************************************************
; InnoSetup script for HomeLib Ru
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
PrivilegesRequired=admin
AppID={{B9B6C409-01CB-4AB6-8E4F-403B49A25B56}
OutputDir=.\Out
SourceDir=.
AppCopyright=© 2008-2026 Oleksiy Penkov
WizardImageFile=.\Images\SetupModern20.bmp
WizardSmallImageFile=.\Images\SetupModernSmall20.bmp
SetupIconFile=.\Images\Setup.ico
UsePreviousAppDir=yes
AllowNoIcons=yes
Compression=lzma/ultra
SolidCompression=yes
LicenseFile=Common\License.txt
VersionInfoVersion = {#AppVersion}
AppName = {#MyAppName}
; Preserve the existing installation and profile paths for upgrades.
DefaultDirName = {autopf}\MyHomeLib\
DefaultGroupName = {#MyAppName}
AppVerName = {#MyAppName + " v. " + ReleaseVersion}
UninstallDisplayIcon = {app}\{#AppExeName}
AppPublisherURL = {#AppURL}
AppSupportURL = {#AppURL}
AppUpdatesURL = {#AppURL}

[Dirs]
Name: "{userappdata}\MyHomeLib"; Permissions: everyone-modify

[Icons]
Name: {group}\{#MyAppName}; Filename: {app}\{#AppExeName}; WorkingDir: {app}; IconFilename: {app}\{#AppExeName}; IconIndex: 0; Comment: {#MyAppName}
Name: {group}\{cm:HelpShortcut}; Filename: {app}\{cm:HelpIndex}; WorkingDir: {app}; IconFilename: {sys}\ieframe.dll; IconIndex: 36; Comment: {cm:HelpShortcut}
Name: {commondesktop}\{#MyAppName}; Filename: {app}\{#AppExeName}; WorkingDir: {app}; IconFilename: {app}\{#AppExeName}; IconIndex: 0; Comment: {#MyAppName}; Tasks: desktopicon
Name: {group}\{cm:WebsiteShortcut}; Filename: {app}\HomeLibRu.url; IconFilename: {sys}\ieframe.dll; IconIndex: 36
Name: {group}\{cm:UninstallProgram,{#MyAppName}}; Filename: {uninstallexe}

[UninstallDelete]
; The legacy profile is shared with existing installations. Keep user data.
Name: {app}; Type: files

[Run]
Filename: {app}\{#AppExeName}; WorkingDir: {app}; Description: {cm:LaunchProgram,{#MyAppName}}; Flags: nowait postinstall skipifsilent

[InstallDelete]
Type: files; Name: {app}\MyHomeLib.chm

[Files]
Source: {#FullSourcePath}; DestDir: {app}; DestName: {#AppExeName}; Flags: replacesameversion

Source: {#LibFolder + 'sqlite3.dll'}; DestDir: {app}; Flags: replacesameversion

Source: {#SourceFolder + 'MHLMcpServer.exe'}; DestDir: {app}; Flags: replacesameversion
Source: {#SourceFolder + 'HomeLibRuUpdater.exe'}; DestDir: {app}; Flags: replacesameversion
Source: Components.json; DestDir: {app}\tools\updates; DestName: COMPONENTS.json; Flags: replacesameversion

Source: {#SourceFolder + 'Icons\MHLIcons.dll'}; DestDir: {app}\Icons; Flags: replacesameversion

Source: {#SourceFolder + 'libzstd.dll'}; DestDir: {app}; Flags: replacesameversion

; Read-only 7z support and JPEG XL conversion for compact FLibrary torrents.
; The preparation script also places the third-party licences under tools, so
; copying the complete tree is both less fragile and licence-correct.
Source: {#SourceFolder + 'tools\*'}; DestDir: {app}\tools; Flags: recursesubdirs createallsubdirs

; Portable readers are kept under one predictable root. MyHomeLib resolves
; their relative paths against {app}, so changed working directories do not
; affect book opening. Take them from the platform build output so x64 gets
; the x64 SumatraPDF executable and x86 gets the x86 one.
Source: {#SourceFolder + 'Readers\*'}; DestDir: {app}\Readers; Flags: recursesubdirs createallsubdirs
Source: Common\converters\fb2lrf\*; DestDir: {app}\converters\fb2lrf\; Flags: skipifsourcedoesntexist
Source: Common\converters\fb2pdf\*; DestDir: {app}\converters\fb2pdf\; Flags: skipifsourcedoesntexist
Source: Common\converters\fb2epub\*; DestDir: {app}\converters\fb2epub\; Flags: skipifsourcedoesntexist
Source: Common\converters\fb2mobi\*; DestDir: {app}\converters\fb2mobi\; Flags: skipifsourcedoesntexist
Source: Common\genres_nonfb2.glst; DestDir: {app}\tools\genres; Flags: replacesameversion
Source: Common\genres_fb2.glst; DestDir: {app}\tools\genres; Flags: replacesameversion
Source: Common\genres_fb2_uk.glst; DestDir: {app}\tools\genres; Flags: replacesameversion
Source: Common\genres_nonfb2_uk.glst; DestDir: {app}\tools\genres; Flags: replacesameversion
Source: Common\genres_fb2_en.glst; DestDir: {app}\tools\genres; Flags: replacesameversion
Source: Common\genres_nonfb2_en.glst; DestDir: {app}\tools\genres; Flags: replacesameversion
Source: Common\genres_fb2_bg.glst; DestDir: {app}\tools\genres; Flags: replacesameversion
Source: Common\genres_nonfb2_bg.glst; DestDir: {app}\tools\genres; Flags: replacesameversion
Source: Common\collections.ini; DestDir: {userappdata}\MyHomeLib; Flags: onlyifdoesntexist
Source: Common\Help\*; DestDir: {app}\Help; Flags: recursesubdirs
Source: Common\HomeLibRu.url; DestDir: {app}; Flags: replacesameversion
Source: Common\LICENSE; DestDir: {app}; Flags: replacesameversion
Source: Common\NOTICE; DestDir: {app}; Flags: replacesameversion
Source: Common\License.txt; DestDir: {app}; Flags: replacesameversion
Source: Common\License_uk.txt; DestDir: {app}; Flags: replacesameversion

[Tasks]
Name: desktopicon; Description: {cm:CreateDesktopIcon}

[Languages]
Name: Russian; MessagesFile: compiler:Languages\Russian.isl; LicenseFile: Common\License.txt
Name: English; MessagesFile: compiler:Default.isl; LicenseFile: Common\License.txt
Name: Ukrainian; MessagesFile: compiler:Languages\Ukrainian.isl; LicenseFile: Common\License_uk.txt
Name: Bulgarian; MessagesFile: compiler:Languages\Bulgarian.isl; LicenseFile: Common\License.txt

[CustomMessages]
Russian.LocaleCode=ru
English.LocaleCode=en
Ukrainian.LocaleCode=uk
Bulgarian.LocaleCode=bg

; user who chose another language. Russian help lives at the root of Help\
Russian.HelpShortcut=Справка HomeLib Ru
English.HelpShortcut=HomeLib Ru Help
Ukrainian.HelpShortcut=Довідка HomeLib Ru
Bulgarian.HelpShortcut=Помощ за HomeLib Ru
Russian.HelpIndex=Help\index.html
; translated -- HomeLib Ru is a name, not a phrase.
Russian.WebsiteShortcut=Сайт HomeLib Ru
English.WebsiteShortcut=HomeLib Ru website
Ukrainian.WebsiteShortcut=Сайт HomeLib Ru
Bulgarian.WebsiteShortcut=Уебсайт на HomeLib Ru

English.HelpIndex=Help\en\index.html
Ukrainian.HelpIndex=Help\uk\index.html
Bulgarian.HelpIndex=Help\bg\index.html

[INI]
;
Filename: {userappdata}\MyHomeLib\myhomelib2.ini; Section: INTERFACE; Key: Locale; String: {cm:LocaleCode}; Flags: createkeyifdoesntexist

#include "LegacyUpgrade.iss"
