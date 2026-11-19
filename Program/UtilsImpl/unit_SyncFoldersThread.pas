(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov (oleksiy.penkov@gmail.com)
  *                     Nick Rymanov (nrymanov@gmail.com)
  * Created             20.08.2008
  * Description
  *
  * $Id: unit_SyncFoldersThread.pas 1119 2012-10-29 01:52:46Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_SyncFoldersThread;

interface


uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  unit_CollectionWorkerThread, unit_Globals, files_list;

type
  TSyncFileEntry = record
    Name, Path: string;
  end;

  TSyncFoldersThread = class(TCollectionWorker)
  private
    FFiles: TFilesList;
    FFilesByName: TList<TSyncFileEntry>;
    procedure OnFile(Sender: TObject; const F: TSearchRec);
    function FindNewPath(const Book: TBookRecord; const Previous: string; out Ambiguous: Boolean): string;
  protected
    procedure WorkFunction; override;
  end;

implementation

uses
  Winapi.Windows, System.IOUtils, System.Generics.Defaults,
  unit_Consts, unit_MHL_strings, unit_Interfaces, unit_MHLArchiveHelpers,
  unit_BookDeletionMembers;

resourcestring
  rstrBuildingFileList = 'Создание списка файлов...';

procedure TSyncFoldersThread.OnFile(Sender: TObject; const F: TSearchRec);
var Entry: TSyncFileEntry;
begin
  if Canceled then begin FFiles.Stop; Exit; end;
  Entry.Name := F.Name;
  Entry.Path := FFiles.LastDir + F.Name;
  FFilesByName.Add(Entry);
end;

function TSyncFoldersThread.FindNewPath(const Book: TBookRecord; const Previous: string;
  out Ambiguous: Boolean): string;
var Format: TBookFormat; Size: Int64; Unverified, SeenUnverified: Boolean;
  Name, Path: string; First, Past, Middle: Integer;
  function BookSizeAt(const Candidate: string; out Unknown: Boolean): Int64;
  var Archive: TMHLZip; Member, Entry: string; Index: Integer;
  begin
    Result := -1; Unknown := False;
    try
      if not FileExists(Candidate) then Exit;
      if not (Format in [bfFb2Archive, bfRawArchive, bfFbd]) then Exit(TFile.GetSize(Candidate));
      Archive := TMHLZip.Create(Candidate, True, False, function: Boolean begin Result := Canceled; end);
      try
        if Format = bfFbd then
        begin
          var Inventory: TArray<string>;
          SetLength(Inventory, Archive.FileCount);
          for var I := 0 to High(Inventory) do Inventory[I] := Archive.FileNames[I];
          Member := ExactBookDeletionMembers(Book, Inventory)[1];
        end
        else
        begin
          Member := Book.FileName;
          if not SameText(ExtractFileExt(Member), Book.FileExt) then Member := Member + Book.FileExt;
        end;
        Index := -1;
        Member := Member.Replace('\', '/');
        for var I := 0 to Archive.FileCount - 1 do
        begin
          if Canceled then Abort;
          Entry := Archive.FileNames[I].Replace('\', '/');
          if Entry.EndsWith('/') or not SameText(Entry, Member) then Continue;
          if Index >= 0 then begin Unknown := True; Exit; end;
          Index := I;
        end;
        if Index >= 0 then Result := Archive.FileSizes[Index];
      finally Archive.Free; end;
    except
      on E: EAbort do raise;
      on E: Exception do Unknown := True;
    end;
  end;
begin
  Result := ''; Ambiguous := False; SeenUnverified := False;
  if (Book.Size <= 0) or (Book.FileName = '') then Exit;
  Name := ExtractFileName(Previous);
  First := 0; Past := FFilesByName.Count;
  while First < Past do
  begin
    Middle := First + (Past - First) div 2;
    if CompareText(FFilesByName[Middle].Name, Name) < 0 then First := Middle + 1
    else Past := Middle;
  end;
  Format := Book.GetBookFormat;
  for var I := First to FFilesByName.Count - 1 do
  begin
    if Canceled then Abort;
    if CompareText(FFilesByName[I].Name, Name) <> 0 then Break;
    Path := FFilesByName[I].Path;
    Size := BookSizeAt(Path, Unverified);
    SeenUnverified := SeenUnverified or Unverified;
    if Size <> Book.Size then Continue;
    if Result <> '' then begin Ambiguous := True; Exit(''); end;
    Result := Path;
  end;
  if SeenUnverified then
  begin
    Ambiguous := Result <> '';
    Result := '';
  end;
end;

procedure TSyncFoldersThread.WorkFunction;
var BookIterator: IBookIterator; Book, Current: TBookRecord;
  NewFolder, OldFile, NewFile: string; Ambiguous: Boolean; Relinked, Multiple: Integer;
begin
  Assert(Assigned(FSystemData));
  Assert(Assigned(FCollection));
  FFilesByName := TList<TSyncFileEntry>.Create;
  Relinked := 0; Multiple := 0;
  try
    FProgressEngine.BeginOperation(-1, rstrBuildingFileList, rstrBuildingFileList);
    try
      FFiles := TFilesList.Create(nil);
      try
        FFiles.OnFile := OnFile;
        FFiles.TargetPath := FCollectionRoot;
        FFiles.Process;
      finally FFiles.Free; end;
    finally FProgressEngine.EndOperation; end;
    if Canceled then Exit;
    FFilesByName.Sort(TComparer<TSyncFileEntry>.Construct(
      function(const Left, Right: TSyncFileEntry): Integer
      begin Result := CompareText(Left.Name, Right.Name); end));

    BookIterator := FCollection.GetBookIterator(bmAll, False);
    FProgressEngine.BeginOperation(BookIterator.RecordCount, rstrBookProcessedMsg1, rstrBookProcessedMsg2);
    try
      while BookIterator.Next(Book) do
      begin
        if Canceled then Exit;
        OldFile := Book.GetBookFileName;
        if not Book.IsLinkedSource and not FileExists(OldFile) then
        begin
          NewFile := FindNewPath(Book, OldFile, Ambiguous);
          if Ambiguous then Inc(Multiple);
          if (NewFile <> '') and not FileExists(OldFile) then
          begin
            FCollection.GetBookRecord(Book.BookKey, Current, False);
            if (Current.LibID = Book.LibID) and (Current.Folder = Book.Folder) and
              (Current.FileName = Book.FileName) and (Current.FileExt = Book.FileExt) and
              (Current.Size = Book.Size) and (Current.InsideNo = Book.InsideNo) then
            begin
              NewFolder := ExtractRelativePath(IncludeTrailingPathDelimiter(FCollectionRoot), ExtractFilePath(NewFile));
              if Book.GetBookFormat in [bfFb2Archive, bfRawArchive] then
                NewFolder := NewFolder + ExtractFileName(NewFile);
              FCollection.SetFolder(Book.BookKey, NewFolder);
              Inc(Relinked);
            end;
          end;
        end;
        FProgressEngine.AddProgress;
      end;
    finally FProgressEngine.EndOperation; end;
    if Multiple > 0 then ShowMessage(Format('Перепривязано книг: %d. Оставлено без изменения из-за нескольких ' +
      'или непроверенных совпадений: %d.', [Relinked, Multiple]), MB_OK or MB_ICONINFORMATION);
  finally FFilesByName.Free; end;
end;

end.
