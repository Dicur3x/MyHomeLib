procedure TestFLibrarySourcePreparation;
var Folder, SourceHash, BeforeImages, BeforeBody, AgainImages, AgainBody, SourceBody,
  SavedTemplate: string;
  Source: TMemoryStream; Restored, Repeated: TStream; Book: TBookRecord;

  procedure Signature(const Input: TStream; out Images, Body: string; ExpectedImages: Integer=3;
    const ExpectedTitle: string='');
  var Document: IXMLDocument; Values: TStringList; Text: TStringBuilder;
    procedure Walk(const Node: IXMLNode; InBody: Boolean);
    begin
      if Node.NodeType in [Xml.XMLIntf.ntText,Xml.XMLIntf.ntCData] then
      begin
        if InBody then for var C in VarToStr(Node.NodeValue) do
          if not CharInSet(C,[' ',#9,#10,#13]) then Text.Append(C);
        Exit;
      end;
      if Node.LocalName='binary' then
      begin
        var ID:=VarToStr(Node.Attributes['id']);
        Require(Values.IndexOfName(ID)<0,'Preparation created duplicate binary ID '+ID);
        var ImageData:=TBytesStream.Create(TNetEncoding.Base64.DecodeStringToBytes(Node.Text));
        try Values.Add(ID+'='+THashSHA2.GetHashString(ImageData));
        finally ImageData.Free; end;
        Exit;
      end;
      for var I:=0 to Node.ChildNodes.Count-1 do
        Walk(Node.ChildNodes[I],InBody or (Node.LocalName='body'));
    end;
  begin
    Values:=TStringList.Create; Text:=TStringBuilder.Create;
    try
      Input.Position:=0; Document:=NewXMLDocument;
      Document.ParseOptions:=[poPreserveWhiteSpace]; Document.LoadFromStream(Input);
      if ExpectedTitle<>'' then
        Require(Document.DocumentElement.ChildNodes['description'].ChildNodes['title-info'].ChildNodes['book-title'].Text=ExpectedTitle,
          'Metadata rewrite did not publish the changed title');
      Walk(Document.DocumentElement,False); Values.Sort;
      Images:=Values.Text; Body:=Text.ToString;
      Require(Values.Count=ExpectedImages,'Unexpected number of image binaries from the compressed source');
      if ExpectedImages>0 then Require((Values.IndexOfName('cover')>=0) and (Values.IndexOfName('1')>=0) and
        (Values.IndexOfName('2')>=0),'Restored image identities differ from the compressed layout');
    finally Document:=nil; Text.Free; Values.Free; end;
  end;

begin
  RequireIsolatedRegression; Folder:=Settings.AppPath+'flibrary-source-fixtures\';
  Source:=TMemoryStream.Create; Restored:=nil;
  SavedTemplate:=Settings.BookHeaderTemplate;
  try
    Source.LoadFromFile(Folder+'557950.fb2'); SourceHash:=UpdateSHA256(Folder+'557950.fb2');
    Require(SameText(SourceHash,'efc28dc668f1d9971833a501baba6480e5a0775996652f6f921e6798118b3019'),
      'Actual compressed source fixture changed');
    Signature(Source,AgainImages,SourceBody,0);
    Source.Position:=17;
    Restored:=RestoreFLibraryBook(Folder+'source.7z','557950.fb2',Source);
    Require((Restored<>nil) and (Source.Position=17),'Restoration lost images or changed borrowed source position');
    Signature(Restored,BeforeImages,BeforeBody);
    Require((Length(BeforeBody)>10000) and (BeforeBody=SourceBody),'Restoration changed readable body text');
    Writeln('PASS actual FLibrary source restores one cover and two illustrations with unchanged borrowed bytes');
    Repeated:=RestoreFLibraryBook(Folder+'source.7z','557950.fb2',Restored);
    try Require(Repeated=nil,'Repeated restoration added already present image binaries');
    finally Repeated.Free; end;
    Signature(Restored,AgainImages,AgainBody);
    Require((AgainImages=BeforeImages) and (AgainBody=BeforeBody),'Repeated restoration changed text or image bytes');
    Writeln('PASS repeated FLibrary restoration does not create another cover or illustration');
    Book.Clear; Book.Title:='Проверка сведений — Ярлинги поневоле';
    Book.Series:=NO_SERIES_TITLE; Settings.BookHeaderTemplate:='%t';
    for var Pass:=1 to 2 do
    begin
      if Pass=1 then Book.Title:='Проверка сведений '+string.Create('я',400)
      else Book.Title:='Короткое название';
      Restored.Position:=0;
      Require(WriteFb2InfoToStream(Book,Restored),'Metadata rewrite failed for the restored source');
      Signature(Restored,AgainImages,AgainBody,3,Book.Title);
      Require((AgainImages=BeforeImages) and (AgainBody=BeforeBody),'Metadata rewrite changed text or image binaries');
    end;
    Require(UpdateSHA256(Folder+'557950.fb2')=SourceHash,'Preparation modified original fixture bytes');
    Writeln('PASS repeated native FB2 metadata rewrite preserves every restored image and readable body');
  finally Settings.BookHeaderTemplate:=SavedTemplate; Restored.Free; Source.Free; end;
end;
