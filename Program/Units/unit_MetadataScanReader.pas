unit unit_MetadataScanReader;

interface

uses System.SysUtils, unit_Globals, unit_MetadataSyncTypes, unit_FB2PublisherMetadataReader;

type
  TMetadataScanRead = record
    SourceKey, ErrorText: string;
    Metadata: TFB2CatalogMetadata;
    Failure: TMetadataReadFailure;
    Ready, Reused, ReadFile, Canceled: Boolean;
  end;

// Only uncached entries with a source key are read. Workers have separate
// archive handles, COM parsers and bounded prefixes; they never write a DB.
procedure ReadMetadataScanBatch(const Books: TArray<TBookRecord>;
  var Results: TArray<TMetadataScanRead>; const IsCanceled: TFunc<Boolean>;
  out ArchiveOpens: Integer; WorkerLimit: Integer = 4;
  const Progress: TProc<Integer> = nil);

implementation

uses Winapi.Windows, Winapi.ActiveX, System.Classes, System.SyncObjs, System.Math,
  unit_PublisherSeriesSource, unit_PackageBookMetadata, unit_MHLExternalTools;

procedure ReadMetadataScanBatch(const Books: TArray<TBookRecord>;
  var Results: TArray<TMetadataScanRead>; const IsCanceled: TFunc<Boolean>;
  out ArchiveOpens: Integer; WorkerLimit: Integer; const Progress: TProc<Integer>);
var Threads: TArray<TThread>; Handles: TArray<THandle>; NextIndex, Stop, OpenCount, Completed: Integer;
  Count, I, Jobs: Integer; FatalMessage, RequiredComponent: string; Guard: TObject;
  Values: TArray<TMetadataScanRead>; CancelCheck: TFunc<Boolean>; ReadJobs: TProc;


begin
  ArchiveOpens:=0; Jobs:=0; Values:=Results;
  if Length(Books)<>Length(Values) then raise EArgumentException.Create('Некорректный пакет метаданных');
  for I:=0 to High(Values) do if not Values[I].Ready and (Values[I].SourceKey<>'') then Inc(Jobs);
  if Jobs=0 then Exit;
  Count:=Min(Jobs,Max(1,Min(Min(4,WorkerLimit),Integer(TThread.ProcessorCount))));
  NextIndex:=0; Stop:=0; OpenCount:=0; Completed:=0; FatalMessage:=''; RequiredComponent:=''; Guard:=TObject.Create;
  CancelCheck:=function: Boolean begin Result:=TInterlocked.CompareExchange(Stop,0,0)<>0; end;
  ReadJobs:=procedure
  var Source: TPublisherSeriesSource; Reader: TFB2PublisherMetadataReader;
    Stream: TStream; Index: Integer; Extension, ErrorText: string;
    Status: TFB2MetadataStatus; HR: HRESULT;
  begin
    Source:=nil; Reader:=nil; HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
    try
      if Failed(HR) then raise EReadError.Create('Не удалось запустить чтение метаданных');
      Source:=TPublisherSeriesSource.Create(CancelCheck); Reader:=TFB2PublisherMetadataReader.Create;
      while not CancelCheck() do
      begin
        Index:=TInterlocked.Increment(NextIndex)-1;
        if Index>=Length(Books) then Break;
        if Values[Index].Ready or (Values[Index].SourceKey='') then Continue;
        Values[Index].ReadFile:=True; Values[Index].Failure:=mrfSourceRead;
        try
          Source.SetUpcoming(Books,Index); Stream:=Source.OpenCatalogMetadata(Books[Index],Extension);
          try
            Values[Index].Failure:=mrfInvalidMetadata;
            if not Assigned(Stream) then Status:=fmsComplete
            else if IsMetadataPackage(Extension) then
              Status:=ReadPackageMetadata(Stream,Extension,Values[Index].Metadata,ErrorText,True,CancelCheck)
            else Status:=Reader.ReadCatalogMetadata(Stream,Values[Index].Metadata,ErrorText,True,CancelCheck);
            if (Status=fmsInvalid) and Assigned(Stream) then
            begin
              Stream.Free; Stream:=nil; Stream:=Source.OpenCatalogMetadata(Books[Index],Extension);
              if IsMetadataPackage(Extension) then
                Status:=ReadPackageMetadata(Stream,Extension,Values[Index].Metadata,ErrorText,False,CancelCheck)
              else Status:=Reader.ReadCatalogMetadata(Stream,Values[Index].Metadata,ErrorText,False,CancelCheck);
            end;
          finally Stream.Free; end;
          if Status=fmsCanceled then begin Values[Index].Canceled:=True; Break; end;
          if Status<>fmsComplete then raise EReadError.Create(ErrorText);
          if Values[Index].SourceKey<>Source.GetSourceKey(Books[Index]) then
          begin Values[Index].Failure:=mrfSourceChanged; raise EReadError.Create('Файл книги изменился во время проверки'); end;
        except
          on E: EOutOfMemory do raise;
          on E: EAccessViolation do raise;
          on E: EMHLComponentRequired do raise;
          on E: EAbort do begin Values[Index].Canceled:=True; Break; end;
          on E: Exception do
          begin
            Values[Index].ErrorText:=E.Message;
            if E is ENotSupportedException then Values[Index].Failure:=mrfDecoder;
            if E is EMetadataAmbiguousBook then Values[Index].Failure:=mrfAmbiguous;
            if E is EFOpenError then Values[Index].Failure:=mrfUnavailable;
          end;
        end;
        Values[Index].Ready:=True; TInterlocked.Increment(Completed);
      end;
    finally
      if Assigned(Source) then TInterlocked.Add(OpenCount,Source.ArchiveOpenCount);
      Reader.Free; Source.Free; if Succeeded(HR) then CoUninitialize;
    end;
  end;

  SetLength(Threads,Count); SetLength(Handles,Count);
  try
    for I:=0 to Count-1 do
    begin
      Threads[I]:=TThread.CreateAnonymousThread(
        procedure
        begin
          try ReadJobs;
          except on E: Exception do
          begin
            TMonitor.Enter(Guard);
            try
              if FatalMessage='' then
              begin
                FatalMessage:=E.ClassName+': '+E.Message;
                if E is EMHLComponentRequired then RequiredComponent:=EMHLComponentRequired(E).ComponentID;
              end;
            finally TMonitor.Exit(Guard); end;
            TInterlocked.Exchange(Stop,1);
          end; end;
        end);
      Threads[I].FreeOnTerminate:=False; Handles[I]:=Threads[I].Handle; Threads[I].Start;
    end;
    repeat
      if Assigned(IsCanceled) and IsCanceled() then TInterlocked.Exchange(Stop,1);
      if Assigned(Progress) then Progress(TInterlocked.CompareExchange(Completed,0,0));
      case WaitForMultipleObjects(Count,@Handles[0],True,50) of
        WAIT_OBJECT_0: Break;
        WAIT_TIMEOUT: ;
      else RaiseLastOSError; end;
    until False;
    if RequiredComponent<>'' then raise EMHLComponentRequired.Create(RequiredComponent,FatalMessage);
    if FatalMessage<>'' then raise EReadError.Create(FatalMessage);
    ArchiveOpens:=OpenCount;
  finally
    TInterlocked.Exchange(Stop,1);
    for I:=0 to High(Threads) do
      if Assigned(Threads[I]) then begin Threads[I].WaitFor; Threads[I].Free; end;
    ReadJobs:=nil; CancelCheck:=nil; Guard.Free;
  end;
end;

end.
