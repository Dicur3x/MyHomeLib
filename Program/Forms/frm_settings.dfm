object frmSettings: TfrmSettings
  Left = 0
  Top = 0
  HelpContext = 144
  BorderStyle = bsDialog
  Caption = #1053#1072#1089#1090#1088#1086#1081#1082#1072
  ClientHeight = 444
  ClientWidth = 617
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  Position = poMainFormCenter
  OnShow = FormShow
  TextHeight = 13
  object pcSetPages: TPageControl
    AlignWithMargins = True
    Left = 159
    Top = 3
    Width = 455
    Height = 397
    ActivePage = tsFileSort
    Align = alClient
    TabOrder = 1
    object tsDevices: TTabSheet
      HelpContext = 143
      Caption = 'tsDevices'
      TabVisible = False
      object pnDeviceOptions: TPanel
        AlignWithMargins = True
        Left = 3
        Top = 61
        Width = 441
        Height = 356
        Align = alTop
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 1
        object Label16: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 435
          Height = 13
          Align = alTop
          Caption = #1059#1089#1090#1088#1086#1081#1089#1090#1074#1086
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 68
        end
        object pnDeviceDir: TPanel
          Left = 0
          Top = 19
          Width = 441
          Height = 71
          Align = alTop
          AutoSize = True
          BevelOuter = bvNone
          ShowCaption = False
          TabOrder = 0
          DesignSize = (
            441
            71)
          object Label14: TLabel
            AlignWithMargins = True
            Left = 9
            Top = 3
            Width = 429
            Height = 13
            Margins.Left = 9
            Align = alTop
            Caption = #1055#1072#1087#1082#1072' '#1085#1072' '#1091#1089#1090#1088#1086#1081#1089#1090#1074#1077
            Font.Charset = DEFAULT_CHARSET
            Font.Color = clWindowText
            Font.Height = -11
            Font.Name = 'Tahoma'
            Font.Style = [fsBold]
            ParentFont = False
            ExplicitWidth = 123
          end
          object btnDeviceDir: TButton
            Left = 351
            Top = 46
            Width = 75
            Height = 25
            Anchors = [akTop, akRight]
            Caption = #1042#1099#1073#1088#1072#1090#1100
            TabOrder = 2
            OnClick = SelectFolder
          end
          object cbPromptPath: TCheckBox
            AlignWithMargins = True
            Left = 15
            Top = 22
            Width = 423
            Height = 20
            Margins.Left = 15
            Align = alTop
            Caption = #1057#1087#1088#1072#1096#1080#1074#1072#1090#1100' '#1087#1091#1090#1100' '#1082#1072#1078#1076#1099#1081' '#1088#1072#1079
            TabOrder = 0
            WordWrap = True
            OnClick = cbPromptPathClick
          end
          object edDeviceDir: TMHLAutoCompleteEdit
            Left = 15
            Top = 48
            Width = 330
            Height = 21
            Anchors = [akLeft, akTop, akRight]
            TabOrder = 1
          end
        end
        object pnFileFormat: TPanel
          Left = 0
          Top = 90
          Width = 441
          Height = 52
          Align = alTop
          AutoSize = True
          BevelOuter = bvNone
          ShowCaption = False
          TabOrder = 1
          object Label17: TLabel
            AlignWithMargins = True
            Left = 9
            Top = 9
            Width = 429
            Height = 13
            Margins.Left = 9
            Margins.Top = 9
            Align = alTop
            Caption = #1060#1086#1088#1084#1072#1090' '#1079#1072#1087#1080#1089#1080' '#1085#1072' '#1091#1089#1090#1088#1086#1081#1089#1090#1074#1086
            Font.Charset = DEFAULT_CHARSET
            Font.Color = clWindowText
            Font.Height = -11
            Font.Name = 'Tahoma'
            Font.Style = [fsBold]
            ParentFont = False
            ExplicitWidth = 173
          end
          object rgDeviceFormat: TComboBox
            AlignWithMargins = True
            Left = 15
            Top = 28
            Width = 419
            Height = 21
            Margins.Left = 15
            Margins.Right = 7
            Align = alTop
            Style = csDropDownList
            TabOrder = 0
            Items.Strings = (
              '.fb2'
              '.fb2.zip'
              '.lrf '
              '.txt'
              '.epub'
              '.pdf'
              '.mobi')
          end
        end
        object pnNameFormat: TPanel
          Left = 0
          Top = 142
          Width = 441
          Height = 78
          Align = alTop
          AutoSize = True
          BevelOuter = bvNone
          ShowCaption = False
          TabOrder = 2
          DesignSize = (
            441
            78)
          object Label18: TLabel
            AlignWithMargins = True
            Left = 9
            Top = 9
            Width = 429
            Height = 13
            Margins.Left = 9
            Margins.Top = 9
            Align = alTop
            Caption = #1060#1086#1088#1084#1072#1090' '#1080#1084#1077#1085#1080
            Font.Charset = DEFAULT_CHARSET
            Font.Color = clWindowText
            Font.Height = -11
            Font.Name = 'Tahoma'
            Font.Style = [fsBold]
            ParentFont = False
            ExplicitWidth = 82
          end
          object Label19: TLabel
            Left = 15
            Top = 31
            Width = 38
            Height = 13
            Alignment = taRightJustify
            Caption = #1055#1072#1087#1082#1072': '
          end
          object Label20: TLabel
            Left = 15
            Top = 58
            Width = 33
            Height = 13
            Alignment = taRightJustify
            Caption = #1060#1072#1081#1083': '
          end
          object btnFolderTemplate: TButton
            Left = 351
            Top = 26
            Width = 75
            Height = 25
            Anchors = [akTop, akRight]
            Caption = #1048#1079#1084#1077#1085#1080#1090#1100
            TabOrder = 1
            OnClick = EditFolderTemplate
          end
          object btnFileNameTemplate: TButton
            Left = 351
            Top = 53
            Width = 75
            Height = 25
            Anchors = [akTop, akRight]
            Caption = #1048#1079#1084#1077#1085#1080#1090#1100
            TabOrder = 3
            OnClick = EditFileNameTemplate
          end
          object edFolderTemplate: TEdit
            Left = 59
            Top = 28
            Width = 286
            Height = 21
            Anchors = [akLeft, akTop, akRight]
            ReadOnly = True
            TabOrder = 0
            Text = '%f\%s'
          end
          object edFileNameTemplate: TEdit
            Left = 59
            Top = 55
            Width = 286
            Height = 21
            Anchors = [akLeft, akTop, akRight]
            ReadOnly = True
            TabOrder = 2
            Text = '%n%t'
          end
        end
        object pnOtherOpt: TPanel
          Left = 0
          Top = 220
          Width = 441
          Height = 109
          Align = alTop
          BevelOuter = bvNone
          ShowCaption = False
          TabOrder = 3
          DesignSize = (
            441
            109)
          object Label5: TLabel
            AlignWithMargins = True
            Left = 9
            Top = 9
            Width = 429
            Height = 13
            Margins.Left = 9
            Margins.Top = 9
            Align = alTop
            Caption = #1055#1088#1086#1095#1080#1077
            Font.Charset = DEFAULT_CHARSET
            Font.Color = clWindowText
            Font.Height = -11
            Font.Name = 'Tahoma'
            Font.Style = [fsBold]
            ParentFont = False
            ExplicitWidth = 42
          end
          object Label1: TLabel
            Left = 15
            Top = 65
            Width = 81
            Height = 13
            Alignment = taRightJustify
            Caption = #1050#1086#1076#1080#1088#1086#1074#1082#1072' TXT:'
          end
          object cbSquareFilter: TCheckBox
            AlignWithMargins = True
            Left = 15
            Top = 28
            Width = 423
            Height = 27
            Margins.Left = 15
            Align = alTop
            Caption = #1042#1082#1083#1102#1095#1080#1090#1100' '#1092#1080#1083#1100#1090#1088' "[...]"'
            TabOrder = 0
            WordWrap = True
          end
          object cbTXTEncoding: TComboBox
            Left = 102
            Top = 62
            Width = 324
            Height = 21
            Style = csDropDownList
            Anchors = [akLeft, akTop, akRight]
            ItemIndex = 0
            TabOrder = 1
            Text = 'UTF-8'
            Items.Strings = (
              'UTF-8'
              'Windows-1251')
          end
        end
      end
      object pnReadDir: TPanel
        AlignWithMargins = True
        Left = 3
        Top = 3
        Width = 441
        Height = 46
        Margins.Bottom = 9
        Align = alTop
        AutoSize = True
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 0
        DesignSize = (
          441
          46)
        object Label15: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 435
          Height = 13
          Align = alTop
          Caption = #1055#1072#1087#1082#1072' "'#1076#1083#1103' '#1095#1090#1077#1085#1080#1103'"'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 118
        end
        object edReadDir: TMHLAutoCompleteEdit
          Left = 9
          Top = 23
          Width = 336
          Height = 21
          Anchors = [akLeft, akTop, akRight]
          TabOrder = 0
          TextHint = #1048#1089#1087#1086#1083#1100#1079#1086#1074#1072#1090#1100' '#1087#1072#1087#1082#1091' '#1087#1086' '#1091#1084#1086#1083#1095#1072#1085#1080#1102
        end
        object btnSelectReadDir: TButton
          Left = 351
          Top = 21
          Width = 75
          Height = 25
          Anchors = [akTop, akRight]
          Caption = #1042#1099#1073#1088#1072#1090#1100
          TabOrder = 1
          OnClick = SelectFolder
        end
      end
    end
    object tsReaders: TTabSheet
      HelpContext = 137
      Caption = 'tsReaders'
      ImageIndex = 1
      TabVisible = False
      object Label11: TLabel
        AlignWithMargins = True
        Left = 3
        Top = 3
        Width = 441
        Height = 13
        Align = alTop
        Caption = #1058#1080#1087#1099' '#1092#1072#1081#1083#1086#1074' '#1080' '#1089#1088#1077#1076#1089#1090#1074#1072' '#1087#1088#1086#1089#1084#1086#1090#1088#1072
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -11
        Font.Name = 'Tahoma'
        Font.Style = [fsBold]
        ParentFont = False
        ExplicitWidth = 210
      end
      object Panel1: TPanel
        Left = 0
        Top = 354
        Width = 447
        Height = 33
        Align = alBottom
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 1
        object btnAddExt: TButton
          Left = 3
          Top = 3
          Width = 75
          Height = 25
          Caption = #1044#1086#1073#1072#1074#1080#1090#1100
          TabOrder = 0
          OnClick = btnAddExtClick
        end
        object btnChangeExt: TButton
          Left = 84
          Top = 3
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 1
          OnClick = btnChangeExtClick
        end
        object btnDeleteExt: TButton
          Left = 165
          Top = 3
          Width = 75
          Height = 25
          Caption = #1059#1076#1072#1083#1080#1090#1100
          TabOrder = 2
          OnClick = btnDeleteExtClick
        end
      end
      object lvReaders: TListView
        AlignWithMargins = True
        Left = 3
        Top = 22
        Width = 441
        Height = 329
        Align = alClient
        Columns = <
          item
            Caption = #1056#1072#1089#1096#1080#1088#1077#1085#1080#1077
            Width = 80
          end
          item
            AutoSize = True
            Caption = #1055#1091#1090#1100
          end>
        ColumnClick = False
        GridLines = True
        HideSelection = False
        ReadOnly = True
        RowSelect = True
        TabOrder = 0
        ViewStyle = vsReport
        OnDblClick = btnChangeExtClick
      end
    end
    object tsInterface: TTabSheet
      HelpContext = 132
      Caption = 'tsInterface'
      ImageIndex = 2
      TabVisible = False
      object Panel8: TPanel
        AlignWithMargins = True
        Left = 3
        Top = 3
        Width = 441
        Height = 194
        Align = alTop
        AutoSize = True
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 0
        object Label31: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 435
          Height = 13
          Align = alTop
          Caption = #1064#1088#1080#1092#1090
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 40
        end
        object Label7: TLabel
          Left = 9
          Top = 25
          Width = 134
          Height = 13
          Caption = #1056#1072#1079#1084#1077#1088' '#1096#1088#1080#1092#1090#1072' '#1074' '#1089#1087#1080#1089#1082#1072#1093':'
          FocusControl = edFontSize
        end
        object Label9: TLabel
          Left = 9
          Top = 52
          Width = 144
          Height = 13
          Caption = #1056#1072#1079#1084#1077#1088' '#1096#1088#1080#1092#1090#1072' '#1080#1085#1089#1090#1088#1091#1082#1094#1080#1080':'
          FocusControl = edShortFontSize
        end
        object Label25: TLabel
          Left = 223
          Top = 25
          Width = 188
          Height = 13
          Caption = '* '#1058#1088#1077#1073#1091#1077#1090#1089#1103' '#1087#1077#1088#1077#1079#1072#1087#1091#1089#1082' '#1087#1088#1080#1083#1086#1078#1077#1085#1080#1103
          FocusControl = edFontSize
        end
        object Button1: TButton
          Left = 223
          Top = 76
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 5
          OnClick = SetDefaultFontColor
        end
        object pnDeletedFontColor: TPanel
          Left = 9
          Top = 138
          Width = 208
          Height = 25
          BevelKind = bkFlat
          BevelOuter = bvNone
          Caption = #1059#1076#1072#1083#1105#1085#1085#1099#1077' '#1074' '#1086#1085#1083#1072#1081#1085' '#1073#1080#1073#1083#1080#1086#1090#1077#1082#1077
          Color = clWhite
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = []
          ParentFont = False
          TabOrder = 8
        end
        object pnDownloadedFontColor: TPanel
          Left = 9
          Top = 107
          Width = 208
          Height = 25
          BevelKind = bkFlat
          BevelOuter = bvNone
          Caption = #1047#1072#1075#1088#1091#1078#1077#1085#1085#1099#1077' '#1082#1085#1080#1075#1080
          Color = clWhite
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = []
          ParentFont = False
          TabOrder = 6
        end
        object edFontSize: TEdit
          Left = 154
          Top = 22
          Width = 47
          Height = 21
          Alignment = taRightJustify
          NumbersOnly = True
          TabOrder = 0
          Text = '10'
          OnExit = CheckNumValue
        end
        object edShortFontSize: TEdit
          Left = 154
          Top = 49
          Width = 47
          Height = 21
          Alignment = taRightJustify
          NumbersOnly = True
          TabOrder = 2
          Text = '10'
          OnExit = CheckNumValue
        end
        object udFontSize: TUpDown
          Left = 201
          Top = 22
          Width = 16
          Height = 21
          Associate = edFontSize
          Min = 6
          Max = 20
          Position = 10
          TabOrder = 1
        end
        object udShortFontSize: TUpDown
          Left = 201
          Top = 49
          Width = 16
          Height = 21
          Associate = edShortFontSize
          Min = 6
          Max = 20
          Position = 10
          TabOrder = 3
        end
        object pnDefaultFontColor: TPanel
          Left = 9
          Top = 76
          Width = 208
          Height = 25
          BevelKind = bkFlat
          BevelOuter = bvNone
          Caption = #1062#1074#1077#1090' '#1096#1088#1080#1092#1090#1072' '#1089#1087#1080#1089#1082#1086#1074
          Color = clWhite
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = []
          ParentFont = False
          TabOrder = 4
        end
        object btnDownloadedFontColor: TButton
          Left = 223
          Top = 107
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 7
          OnClick = SetCustomFontColor
        end
        object btnDeletedFontColor: TButton
          Left = 223
          Top = 138
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 9
          OnClick = SetCustomFontColor
        end
        object pnASG: TPanel
          Left = 9
          Top = 169
          Width = 208
          Height = 25
          BevelKind = bkFlat
          BevelOuter = bvNone
          Caption = #1054#1073#1097#1080#1081' '#1092#1086#1085
          Color = clWhite
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = []
          ParentBackground = False
          ParentFont = False
          TabOrder = 10
        end
        object btnASG: TButton
          Left = 223
          Top = 169
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 11
          OnClick = SetBackgroundColor
        end
      end
      object Panel10: TPanel
        AlignWithMargins = True
        Left = 3
        Top = 203
        Width = 441
        Height = 181
        Align = alClient
        AutoSize = True
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 1
        object Label32: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 435
          Height = 13
          Align = alTop
          Caption = #1044#1080#1092#1092#1077#1088#1077#1085#1094#1080#1072#1083#1100#1085#1099#1081' '#1092#1086#1085' '#1074' '#1089#1087#1080#1089#1082#1072#1093' '#1082#1085#1080#1075
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 234
        end
        object btnCA: TButton
          Left = 223
          Top = 21
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 1
          OnClick = SetBackgroundColor
        end
        object btnCS: TButton
          Left = 223
          Top = 52
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 3
          OnClick = SetBackgroundColor
        end
        object pnBS: TPanel
          Left = 9
          Top = 114
          Width = 208
          Height = 25
          BevelKind = bkFlat
          BevelOuter = bvNone
          Caption = #1050#1085#1080#1075#1072' '#1074#1085#1091#1090#1088#1080' '#1089#1077#1088#1080#1080
          Color = clWhite
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = []
          ParentBackground = False
          ParentFont = False
          TabOrder = 6
        end
        object pnCA: TPanel
          Left = 9
          Top = 21
          Width = 208
          Height = 25
          BevelKind = bkFlat
          BevelOuter = bvNone
          Caption = #1040#1074#1090#1086#1088
          Color = clWhite
          ParentBackground = False
          TabOrder = 0
        end
        object pnCS: TPanel
          Left = 9
          Top = 52
          Width = 208
          Height = 25
          BevelKind = bkFlat
          BevelOuter = bvNone
          Caption = #1057#1077#1088#1080#1103
          Color = clWhite
          ParentBackground = False
          TabOrder = 2
        end
        object pnCT: TPanel
          Left = 9
          Top = 83
          Width = 208
          Height = 25
          BevelKind = bkFlat
          BevelOuter = bvNone
          Caption = #1050#1085#1080#1075#1072' '#1073#1077#1079' '#1089#1077#1088#1080#1080
          Color = clWhite
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = []
          ParentBackground = False
          ParentFont = False
          TabOrder = 4
        end
        object btnCT: TButton
          Left = 223
          Top = 83
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 5
          OnClick = SetBackgroundColor
        end
        object btnBS: TButton
          Left = 223
          Top = 114
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 7
          OnClick = SetBackgroundColor
        end
      end
    end
    object tsInternet: TTabSheet
      HelpContext = 133
      Caption = 'tsInternet'
      ImageIndex = 4
      TabVisible = False
      object Panel7: TPanel
        Left = 0
        Top = 0
        Width = 447
        Height = 176
        Align = alTop
        AutoSize = True
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 0
        DesignSize = (
          447
          176)
        object Label27: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 9
          Width = 441
          Height = 13
          Margins.Top = 9
          Align = alTop
          Caption = #1055#1072#1088#1072#1084#1077#1090#1088#1099' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1103
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 140
        end
        object Label26: TLabel
          Left = 12
          Top = 31
          Width = 118
          Height = 13
          Caption = #1055#1072#1087#1082#1072' '#1089' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1103#1084#1080':'
          FocusControl = edUpdateDir
        end
        object Label28: TLabel
          Left = 12
          Top = 59
          Width = 67
          Height = 13
          Caption = #1057#1077#1088#1074#1077#1088' INPX:'
          FocusControl = edINPXUrl
        end
        object Label29: TLabel
          Left = 12
          Top = 86
          Width = 104
          Height = 13
          Caption = #1057#1077#1088#1074#1077#1088' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1081':'
          FocusControl = edUpdates
        end
        object edUpdateDir: TMHLAutoCompleteEdit
          Left = 136
          Top = 28
          Width = 218
          Height = 21
          HelpContext = 5001
          Anchors = [akLeft, akTop, akRight]
          TabOrder = 0
          TextHint = #1048#1089#1087#1086#1083#1100#1079#1086#1074#1072#1090#1100' '#1087#1072#1087#1082#1091' '#1087#1086' '#1091#1084#1086#1083#1095#1072#1085#1080#1102
        end
        object btnUpdateDir: TButton
          Left = 360
          Top = 26
          Width = 75
          Height = 25
          Anchors = [akTop, akRight]
          Caption = #1042#1099#1073#1088#1072#1090#1100
          TabOrder = 1
          OnClick = SelectFolder
        end
        object edINPXUrl: TMHLAutoCompleteEdit
          Left = 136
          Top = 56
          Width = 299
          Height = 21
          HelpContext = 5001
          Anchors = [akLeft, akTop, akRight]
          TabOrder = 2
          AutoCompleteOption = [acoURLHistory, acoURLMRU]
        end
        object edUpdates: TMHLAutoCompleteEdit
          Left = 136
          Top = 83
          Width = 299
          Height = 21
          HelpContext = 5001
          Anchors = [akLeft, akTop, akRight]
          TabOrder = 3
          AutoCompleteOption = [acoURLHistory, acoURLMRU]
        end
        object cbAutoRunUpdate: TCheckBox
          AlignWithMargins = True
          Left = 12
          Top = 133
          Width = 424
          Height = 17
          Anchors = [akLeft, akTop, akRight]
          Caption = #1047#1072#1087#1091#1089#1082#1072#1090#1100' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1103' '#1073#1080#1073#1083#1080#1086#1090#1077#1082' '#1072#1074#1090#1086#1084#1072#1090#1080#1095#1077#1089#1082#1080
          TabOrder = 5
        end
        object cbCheckColUpdate: TCheckBox
          AlignWithMargins = True
          Left = 12
          Top = 110
          Width = 424
          Height = 17
          Anchors = [akLeft, akTop, akRight]
          Caption = #1055#1088#1086#1074#1077#1088#1103#1090#1100' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1103' '#1073#1080#1073#1083#1080#1086#1090#1077#1082
          TabOrder = 4
        end
        object cbUpdates: TCheckBox
          AlignWithMargins = True
          Left = 12
          Top = 156
          Width = 424
          Height = 17
          Anchors = [akLeft, akTop, akRight]
          Caption = #1055#1088#1086#1074#1077#1088#1080#1090#1100' '#1085#1072#1083#1080#1095#1080#1077' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1103' '#1087#1088#1080#1083#1086#1078#1077#1085#1080#1103
          TabOrder = 6
        end
      end
      object Panel6: TPanel
        Left = 0
        Top = 195
        Width = 447
        Height = 93
        Align = alTop
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 1
        object Label30: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 9
          Width = 441
          Height = 13
          Margins.Top = 9
          Align = alTop
          Caption = #1055#1072#1088#1072#1084#1077#1090#1088#1099' '#1089#1086#1077#1076#1080#1085#1077#1085#1080#1103
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 140
        end
        object RzLabel7: TLabel
          Left = 8
          Top = 31
          Width = 135
          Height = 13
          Alignment = taRightJustify
          Caption = #1058#1072#1081#1084'-'#1072#1091#1090' '#1089#1086#1077#1076#1080#1085#1077#1085#1080#1103' ('#1084#1089'):'
          Color = clMenuBar
          FocusControl = edTimeOut
          ParentColor = False
          Transparent = True
        end
        object RzLabel8: TLabel
          Left = 32
          Top = 58
          Width = 111
          Height = 13
          Alignment = taRightJustify
          Caption = #1058#1072#1081#1084'-'#1072#1091#1090' '#1095#1090#1077#1085#1080#1103' ('#1084#1089'):'
          Color = clMenuBar
          FocusControl = edReadTimeOut
          ParentColor = False
          Transparent = True
        end
        object RzLabel9: TLabel
          Left = 248
          Top = 28
          Width = 75
          Height = 13
          Alignment = taRightJustify
          Caption = #1048#1085#1090#1077#1088#1074#1072#1083' ('#1084#1089'):'
          Color = clMenuBar
          FocusControl = edDwnldInterval
          ParentColor = False
          Transparent = True
        end
        object edDwnldInterval: TEdit
          Left = 329
          Top = 28
          Width = 65
          Height = 21
          Alignment = taRightJustify
          NumbersOnly = True
          TabOrder = 2
          Text = '0'
          OnExit = CheckNumValue
        end
        object edReadTimeOut: TEdit
          Left = 149
          Top = 55
          Width = 65
          Height = 21
          Alignment = taRightJustify
          NumbersOnly = True
          TabOrder = 4
          Text = '1'#160'000'
          OnExit = CheckNumValue
        end
        object edTimeOut: TEdit
          Left = 149
          Top = 28
          Width = 65
          Height = 21
          Alignment = taRightJustify
          NumbersOnly = True
          TabOrder = 0
          Text = '1'#160'000'
          OnChange = edTimeOutChange
          OnExit = CheckNumValue
        end
        object udTimeOut: TUpDown
          Left = 214
          Top = 28
          Width = 16
          Height = 21
          Associate = edTimeOut
          Min = 1000
          Max = 100000
          Increment = 1000
          Position = 1000
          TabOrder = 1
        end
        object udReadTimeOut: TUpDown
          Left = 214
          Top = 55
          Width = 16
          Height = 21
          Associate = edReadTimeOut
          Min = 1000
          Max = 100000
          Increment = 1000
          Position = 1000
          TabOrder = 5
        end
        object udDwnldInterval: TUpDown
          Left = 394
          Top = 28
          Width = 16
          Height = 21
          Associate = edDwnldInterval
          Max = 900000
          Increment = 1000
          TabOrder = 3
        end
      end
      object Panel9: TPanel
        AlignWithMargins = True
        Left = 3
        Top = 179
        Width = 441
        Height = 13
        Align = alTop
        AutoSize = True
        BevelOuter = bvNone
        Caption = ' '
        TabOrder = 2
      end
    end
    object tsProxy: TTabSheet
      Caption = #1053#1072#1089#1090#1088#1086#1081#1082#1080' '#1087#1088#1086#1082#1089#1080
      ImageIndex = 7
      TabVisible = False
      DesignSize = (
        447
        387)
      object lblProxyServer: TLabel
        Left = 15
        Top = 33
        Width = 41
        Height = 13
        Caption = #1057#1077#1088#1074#1077#1088':'
        Color = clMenuBar
        FocusControl = edProxyServer
        ParentColor = False
        Transparent = True
      end
      object lblProxyPort: TLabel
        Left = 322
        Top = 33
        Width = 29
        Height = 13
        Anchors = [akTop, akRight]
        Caption = #1055#1086#1088#1090':'
        Color = clMenuBar
        FocusControl = edProxyPort
        ParentColor = False
        Transparent = True
        ExplicitLeft = 330
      end
      object lblProxyPassword: TLabel
        Left = 273
        Top = 60
        Width = 41
        Height = 21
        Anchors = [akTop, akRight]
        Caption = #1055#1072#1088#1086#1083#1100':'
        Color = clMenuBar
        FocusControl = edProxyPassword
        ParentColor = False
        Transparent = True
      end
      object lblProxyUser: TLabel
        Left = 15
        Top = 60
        Width = 41
        Height = 21
        Caption = #1051#1086#1075#1080#1085':'
        Color = clMenuBar
        FocusControl = edProxyUsername
        ParentColor = False
        Transparent = True
      end
      object Label33: TLabel
        AlignWithMargins = True
        Left = 3
        Top = 122
        Width = 267
        Height = 13
        Caption = #1053#1072#1089#1090#1088#1086#1081#1082#1080' '#1087#1088#1086#1082#1089#1080' '#1076#1083#1103' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1103' '#1082#1086#1083#1083#1077#1082#1094#1080#1081
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -11
        Font.Name = 'Tahoma'
        Font.Style = [fsBold]
        ParentFont = False
      end
      object lblProxyServerUpdate: TLabel
        Left = 15
        Top = 190
        Width = 41
        Height = 22
        Caption = #1057#1077#1088#1074#1077#1088':'
        Color = clMenuBar
        FocusControl = edProxyServerUpdate
        ParentColor = False
        Transparent = True
      end
      object lblProxyPortUpdate: TLabel
        Left = 311
        Top = 191
        Width = 29
        Height = 13
        Anchors = [akTop, akRight]
        Caption = #1055#1086#1088#1090':'
        Color = clMenuBar
        FocusControl = edProxyPortUpdate
        ParentColor = False
        Transparent = True
        ExplicitLeft = 319
      end
      object lblProxyPasswordUpdate: TLabel
        Left = 261
        Top = 218
        Width = 41
        Height = 13
        Anchors = [akTop, akRight]
        Caption = #1055#1072#1088#1086#1083#1100':'
        Color = clMenuBar
        FocusControl = edProxyPasswordUpdate
        ParentColor = False
        Transparent = True
        ExplicitLeft = 269
      end
      object lblProxyUserUpdate: TLabel
        Left = 14
        Top = 218
        Width = 34
        Height = 15
        Caption = #1051#1086#1075#1080#1085':'
        Color = clMenuBar
        FocusControl = edProxyUsernameUpdate
        ParentColor = False
        Transparent = True
      end
      object lbProxyType: TLabel
        AlignWithMargins = True
        Left = 15
        Top = 87
        Width = 56
        Height = 13
        Caption = #1058#1080#1087' '#1087#1088#1086#1082#1089#1080
      end
      object cbUseIESettings: TCheckBox
        AlignWithMargins = True
        Left = 9
        Top = 3
        Width = 435
        Height = 17
        Margins.Left = 9
        Align = alTop
        Caption = #1048#1089#1087#1086#1083#1100#1079#1086#1074#1072#1090#1100' '#1085#1072#1089#1090#1088#1086#1081#1082#1080' Internet Explorer'
        TabOrder = 0
        OnClick = cbUseIESettingsClick
      end
      object edProxyServer: TEdit
        Left = 62
        Top = 30
        Width = 248
        Height = 21
        Anchors = [akLeft, akTop, akRight]
        TabOrder = 1
      end
      object edProxyPort: TEdit
        Left = 356
        Top = 30
        Width = 68
        Height = 21
        Alignment = taRightJustify
        Anchors = [akTop, akRight]
        MaxLength = 5
        NumbersOnly = True
        TabOrder = 2
        OnExit = CheckNumValue
      end
      object edProxyPassword: TEdit
        Left = 320
        Top = 57
        Width = 104
        Height = 21
        Anchors = [akTop, akRight]
        PasswordChar = '*'
        TabOrder = 3
      end
      object edProxyUsername: TEdit
        Left = 62
        Top = 57
        Width = 199
        Height = 21
        Anchors = [akLeft, akTop, akRight]
        TabOrder = 4
      end
      object rbDNotUseProxyForUpdate: TRadioButton
        AlignWithMargins = True
        Left = 9
        Top = 141
        Width = 435
        Height = 17
        Margins.Left = 9
        Caption = #1053#1077' '#1080#1089#1087#1086#1083#1100#1079#1086#1074#1072#1090#1100' '#1087#1088#1086#1082#1089#1080' '#1076#1083#1103' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1081
        Checked = True
        TabOrder = 5
        TabStop = True
        OnClick = rbUseProxyForUpdateClick
      end
      object rbUseProxyForUpdate: TRadioButton
        AlignWithMargins = True
        Left = 9
        Top = 164
        Width = 435
        Height = 17
        Margins.Left = 9
        Caption = #1048#1089#1087#1086#1083#1100#1079#1086#1074#1072#1090#1100' '#1087#1088#1086#1082#1089#1080' '#1076#1083#1103' '#1086#1073#1085#1086#1074#1083#1077#1085#1080#1081
        TabOrder = 6
        OnClick = rbUseProxyForUpdateClick
      end
      object edProxyServerUpdate: TEdit
        Left = 62
        Top = 188
        Width = 240
        Height = 21
        Anchors = [akLeft, akTop, akRight]
        TabOrder = 7
      end
      object edProxyPortUpdate: TEdit
        Left = 345
        Top = 188
        Width = 68
        Height = 21
        Alignment = taRightJustify
        Anchors = [akTop, akRight]
        MaxLength = 5
        NumbersOnly = True
        TabOrder = 8
        OnExit = CheckNumValue
      end
      object edProxyPasswordUpdate: TEdit
        Left = 309
        Top = 215
        Width = 104
        Height = 21
        Anchors = [akTop, akRight]
        PasswordChar = '*'
        TabOrder = 9
      end
      object edProxyUsernameUpdate: TEdit
        Left = 62
        Top = 215
        Width = 188
        Height = 21
        Anchors = [akLeft, akTop, akRight]
        TabOrder = 10
      end
      object cbProxyType: TComboBox
        AlignWithMargins = True
        Left = 81
        Top = 84
        Width = 72
        Height = 21
        Margins.Left = 15
        Margins.Right = 7
        Style = csDropDownList
        ItemIndex = 0
        TabOrder = 11
        Text = 'HTTP'
        Items.Strings = (
          'HTTP'
          'SOCKS 4'
          'SOCKS 5')
      end
    end
    object tsScripts: TTabSheet
      HelpContext = 140
      Caption = 'tsScripts'
      ImageIndex = 4
      TabVisible = False
      object Label12: TLabel
        AlignWithMargins = True
        Left = 3
        Top = 3
        Width = 441
        Height = 13
        Align = alTop
        Caption = #1057#1082#1088#1080#1087#1090#1099
        Font.Charset = DEFAULT_CHARSET
        Font.Color = clWindowText
        Font.Height = -11
        Font.Name = 'Tahoma'
        Font.Style = [fsBold]
        ParentFont = False
        ExplicitWidth = 51
      end
      object Panel2: TPanel
        Left = 0
        Top = 318
        Width = 447
        Height = 69
        Align = alBottom
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 1
        DesignSize = (
          447
          69)
        object Label13: TLabel
          Left = 3
          Top = 44
          Width = 77
          Height = 13
          Caption = #1055#1086' '#1091#1084#1086#1083#1095#1072#1085#1080#1102':'
          FocusControl = cbDefaultAction
        end
        object btnAddScript: TButton
          Left = 3
          Top = 3
          Width = 75
          Height = 25
          Caption = #1044#1086#1073#1072#1074#1080#1090#1100
          TabOrder = 0
          OnClick = btnAddScriptClick
        end
        object btnEditScript: TButton
          Left = 84
          Top = 3
          Width = 75
          Height = 25
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 1
          OnClick = btnEditScriptClick
        end
        object btnDeleteScript: TButton
          Left = 165
          Top = 3
          Width = 75
          Height = 25
          Caption = #1059#1076#1072#1083#1080#1090#1100
          TabOrder = 2
          OnClick = btnDeleteScriptClick
        end
        object cbDefaultAction: TComboBox
          Left = 137
          Top = 41
          Width = 307
          Height = 21
          Style = csDropDownList
          Anchors = [akLeft, akTop, akRight]
          TabOrder = 3
        end
      end
      object lvScripts: TListView
        AlignWithMargins = True
        Left = 3
        Top = 22
        Width = 441
        Height = 293
        Align = alClient
        Columns = <
          item
            Caption = #1053#1072#1079#1074#1072#1085#1080#1077
            Width = 80
          end
          item
            AutoSize = True
            Caption = #1055#1091#1090#1100
          end
          item
            Caption = #1055#1072#1088#1072#1084#1077#1090#1088#1099
            Width = 135
          end>
        ColumnClick = False
        GridLines = True
        HideSelection = False
        ReadOnly = True
        RowSelect = True
        TabOrder = 0
        ViewStyle = vsReport
        OnDblClick = btnEditScriptClick
      end
    end
    object tsBehavour: TTabSheet
      Caption = 'tsBehavior'
      ImageIndex = 5
      TabVisible = False
      object Panel3: TPanel
        AlignWithMargins = True
        Left = 3
        Top = 3
        Width = 441
        Height = 375
        Margins.Bottom = 9
        Align = alClient
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 0
        DesignSize = (
          441
          375)
        object Label6: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 435
          Height = 13
          Align = alTop
          Caption = #1055#1086#1074#1077#1076#1077#1085#1080#1077
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          Transparent = True
          ExplicitWidth = 65
        end
        object Label10: TLabel
          Left = 15
          Top = 330
          Width = 131
          Height = 13
          Alignment = taRightJustify
          Caption = #1064#1072#1073#1083#1086#1085' '#1079#1072#1075#1086#1083#1086#1074#1082#1072' '#1082#1085#1080#1075#1080':'
          WordWrap = True
        end
        object cbShowSubGenreBooks: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 22
          Width = 429
          Height = 17
          Margins.Left = 9
          Align = alTop
          Caption = #1055#1086#1082#1072#1079#1099#1074#1072#1090#1100' '#1082#1085#1080#1075#1080' '#1080#1079' '#1074#1083#1086#1078#1077#1085#1085#1099#1093' '#1078#1072#1085#1088#1086#1074' ('#1085#1077' fb2)'
          Color = clBtnFace
          ParentColor = False
          TabOrder = 0
        end
        object cbMinimizeToTray: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 45
          Width = 429
          Height = 17
          Margins.Left = 9
          Align = alTop
          Caption = #1057#1074#1086#1088#1072#1095#1080#1074#1072#1090#1100' '#1074' '#1090#1088#1077#1081
          Color = clBtnFace
          ParentColor = False
          TabOrder = 1
        end
        object cbAutoStartDwnld: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 68
          Width = 429
          Height = 17
          Margins.Left = 9
          Align = alTop
          Caption = #1057#1090#1072#1088#1090#1086#1074#1072#1090#1100' '#1079#1072#1075#1088#1091#1079#1082#1091' '#1072#1074#1090#1086#1084#1072#1090#1080#1095#1077#1089#1082#1080
          TabOrder = 2
        end
        object cbAllowMixedCollections: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 91
          Width = 429
          Height = 17
          Margins.Left = 9
          Align = alTop
          Caption = #1056#1072#1079#1088#1077#1096#1080#1090#1100' '#1089#1084#1077#1096#1072#1085#1085#1099#1077' '#1082#1086#1083#1083#1077#1082#1094#1080#1080
          Color = clBtnFace
          ParentColor = False
          TabOrder = 3
        end
        object cbDeleteDeleted: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 114
          Width = 429
          Height = 17
          Margins.Left = 9
          Align = alTop
          Caption = #1059#1076#1072#1083#1103#1090#1100' "'#1091#1076#1072#1083#1105#1085#1085#1099#1077' '#1074' '#1073#1080#1073#1083#1080#1086#1090#1077#1082#1077'"'
          Color = clBtnFace
          ParentColor = False
          TabOrder = 4
        end
        object cbAutoLoadReview: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 137
          Width = 429
          Height = 16
          Margins.Left = 9
          Align = alTop
          Caption = #1040#1074#1090#1086#1084#1072#1090#1080#1095#1077#1089#1082#1080' '#1079#1072#1075#1088#1091#1078#1072#1090#1100' '#1088#1077#1094#1077#1085#1079#1080#1080
          Color = clBtnFace
          ParentColor = False
          TabOrder = 5
        end
        object cbDeleteFiles: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 187
          Width = 429
          Height = 16
          Margins.Left = 9
          Align = alTop
          Caption = #1059#1076#1072#1083#1103#1090#1100' '#1092#1072#1081#1083#1099' '#1087#1088#1080' '#1091#1076#1072#1083#1077#1085#1080#1080' '#1082#1085#1080#1075
          Color = clBtnFace
          ParentColor = False
          TabOrder = 6
        end
        object cbOverwriteFB2Info: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 165
          Width = 429
          Height = 16
          Margins.Left = 9
          Margins.Top = 9
          Align = alTop
          Caption = #1055#1077#1088#1077#1079#1072#1087#1080#1089#1099#1074#1072#1090#1100' '#1079#1072#1075#1086#1083#1086#1074#1086#1082' fb2'
          TabOrder = 7
          OnClick = cbOverwriteFB2InfoClick
        end
        object edTitleTemplate: TEdit
          Left = 152
          Top = 327
          Width = 201
          Height = 21
          Anchors = [akLeft, akTop, akRight]
          ReadOnly = True
          TabOrder = 8
          Text = '[%s [(%n) ]- ]%t'
        end
        object btnTitleTemplate: TButton
          Left = 358
          Top = 325
          Width = 76
          Height = 25
          Anchors = [akTop, akRight]
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 9
          OnClick = EditTextTemplate
        end
        object cbSelectedIsChecked: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 243
          Width = 429
          Height = 16
          Margins.Left = 9
          Margins.Top = 9
          Align = alTop
          Caption = #1054#1073#1088#1072#1073#1072#1090#1099#1074#1072#1090#1100' '#1074#1099#1076#1077#1083#1077#1085#1085#1099#1077' '#1082#1072#1082' '#1086#1090#1084#1077#1095#1077#1085#1085#1099#1077
          TabOrder = 10
          OnClick = cbOverwriteFB2InfoClick
        end
        object cbIgnoreArchives: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 215
          Width = 429
          Height = 16
          Margins.Left = 9
          Margins.Top = 9
          Align = alTop
          Caption = #1048#1075#1085#1086#1088#1080#1088#1086#1074#1072#1090#1100' '#1085#1077#1076#1086#1089#1090#1072#1102#1097#1080#1077' '#1072#1088#1093#1080#1074#1099
          TabOrder = 11
          OnClick = cbIgnoreArchivesClick
        end
      end
    end
    object tsFileSort: TTabSheet
      Caption = 'tsFileSort'
      ImageIndex = 6
      TabVisible = False
      object Panel4: TPanel
        AlignWithMargins = True
        Left = 3
        Top = 3
        Width = 441
        Height = 246
        Margins.Bottom = 9
        Align = alTop
        BevelOuter = bvNone
        ShowCaption = False
        TabOrder = 0
        DesignSize = (
          441
          246)
        object Label21: TLabel
          AlignWithMargins = True
          Left = 3
          Top = 3
          Width = 435
          Height = 13
          Align = alTop
          Caption = #1048#1084#1087#1086#1088#1090' '#1092#1072#1081#1083#1086#1074
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 90
        end
        object Label22: TLabel
          Left = 15
          Top = 58
          Width = 35
          Height = 13
          Caption = #1055#1072#1087#1082#1072':'
          FocusControl = edImportFolder
        end
        object Label23: TLabel
          Left = 15
          Top = 82
          Width = 419
          Height = 13
          Anchors = [akLeft, akTop, akRight]
          AutoSize = False
          Caption = #1057#1086#1088#1090#1080#1088#1086#1074#1082#1072' FB2'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 421
        end
        object Label4: TLabel
          Left = 21
          Top = 104
          Width = 38
          Height = 13
          Alignment = taRightJustify
          Caption = #1055#1072#1087#1082#1072': '
          FocusControl = edFB2FolderTemplate
        end
        object Label8: TLabel
          Left = 21
          Top = 131
          Width = 33
          Height = 13
          Alignment = taRightJustify
          Caption = #1060#1072#1081#1083': '
          FocusControl = edFB2FileTemplate
        end
        object Label24: TLabel
          Left = 15
          Top = 155
          Width = 419
          Height = 13
          Anchors = [akLeft, akTop, akRight]
          AutoSize = False
          Caption = #1057#1086#1088#1090#1080#1088#1086#1074#1082#1072' FBD'
          Font.Charset = DEFAULT_CHARSET
          Font.Color = clWindowText
          Font.Height = -11
          Font.Name = 'Tahoma'
          Font.Style = [fsBold]
          ParentFont = False
          ExplicitWidth = 421
        end
        object Label2: TLabel
          Left = 21
          Top = 177
          Width = 38
          Height = 13
          Alignment = taRightJustify
          Caption = #1055#1072#1087#1082#1072': '
          FocusControl = edFBDFolderTemplate
        end
        object Label3: TLabel
          Left = 21
          Top = 204
          Width = 33
          Height = 13
          Alignment = taRightJustify
          Caption = #1060#1072#1081#1083': '
          FocusControl = edFBDFileTemplate
        end
        object btnImportFolder: TButton
          Left = 358
          Top = 53
          Width = 76
          Height = 25
          Anchors = [akTop, akRight]
          Caption = #1042#1099#1073#1088#1072#1090#1100
          TabOrder = 2
          OnClick = SelectFolder
        end
        object cbEnableFileSort: TCheckBox
          AlignWithMargins = True
          Left = 9
          Top = 22
          Width = 429
          Height = 27
          Margins.Left = 9
          Align = alTop
          Caption = #1042#1082#1083#1102#1095#1080#1090#1100' '#1089#1086#1088#1090#1080#1088#1086#1074#1082#1091' '#1087#1088#1080' '#1080#1084#1087#1086#1088#1090#1077
          TabOrder = 0
          WordWrap = True
          OnClick = cbEnableFileSortClick
        end
        object edImportFolder: TMHLAutoCompleteEdit
          Left = 56
          Top = 55
          Width = 297
          Height = 21
          HelpContext = 5001
          Anchors = [akLeft, akTop, akRight]
          TabOrder = 1
        end
        object edFB2FileTemplate: TEdit
          Tag = 785
          Left = 65
          Top = 128
          Width = 288
          Height = 21
          Anchors = [akLeft, akTop, akRight]
          ReadOnly = True
          TabOrder = 5
        end
        object edFB2FolderTemplate: TEdit
          Tag = 785
          Left = 65
          Top = 101
          Width = 288
          Height = 21
          Anchors = [akLeft, akTop, akRight]
          ReadOnly = True
          TabOrder = 3
        end
        object edFBDFileTemplate: TEdit
          Tag = 785
          Left = 65
          Top = 201
          Width = 288
          Height = 21
          Anchors = [akLeft, akTop, akRight]
          ReadOnly = True
          TabOrder = 9
        end
        object edFBDFolderTemplate: TEdit
          Tag = 785
          Left = 65
          Top = 174
          Width = 288
          Height = 21
          Anchors = [akLeft, akTop, akRight]
          ReadOnly = True
          TabOrder = 7
          Text = '%g\%s'
        end
        object btnFB2FolderTemplate: TButton
          Left = 358
          Top = 99
          Width = 76
          Height = 25
          Anchors = [akTop, akRight]
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 4
          OnClick = EditFolderTemplate
        end
        object btnFB2FileTemplate: TButton
          Left = 358
          Top = 126
          Width = 76
          Height = 25
          Anchors = [akTop, akRight]
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 6
          OnClick = EditFileNameTemplate
        end
        object btnFBDFileTemplate: TButton
          Left = 358
          Top = 199
          Width = 76
          Height = 25
          Anchors = [akTop, akRight]
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 10
          OnClick = EditFileNameTemplate
        end
        object btnFBDFolderTemplate: TButton
          Left = 358
          Top = 172
          Width = 76
          Height = 25
          Anchors = [akTop, akRight]
          Caption = #1048#1079#1084#1077#1085#1080#1090#1100
          TabOrder = 8
          OnClick = EditFolderTemplate
        end
      end
    end
  end
  object pnButtons: TPanel
    Left = 0
    Top = 403
    Width = 617
    Height = 41
    Align = alBottom
    BevelOuter = bvNone
    Caption = 'pnButtons'
    ShowCaption = False
    TabOrder = 2
    DesignSize = (
      617
      41)
    object btnOk: TButton
      Left = 445
      Top = 10
      Width = 75
      Height = 25
      Anchors = [akTop, akRight]
      Caption = '&'#1057#1086#1093#1088#1072#1085#1080#1090#1100
      Default = True
      ModalResult = 1
      TabOrder = 0
      OnClick = SaveSettingsClick
    end
    object btnCancel: TButton
      Left = 526
      Top = 10
      Width = 75
      Height = 25
      Anchors = [akTop, akRight]
      Cancel = True
      Caption = '&'#1054#1090#1084#1077#1085#1072
      ModalResult = 2
      TabOrder = 1
    end
    object btnHelp: TButton
      Left = 12
      Top = 10
      Width = 75
      Height = 25
      Caption = #1057#1087#1088#1072#1074#1082#1072
      TabOrder = 2
      OnClick = ShowHelpClick
    end
  end
  object tvSections: TTreeView
    AlignWithMargins = True
    Left = 3
    Top = 5
    Width = 150
    Height = 394
    Margins.Top = 5
    Margins.Bottom = 4
    Align = alLeft
    HideSelection = False
    Indent = 19
    RowSelect = True
    TabOrder = 0
    OnChange = tvSectionsChange
    Items.NodeData = {
      070800000009540054007200650065004E006F00640065004300000000000000
      00000000FFFFFFFFFFFFFFFFFFFFFFFF00000000000000000001121F0430043F
      043A04380420002F00200023044104420440043E043904410442043204300400
      00350000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF00000000000000
      0000010B220438043F044B0420004404300439043B043E043204000031000000
      0000000000000000FFFFFFFFFFFFFFFFFFFFFFFF000000000000000000010918
      043D04420435044004440435043904410400002F0000000000000000000000FF
      FFFFFFFFFFFFFFFFFFFFFF000000000000000000010818043D04420435044004
      3D043504420400002B0000000000000000000000FFFFFFFFFFFFFFFF00000000
      00000000000000000001061F0440043E043A044104380400002D000000000000
      0000000000FFFFFFFFFFFFFFFFFFFFFFFF000000000000000000010721043A04
      400438043F0442044B0400002B0000000000000000000000FFFFFFFFFFFFFFFF
      0000000000000000000000000001062004300437043D043E0435040000410000
      000000000000000000FFFFFFFFFFFFFFFF000000000000000000000000000111
      21043E0440044204380440043E0432043A04300420004404300439043B043E04
      3204}
  end
  object dlgColors: TColorDialog
    Left = 32
    Top = 176
  end
end
