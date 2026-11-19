(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov aka Koreec (oleksiy.penkov@gmail.com)
  *
  * Author(s)           Oleksiy Penkov (oleksiy.penkov@gmail.com)
  * Created             24.07.2026
  * Description         Maps form/tab HelpContext IDs onto the HTML help topics
  *                     shipped in the Help subfolder, and opens them in the
  *                     default browser.
  *
  ****************************************************************************** *)

unit unit_HelpTopics;

interface

const
  HELP_BOOK_CACHE = 149;
  HELP_BOOK_LISTS = 150;

function HelpTopicFile(ContextID: Integer): string;
function HelpTopicAnchor(ContextID: Integer): string;
function HelpTopicLink(const FullName, Anchor: string): string;
function HelpTopicPath(const Preferred, Fallback, Anchor: string): string;
procedure ShowHelpTopic(ContextID: Integer; const Anchor: string = '');

implementation

uses
  Windows,
  SysUtils,
  System.Classes,
  System.IOUtils,
  Forms,
  Dialogs,
  ShellAPI,
  Winapi.Shlwapi,
  unit_Consts,
  unit_Settings,
  unit_MHL_strings,
  dm_user;

const
  HELP_TOPIC_INDEX = 'index.html';

type
  THelpTopic = record
    ContextID: Integer;
    FileName: string;
  end;

const
  // Каждый ID взят из свойства HelpContext соответствующей формы, вкладки
  // или пункта меню. 5001 и любой неизвестный ID открывают содержание.
  HelpTopics: array [0 .. 23] of THelpTopic = (
    (ContextID: 1;   FileName: 'index.html'),              // pgControl
    (ContextID: 2;   FileName: 'main_window.html'),        // frmMain
    (ContextID: 105; FileName: 'menu_book.html'),          // меню "Книга"
    (ContextID: 108; FileName: 'download.html'),           // tsDownload
    (ContextID: 110; FileName: 'collections.html'),        // frmBases
    (ContextID: 112; FileName: 'menu_collection.html'),    // меню "Коллекция"
    (ContextID: 113; FileName: 'update.html'),             // dlgUpdateFromFile
    (ContextID: 117; FileName: 'editing.html'),            // frmEditAuthor
    (ContextID: 125; FileName: 'groups.html'),             // tsByGroup
    (ContextID: 126; FileName: 'search.html'),             // tsSearch
    (ContextID: 129; FileName: 'import_nonfb2.html'),      // frmAddNonFB2
    (ContextID: 132; FileName: 'set_interface.html'),      // tsInterface
    (ContextID: 133; FileName: 'set_internet.html'),       // tsInternet
    (ContextID: 135; FileName: 'browsing.html'),           // tsByAuthor/tsBySerie/tsByGenre
    (ContextID: 136; FileName: 'new_collection.html'),     // frmMHLWizardBase
    (ContextID: 137; FileName: 'set_readers.html'),        // tsReaders
    (ContextID: 140; FileName: 'set_scripts.html'),        // tsScripts
    (ContextID: 143; FileName: 'set_device.html'),         // tsDevices
    (ContextID: 144; FileName: 'settings.html'),           // frmSettings
    (ContextID: 145; FileName: 'set_internet.html'),       // tsProxy
    (ContextID: 147; FileName: 'set_other.html'),          // tsBehavour
    (ContextID: 148; FileName: 'set_filesort.html'),       // tsFileSort
    (ContextID: HELP_BOOK_CACHE; FileName: 'settings.html'),
    (ContextID: HELP_BOOK_LISTS; FileName: 'settings.html')
  );

function HelpTopicFile(ContextID: Integer): string;
var
  i: Integer;
begin
  for i := Low(HelpTopics) to High(HelpTopics) do
    if HelpTopics[i].ContextID = ContextID then
      Exit(HelpTopics[i].FileName);

  Result := HELP_TOPIC_INDEX;
end;

function HelpTopicAnchor(ContextID: Integer): string;
begin
  case ContextID of
    HELP_BOOK_CACHE: Result:='book-cache';
    HELP_BOOK_LISTS: Result:='book-lists';
  else
    Result:='';
  end;
end;

function HelpTopicLink(const FullName, Anchor: string): string;
var C: Char; Count: DWORD;
begin
  if Anchor='' then Exit(FullName);
  for C in Anchor do
    if not CharInSet(C,['a'..'z','A'..'Z','0'..'9','-','_']) then
      raise EArgumentException.Create('Invalid help section');
  // A '#' appended to a Windows filename is another filename, not a section.
  // Let Windows encode spaces, Unicode, '%' and '#' in the local file URL.
  Count:=Length(FullName)*9+32;
  SetLength(Result,Count);
  if UrlCreateFromPathW(PChar(FullName),PChar(Result),@Count,0)<0 then
    raise Exception.Create('Could not open the local help section');
  SetLength(Result,Count);
  Result:=Result+'#'+Anchor;
end;

function HelpTopicPath(const Preferred, Fallback, Anchor: string): string;
var Text: string;
begin
  Result:=Preferred;
  if not FileExists(Result) then Exit(Fallback);
  if Anchor='' then Exit;
  try
    Text:=TFile.ReadAllText(Result,TEncoding.UTF8);
    if (Pos('id="'+Anchor+'"',Text)=0) and (Pos('id='''+Anchor+'''',Text)=0) then
      Result:=Fallback;
  except
    // Incomplete translations must not hide a newly added help section.
    Result:=Fallback;
  end;
end;

procedure ShowHelpTopic(ContextID: Integer; const Anchor: string);
var
  HelpDir: string;
  FullName, Section: string;
begin
  HelpDir := ExtractFilePath(Settings.SystemFileName[sfAppHelp]);
  FullName := HelpDir + HelpTopicFile(ContextID);
  Section := Anchor;
  if Section = '' then Section := HelpTopicAnchor(ContextID);

  // A translated help tree may be incomplete -- pages are added to the
  // Ukrainian original over time and a translation lags. Fall back to the
  // Ukrainian page rather than refusing to show help at all, the same way a
  // partial catalog degrades to Ukrainian instead of blanking the UI.
  FullName:=HelpTopicPath(FullName,Settings.AppPath+APP_HELP_DIR_NAME+PathDelim+
    HelpTopicFile(ContextID),Section);

  if not FileExists(FullName) then
  begin
    MessageDlg(Format(rstrHelpFileNotFound, [FullName]), mtWarning, [mbOK], 0);
    Exit;
  end;

  FullName:=HelpTopicLink(FullName,Section);
  ShellExecute(Application.Handle, 'open', PChar(FullName), nil, nil, SW_SHOWNORMAL);
end;

end.
