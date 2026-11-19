inherited frameNCWCollectionFileTypes: TframeNCWCollectionFileTypes
  Width = 460
  Height = 216
  Constraints.MinHeight = 200
  Constraints.MinWidth = 460
  ExplicitWidth = 460
  ExplicitHeight = 216
  object pageHint: TMHLStaticTip [0]
    AlignWithMargins = True
    Left = 14
    Top = 150
    Width = 432
    Height = 59
    Margins.Left = 14
    Margins.Right = 14
    ImageIndex = 0
    Align = alTop
    ExplicitTop = 126
  end
  inherited pnTitle: TPanel
    Width = 460
    Height = 58
    StyleElements = [seFont, seClient, seBorder]
    ExplicitWidth = 460
    ExplicitHeight = 58
    inherited lblTitle: TLabel
      Width = 432
      Caption = #1046#1072#1085#1088#1099#32#1080#32#1080#1084#1087#1086#1088#1090#32#1080#1079#32#1087#1072#1087#1082#1080
      StyleElements = [seFont, seClient, seBorder]
      ExplicitWidth = 91
    end
    inherited lblSubTitle: TLabel
      Width = 425
      Caption = #1042#1099#1073#1077#1088#1080#1090#1077#32#1085#1072#1073#1086#1088#32#1078#1072#1085#1088#1086#1074#32#1076#1083#1103#32#1085#1086#1074#1086#1081#32#1082#1086#1083#1083#1077#1082#1094#1080#1080
      StyleElements = [seFont, seClient, seBorder]
      ExplicitWidth = 383
    end
  end
  object Panel3: TPanel
    Left = 0
    Top = 58
    Width = 460
    Height = 89
    Margins.Left = 7
    Margins.Top = 7
    Margins.Right = 7
    Margins.Bottom = 0
    Align = alTop
    BevelOuter = bvNone
    Constraints.MinWidth = 460
    TabOrder = 1
    object rbSoreAnyFiles: TRadioButton
      AlignWithMargins = True
      Left = 14
      Top = 38
      Width = 439
      Height = 17
      Margins.Left = 14
      Margins.Top = 7
      Margins.Right = 7
      Margins.Bottom = 0
      Align = alTop
      Caption = #1054#1073#1097#1080#1077#32#1080#1083#1080#32#1089#1086#1073#1089#1090#1074#1077#1085#1085#1099#1077#32#1078#1072#1085#1088#1099
      TabOrder = 0
      OnClick = OnSetFileType
    end
    object rbSoreFB2Files: TRadioButton
      AlignWithMargins = True
      Left = 14
      Top = 14
      Width = 439
      Height = 17
      Margins.Left = 14
      Margins.Top = 14
      Margins.Right = 7
      Margins.Bottom = 0
      Align = alTop
      Caption = #1046#1072#1085#1088#1099#32#70#105#99#116#105#111#110#66#111#111#107#32#1080#32#1087#1072#1082#1077#1090#1085#1099#1081#32#1080#1084#1087#1086#1088#1090#32#70#66#50
      Checked = True
      TabOrder = 1
      TabStop = True
      OnClick = OnSetFileType
    end
    object cbAutoImport: TCheckBox
      Left = 14
      Top = 66
      Width = 403
      Height = 17
      Caption = #1053#1072#1095#1072#1090#1100#32#1087#1072#1082#1077#1090#1085#1099#1081#32#1080#1084#1087#1086#1088#1090#32#70#66#50#32#1087#1086#1089#1083#1077#32#1089#1086#1079#1076#1072#1085#1080#1103#32#1082#1086#1083#1083#1077#1082#1094#1080#1080
      Checked = True
      State = cbChecked
      TabOrder = 2
    end
  end
end
