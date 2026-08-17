(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2023 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Matvienko Sergei  matv84@mail.ru
  * Created             12.02.2010
  * Description         Класс работы с шаблонами
  *
  * $Id: unit_Templater.pas 1157 2014-04-16 15:57:13Z Demsa $
  *
  * History
  * NickR 15.02.2010    Код переформатирован
  *
  ****************************************************************************** *)

unit unit_Templater;

interface

uses
  FictionBook_21,
  unit_Globals;

const
  COL_MASK_ELEMENTS = 13;

type
  TErrorType = (ErFine, ErTemplate, ErBlocks, ErElements);
  TTemplateType = (TpFile, TpPath, TpText);

  TElement = record
    name: string;
    BegBlock, EndBlock: Integer;
  end;

  TTemplater = class
  private
    FTemplate: string;
    FBlocksMap: array[0..255] of TElement;
    ColElements: Integer;
  public
    constructor Create;

    function ValidateTemplate(const Template: string; TemplType: TTemplateType)
      : TErrorType;
    function SetTemplate(Template: string; TemplType: TTemplateType)
      : TErrorType;
    function ParseString(R: TBookRecord; TemplType: TTemplateType): string;
  end;

implementation

uses
  SysUtils,
  unit_Consts,
  dm_user;

constructor TTemplater.Create;
begin
  inherited;
  FTemplate := '';
end;

function TTemplater.ValidateTemplate(const Template: string;
  TemplType: TTemplateType): TErrorType;
const
  { DONE : совпадает с названием константы }
  MASK_ELEMENTS: array [1 .. COL_MASK_ELEMENTS] of string = ('f', 'fa', 't',
    's', 'n', 'id', 'g', 'ga', 'ff', 'fl', 'rg', 'fn', 'fc');
var
  stack: array [0..255] of TElement;
  h, k, i, j, StackPos, ElementPos, last_char,
    last_col_elements: Integer;
  bol, TemplEnd: boolean;
  TemplatePart: string;
begin
  if Template = '' then
  begin
    if TemplType <> TpPath then
      Result := ErTemplate
    else
      Result := ErFine;
    Exit;
  end;

  // Поправка на количество частей пути в карту элементов и блоков (используется при разборе путей)
  last_col_elements := 0;
  last_char := 0;

  // Определение количества элементов в шаблоне
  ColElements := 0;
  for i := 1 to Length(Template) do
    if Template[i] = '%' then
      Inc(ColElements);

  if ColElements > Length(FBlocksMap) then
  begin
    Result := ErTemplate;
    Exit;
  end;

  // ValidateTemplate is called repeatedly by ParseString. Clear the complete
  // fixed-size buffers so stale block coordinates from an older template can
  // never be reused when the new template contains fewer elements.
  for i := Low(stack) to High(stack) do
  begin
    stack[i].name := '';
    stack[i].BegBlock := 0;
    stack[i].EndBlock := 0;
  end;
  for i := Low(FBlocksMap) to High(FBlocksMap) do
  begin
    FBlocksMap[i].name := '';
    FBlocksMap[i].BegBlock := 0;
    FBlocksMap[i].EndBlock := 0;
  end;

  bol := True;
  TemplEnd := false;
  k := 1;
  while not(TemplEnd) do
  begin
    i := 1;
    TemplatePart := '';

    // Разбор пути к файлу на составляющие
    while (k <= Length(Template)) and (Template[k] <> '\') do
    begin
      TemplatePart := TemplatePart + Template[k];
      Inc(k);
    end;
    Inc(k);
    // Если больше нет элементов пути, то итерация крайняя
    if k > Length(Template) then
      TemplEnd := True;

    // Инициализация счётчика глубины стека и элементов шаблона
    StackPos := 0;
    ElementPos := 0;
    while i <= Length(TemplatePart) do
    begin
      // Поиск открывающей скобки блока элемента
      if TemplatePart[i] = '[' then
      begin
        Inc(StackPos);
        if StackPos > High(stack) then
        begin
          Result := ErTemplate; // prevent an access violation (exceeding "stack" var size)
          Exit;
        end;
        stack[StackPos].BegBlock := i;
        stack[StackPos].name := '';

      end;

      // Поиск элемента шаблона
      if TemplatePart[i] = '%' then
      begin
        // Если внутри блока имеется более одного элемента, то шаблон неправильный
        if (stack[StackPos].name <> '') and (StackPos > 0) then
        begin
          Result := ErTemplate; // В блоке не может быть более одного элемента
          Exit;
        end;

        // Выделяем название элемента
        Inc(i);
        stack[StackPos].name := '';
        while (i <= Length(TemplatePart)) and
          CharInSet(TemplatePart[i], ['a' .. 'z', 'A' .. 'Z']) do
        begin
          stack[StackPos].name := stack[StackPos].name + TemplatePart[i];
          Inc(i);
        end;
        if stack[StackPos].name = '' then
        begin
          Result := ErElements;
          Exit;
        end;
        Dec(i);

        // Добавляем элемент в общий список элементов
        if StackPos = 0 then
        begin
          if ElementPos + last_col_elements > High(FBlocksMap) then
          begin
            Result := ErTemplate;
            Exit;
          end;
          FBlocksMap[ElementPos + last_col_elements].name :=
            stack[StackPos].name;
          FBlocksMap[ElementPos + last_col_elements].BegBlock := 0;
          FBlocksMap[ElementPos + last_col_elements].EndBlock := 0;
          Inc(ElementPos);
        end;
      end;

      // Поиск окончания блока элемента
      if TemplatePart[i] = ']' then
      begin
        // Если на текущем уровне стека нет элемента или элемент на 0-м уровне
        // то шаблон неправильный
        if (stack[StackPos].name = '') or (StackPos <= 0) then
        begin
          Result := ErBlocks;
          // Проверьте соответствие открывающих и закрывающих скобок блоков элементов
          Exit;
        end;
        stack[StackPos].EndBlock := i;

        // Добавляем элемент в общий список элементов
        if ElementPos + last_col_elements > High(FBlocksMap) then
        begin
          Result := ErTemplate;
          Exit;
        end;
        FBlocksMap[ElementPos + last_col_elements].name := stack[StackPos].name;
        FBlocksMap[ElementPos + last_col_elements].BegBlock :=
          stack[StackPos].BegBlock + last_char;
        FBlocksMap[ElementPos + last_col_elements].EndBlock :=
          stack[StackPos].EndBlock + last_char;
        Inc(ElementPos);
        Dec(StackPos);
      end;
      // Переход к очередному символу в шаблоне
      Inc(i);
    end;

    // Имеются незакрытые скобки блоков
    if StackPos > 0 then
    begin
      Result := ErBlocks;
      // Проверьте соответствие открывающих и закрывающих скобок блоков элементов
      Exit;
    end;

    // Проверка всех элементов на правильность написания
    for h := 0 to ColElements - 1 do
    begin
      if FBlocksMap[h].name <> '' then
      begin
        bol := false;
        for j := 1 to High(MASK_ELEMENTS) do
          if UpperCase(FBlocksMap[h].name) = UpperCase(MASK_ELEMENTS[j]) then
          begin
            bol := True;
            Break;
          end;

        if not(bol) then
          Break;
      end;
    end;

    // Имеются неверние элементы шаблона
    if not(bol) then
    begin
      Result := ErElements; // Неверные элементы шаблона
      Exit;
    end;

    Inc(last_col_elements, ElementPos);

    // Поправка на количество символов с начала строки шаблона в
    // карту элементов и блоков (используется при разборе путей)
    // k is an absolute position in Template, not a segment-relative offset.
    // Adding it repeatedly shifted block coordinates from the third path
    // component onward.
    last_char := k - 1;

    // Переход к очередному символу в шаблоне с целью обработки следующей части пути к файлу
    Inc(i);
  end;

  // Если проверяем шаблон имени файла, то бэкслэш не допустим
  if TemplType = TpFile then
    if pos('\', Template) <> 0 then
    begin
      Result := ErTemplate;
      Exit;
    end;

  // Если замечаний нет, то шаблон валиден
  Result := ErFine;
end;

function TTemplater.SetTemplate(Template: String; TemplType: TTemplateType)
  : TErrorType;
begin
  // Спецсимволы чистим только для имени файла или пути к файлу
  if TemplType in [TpFile, TpPath] then
    Template := CheckSymbols(Template, False);
  Template := Trim(Template);

  // Validate exactly the text that ParseString will use. Validating before
  // Trim made optional-block coordinates wrong for templates with surrounding
  // whitespace.
  Result := ValidateTemplate(Template, TemplType);

  if Result = ErFine then
    FTemplate := Template;
end;

function TTemplater.ParseString(R: TBookRecord;
  TemplType: TTemplateType): string;
type
  TMaskElement = record
    templ, value: string;
  end;

  TMaskElements = array [1 .. COL_MASK_ELEMENTS] of TMaskElement;

  TBlockRange = record
    BegPos: Integer;
    EndPos: Integer;
  end;
var
  AuthorName, s, Token: string;
  i, j, RangeCount: Integer;
  MaskElements: TMaskElements;
  BlockRanges: array of TBlockRange;
  TempRange: TBlockRange;
  p1, p2: Integer;
begin
  Result := FTemplate;

  // Формирование массива значений элементов маски
  MaskElements[1].templ := 'ga';
  for i := Low(R.Genres) to High(R.Genres) do
  begin
    MaskElements[1].value := MaskElements[1].value +
      CheckSymbols(R.Genres[i].GenreAlias, True);
    if i < High(R.Genres) then
      MaskElements[1].value := MaskElements[1].value + ', ';
  end;

  MaskElements[2].templ := 'rg';
  MaskElements[2].value := Trim(CleanFileName(R.RootGenre.GenreAlias));

  MaskElements[3].templ := 'g';
  if R.GenreCount > 0 then
    MaskElements[3].value := Trim(CleanFileName(R.Genres[0].GenreAlias))
  else
    MaskElements[3].value := '';

  MaskElements[4].templ := 'ff';
  if R.AuthorCount > 0 then
  begin
    s := Trim(CheckSymbols(R.Authors[ Low(R.Authors)].FLastName, True));
    if s <> '' then
      MaskElements[4].value := s[1]
    else
      MaskElements[4].value := '';
  end
  else
    MaskElements[4].value := '';

  MaskElements[5].templ := 'fa';
  AuthorName := '';
  if R.AuthorCount > 0 then
    for i := 0 to High(R.Authors) do
    begin
      AuthorName := AuthorName + CleanFileName(R.Authors[i].GetFullName(True));
      if i < High(R.Authors) then
        AuthorName := AuthorName + ', ';
    end;
  MaskElements[5].value := CleanFileName(AuthorName);

  MaskElements[6].templ := 'fl';
  if R.AuthorCount > 0 then
    MaskElements[6].value := Trim(CleanFileName(R.Authors[0].FLastName))
  else
    MaskElements[6].value := '';

  MaskElements[7].templ := 'fn';
  if R.AuthorCount > 0 then
    MaskElements[7].value := Trim(CleanFileName(R.Authors[0].FLastName + ' ' + R.Authors[0].FFirstName))
  else
    MaskElements[7].value := '';

  MaskElements[8].templ := 'fc';
  if CurrentSelectedAuthor <> ''  then
    MaskElements[8].value := CurrentSelectedAuthor
  else
    // Повтор алгоритма из пункта 9
  if R.AuthorCount > 0 then
    MaskElements[8].value := Trim(CleanFileName(R.Authors[0].GetFullName))
  else
    MaskElements[8].value := '';

  // Может поменять шаблон? т.к. при добавлении шаблонов на f приходится менять структуру.
  MaskElements[9].templ := 'f';
  if R.AuthorCount > 0 then
    MaskElements[9].value := Trim(CleanFileName(R.Authors[0].GetFullName))
  else
    MaskElements[9].value := '';

  MaskElements[10].templ := 's';
  MaskElements[10].value := Trim(CleanFileName(R.Series));

  MaskElements[11].templ := 'n';
  if R.SeqNumber <> 0 then
    MaskElements[11].value := Format('%.2d', [R.SeqNumber])
  else
    MaskElements[11].value := '';

  MaskElements[12].templ := 't';
  MaskElements[12].value := Trim(CleanFileName(R.Title));

  MaskElements[13].templ := 'id';
  MaskElements[13].value := R.LibID;

  // Collect empty optional blocks once. The former implementation reparsed the
  // complete template after every deletion and left FBlocksMap describing the
  // previous book instead of FTemplate. Besides being quadratic, that produced
  // incorrect names when one templater instance was reused for multiple books.
  RangeCount := 0;
  SetLength(BlockRanges, 0);
  for j := 0 to ColElements - 1 do
    if (FBlocksMap[j].BegBlock <> 0) and (FBlocksMap[j].EndBlock <> 0) then
      for i := Low(MaskElements) to High(MaskElements) do
        if SameText(MaskElements[i].templ, FBlocksMap[j].name) and
          (MaskElements[i].value = '') then
        begin
          SetLength(BlockRanges, RangeCount + 1);
          BlockRanges[RangeCount].BegPos := FBlocksMap[j].BegBlock;
          BlockRanges[RangeCount].EndPos := FBlocksMap[j].EndBlock;
          Inc(RangeCount);
          Break;
        end;

  // If both an outer and an inner optional block are empty, deleting the outer
  // block is sufficient. Mark contained ranges so original coordinates remain
  // valid for every deletion that follows.
  for i := 0 to RangeCount - 1 do
    for j := 0 to RangeCount - 1 do
      if (i <> j) and
        (BlockRanges[j].BegPos <= BlockRanges[i].BegPos) and
        (BlockRanges[j].EndPos >= BlockRanges[i].EndPos) and
        ((BlockRanges[j].BegPos < BlockRanges[i].BegPos) or
         (BlockRanges[j].EndPos > BlockRanges[i].EndPos)) then
      begin
        BlockRanges[i].BegPos := 0;
        BlockRanges[i].EndPos := 0;
        Break;
      end;

  // Delete from right to left so positions calculated for FTemplate never
  // shift underneath the remaining ranges.
  for i := 0 to RangeCount - 2 do
    for j := i + 1 to RangeCount - 1 do
      if BlockRanges[j].BegPos > BlockRanges[i].BegPos then
      begin
        TempRange := BlockRanges[i];
        BlockRanges[i] := BlockRanges[j];
        BlockRanges[j] := TempRange;
      end;

  for i := 0 to RangeCount - 1 do
    if BlockRanges[i].BegPos > 0 then
      Delete(Result, BlockRanges[i].BegPos,
        BlockRanges[i].EndPos - BlockRanges[i].BegPos + 1);

  StrReplace('[', '', Result);
  StrReplace(']', '', Result);

  // Цикл замены элементов шаблона их значениями
  for i := 1 to COL_MASK_ELEMENTS do
  begin
    Token := '%' + UpperCase(MaskElements[i].templ);
    if Pos(Token, Result) > 0 then
    begin
      S := Transliterate(MaskElements[i].value);
      StrReplace(Token, S, Result);
    end;

    Token := '%' + MaskElements[i].templ;
    if Pos(Token, Result) > 0 then
      StrReplace(Token, MaskElements[i].value, Result);
  end;

  // Удаление содержимого квадратных скобок из названий (для либрусека)
  if Settings.RemoveSquarebrackets then
  begin
    p1 := pos('[', Result);
    p2 := pos(']', Result);
    if (p1 > 0) and (p2 > 0) and (p1 < p2) then
    begin
      Delete(Result, p1, p2 - p1 + 1);
      Result := Trim(Result);
    end;
  end;
end;

end.
