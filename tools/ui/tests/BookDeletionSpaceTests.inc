procedure TestBookDeletionSpace;
var Root, Path, AliasPath, Moved, LongFolder: string;
  Before: TArray<TDeletionFileSpace>; Changes, Total: TArray<TDeletionVolumeSpace>;
  Stream: TFileStream; Buffer: TBytes; Returned: DWORD;
  State: TBookDeletionOperationStatus; Progress: TBookDeletionProgress;
  LabelText,ArchiveText,VolumesText: TLabel; CopyButton:TButton;
  Bitmap: TBitmap; R: TRect; Caption: string; CaptionFont: TFont; Padding,Flags:Integer;
  function Released(const Values:TArray<TDeletionVolumeSpace>):Int64;
  begin Result:=0; for var Value in Values do Inc(Result,Value.ReleasedBytes); end;
  function Unknown(const Values:TArray<TDeletionVolumeSpace>):Integer;
  begin Result:=0; for var Value in Values do Inc(Result,Value.UnmeasuredFiles); end;
  procedure Write(const FileName:string; Count:Integer);
  var Output:TFileStream;
  begin
    Output:=TFileStream.Create(DeletionNativePath(FileName),fmCreate);
    try
      SetLength(Buffer,Count); FillChar(Buffer[0],Count,$5A); Output.WriteBuffer(Buffer[0],Count);
    finally Output.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'space-measurement'); ForceDirectories(Root);
  Path:=Root+'точный файл.bin'; Write(Path,65536);
  Before:=CaptureDeletionSpace([Path]);
  Require((Length(Before)=1) and Before[0].Known and Before[0].Exists and
    (Before[0].Bytes=65536),'Cannot measure the owned ordinary fixture');
  Stream:=TFileStream.Create(Path,fmOpenReadWrite);
  try Stream.Size:=4096; finally Stream.Free; end;
  Changes:=MeasureDeletionSpace(Before);
  Require((Released(Changes)=61440) and (Unknown(Changes)=0),'Shrink was not measured from the actual file');
  Total:=nil; AddDeletionSpace(Total,Changes);
  Before:=CaptureDeletionSpace([Path]); Write(Path,8192);
  Changes:=MeasureDeletionSpace(Before);
  Require(Released(Changes)=-4096,'Unexpected file growth was hidden');
  AddDeletionSpace(Total,Changes);
  Require((Length(Total)=1) and (Released(Total)=57344),'Cumulative accounting repeated or clamped a file');
  AliasPath:=Root+'same-file.bin'; Win32Check(CreateHardLink(PChar(AliasPath),PChar(Path),nil));
  Before:=CaptureDeletionSpace([Path,AliasPath]);
  Require(Length(Before)=1,'Two hard links were counted as two files');
  Win32Check(Winapi.Windows.DeleteFile(PChar(Path)));
  Require(Released(MeasureDeletionSpace(Before))=0,'Unlinking one name falsely released all file data');
  Before:=CaptureDeletionSpace([AliasPath]);
  Win32Check(Winapi.Windows.DeleteFile(PChar(AliasPath)));
  Require(Released(MeasureDeletionSpace(Before))=8192,'Deleting the final hard link lost the actual saving');
  Write(Path,8192); Before:=CaptureDeletionSpace([Path]); Moved:=Root+'old-file.bin';
  Win32Check(MoveFile(PChar(Path),PChar(Moved))); Write(Path,4096);
  Changes:=MeasureDeletionSpace(Before);
  Require((Unknown(Changes)=1) and (Released(Changes)=0),'A replacement file was credited as our deletion');
  Require(Unknown(MeasureDeletionSpace(CaptureDeletionSpace([Root])))=1,
    'An unsupported directory was silently counted as zero known bytes');
  LongFolder:=Root;
  for var I:=1 to 14 do LongFolder:=LongFolder+'длинная-папка-'+IntToStr(I)+PathDelim;
  ForceDirectories(DeletionNativePath(LongFolder)); Write(LongFolder+'книга.bin',32768);
  Before:=CaptureDeletionSpace([LongFolder+'книга.bin']);
  Require(Before[0].Known,'Long Unicode path could not be measured');
  Win32Check(Winapi.Windows.DeleteFile(PChar(DeletionNativePath(LongFolder+'книга.bin'))));
  Require(Released(MeasureDeletionSpace(Before))=32768,'Long Unicode deletion saving was lost');
  Path:=Root+'sparse-over-4gb.bin'; Stream:=TFileStream.Create(Path,fmCreate);
  try
    Win32Check(DeviceIoControl(Stream.Handle,$000900C4,nil,0,nil,0,Returned,nil));
    // TFileStream.Size/CRT extension can eagerly zero-fill the range even
    // after setting the sparse attribute. Extend the sparse file directly.
    Win32Check(SetFilePointerEx(Stream.Handle,Int64(5)*1024*1024*1024+4096,nil,FILE_BEGIN));
    Win32Check(SetEndOfFile(Stream.Handle)); Stream.Position:=Stream.Size-4096;
    SetLength(Buffer,4096); FillChar(Buffer[0],Length(Buffer),$5A); Stream.WriteBuffer(Buffer[0],Length(Buffer));
    Win32Check(FlushFileBuffers(Stream.Handle));
  finally Stream.Free; end;
  Before:=CaptureDeletionSpace([Path]);
  Writeln('TRACE sparse known=',Before[0].Known,' exists=',Before[0].Exists,' disk_bytes=',Before[0].Bytes);
  Require(Before[0].Known and (Before[0].Bytes>0) and (Before[0].Bytes<1024*1024),
    'Sparse accounting used the five-gigabyte logical size');
  Win32Check(Winapi.Windows.DeleteFile(PChar(Path)));
  Require(Released(MeasureDeletionSpace(Before))=Before[0].Bytes,'Sparse storage release was not measured');
  Writeln('PASS actual deletion space counts shrink growth hard-link aliases replacement long Unicode and sparse files beyond 4 GiB');

  State:=Default(TBookDeletionOperationStatus); SetLength(State.SpaceByVolume,5);
  for var I:=0 to 4 do
  begin
    State.SpaceByVolume[I].Volume:=Char(Ord('F')+I)+':\';
    State.SpaceByVolume[I].ReleasedBytes:=(I+1)*1024*1024;
  end;
  State.SpaceByVolume[4].ReleasedBytes:=-1024;
  State.Stage:=ArchiveDeletionWriteStage; State.Archive:=Root+'источник коллекции\общий архив.zip';
  State.SelectedDuplicates:=856998; State.CompletedCopies:=273178; State.DuplicateBatch:=28;
  State.Done:=100; State.Total:=10000; State.SkippedDuplicates:=3;
  Progress:=TBookDeletionProgress.CreateProgress(frmMain,nil,nil); Bitmap:=TBitmap.Create;
  try
    Progress.Show; Progress.UpdateProgress(State);
    ArchiveText:=Progress.FindComponent('BookDeletionCurrentArchive') as TLabel;
    CopyButton:=Progress.FindComponent('BookDeletionCopyPath') as TButton;
    Require((ArchiveText.Caption=State.Archive) and ArchiveText.Visible and
      CopyButton.Visible and Assigned(CopyButton.OnClick),'Current archive is not a static copyable path');
    State.Archive:=''; Progress.UpdateProgress(State);
    Require(not ArchiveText.Visible and not CopyButton.Visible,'Empty path leaves a blank input row');
    State.Archive:=Root+'источник коллекции\общий архив.zip'; Progress.UpdateProgress(State);
    LabelText:=Progress.FindComponent('BookDeletionReleasedSpace') as TLabel;
    Require(string(LabelText.Caption).Contains('Освобождено') and
      (Pos('F:',LabelText.Caption)=0),'Five volumes overloaded the compact total line');
    VolumesText:=Progress.FindComponent('BookDeletionVolumeTotals') as TLabel;
    for var Letter:='F' to 'J' do Require(string(VolumesText.Caption).Contains(Letter+':'), 'A drive disappeared from inline totals');
    Require(string(VolumesText.Caption).Contains('занято'),'Drive totals hide unexpected growth');
    Require(not Assigned(frmMain.FindComponent('BookDeletionSpaceReport')),'Inline totals open a second window');
    Inc(State.SpaceByVolume[0].ReleasedBytes,4096); Progress.UpdateProgress(State);
    Require(string(VolumesText.Caption).Contains(BookEstimateSizeText(State.SpaceByVolume[0].ReleasedBytes)),
      'Inline drive totals did not update');
    State.Stage:='Обновление коллекции'; State.Done:=12; State.Total:=50;
    Progress.UpdateProgress(State);
    Require(string((Progress.FindComponent('BookDeletionDetails') as TLabel).Caption).Contains('12 из 50'),
      'Catalogue progress appears frozen');
    for var DPI in [96,144,192,240,288] do
    begin
      Progress.ScaleForPPI(DPI); Progress.ClientWidth:=MulDiv(560,DPI,96); Progress.ClientHeight:=MulDiv(280,DPI,96);
      for var Confirm in [False,True] do
      begin
        State.AwaitingArchiveConfirmation:=Confirm; Progress.UpdateProgress(State);
        for var I:=0 to Progress.ControlCount-1 do
        begin
          var Control:=Progress.Controls[I]; if not Control.Visible then Continue;
          Require((Control.Left>=0) and (Control.Top>=0) and
            (Control.Left+Control.Width<=Progress.ClientWidth) and
            (Control.Top+Control.Height<=Progress.ClientHeight),
            Format('Deletion control %s/%s clipped at %d DPI: %d,%d %dx%d in %dx%d',
              [Control.ClassName,Control.Name,DPI,Control.Left,Control.Top,Control.Width,Control.Height,
              Progress.ClientWidth,Progress.ClientHeight]));
          Padding:=0; Flags:=DT_SINGLELINE; CaptionFont:=nil;
          if Control is TLabel then
          begin
            Caption:=TLabel(Control).Caption; CaptionFont:=TLabel(Control).Font;
            if TLabel(Control).WordWrap then Flags:=DT_WORDBREAK;
          end
          else if Control is TButton then
          begin Caption:=TButton(Control).Caption; CaptionFont:=TButton(Control).Font; Padding:=MulDiv(8,DPI,96); end;
          if not Assigned(CaptionFont) or (Control=ArchiveText) then Continue;
          Bitmap.Canvas.Font.Assign(CaptionFont); R:=Rect(0,0,Control.Width-Padding,0);
          DrawText(Bitmap.Canvas.Handle,PChar(Caption),Length(Caption),R,Flags or DT_CALCRECT);
          Require((R.Width+Padding<=Control.Width) and (R.Height<=Control.Height),
            Format('Deletion text clipped at %d DPI: %s (%dx%d > %dx%d)',
            [DPI,Caption,R.Width+Padding,R.Height,Control.Width,Control.Height]));
        end;
      end;
    end;
  finally Bitmap.Free; Progress.Free; end;
  ShowBookDeletionReport(frmMain,'Owned completion','Owned details');
  var Report:=TForm(frmMain.FindComponent('BookDeletionReport'));
  Require(Assigned(Report) and Report.Visible and (Report.FormStyle=fsStayOnTop) and
    IsWindowEnabled(frmMain.Handle),'Deletion result is hidden behind windows or blocks the catalogue');
  TButton(Report.FindComponent('PinBookDeletionReport')).Click;
  Require(Report.FormStyle=fsNormal,'Deletion result cannot be unpinned');
  Report.Close;
  Writeln('PASS compact deletion progress shows copyable full path and live inline five-drive totals at 100 to 300 percent');
end;
