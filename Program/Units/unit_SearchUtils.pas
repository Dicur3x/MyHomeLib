(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Created             12.02.2010
  * Description
  * Author(s)           Oleksiy Penkov  oleksiy.penkov@gmail.com
  *
  * $Id: unit_SearchUtils.pas 642 2010-08-26 13:04:37Z eg_ $
  *
  * History
  * NickR 15.02.2010    Код переформатирован
  *
  ****************************************************************************** *)

unit unit_SearchUtils;

interface

uses unit_Globals;

procedure AddToFilter(const Field: string; Value: string; UP: Boolean; var FilterString: string);
function PrepareQuery(S: string; UP: Boolean; ConverToFull: Boolean = True): string;
function PrepareSearchQuery(const S: string; UP: Boolean;
  Mode: TSearchQueryMode; ConvertToFull: Boolean = True): string;

procedure AddToWhere(var Where: string; const Filter: string);

implementation

uses
  StrUtils,
  SysUtils,
  unit_Consts;

function PrepareSearchQuery(const S: string; UP: Boolean;
  Mode: TSearchQueryMode; ConvertToFull: Boolean = True): string;
var Text: string;
begin
  if Mode = sqmLegacy then Exit(PrepareQuery(S, UP, ConvertToFull));
  Text := Trim(S);
  if Text = '' then Exit('');
  if UP then Text := AnsiUpperCase(Text);
  if Mode = sqmExpression then Exit(Text);
  if not ConvertToFull then Exit('=' + QuotedStr(Text));
  // Escape LIKE metacharacters before quoting the SQL literal. The explicit
  // escape character also keeps Windows path backslashes literal.
  Text := Text.Replace('!', '!!').Replace('%', '!%').Replace('_', '!_');
  Result := 'LIKE ' + QuotedStr('%' + Text + '%') + ' ESCAPE ''!''';
end;

function QualifySearchExpression(const Value, Field: string): string;
var
  I, Start: Integer;
  Quote: Char;
  IsOperator: Boolean;
  Builder: TStringBuilder;
begin
  Builder := TStringBuilder.Create;
  try
    I := 1;
    Quote := #0;
    while I <= Length(Value) do
    begin
      if Quote <> #0 then
      begin
        Builder.Append(Value[I]);
        if Value[I] = Quote then
        begin
          // SQL escapes either kind of quote by doubling it.
          if (I < Length(Value)) and (Value[I + 1] = Quote) then
          begin
            Inc(I);
            Builder.Append(Value[I]);
          end
          else Quote := #0;
        end;
        Inc(I);
        Continue;
      end;
      if CharInSet(Value[I], [#34, #39]) then
      begin
        Quote := Value[I];
        Builder.Append(Value[I]);
        Inc(I);
        Continue;
      end;

      IsOperator := (I = 1) or CharInSet(Value[I - 1], [' ', #9, #10, #13, '(']);
      Start := I;
      if IsOperator and CharInSet(Value[I], ['=', '<', '>']) then
      begin
        Inc(I);
        if (I <= Length(Value)) and CharInSet(Value[I], ['=', '>']) then Inc(I);
      end
      else if IsOperator and SameText(Copy(Value, I, 4), 'LIKE') and
        ((I + 4 > Length(Value)) or CharInSet(Value[I + 4], [' ', #9, #10, #13, #34, #39])) then
        Inc(I, 4)
      else IsOperator := False;

      if IsOperator then
      begin
        Builder.Append(Field).Append(' ').Append(Copy(Value, Start, I - Start));
        Continue;
      end;
      if CharInSet(Value[I], [#10, #13]) then Builder.Append(' ')
      else Builder.Append(Value[I]);
      Inc(I);
    end;
    Result := Builder.ToString;
  finally Builder.Free; end;
end;

procedure AddToFilter(const Field: string; Value: string; UP: Boolean; var FilterString: string);
var
  FixedField: string;
  I: Integer; Quoted, NeedsYo: Boolean; Quote: Char;
begin
  if Value = '' then
    Exit;

  if UP then
    FixedField := 'UPPER(' + Field + ')'
  else
    FixedField := Field;

  // Inspect SQL string literals, excluding operators such as LIKE.
  // Queries without these letters retain their existing indexed expression.
  Quoted := False; NeedsYo := False; Quote := #0;
  for I := 1 to Length(Value) do
    if not Quoted then
    begin
      if CharInSet(Value[I], [#34,#39]) then begin Quoted := True; Quote := Value[I]; end;
    end
    else if Value[I] = Quote then Quoted := False
    else if (Value[I] = 'Е') or (Value[I] = 'е') or (Value[I] = 'Ё') or (Value[I] = 'ё') then
      NeedsYo := True;
  if NeedsYo then
  begin
    FixedField := 'REPLACE(REPLACE('+FixedField+',''Ё'',''Е''),''ё'',''е'')';
    Value := StringReplace(StringReplace(Value,'Ё','Е',[rfReplaceAll]),'ё','е',[rfReplaceAll]);
  end;

  // Qualify only expression operators. A title, author or path can itself
  // contain " =", " >" or " LIKE "; rewriting a quoted value changes the
  // requested text and can even produce invalid SQL.
  Value := QualifySearchExpression(Value, FixedField);

  if FilterString <> '' then
    FilterString := FilterString + ' AND (' + Value + ')'
  else
    FilterString := '(' + Value + ')';
end;

function Clear(const S: string): string; inline;
begin
  Result := S;
  StrReplace(CRLF, ' ', Result);
  Result := Trim(Result);
end;

// проверяем запрос, если нативный - преобразовываем в SQL
function PrepareQuery(S: string; UP: Boolean; ConverToFull: Boolean = True): string;
begin
  if UP then
    S := Trim(AnsiUpperCase(S));

  if S = '' then
  begin
    Result := '';
    Exit;
  end;

  if ConverToFull and (Pos('%', S) = 0) and (Pos('=', S) = 0) and (Pos('"', S) = 0) and (Pos('LIKE', S) = 0) then
    S := Format('%%%s%%', [S]);

  if (Pos('=', S) = 0) and (Pos('LIKE', S) = 0) and (Pos('"', S) = 0) then
  begin
    if Pos('%', S) = 0 then
      S := '="' + S + '"'
    else
      S := 'LIKE "' + S + '"';
  end;

  Result := Clear(S);
end;

procedure AddToWhere(var Where: string; const Filter: string);
begin
  if Where = '' then
    Where := ' WHERE '
  else
    Where := Where + ' AND ';
  Where := Where + Filter;
end;

end.
