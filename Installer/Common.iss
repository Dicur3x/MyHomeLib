; ****************************************************************************
;
; InnoSetup script for MyHomeLib
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
DefaultDirName = {autopf}\{#MyAppName}\
DefaultGroupName = {#MyAppName}
AppVerName = {#MyAppName + " v. " + ShortVersion}
UninstallDisplayIcon = {app}\{#AppExeName}
AppPublisherURL = {#AppURL}
AppSupportURL = {#AppURL}
AppUpdatesURL = {#AppURL}

[Dirs]
Name: "{userappdata}\{#MyAppName}"; Permissions: everyone-modify

[Icons]
Name: {group}\{#MyAppName}; Filename: {app}\{#AppExeName}; WorkingDir: {app}; IconFilename: {app}\{#AppExeName}; IconIndex: 0; Comment: {#MyAppName}
Name: {group}\{cm:HelpShortcut}; Filename: {app}\{cm:HelpIndex}; WorkingDir: {app}; IconFilename: {sys}\ieframe.dll; IconIndex: 36; Comment: {cm:HelpShortcut}
Name: {commondesktop}\{#MyAppName}; Filename: {app}\{#AppExeName}; WorkingDir: {app}; IconFilename: {app}\{#AppExeName}; IconIndex: 0; Comment: {#MyAppName}; Tasks: desktopicon
Name: {group}\{cm:WebsiteShortcut}; Filename: {app}\{#MyAppName}.url; IconFilename: {sys}\ieframe.dll; IconIndex: 36
Name: {group}\{cm:UninstallProgram,{#MyAppName}}; Filename: {uninstallexe}

[UninstallDelete]
Name: {userappdata}\{#MyAppName}\Data; Type: filesandordirs
Name: {userappdata}\{#MyAppName}\Presets; Type: filesandordirs
Name: {userappdata}\{#MyAppName}\*.*; Type: files
Name: {userappdata}\{#MyAppName}; Type: dirifempty
Name: {app}; Type: files

[Run]
Filename: {app}\{#AppExeName}; WorkingDir: {app}; Description: {cm:LaunchProgram,{#MyAppName}}; Flags: nowait postinstall skipifsilent

[InstallDelete]
Type: files; Name: {app}\MyHomeLib.chm

[Files]
Source: {#FullSourcePath}; DestDir: {app}; DestName: {#AppExeName}; Flags: replacesameversion

Source: {#LibFolder + 'sqlite3.dll'}; DestDir: {app}; Flags: replacesameversion

; Needs sqlite3.dll beside it: the DAO layer imports it at load time.
Source: {#SourceFolder + 'MHLMcpServer.exe'}; DestDir: {app}; Flags: replacesameversion

; No skipifsourcedoesntexist on purpose: without it the app installs with no icons.
Source: {#SourceFolder + 'Icons\MHLIcons.dll'}; DestDir: {app}\Icons; Flags: replacesameversion

Source: {#SourceFolder + 'libzstd.dll'}; DestDir: {app}; Flags: replacesameversion

Source: Common\AlReader\*; DestDir: {app}\AlReader; Flags: recursesubdirs
Source: Common\converters\fb2lrf\*; DestDir: {app}\converters\fb2lrf\; Flags: skipifsourcedoesntexist
Source: Common\converters\fb2pdf\*; DestDir: {app}\converters\fb2pdf\; Flags: skipifsourcedoesntexist
Source: Common\converters\fb2epub\*; DestDir: {app}\converters\fb2epub\; Flags: skipifsourcedoesntexist
Source: Common\converters\fb2mobi\*; DestDir: {app}\converters\fb2mobi\; Flags: skipifsourcedoesntexist
Source: Common\genres_nonfb2.glst; DestDir: {app}; Flags: replacesameversion
Source: Common\genres_fb2.glst; DestDir: {app}; Flags: replacesameversion
; Optional: the app falls back to the Russian original when these are absent.
Source: Common\genres_fb2_uk.glst; DestDir: {app}; Flags: replacesameversion
Source: Common\genres_nonfb2_uk.glst; DestDir: {app}; Flags: replacesameversion
Source: Common\genres_fb2_en.glst; DestDir: {app}; Flags: replacesameversion
Source: Common\genres_nonfb2_en.glst; DestDir: {app}; Flags: replacesameversion
Source: Common\genres_fb2_bg.glst; DestDir: {app}; Flags: replacesameversion
Source: Common\genres_nonfb2_bg.glst; DestDir: {app}; Flags: replacesameversion
Source: Common\collections.ini; DestDir: {userappdata}\MyHomeLib; Flags: onlyifdoesntexist
Source: Common\Help\*; DestDir: {app}\Help; Flags: recursesubdirs
Source: Common\MyHomeLib.url; DestDir: {app}; Flags: replacesameversion
Source: Common\License.txt; DestDir: {app}; Flags: replacesameversion
Source: Common\License_uk.txt; DestDir: {app}; Flags: replacesameversion

[Tasks]
Name: desktopicon; Description: {cm:CreateDesktopIcon}

[Languages]
; Licence files must be UTF-8 with BOM: Inno 6 reads BOM-less text as ANSI.
Name: English; MessagesFile: compiler:Default.isl; LicenseFile: Common\License.txt
Name: Ukrainian; MessagesFile: compiler:Languages\Ukrainian.isl; LicenseFile: Common\License_uk.txt
; Bulgarian uses the English licence on purpose: only the English MIT text is authoritative.
Name: Bulgarian; MessagesFile: compiler:Languages\Bulgarian.isl; LicenseFile: Common\License.txt

[CustomMessages]
; Initial app interface locale, keyed by wizard language.
English.LocaleCode=en
Ukrainian.LocaleCode=uk
Bulgarian.LocaleCode=bg

English.HelpShortcut=MyHomeLib Help
Ukrainian.HelpShortcut=Довідка MyHomeLib
Bulgarian.HelpShortcut=Помощ за MyHomeLib
English.WebsiteShortcut=MyHomeLib website
Ukrainian.WebsiteShortcut=Сайт MyHomeLib
Bulgarian.WebsiteShortcut=Уебсайт на MyHomeLib

; Ukrainian help is at the root of Help\, translations in Help\<locale>\.
English.HelpIndex=Help\en\index.html
Ukrainian.HelpIndex=Help\index.html
Bulgarian.HelpIndex=Help\bg\index.html

[INI]
; createkeyifdoesntexist is load-bearing: an update must never change an existing user's language.
; Writes to the installing (admin) user's profile, not necessarily the end user's.
Filename: {userappdata}\MyHomeLib\myhomelib2.ini; Section: INTERFACE; Key: Locale; String: {cm:LocaleCode}; Flags: createkeyifdoesntexist
