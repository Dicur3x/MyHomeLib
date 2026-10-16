unit unit_SearchQueryModeControl;

interface

uses System.Classes, Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls,
  unit_Globals, unit_SearchPresets;

type
  TSearchQueryModeControl = class(TPanel)
  private
    FCombo: TComboBox;
    FExplanation: TLabel;
    FOnModeChange: TNotifyEvent;
    function GetMode: TSearchQueryMode;
    procedure SetMode(Value: TSearchQueryMode);
    procedure Changed(Sender: TObject);
    procedure UpdateExplanation;
  public
    constructor CreateFor(AOwner: TComponent; AParent: TWinControl);
    procedure Reset;
    procedure LoadPreset(Preset: TSearchPreset);
    procedure SavePreset(Preset: TSearchPreset);
    procedure ApplyTo(var Criteria: TBookSearchCriteria);
    property Mode: TSearchQueryMode read GetMode write SetMode;
    property Combo: TComboBox read FCombo;
    property Explanation: TLabel read FExplanation;
    property OnModeChange: TNotifyEvent read FOnModeChange write FOnModeChange;
  end;

implementation

uses Winapi.Windows, unit_MHLTheme;

constructor TSearchQueryModeControl.CreateFor(AOwner: TComponent; AParent: TWinControl);
begin
  inherited Create(AOwner);
  Name := 'SearchQueryModeControl';
  Parent := AParent;
  BevelOuter := bvNone;
  Caption := '';
  Align := alTop;
  Height := MulDiv(88, Font.PixelsPerInch, 96);
  FCombo := TComboBox.Create(Self);
  FCombo.Name := 'SearchQueryModeCombo';
  FCombo.Parent := Self;
  FCombo.Align := alTop;
  FCombo.Style := csDropDownList;
  FCombo.Items.Add('Обычный текст');
  FCombo.Items.Add('Условия поиска');
  FCombo.OnChange := Changed;
  FCombo.ShowHint := True;
  FCombo.Hint := 'Режим текстовых полей. Дата, год, оценка и язык сохраняют свои правила.';
  FExplanation := TLabel.Create(Self);
  FExplanation.Name := 'SearchQueryModeExplanation';
  FExplanation.Parent := Self;
  FExplanation.Align := alTop;
  FExplanation.WordWrap := True;
  FExplanation.AutoSize := True;
  FExplanation.Layout := tlCenter;
  Reset;
  AutoSize := True;
  ApplyMHLControlTheme(Self);
end;

function TSearchQueryModeControl.GetMode: TSearchQueryMode;
begin
  case FCombo.ItemIndex of
    0: Result := sqmText;
    1: Result := sqmExpression;
  else Result := sqmLegacy;
  end;
end;

procedure TSearchQueryModeControl.SetMode(Value: TSearchQueryMode);
begin
  if (Value = sqmLegacy) and (FCombo.Items.Count = 2) then
    FCombo.Items.Add('Как в старом пресете');
  case Value of
    sqmText: FCombo.ItemIndex := 0;
    sqmExpression: FCombo.ItemIndex := 1;
    sqmLegacy: FCombo.ItemIndex := 2;
  end;
  UpdateExplanation;
end;

procedure TSearchQueryModeControl.UpdateExplanation;
begin
  case Mode of
    sqmText: FExplanation.Caption := 'Ищется введённый текст. LIKE, %, _, = и кавычки считаются обычными символами.';
    sqmExpression: FExplanation.Caption := 'Задайте условие: ="точно", LIKE "%часть%" или ="одно" OR ="другое".';
    sqmLegacy: FExplanation.Caption := 'Сохранены прежние правила этого пресета. Можно выбрать обычный текст или явные условия.';
  end;
  FExplanation.Hint := FExplanation.Caption;
  FExplanation.ShowHint := True;
end;

procedure TSearchQueryModeControl.Changed(Sender: TObject);
begin
  UpdateExplanation;
  if Assigned(FOnModeChange) then FOnModeChange(Self);
end;

procedure TSearchQueryModeControl.Reset;
begin
  Mode := sqmText;
  while FCombo.Items.Count > 2 do FCombo.Items.Delete(FCombo.Items.Count - 1);
end;

procedure TSearchQueryModeControl.LoadPreset(Preset: TSearchPreset);
begin
  Mode := Preset.QueryMode;
end;

procedure TSearchQueryModeControl.SavePreset(Preset: TSearchPreset);
begin
  Preset.QueryMode := Mode;
end;

procedure TSearchQueryModeControl.ApplyTo(var Criteria: TBookSearchCriteria);
begin
  Criteria.QueryMode := Mode;
end;

end.
