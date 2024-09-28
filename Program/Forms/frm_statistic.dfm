object frmStat: TfrmStat
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = #1057#1090#1072#1090#1080#1089#1090#1080#1082#1072' '#1082#1086#1083#1083#1077#1082#1094#1080#1080
  ClientHeight = 244
  ClientWidth = 473
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  Position = poScreenCenter
  DesignSize = (
    473
    244)
  TextHeight = 13
  object btnClose: TButton
    Left = 386
    Top = 211
    Width = 75
    Height = 25
    Anchors = [akRight, akBottom]
    Cancel = True
    Caption = #1047#1072#1082#1088#1099#1090#1100
    Default = True
    ModalResult = 1
    TabOrder = 0
  end
  object lvInfo: TListView
    Left = 8
    Top = 8
    Width = 453
    Height = 197
    Anchors = [akLeft, akTop, akRight, akBottom]
    Columns = <
      item
        Caption = 'Prop'
        Width = 100
      end
      item
        Caption = 'Value'
        Width = 350
      end>
    ColumnClick = False
    Groups = <
      item
        Header = #1054#1073#1097#1072#1103' '#1080#1085#1092#1086#1088#1084#1072#1094#1080#1103
        GroupID = 0
        State = [lgsNormal]
        HeaderAlign = taLeftJustify
        FooterAlign = taLeftJustify
        TitleImage = -1
      end
      item
        Header = #1057#1090#1072#1090#1080#1089#1090#1080#1082#1072
        GroupID = 2
        State = [lgsNormal]
        HeaderAlign = taLeftJustify
        FooterAlign = taLeftJustify
        TitleImage = -1
      end>
    Items.ItemData = {
      05CB0100000700000000000000FFFFFFFFFFFFFFFF0100000000000000000000
      00091D0430043704320430043D04380435043A00087300750062002000690074
      0065006D00885BBF3A00000000FFFFFFFFFFFFFFFF0100000000000000000000
      000E1404300442043004200041043E043704340430043D0438044F043A000873
      007500620020006900740065006D00A040BF3A00000000FFFFFFFFFFFFFFFF01
      000000000000000000000007120435044004410438044F043A00087300750062
      0020006900740065006D009849BF3A00000000FFFFFFFFFFFFFFFF0100000000
      00000000000000091E043F043804410430043D04380435043A00087300750062
      0020006900740065006D00D87FBF3A00000000FFFFFFFFFFFFFFFF0100000002
      00000000000000081004320442043E0440043E0432043A000873007500620020
      006900740065006D009067BF3A00000000FFFFFFFFFFFFFFFF01000000020000
      0000000000051A043D04380433043A000873007500620020006900740065006D
      00607ABF3A00000000FFFFFFFFFFFFFFFF010000000200000000000000062104
      35044004380439043A000873007500620020006900740065006D00C077BF3AFF
      FFFFFFFFFFFFFFFFFFFFFFFFFF}
    GroupView = True
    ReadOnly = True
    RowSelect = True
    ShowColumnHeaders = False
    TabOrder = 1
    ViewStyle = vsReport
  end
end
