program LibraryIndexFetchTest;
{$APPTYPE CONSOLE}
{$R *.res}
uses System.SysUtils, System.Classes, System.IOUtils, System.Hash,
  System.Net.HttpClient, System.Net.URLClient,
  unit_LibraryUpdateSources, unit_LibraryUpdateFetch;

procedure Check(Value: Boolean; const Reason: string);
begin if not Value then raise Exception.Create(Reason); end;

var Source: TLibraryUpdateSource; Staged: TStagedLibraryIndex;
  InputName, NativeInput, Root, NativeRoot, Original, Folder, Prepared, Note: string;
  Rejected, Locked: Boolean; Checks, ProgressCount: Integer;
  Writer: TFileStream; HTTP: THTTPClient;
begin
  SetTextCodePage(Output,65001);
  try
    if ParamCount<2 then raise EArgumentException.Create('Input and private cache root required');
    InputName:=TPath.GetFullPath(ParamStr(1)); Root:=TPath.GetFullPath(ParamStr(2));
    NativeInput:='\\?\'+InputName; NativeRoot:='\\?\'+Root;
    Original:=THashSHA2.GetHashStringFromFile(NativeInput);
    Writer:=TFileStream.Create(NativeInput,fmOpenWrite or fmShareDenyNone); Writer.Free;
    Source:=TLibraryUpdateSource.NewSource; Source.Name:='Read-only test index';
    Source.Location:=TPath.GetDirectoryName(InputName); Source.IndexFile:=TPath.GetFileName(InputName);
    ProgressCount:=0; Locked:=False;
    Staged:=TStagedLibraryIndex.Fetch(Source,Root,nil,nil,
      procedure(Done,Total:Int64)
      begin
        Inc(ProgressCount);
        try Writer:=TFileStream.Create(NativeInput,fmOpenWrite or fmShareDenyNone); Writer.Free;
        except on E:Exception do Locked:=True; end;
      end);
    Folder:=Staged.Folder; Prepared:=Staged.FileName;
    try
      Check(Staged.SHA256=Original,'Local staged bytes changed');
      Check(THashSHA2.GetHashStringFromFile(Prepared)=Original,'Prepared snapshot cannot be read');
      Check((ProgressCount>0) and Locked,'Local original was not protected during copying');
      Rejected:=False;
      try Writer:=TFileStream.Create(Prepared,fmOpenWrite or fmShareDenyNone); Writer.Free;
      except on E:Exception do Rejected:=True; end;
      Check(Rejected,'Prepared snapshot could be changed after checking');
    finally Staged.Free; end;
    Check(not DirectoryExists(Folder),'Completed private staging was not removed');
    Check(THashSHA2.GetHashStringFromFile(NativeInput)=Original,'Local original was changed/deleted');
    Rejected:=False; Checks:=0;
    try
      Staged:=TStagedLibraryIndex.Fetch(Source,Root,nil,
        procedure begin Inc(Checks); if Checks>=3 then raise EAbort.Create('Cancel during copy'); end);
      Staged.Free;
    except on E:EAbort do Rejected:=True; end;
    Check(Rejected,'Mid-copy cancellation was ignored');
    Check(Length(TDirectory.GetDirectories(NativeRoot,'HomeLibre-index-*'))=0,'Canceled staging was retained');
    Check(THashSHA2.GetHashStringFromFile(NativeInput)=Original,'Cancellation changed original');
    Staged:=TStagedLibraryIndex.Fetch(Source,Root,nil);
    Folder:=Staged.Folder; Note:=TPath.Combine(Folder,'foreign-note.txt');
    TFile.WriteAllText(Note,'Keep unexpected data'); Staged.Free;
    Check(TFile.ReadAllText(Note)='Keep unexpected data','Cleanup removed unexpected data');
    TFile.Delete(Note); TDirectory.Delete(Folder);
    if ParamCount>=3 then
    begin
      HTTP:=THTTPClient.Create;
      try
        HTTP.ProxySettings:=TProxySettings.Create('direct',80,'','','http');
        HTTP.ConnectionTimeout:=2000; HTTP.ResponseTimeout:=2000;
        Source.Location:=ParamStr(3); Source.IndexFile:='folder/индекс с пробелом.inpx';
        Staged:=TStagedLibraryIndex.Fetch(Source,Root,HTTP);
        try Check(Staged.SHA256=Original,'Remote source did not use the exact endpoint/path');
        finally Staged.Free; end;
        Source.IndexFile:='missing.inpx'; Rejected:=False;
        try Staged:=TStagedLibraryIndex.Fetch(Source,Root,HTTP); Staged.Free;
        except on E:EReadError do Rejected:=True; end;
        Check(Rejected,'HTTP error was accepted as an index');
        Check(Length(TDirectory.GetDirectories(NativeRoot,'HomeLibre-index-*'))=0,'Failed HTTP staging was retained');
      finally HTTP.Free; end;
    end;
    Writeln('PASS: immutable local/remote staging, source leases, Unicode, cancellation, HTTP failure, nonrecursive cleanup');
  except on E:Exception do begin Writeln(E.ClassName+': '+E.Message); ExitCode:=1; end; end;
end.
