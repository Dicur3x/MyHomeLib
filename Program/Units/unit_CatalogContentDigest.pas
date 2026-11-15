unit unit_CatalogContentDigest;

interface

uses System.SysUtils, SQLiteWrap;

// Stream the logical SQLite state in deterministic table/row order. No copy
// of all rows or database-sized serialized buffer is retained in memory.
function CatalogContentDigest(Database: TSQLiteDatabase; const Check: TProc): string;

implementation

uses System.Classes, System.Hash;

function Identifier(const Value: string): string;
begin Result:='"'+Value.Replace('"','""')+'"'; end;

function CatalogContentDigest(Database: TSQLiteDatabase; const Check: TProc): string;
var Hash: THashSHA2; Schema, Columns, Rows: TSQLiteQuery;
  Names, Keys: TStringList; Name, SQL, Projection, Ordering, RowID: string;
  Count: Int64;
  procedure Add(const Value: string);
  var Bytes: TBytes;
  begin
    Bytes:=TEncoding.UTF8.GetBytes(Value);
    Hash.Update(TEncoding.ASCII.GetBytes(IntToStr(Length(Bytes))+':'));
    if Length(Bytes)>0 then Hash.Update(Bytes);
  end;
begin
  if not Assigned(Database) then raise EArgumentNilException.Create('Database');
  Hash:=THashSHA2.Create; Add('HomeLibre catalogue logical digest 1'); Count:=0;
  Schema:=Database.NewQuery('SELECT type,name,coalesce(sql,'''') FROM sqlite_master '+
    'WHERE name NOT LIKE ''sqlite_stat%'' ORDER BY type COLLATE BINARY,name COLLATE BINARY');
  Names:=TStringList.Create; Keys:=TStringList.Create;
  try
    Names.CaseSensitive:=False; Schema.Open;
    while not Schema.Eof do
    begin
      if Assigned(Check) then Check;
      Add(Schema.FieldAsString(0)); Name:=Schema.FieldAsString(1); Add(Name); Add(Schema.FieldAsString(2));
      if Schema.FieldAsString(0)='table' then
      begin
        Names.Clear; Keys.Clear; Projection:='';
        Columns:=Database.NewQuery('PRAGMA table_info('+Identifier(Name)+')');
        try
          Columns.Open;
          while not Columns.Eof do
          begin
            var Column:=Columns.FieldAsString(1); Names.Add(Column);
            if Projection<>'' then Projection:=Projection+',';
            // hex preserves embedded NULs and distinguishes text from blobs.
            // SQLite's 26-digit real formatting preserves binary64 values.
            Projection:=Projection+'typeof('+Identifier(Column)+'),CASE typeof('+Identifier(Column)+') '+
              'WHEN ''real'' THEN printf(''%!.26g'','+Identifier(Column)+') ELSE hex('+Identifier(Column)+') END';
            if Columns.FieldAsInt(5)>0 then Keys.Add(Format('%.8d',[Columns.FieldAsInt(5)])+' '+Identifier(Column));
            Columns.Next;
          end;
        finally Columns.Free; end;
        if Projection='' then raise EReadError.Create('Нет столбцов таблицы для проверки: '+Name);
        RowID:='';
        for var Candidate in TArray<string>.Create('rowid','_rowid_','oid') do
          if (RowID='') and (Names.IndexOf(Candidate)<0) then RowID:=Candidate;
        Ordering:='';
        if RowID<>'' then
        begin
          var Probe: TSQLiteQuery:=nil;
          try
            try
              Probe:=Database.NewQuery('SELECT '+RowID+' FROM '+Identifier(Name)+' LIMIT 0'); Probe.Open;
              Ordering:=RowID;
            except on E:ESQLiteException do
              if not E.Message.Contains('no such column') then raise;
            end;
          finally Probe.Free; end;
        end;
        if Ordering='' then
        begin
          Keys.Sort;
          for var I:=0 to Keys.Count-1 do
          begin
            if Ordering<>'' then Ordering:=Ordering+',';
            Ordering:=Ordering+Copy(Keys[I],10,MaxInt);
          end;
          if Ordering='' then raise EReadError.Create('Нет устойчивого порядка строк: '+Name);
        end
        else Projection:='quote('+RowID+'),'+Projection;
        SQL:='SELECT '+Projection+' FROM '+Identifier(Name)+' ORDER BY '+Ordering;
        Rows:=Database.NewQuery(SQL);
        try
          Rows.Open;
          while not Rows.Eof do
          begin
            if (Count mod 1000=0) and Assigned(Check) then Check;
            Add('row');
            for var I:=0 to Rows.ColCount-1 do Add(Rows.FieldAsString(I));
            Inc(Count); Rows.Next;
          end;
          Add('end-table');
        finally Rows.Free; end;
      end;
      Schema.Next;
    end;
    Add(IntToStr(Count)); Result:=Hash.HashAsString;
  finally Keys.Free; Names.Free; Schema.Free; end;
end;

end.
