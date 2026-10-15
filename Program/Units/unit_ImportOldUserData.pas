unit unit_ImportOldUserData;

interface

uses
  unit_UserData,
  Classes,
  SysUtils,
  Generics.Collections;

procedure LoadOldUserData(const FileName: string;
  var UserDataSource: TUserData);

implementation

type
  TLegacySection = (lsNone, lsGroups, lsRates, lsFinished, lsReviews, lsGroupedBooks);

procedure LoadOldUserData(const FileName: string;
  var UserDataSource: TUserData);
var
  Lines: TStringList;
  Parsed: TUserData;
  Groups: TDictionary<string, TBookGroup>;
  Section: TLegacySection;
  I, P, Number: Integer;
  Line, Header, ID, Value: string;
  Group: TBookGroup;

  procedure InvalidLine(const Reason: string);
  begin
    raise EConvertError.CreateFmt('Ошибка импорта пользовательских данных, строка %d: %s',
      [I + 1, Reason]);
  end;

begin
  Lines := TStringList.Create;
  Parsed := nil;
  Groups := nil;
  try
    Lines.LoadFromFile(FileName);
    Parsed := TUserData.Create;
    Groups := TDictionary<string, TBookGroup>.Create;
    Section := lsNone;
    // Every line is visited once, including blank lines, unknown sections and
    // text preceding the first section. No section needs a trailing sentinel.
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      Header := Trim(Line);
      if Header = '' then Continue;
      if Header[1] = '#' then
      begin
        Section := lsNone;
        if Header = '# Группы' then Section := lsGroups
        else if Header = '# Рейтинги' then Section := lsRates
        else if Header = '# Прочитанное' then Section := lsFinished
        else if Header = '# Рецензии' then Section := lsReviews
        else if Header = '# Избранное' then Section := lsGroupedBooks;
        Continue;
      end;
      if Section = lsNone then Continue;
      if Section = lsGroups then
      begin
        if Groups.ContainsKey(Line) then InvalidLine('название группы повторяется: ' + Line);
        Group := Parsed.Groups.AddGroup(Parsed.Groups.Count + 1, Line);
        Groups.Add(Line, Group);
        Continue;
      end;

      P := Pos(' ', Line);
      if P = 0 then
      begin
        if Section <> lsGroupedBooks then InvalidLine('ожидаются ID книги и значение через пробел');
        ID := Line;
        Value := '';
      end
      else
      begin
        ID := Copy(Line, 1, P - 1);
        Value := Copy(Line, P + 1, MaxInt);
      end;
      if ID = '' then InvalidLine('не указан ID книги');
      case Section of
        lsRates, lsFinished:
          begin
            if not TryStrToInt(Value, Number) then InvalidLine('неверное числовое значение');
            if Section = lsRates then Parsed.Extras.AddExtra(0, ID, Number, 0, '')
            else Parsed.Extras.AddExtra(0, ID, 0, Number, '');
          end;
        lsReviews: Parsed.Extras.AddExtra(0, ID, 0, 0, Value);
        lsGroupedBooks:
          begin
            if P = 0 then
            begin
              // Keep the historical second-group convention for bare IDs.
              // Without that group the old importer indexed outside the list;
              // guessing another group would silently move personal data.
              if Parsed.Groups.Count <= 1 then InvalidLine('для книги без названия группы отсутствует вторая группа');
              Group := Parsed.Groups[1];
            end
            else if not Groups.TryGetValue(Value, Group) then
              InvalidLine('неизвестная группа: ' + Value);
            Group.AddBook(0, ID);
          end;
      end;
    end;

    // Validate the whole file before exposing any partial personal data to the
    // caller. Existing destination entries survive both success and failure.
    UserDataSource.Extras.AddRange(Parsed.Extras);
    Parsed.Extras.OwnsObjects := False;
    UserDataSource.Groups.AddRange(Parsed.Groups);
    Parsed.Groups.OwnsObjects := False;
  finally
    Groups.Free;
    Parsed.Free;
    Lines.Free;
  end;
end;

end.
