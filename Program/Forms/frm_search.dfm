object frmBookSearch: TfrmBookSearch
  Left = 0
  Top = 0
  BorderIcons = [biSystemMenu]
  BorderStyle = bsDialog
  Caption = #1053#1072#1081#1090#1080#32#1074#32#1090#1077#1082#1091#1097#1077#1084#32#1089#1087#1080#1089#1082#1077
  ClientHeight = 135
  ClientWidth = 416
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  Position = poMainFormCenter
  TextHeight = 13
  object RzPanel1: TMHLSimplePanel
    Left = 0
    Top = 0
    Width = 416
    Height = 135
    Align = alClient
    BorderWidth = 5
    TabOrder = 0
    object Label1: TLabel
      AlignWithMargins = True
      Left = 8
      Top = 8
      Width = 400
      Height = 13
      Align = alTop
      Caption = #1042#1074#1077#1076#1080#1090#1077#32#1095#1072#1089#1090#1100#32#1085#1072#1079#1074#1072#1085#1080#1103#32#1082#1085#1080#1075#1080
    end
    object edText: TEdit
      AlignWithMargins = True
      Left = 8
      Top = 27
      Width = 400
      Height = 21
      Align = alTop
      TabOrder = 0
      OnChange = edTextChange
    end
    object lblResult: TLabel
      Left = 8
      Top = 56
      Width = 400
      Height = 34
      Anchors = [akLeft, akTop, akRight]
      AutoSize = False
      WordWrap = True
    end
    object btnFind: TButton
      Left = 180
      Top = 100
      Width = 120
      Height = 26
      Anchors = [akRight, akBottom]
      Caption = #1053#1072#1081#1090#1080
      Default = True
      Enabled = False
      TabOrder = 1
      OnClick = FindClick
    end
    object btnClose: TButton
      Left = 308
      Top = 100
      Width = 100
      Height = 26
      Anchors = [akRight, akBottom]
      Cancel = True
      Caption = #1047#1072#1082#1088#1099#1090#1100
      ModalResult = 2
      TabOrder = 2
    end
  end
end
