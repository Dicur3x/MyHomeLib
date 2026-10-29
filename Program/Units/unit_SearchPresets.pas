(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             30.06.2010
  * Description
  *
  * $Id: unit_SearchPresets.pas 1064 2011-09-02 11:33:04Z eg_ $
  *
  *
  * History
  *
  ****************************************************************************** *)

unit unit_SearchPresets;

interface

uses
  msxml,
  ComObj,
  Generics.Collections,
  unit_Globals;

type
  TSearchPreset = class(TDictionary<string, string>)
  strict private
    FDisplayName: string;
    function GetQueryMode: TSearchQueryMode;
    procedure SetQueryMode(Value: TSearchQueryMode);

  public
    constructor Create(const DisplayName: string);
    destructor Destroy; override;

    property DisplayName: string read FDisplayName;
    property QueryMode: TSearchQueryMode read GetQueryMode write SetQueryMode;
  end;

  TSearchPresets = class(TObjectList<TSearchPreset>)
  strict private
    function PresetByName(const presetName: string): Integer;

  public
    constructor Create;
    destructor Destroy; override;

    procedure Load(const FileName: string);
    procedure Save(const FileName: string);
    function Clone: TSearchPresets;

    function GetPreset(const presetName: string): TSearchPreset;
    procedure RemovePreset(const presetName: string);
  end;

implementation

uses
  msxmldom,
  XMLConst,
  SysUtils,
  unit_xmlUtils;

resourcestring
  rstrInvalidPresetName = 'Неверное название пресета';

const
  QUERY_MODE_FIELD = 'QueryMode';
  PRESETS_ELEMENT = 'Presets';
  PRESET_ELEMENT = 'Preset';
  FIELD_ELEMENT = 'Field';
  DISPLAYNAME_ATTRIBUTE = 'displayName';


constructor TSearchPreset.Create(const DisplayName: string);
begin
  inherited Create;
  FDisplayName := DisplayName;
end;

function TSearchPreset.GetQueryMode: TSearchQueryMode;
var Value: string;
begin
  Result := sqmLegacy;
  if not TryGetValue(QUERY_MODE_FIELD, Value) then Exit;
  if SameText(Value, 'text') then Result := sqmText
  else if SameText(Value, 'expression') then Result := sqmExpression
  else if not SameText(Value, 'legacy') then
    raise EConvertError.Create('Неизвестный режим поиска в пресете «' + DisplayName + '».');
end;

procedure TSearchPreset.SetQueryMode(Value: TSearchQueryMode);
const Names: array[TSearchQueryMode] of string = ('legacy', 'text', 'expression');
begin
  AddOrSetValue(QUERY_MODE_FIELD, Names[Value]);
end;

destructor TSearchPreset.Destroy;
begin
  inherited;
end;


constructor TSearchPresets.Create;
begin
  inherited Create(True);
end;

destructor TSearchPresets.Destroy;
begin
  inherited;
end;

function TSearchPresets.Clone: TSearchPresets;
var Source, Target: TSearchPreset; Field: TPair<string,string>;
begin
  Result:=TSearchPresets.Create;
  try
    for Source in Self do
    begin
      Target:=Result.GetPreset(Source.DisplayName);
      for Field in Source do Target.AddOrSetValue(Field.Key,Field.Value);
    end;
  except Result.Free; raise; end;
end;

procedure TSearchPresets.Load(const FileName: string);
var
  xmlDoc: IXMLDOMDocument; xmlPresets, xmlFields: IXMLDOMNodeList;
  xmlPreset, xmlField, Attribute: IXMLDOMNode; Preset: TSearchPreset;
  Candidate: TSearchPresets; Name, Key: string; Prepared: TArray<TSearchPreset>;
  HasQueryMode: Boolean;
  ValidatedMode: TSearchQueryMode;
begin
  xmlDoc:=TMSXMLHelper.LoadFromFile(FileName,not SameText(ExtractFileExt(FileName),'.xml'),True);
  if not Assigned(xmlDoc.documentElement) or (xmlDoc.documentElement.nodeName<>PRESETS_ELEMENT) then
    raise EArgumentException.Create('Файл не содержит пресеты поиска HomeLibre.');
  Candidate:=Clone;
  try
    xmlPresets:=xmlDoc.selectNodes('/'+PRESETS_ELEMENT+'/'+PRESET_ELEMENT);
    xmlPreset:=xmlPresets.nextNode;
    while Assigned(xmlPreset) do
    begin
      Attribute:=xmlPreset.attributes.getNamedItem(DISPLAYNAME_ATTRIBUTE);
      if not Assigned(Attribute) or (Trim(Attribute.text)='') then
        raise EArgumentException.Create('В файле пресетов отсутствует название пресета.');
      Name:=Attribute.text; Preset:=Candidate.GetPreset(Name); HasQueryMode:=False;
      xmlFields:=xmlPreset.selectNodes(FIELD_ELEMENT); xmlField:=xmlFields.nextNode;
      while Assigned(xmlField) do
      begin
        Attribute:=xmlField.attributes.getNamedItem(DISPLAYNAME_ATTRIBUTE);
        if not Assigned(Attribute) or (Trim(Attribute.text)='') then
          raise EArgumentException.Create('В пресете «'+Name+'» отсутствует название поля.');
        Key:=Attribute.text; Preset.AddOrSetValue(Key,xmlField.text);
        if Key=QUERY_MODE_FIELD then HasQueryMode:=True;
        xmlField:=xmlFields.nextNode;
      end;
      // Importing a legacy preset over a modern one still restores the legacy
      // interpretation; absent mode must not inherit the destination's mode.
      if not HasQueryMode then Preset.Remove(QUERY_MODE_FIELD);
      // An unsupported future mode must not silently change query meaning.
      ValidatedMode := Preset.QueryMode;
      xmlPreset:=xmlPresets.nextNode;
    end;
    // All parsing/validation and required list allocation precede publication.
    // A later invalid entry cannot leave an earlier preset partially imported.
    Prepared:=Candidate.ToArray;
    if Capacity<Length(Prepared) then Capacity:=Length(Prepared);
    Candidate.OwnsObjects:=False;
    Clear; AddRange(Prepared);
  finally Candidate.Free; end;
end;

procedure TSearchPresets.Save(const FileName: string);
var
  xmlDoc : IXMLDOMDocument;
  xmlPresets: IXMLDOMElement;
  i: Integer;
  preset: TSearchPreset;
  xmlPreset: IXMLDOMElement;
  xmlField: IXMLDOMElement;
  At, SplitAt: Integer;
  presetField: TPair<string, string>;
begin
  xmlDoc := TMSXMLHelper.CreateEmptyDocument;

  xmlPresets := xmlDoc.createElement(PRESETS_ELEMENT);
  xmlDoc.appendChild(xmlPresets);
  xmlPresets.appendChild(xmlDoc.createTextNode(sLineBreak));

  for i := 0 to Count - 1 do
  begin
    preset := Items[i];

    xmlPreset := xmlDoc.createElement(PRESET_ELEMENT);
    xmlPreset.setAttribute(DISPLAYNAME_ATTRIBUTE, preset.DisplayName);
    xmlPreset.appendChild(xmlDoc.createTextNode(sLineBreak));

    for presetField in preset do
    begin
      xmlField := xmlDoc.createElement(FIELD_ELEMENT);
      xmlField.setAttribute(DISPLAYNAME_ATTRIBUTE, presetField.Key);

      // CDATA remains compatible with old readers. Split its closing marker
      // without changing any field characters or inventing a new file schema.
      At:=1;
      repeat
        SplitAt:=Pos(']]>',presetField.Value,At);
        if SplitAt=0 then
        begin
          xmlField.appendChild(xmlDoc.createCDATASection(Copy(presetField.Value,At,MaxInt)));
          Break;
        end;
        xmlField.appendChild(xmlDoc.createCDATASection(Copy(presetField.Value,At,SplitAt-At+2)));
        xmlField.appendChild(xmlDoc.createTextNode('>'));
        At:=SplitAt+3;
      until False;

      xmlPreset.appendChild(xmlDoc.createTextNode('    '));
      xmlPreset.appendChild(xmlField);
      xmlPreset.appendChild(xmlDoc.createTextNode(sLineBreak));
    end;

    xmlPreset.appendChild(xmlDoc.createTextNode('  '));
    xmlPresets.appendChild(xmlDoc.createTextNode('  '));
    xmlPresets.appendChild(xmlPreset);
    xmlPresets.appendChild(xmlDoc.createTextNode(sLineBreak));
  end;

  TMSXMLHelper.SaveToFile(xmlDoc,FileName,not SameText(ExtractFileExt(FileName),'.xml'));
end;

function TSearchPresets.PresetByName(const presetName: string): Integer;
var
  i: Integer;
begin
  for i := 0 to Count - 1 do
  begin
    if Items[i].DisplayName = presetName then
    begin
      Result := i;
      Exit;
    end;
  end;
  Result := -1;
end;

function TSearchPresets.GetPreset(const presetName: string): TSearchPreset;
var
  i: Integer;
begin
  Assert(presetName <> '');

  if presetName = '' then
    raise EArgumentException.Create(rstrInvalidPresetName);

  i := PresetByName(presetName);
  if i = -1 then
  begin
    Result := TSearchPreset.Create(presetName);
    Add(Result);
  end
  else
    Result := Items[i];
end;

procedure TSearchPresets.RemovePreset(const presetName: string);
var
  i: Integer;
begin
  i := PresetByName(presetName);
  if i <> -1 then
    Delete(i);
end;

end.
