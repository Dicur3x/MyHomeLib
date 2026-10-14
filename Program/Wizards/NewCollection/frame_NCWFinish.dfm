inherited frameNCWFinish: TframeNCWFinish
  inherited Panel8: TPanel
    StyleElements = [seFont, seClient, seBorder]
  end
  inherited Panel9: TPanel
    StyleElements = [seFont, seClient, seBorder]
    inherited lblTitle: TLabel
      Width = 293
      Caption = #1052#1072#1089#1090#1077#1088' '#1089#1086#1079#1076#1072#1085#1080#1103' '#1082#1086#1083#1083#1077#1082#1094#1080#1081' '#1091#1089#1087#1077#1096#1085#1086' '#1079#1072#1074#1077#1088#1096#1080#1083' '#1088#1072#1073#1086#1090#1091'.'
      StyleElements = [seFont, seClient, seBorder]
      ExplicitWidth = 258
    end
    inherited lblSubTitle: TLabel
      Width = 286
      Height = 30
      Caption = 
        #1042#1099' '#1084#1086#1078#1077#1090#1077' '#1085#1072#1095#1072#1090#1100' '#1080#1089#1087#1086#1083#1100#1079#1086#1074#1072#1090#1100' '#1085#1086#1074#1091#1102' '#1082#1086#1083#1083#1077#1082#1094#1080#1102' '#1089#1088#1072#1079#1091' '#1087#1086#1089#1083#1077' '#1079#1072#1082#1088#1099#1090 +
        #1080#1103' '#1101#1090#1086#1075#1086' '#1084#1072#1089#1090#1077#1088#1072'.'
      StyleElements = [seFont, seClient, seBorder]
      ExplicitTop = 62
      ExplicitWidth = 284
      ExplicitHeight = 30
    end
    object btnMetadataFill: TButton
      AlignWithMargins = True
      Left = 14
      Top = 100
      Width = 286
      Height = 36
      Margins.Left = 14
      Margins.Top = 14
      Margins.Right = 7
      Margins.Bottom = 0
      Align = alTop
      Caption = 'Заполнить сведения из книг…'
      Enabled = False
      TabOrder = 0
    end
    object lblMetadataFill: TLabel
      AlignWithMargins = True
      Left = 14
      Top = 143
      Width = 286
      Height = 65
      Margins.Left = 14
      Margins.Top = 7
      Margins.Right = 7
      Margins.Bottom = 0
      Align = alTop
      AutoSize = True
      Caption = 'Можно выбрать пустые поля каталога и заполнить их из местных FB2 и FB2 в ZIP. Проверка книг начнётся только по вашей команде. Нужна доступная папка книг.'
      WordWrap = True
    end
    inherited lblPageHint: TLabel
      Width = 286
      Caption = ''
      StyleElements = [seFont, seClient, seBorder]
      ExplicitWidth = 3
    end
  end
end
