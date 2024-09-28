inherited frmEditAuthorDataEx: TfrmEditAuthorDataEx
  ClientHeight = 195
  StyleElements = [seFont, seClient, seBorder]
  ExplicitHeight = 234
  TextHeight = 13
  inherited Label1: TLabel
    StyleElements = [seFont, seClient, seBorder]
  end
  inherited Label2: TLabel
    StyleElements = [seFont, seClient, seBorder]
  end
  inherited Label3: TLabel
    Width = 49
    Caption = #1054#1090#1095#1077#1089#1090#1074#1086
    StyleElements = [seFont, seClient, seBorder]
    ExplicitWidth = 49
  end
  inherited pnButtons: TPanel
    Top = 154
    TabOrder = 4
    StyleElements = [seFont, seClient, seBorder]
    ExplicitTop = 154
    inherited btnOk: TButton
      Left = 186
      ExplicitLeft = 186
    end
    inherited btnCancel: TButton
      Left = 267
      ExplicitLeft = 267
    end
  end
  object gbAddNew: TGroupBox [4]
    AlignWithMargins = True
    Left = 8
    Top = 91
    Width = 342
    Height = 61
    Caption = #1054#1087#1094#1080#1080
    TabOrder = 3
    object cbAddNew: TCheckBox
      Left = 17
      Top = 28
      Width = 85
      Height = 15
      Caption = '&'#1053#1086#1074#1099#1081' '#1072#1074#1090#1086#1088
      TabOrder = 0
    end
    object cbSaveLinks: TCheckBox
      Left = 158
      Top = 28
      Width = 108
      Height = 15
      Caption = #1057#1086#1093#1088#1072#1085#1080#1090#1100' '#1089#1074#1103#1079#1080
      TabOrder = 1
    end
  end
  inherited edFirstName: TEdit
    StyleElements = [seFont, seClient, seBorder]
  end
  inherited edLastName: TEdit
    StyleElements = [seFont, seClient, seBorder]
  end
  inherited edMiddleName: TEdit
    StyleElements = [seFont, seClient, seBorder]
  end
end
