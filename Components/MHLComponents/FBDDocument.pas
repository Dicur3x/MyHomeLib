(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov
  *                     Nick Rymanov (nrymanov@gmail.com)
  * Created             15.04.2010
  * Description
  *
  * $Id: FBDDocument.pas 1119 2012-10-29 01:52:46Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit FBDDocument;

//
// TODO -oNickR: разобраться с использованием FImage. Не везде есть проверки на nil, картинка не перерисовывается...
// TODO -oNickR: более аккуратная работа с архивами (расставить флаги у метода OpenArchive)
// TODO -oNickR: расставить const у параметров
//

interface

uses
  Windows,
  SysUtils,
  Classes,
  Graphics,
  fbd_xml,
  ExtCtrls,
  StdCtrls,
  FBDAuthorTable,
  unit_MHLArchiveHelpers;

type
  TCoverImageType = (itPng, itJPG);

  TResizeMode = (rmMax, rmHeight, rmWidth);

  TCoverSize = (cs160, cs200, cs320, cs400, cs640, cs800);

  TCover = record
    Str: string;
    ImgType: TCoverImageType;
  end;

  TAuthorListType = (atlBook, atlFBD, atlTrans);

  TSeriesListType = (sltBook, sltPublisher);

  TFBDDocument = class(TComponent)
  private
    FFBDFilename: string;
    FBookFilename: string;
    FArchiveFilename: string;
    FArchiveDescriptionName: string;
    FFolder: string;
    FProgramUsed: string;

    FMemo: TMemo;
    FImage: TImage;

    FFBD: IXMLFictionBookDescription;
    FCoverData: TCover;

    FCoverWidth: integer;
    FCoverHeight: integer;

    FResizeMode: TResizeMode;
    FReportErrors: Boolean;

    function GetCustomInfo: IXMLCustominfoList;
    function GetDocumentInfo: IXMLDocumentinfo;
    function GetPublishInfo: IXMLPublishinfo;
    function GetTitleInfo: IXMLTitleInfoType;
    procedure SetCustomInfo(const Value: IXMLCustominfoList);
    procedure SetDocumentInfo(const Value: IXMLDocumentinfo);
    procedure SetPublishInfo(const Value: IXMLPublishinfo);
    procedure SetTitleInfo(const Value: IXMLTitleInfoType);

    procedure SetFileNames(const Folder: string; const Filename: string; const Ext: string);
    procedure CreateImage(ext: string; var IMG: TGraphic; var ImageType: TCoverImageType);
    procedure SetMemo(Value: TMemo);
    procedure SetTImage(Value: TImage);
    function SaveFBD: Boolean;
    function CreateArchive(EditorMode: Boolean): boolean;
    procedure ResizeImage;
    function ExecAndWait(const FileName, Params: string; const WinState: Word): Boolean;
    procedure SetCoverSize(const Value: Integer);
    procedure SetResizeMode(const Value: Integer);

  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;

  public
    constructor Create(AOwner: TComponent); override;

    procedure New(Folder, Filename, Ext: string);
    function Load(Folder, Filename, Ext: string; NoCover: Boolean = False): Boolean;
    function Save(EditorMode: Boolean): Boolean;

    //
    // Пакетний режим сам звітує про помилки, тому діалог можна вимкнути.
    //
    property ReportErrors: Boolean read FReportErrors write FReportErrors;

    property Title: IXMLTitleInfoType read GetTitleInfo write SetTitleInfo;
    property Document: IXMLDocumentinfo read GetDocumentInfo write SetDocumentInfo;
    property Publisher: IXMLPublishinfo read GetPublishInfo write SetPublishInfo;
    property Custom: IXMLCustominfoList read GetCustomInfo write SetCustomInfo;
    property Cover: TCover read FCoverData write FCoverData;
    property ProgramUsed: string read FProgramUsed write FProgramUsed;

    //
    // Повне ім'я цільового архіву. Визначене після New/Load.
    //
    property ArchiveFileName: string read FArchiveFilename;

    procedure SetCustom(const Field: string; const Value: string);
    function GetCustom(const Field: string): string;

    function GetAuthors(ListType: TAuthorListType): TAuthorDataList;
    procedure SetAuthors(List: TAuthorDataList; ListType: TAuthorListType);
    procedure AddSeries(SeriesType: TSeriesListType; const Title: string; const No: integer);
    procedure LoadFBDFromFile(Folder, Filename, Ext: string);
    procedure AutoLoadCover;
    procedure DecodeCover(Path: string; FileName: string  = ''; Delete: boolean = True);
    procedure LoadCoverFromFile(FileName: string);
    procedure LoadCoverFromClpbrd;
    function ExtractBook(TempFolder: string):string;
    procedure ClearCover;
  published
    property Memo: TMemo read FMemo write SetMemo;
    property Image: TImage read FImage write SetTImage;
    property CoverSizeCode: Integer write SetCoverSize;
    property ResizeMode: Integer write SetResizeMode;
  end;

resourcestring
rstrErrorCreatingFBD = 'Помилка створення FBD!';
   rstrErrorLaunching = 'Не вдалося запустити %s!';

implementation

uses
  Forms,
  XMLDoc,
  XMLIntf,
  ClipBrd,
  EncdDecd,
  ActiveX,
  Dialogs,
  pngimage,
  jpeg,
  IOUtils,
  System.Zip;

const
  FBD_EXTENSION = '.fbd';
  ZIP_EXTENSION = '.zip';
  TEMP_EXTENSION = '.mhltmp';
  DEFAULT_PROGRAM_USED = 'MyHomeLib';

{ TFBDDocument }

procedure TFBDDocument.SetFileNames(const Folder: string; const Filename: string; const Ext: string);
begin
  FFBDFilename := FileName + FBD_EXTENSION;
  FBookFileName := FileName + Ext;
  FFolder := Folder;
  FArchiveFilename := TPath.Combine(Folder, FileName + ZIP_EXTENSION);
  FArchiveDescriptionName := '';
end;

procedure TFBDDocument.SetMemo(Value: TMemo);
begin
  if FMemo <> Value then
  begin
    if Assigned(FMemo) then
      FMemo.RemoveFreeNotification(Self);

    FMemo := Value;

    if Assigned(FMemo) then
      FMemo.FreeNotification(Self);
  end;
end;

procedure TFBDDocument.SetTImage(Value: TImage);
begin
  if FImage <> Value then
  begin
    if Assigned(FImage) then
      FImage.RemoveFreeNotification(Self);

    FImage := Value;

    if Assigned(FImage) then
      FImage.FreeNotification(Self);
  end;
end;

procedure TFBDDocument.ClearCover;
begin
  FCoverData.Str := '';
end;

constructor TFBDDocument.Create(AOwner: TComponent);
begin
  inherited;
  FResizeMode := rmMax;
  FProgramUsed := DEFAULT_PROGRAM_USED;
  FReportErrors := True;
end;

function TFBDDocument.Load(Folder, Filename, Ext: string; NoCover: boolean = False):boolean;
var
  Input, Output: TMemoryStream;
  archiver: TMHLZip;
  CoverID: string;
  i: integer;
  IMG: TGraphic;

  Lines: TStringList;
begin
  Result := False;
  SetFileNames(Folder, Filename, Ext);
  FCoverData.Str := '';
  Input := nil;
  Output := nil;
  archiver := nil;
  IMG := nil;
  Lines := TstringList.Create;
  try
    archiver := TMHLZip.Create(FArchiveFilename, True);
    Input := TMemoryStream.Create;
    if archiver.Find('*.fbd') then
    begin
      FArchiveDescriptionName := archiver.LastName;
      archiver.ExtractToStream(archiver.LastName, Input);
    end;

    if Assigned(Input) and (Input.Size > 0) then
    begin
      FFBD := LoadFictionBook(Input);

      if Assigned(FImage) then
      begin
        FImage.Picture := nil;
        if not NoCover and (FFBD.Description.Titleinfo.Coverpage.Count > 0) then
        begin
          CoverID := FFBD.Description.Titleinfo.Coverpage.ImageList[0].xlinkHref;
          Delete(CoverID, 1, 1);
          for i := 0 to FFBD.Binary.Count - 1 do
          begin
            if FFBD.Binary.Items[i].Id = CoverID then
            begin
              Output := nil;
              IMG := nil;
              try
                Output := TMemoryStream.Create;
                Lines.Clear;
                Input.Clear;
                Lines.Text := FFBD.Binary.Items[i].Text;
                FCoverData.Str := FFBD.Binary.Items[i].Text;

                Lines.SaveToStream(Output);

                Output.Seek(0,soFromBeginning);
                DecodeStream(Output, Input);

                CreateImage(ExtractFileExt(CoverID), IMG, FCoverData.ImgType);
                if Assigned(IMG) then
                begin
                  Input.Seek(0,soFromBeginning);
                  IMG.LoadFromStream(Input);
                  FImage.Picture.Assign(IMG);
                  FImage.Invalidate;
                end;
              finally
                IMG.Free;
                Output.Free;
              end;
            end;
          end;
        end;
      end;

      with FFBD.Description do
      begin
        if not NoCover and Assigned(FMemo) then
        begin
          FMemo.Lines.BeginUpdate;
          try
            FMemo.Clear;

            if Titleinfo.Annotation.P.Count <> 0 then
            begin
              for I := 0 to Titleinfo.Annotation.P.Count - 1 do
                FMemo.Lines.Add(Titleinfo.Annotation.P.Items[i].Text)
            end
            else
            begin
              for I := 0 to Titleinfo.Annotation.ChildNodes.Count - 1 do
                FMemo.Lines.Add(Titleinfo.Annotation.ChildNodes[i].Text);
            end;
          finally
            FMemo.Lines.EndUpdate;
          end;
        end;
    end;
    Result := True;
  end;
  finally
    FreeAndNil(archiver);
    FreeAndNil(Input);
    FreeAndNil(Lines);
  end;
end;

procedure TFBDDocument.LoadCoverFromFile(FileName: string);
var
  IMG: TGraphic;
  Input, Output: TMemoryStream;
  Lines: TStringList;
begin
  if not Assigned(FImage) then
    Exit;

  IMG := nil;
  try
    CreateImage(ExtractFileExt(Filename), IMG, FCoverData.ImgType);
    if Assigned(IMG) then
    begin
      IMG.LoadFromFile(FileName);
      FImage.Picture.Bitmap.Assign(IMG);

      ResizeImage;
      IMG.Assign(FImage.Picture.Bitmap);

      Input := TMemoryStream.Create;
      try
        IMG.SaveToStream(Input);
        Input.Seek(0,soFromBeginning);

        Output := TMemoryStream.Create;
        try
          EncodeStream(Input, Output);

          Lines := TStringList.Create;
          try
            Output.Seek(0, soFromBeginning);
            Lines.LoadFromStream(Output);
            FCoverData.Str := Lines.Text;
          finally
            Lines.Free;
          end;
        finally
          Output.Free;
        end;
      finally
        Input.Free;
      end;

      FCoverData.ImgType := FCoverData.ImgType;
    end;
  finally
    IMG.Free;
  end;
end;

procedure TFBDDocument.LoadCoverFromClpbrd;
var
  Input, Output: TMemoryStream;
  IMG: TGraphic;
  Lines : TStringList;
begin
  if not Assigned(FImage) then
    Exit;

  Output := TMemoryStream.Create;
  Input := TMemoryStream.Create;
  Lines := TStringList.Create;
  IMG := TJPEGImage.Create;
  try
    FImage.Picture.RegisterClipboardFormat(cf_BitMap, TPNGImage);
    FImage.Picture.RegisterClipboardFormat(cf_BitMap, TJPEGImage);
    FImage.Picture.Bitmap.LoadFromClipBoardFormat(cf_BitMap, ClipBoard.GetAsHandle(cf_Bitmap), 0);

    ResizeImage;

    IMG.Assign(FImage.Picture.Bitmap);
    IMG.SaveToStream(Input);

    Input.Seek(0,soFromBeginning);
    EncodeStream(Input,Output);
    Lines.Clear;
    Output.Seek(0,soFromBeginning);
    Lines.LoadFromStream(Output);
    FCoverData.Str := Lines.Text;

    FCoverData.ImgType := itJPG;
  finally
    Output.Free;
    Input.Free;
    IMG.Free;
    Lines.Free
  end;
end;

procedure TFBDDocument.LoadFBDFromFile(Folder, Filename, Ext: string);
begin
  SetFileNames(Folder, Filename, Ext);
  FFBD := LoadFictionBook(TPath.Combine(Folder, FFBDFileName));
end;

procedure TFBDDocument.New;
var
  XML : TXMLDocument;
begin
  SetFilenames(Folder, Filename, Ext);
  XML := TXMLDocument.Create(nil);
  try
    FFBD := GetFictionBook(XML);
    XML.Version := '1.0';
    XML.Encoding := 'UTF-8';
    XML.Options := XML.Options + [doNodeAutoIndent];
    FFBD.Attributes['xmlns:xlink'] := 'http://www.w3.org/1999/xlink';
    FCoverData.Str := '';
  finally
  end;
end;

function TFBDDocument.ExtractBook(TempFolder: string):string;
var
  archiver: TMHLZip;
  MS: TMemoryStream;
  No, I: integer;
  EntryName: string;
begin
  Result := '';
  MS := nil;
  archiver := nil;
  try
    archiver := TMHLZip.Create(FArchiveFilename, True);
    No := -1;
    if archiver.Find(FBookFilename) then
      No := archiver.LastIndex
    else
      for I := 0 to archiver.FileCount - 1 do
        if not SameText(ExtractFileExt(archiver.FileNameAt(I)), FBD_EXTENSION) then
        begin
          No := I;
          Break;
        end;

    if No < 0 then
      raise EInvalidOpException.Create('Book payload was not found in FBD archive');
    MS := archiver.ExtractToStream(No);
    EntryName := StringReplace(archiver.FileNameAt(No), '/', '\', [rfReplaceAll]);
    Result := TPath.Combine(TempFolder, ExtractFileName(EntryName));
    MS.SaveToFile(Result);
  finally
    FreeAndNil(archiver);
    FreeAndNil(MS);
  end;
end;

procedure TFBDDocument.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) then
  begin
   if FMemo = AComponent then
     Memo := nil
   else if FImage = AComponent then
     Image := nil;
  end;
end;

function TFBDDocument.Save(EditorMode: boolean): Boolean;
begin
  Result := SaveFBD and CreateArchive(EditorMode);
end;

function TFBDDocument.SaveFBD : boolean;
var
  Bin : IXMLBinary;
  C: IXMLImageType;
  P: IXMLPType;
  Str: string;
  i: integer;
  XML : TXMLDocument;

begin
  XML := nil;
  try
    if Cover.Str <> '' then
    begin
      // Prepare FFBD for addition of the cover later on in the flow
      FFBD.Binary.Clear;
      FFBD.Description.Titleinfo.Coverpage.Clear;
    end;

    with FFBD.Description.Titleinfo do
    begin
      Annotation.ChildNodes.Clear;
      if Assigned(FMemo) then
      begin
        for I := 0 to FMemo.Lines.Count - 1 do
        begin
          Str := FMemo.Lines[i];
          // StrReplace(#10,'',str);
          P := Annotation.P.Add;
          P.Text := Str;
        end;
      end;
    end; // with Description

    with FFBD.Description do
    begin
      DocumentInfo.Programused.Text := FProgramUsed;
      DocumentInfo.Date.Text := DateToStr(Now);
      DocumentInfo.Version := '1.0';
    end;

    if Cover.Str <> '' then
    begin
      Bin := FFBD.Binary.Add;
      C := FFBD.Description.Titleinfo.Coverpage.Add;

      case Cover.ImgType of
        itPng: begin
                 Bin.Id := 'cover.png';
                 C.xlinkHref := '#cover.png';
                 Bin.Contenttype := 'image/png';
               end ;
        itJPG: begin
                 Bin.Id := 'cover.jpg';
                 C.xlinkHref := '#cover.jpg';
                 Bin.Contenttype := 'image/jpeg';
               end;
      end;
      Bin.Text := Cover.Str;
    end;

    XML := TXMLDocument.Create(nil);
    XML.Options := XML.Options + [doNodeAutoIndent];
    XML.LoadFromXML(FFBD.XML);
    XML.SaveToFile(TPath.Combine(FFolder, FFBDFileName));
    XML.Active := False;

    Result := True;
  finally
    XML.Free;
  end;
end;

function TFBDDocument.CreateArchive(EditorMode: boolean):boolean;
var
  archiveFileName: string;
  bookFileName: string;
  fbdFileName: string;
  tempArchiveFileName: string;
  tempEntryFileName: string;
  entryName: string;
  i: Integer;
  descriptionReplaced: Boolean;
  archiver: TMHLZip;
  sourceArchiver: TMHLZip;
  validator: TMHLZip;
  entryStream: TFileStream;
begin
  Result := False;
  archiver := nil;
  sourceArchiver := nil;
  validator := nil;
  entryStream := nil;
  tempArchiveFileName := '';
  tempEntryFileName := '';

  archiveFileName := FArchiveFilename;
  bookFileName := TPath.Combine(FFolder, FBookFileName);
  fbdFileName := TPath.Combine(FFolder, FFBDFileName);

  try
    repeat
      tempArchiveFileName := TPath.Combine(ExtractFilePath(archiveFileName),
        TPath.GetRandomFileName + TEMP_EXTENSION);
    until not FileExists(tempArchiveFileName);

    if EditorMode then
    begin
      if not FileExists(archiveFileName) then
        raise EFileNotFoundException.CreateFmt('Archive "%s" was not found',
          [archiveFileName]);

      // Preserve the original ZIP order. Removing the descriptor and appending
      // it would shift the book index stored in the collection database.
      sourceArchiver := TMHLZip.Create(archiveFileName, True);
      archiver := TMHLZip.Create(tempArchiveFileName, False);
      tempEntryFileName := tempArchiveFileName + '.entry';
      descriptionReplaced := False;
      for i := 0 to sourceArchiver.FileCount - 1 do
      begin
        entryName := sourceArchiver.FileNameAt(i);
        if (not descriptionReplaced) and
           (((FArchiveDescriptionName <> '') and
             SameText(entryName, FArchiveDescriptionName)) or
            ((FArchiveDescriptionName = '') and
             SameText(ExtractFileExt(entryName), FBD_EXTENSION))) then
        begin
          entryStream := TFileStream.Create(fbdFileName,
            fmOpenRead or fmShareDenyWrite);
          try
            archiver.AddFromStream(entryName, entryStream);
          finally
            FreeAndNil(entryStream);
          end;
          descriptionReplaced := True;
        end
        else
        begin
          entryStream := TFileStream.Create(tempEntryFileName, fmCreate);
          try
            // Extraction validates CRC before the payload is repacked.
            sourceArchiver.ExtractToStream(i, entryStream);
            archiver.AddFromStream(entryName, entryStream);
          finally
            FreeAndNil(entryStream);
          end;
        end;
      end;

      if not descriptionReplaced then
        raise EInvalidOpException.Create('FBD descriptor was not found in archive');
    end
    else
    begin
      archiver := TMHLZip.Create(tempArchiveFileName, False);
      // Raw books already have InsideNo=0. Keep the payload at index zero so
      // conversion does not invalidate the database record.
      archiver.AddFiles(bookFileName);
      archiver.AddFiles(fbdFileName);
    end;

    // TZipFile writes the central directory on close. Validate the completed
    // temporary archive, then replace the destination atomically.
    FreeAndNil(archiver);
    FreeAndNil(sourceArchiver);
    validator := TMHLZip.Create(tempArchiveFileName, True);
    Result := validator.FileCount > 0;
    FreeAndNil(validator);

    if Result then
    begin
      if not Windows.MoveFileEx(PChar(tempArchiveFileName),
        PChar(archiveFileName), MOVEFILE_REPLACE_EXISTING or
        MOVEFILE_WRITE_THROUGH) then
        RaiseLastOSError;
      tempArchiveFileName := '';

      SysUtils.DeleteFile(fbdFileName);
      if not EditorMode then
        SysUtils.DeleteFile(bookFileName);
    end;
  except
    Result := False;
  end;

  FreeAndNil(entryStream);
  FreeAndNil(archiver);
  FreeAndNil(sourceArchiver);
  FreeAndNil(validator);
  if (tempEntryFileName <> '') and FileExists(tempEntryFileName) then
    SysUtils.DeleteFile(tempEntryFileName);
  if (tempArchiveFileName <> '') and FileExists(tempArchiveFileName) then
    SysUtils.DeleteFile(tempArchiveFileName);

  if not Result then
    if FReportErrors then
      MessageDlg(rstrErrorCreatingFBD, mtError, [mbOK], 0);
end;

{--------------------  Списки авторов ----------------------------------------}
function TFBDDocument.GetAuthors(ListType: TAuthorListType): TAuthorDataList;
var
  i: integer;
  Author : IXMLAuthorTypeList;
begin
  case ListType of
    atlBook: Author := FFBD.Description.Titleinfo.Author;
    atlFBD: Author := FFBD.Description.Documentinfo.Author;
    atlTrans: Author := FFBD.Description.Titleinfo.Translator;
  end;

  SetLength(Result, Author.Count);
  for I := 0 to Author.Count - 1 do
  begin
    Result[i].Last := Author[i].LastName.Text;
    Result[i].First := Author[i].FirstName.Text;
    Result[i].Middle := Author[i].MiddleName.Text;
    Result[i].Nick := Author[i].NickName.Text;
    if Author[i].Email.Count > 0 then
      Result[i].Email:= Author[i].Email.Items[0];
    if Author[i].Homepage.Count > 0 then
      Result[i].Homepage := Author[i].Homepage[0];
  end;
end;

procedure TFBDDocument.SetAuthors(List: TAuthorDataList; ListType: TAuthorListType);
var
  Item: TAuthorRecord;
  A: IXMLAuthorType;
  Author : IXMLAuthorTypeList;
begin
  case ListType of
    atlBook  : Author := FFBD.Description.Titleinfo.Author;
    atlFBD   : Author := FFBD.Description.Documentinfo.Author;
    atlTrans : Author := FFBD.Description.Titleinfo.Translator;
  end;

  Author.Clear;
  for Item in List do
  begin
    A := Author.Add;
    A.Firstname.Text := Item.First;
    A.Lastname.Text := Item.Last;
    A.Middlename.Text := Item.Middle;
    A.Nickname.Text := Item.Nick;
    A.Email.Add(Item.Email);
    A.Homepage.Add(Item.Homepage)
  end;
end;

procedure TFBDDocument.AutoLoadCover;
var
  CoverFile: string;
begin
  if (FCoverData.Str = '') then
  begin
    CoverFile := TPath.Combine(FFolder, ChangeFileExt(FBookFilename, '.jpg'));
    if FileExists(CoverFile) then
    begin
      LoadCoverFromFile(CoverFile);
    end
    else
    begin
      CoverFile := TPath.Combine(FFolder, ChangeFileExt(FBookFilename, '.png'));
      if FileExists(CoverFile) then
      begin
        LoadCoverFromFile(CoverFile);
      end;
    end;
    if (FCoverData.Str = '') and Assigned(FImage) then
      FImage.Picture := nil;
  end;
end;

procedure TFBDDocument.DecodeCover(Path: string; FileName: string; Delete: boolean);
var
  S, Params, Ext: string;
begin
  if Filename = '' then
    FileName := TPath.Combine(FFolder, FBookFileName);

  if Assigned(FImage) then
    FImage.Picture := nil;
  FCoverData.Str := '';
  Ext := AnsiLowerCase(ExtractFileExt(FileName));
  if (Ext = '.djvu') or (Ext = '.pdf') or (Ext = '.djv') then
  begin
    S := ChangeFileExt(FileName, '.jpg');
    Params := Format('"%s" /convert="%s"', [FileName, S]);
    ExecAndWait(Path + 'decoders\iv\i_view32.exe', Params, SW_HIDE);
    LoadCoverFromFile(S);
    if Delete then
      DeleteFile(S);
  end;
end;

{--------------------  Helpers -----------------------------------------------}

procedure TFBDDocument.AddSeries(SeriesType: TSeriesListType; const Title: string; const No: integer);
var
  Sequence : IXMLSequenceTypeList;
  S: IXMLSequenceType;
begin
  case SeriesType of
    sltBook : Sequence := FFBD.Description.Titleinfo.Sequence;
    sltPublisher : Sequence := FFBD.Description.Publishinfo.Sequence;
  end;

  Sequence.Clear;
  if Title <> '' then
  begin
    S := Sequence.Add;
    S.Name := Title;
    S.Number := No;
  end;
end;

procedure TFBDDocument.ResizeImage;
var
  thumbnail : TBitmap;
  thumbRect : TRect;

  procedure Max;
  begin
    if (thumbnail.Width > FCoverWidth) and (thumbnail.Height > FCoverHeight) then
    begin
      thumbRect.Left := 0;
      thumbRect.Top := 0;
      //proportional resize
      if thumbnail.Width > thumbnail.Height then
      begin
        thumbRect.Right := FCoverWidth;
        thumbRect.Bottom := (FCoverWidth * thumbnail.Height) div thumbnail.Width;
      end
      else
      begin
        thumbRect.Bottom := FCoverHeight;
        thumbRect.Right := (FCoverHeight * thumbnail.Width) div thumbnail.Height;
      end;
      thumbnail.Canvas.StretchDraw(thumbRect, thumbnail) ;
      //resize image
      thumbnail.Width := thumbRect.Right;
      thumbnail.Height := thumbRect.Bottom;
    end;
  end;

  procedure Width;
  begin
    if (thumbnail.Width > FCoverWidth) then
    begin
      thumbRect.Left := 0;
      thumbRect.Top := 0;

      //proportional resize
      thumbRect.Right := FCoverWidth;
      thumbRect.Bottom := (FCoverWidth * thumbnail.Height) div thumbnail.Width;
      thumbnail.Canvas.StretchDraw(thumbRect, thumbnail) ;
      //resize image
      thumbnail.Width := thumbRect.Right;
      thumbnail.Height := thumbRect.Bottom;
    end;
  end;

  procedure Height;
  begin
    if (thumbnail.Height > FCoverHeight) then
    begin
      thumbRect.Left := 0;
      thumbRect.Top := 0;

      //proportional resize
      thumbRect.Bottom := FCoverHeight;
      thumbRect.Right := (FCoverHeight * thumbnail.Width) div thumbnail.Height;
      thumbnail.Canvas.StretchDraw(thumbRect, thumbnail) ;
      //resize image
      thumbnail.Width := thumbRect.Right;
      thumbnail.Height := thumbRect.Bottom;
    end;
  end;

begin
  if not Assigned(FImage) then
    Exit;

  thumbnail := FImage.Picture.Bitmap;
  case FResizeMode of
     rmMax    : Max;
     rmHeight : Height;
     rmWidth  : Width;
  end;
end;

procedure TFBDDocument.CreateImage(ext: string; var IMG: TGraphic; var ImageType: TCoverImageType);
begin
  IMG := nil;
  Ext := LowerCase(Ext);
  if Ext = '.png' then
  begin
    IMG := TPngImage.Create;
    ImageType := itPNG;
  end
  else if (Ext = '.jpg') or (Ext = '.jpeg') then
  begin
    IMG := TJPEGImage.Create;
    ImageType := itJPG;
  end;
end;

{--------------   Custom info           --------------------------------------}

function TFBDDocument.GetCustom(const Field: string): string;
var
  i: integer;
begin
  Result := '';
  with FFBD.Description do
    for i := 0 to Custominfo.Count - 1 do
      if Custominfo.Items[i].Infotype = Field then
      begin
        Result := Custominfo.Items[i].Text;
        Break;
      end;
end;

procedure TFBDDocument.SetCoverSize(const Value: Integer);
const
   H : array [0..6] of Integer = (120, 160, 200, 320, 400, 640, 800);
   W : array [0..6] of Integer = (90,  120, 150, 240, 300, 480, 600);
begin
  FCoverWidth := W[Value];
  FCoverHeight := H[Value];
end;

procedure TFBDDocument.SetCustom(const Field, Value: string);
var
  Item : IXMLCustomInfo;
begin
  if Value = '' then Exit;

  Item := FFBD.Description.Custominfo.Add;
  Item.Infotype := Field;
  Item.Text := Value;
end;

function TFBDDocument.ExecAndWait(const FileName,Params: String; const WinState: Word): boolean;
var
  StartInfo: TStartupInfo;
  ProcInfo: TProcessInformation;
  CmdLine: String;
begin
  CmdLine := '"' + FileName + '"';
  if Params <> '' then
    CmdLine := CmdLine + ' ' + Params;
  FillChar(StartInfo, SizeOf(StartInfo), #0);
  with StartInfo do
  begin
    cb := SizeOf(StartInfo);
    dwFlags := STARTF_USESHOWWINDOW;
    wShowWindow := WinState;
  end;
  Result := CreateProcess(
    PChar(FileName),
    PChar(CmdLine),
    nil,
    nil,
    False,
    CREATE_NEW_CONSOLE or NORMAL_PRIORITY_CLASS,
    nil,
    PChar(ExtractFilePath(Filename)),
    StartInfo,
    ProcInfo
  );
  if Result then
  begin
    WaitForSingleObject(ProcInfo.hProcess, INFINITE);
    { Free the Handles }
    CloseHandle(ProcInfo.hProcess);
    CloseHandle(ProcInfo.hThread);
  end
  else
  begin
    // { TODO -oNickR -cRefactoring : не самая лучшая идея показывать диалоги прямо из этой функции. Она может быть вызвана из рабочего потока. }
    Application.MessageBox(PChar(Format(rstrErrorLaunching, [FileName])), '', mb_IconExclamation);
  end;
end;

{---------------   FBD sections         --------------------------------------}

function TFBDDocument.GetCustomInfo: IXMLCustominfoList;
begin
  Result := FFBD.Description.Custominfo;
end;

function TFBDDocument.GetDocumentInfo: IXMLDocumentinfo;
begin
  Result := FFBD.Description.Documentinfo;
end;

function TFBDDocument.GetPublishInfo: IXMLPublishinfo;
begin
  Result := FFBD.Description.Publishinfo;
end;

function TFBDDocument.GetTitleInfo: IXMLTitleInfoType;
begin
  Result := FFBD.Description.Titleinfo;
end;

procedure TFBDDocument.SetCustomInfo(const Value: IXMLCustominfoList);
begin
  FFBD.Description.Custominfo := Value;
end;

procedure TFBDDocument.SetDocumentInfo(const Value: IXMLDocumentinfo);
begin
  FFBD.Description.Documentinfo := Value;
end;

procedure TFBDDocument.SetPublishInfo(const Value: IXMLPublishinfo);
begin
  FFBD.Description.Publishinfo := Value;
end;

procedure TFBDDocument.SetResizeMode(const Value: Integer);
begin
  case Value of
    0: FResizeMode := rmMax;
    1: FResizeMode := rmHeight;
    2: FResizeMode := rmWidth;
  end;
end;

procedure TFBDDocument.SetTitleInfo(const Value: IXMLTitleInfoType);
begin
  FFBD.Description.Titleinfo := Value;
end;

end.
