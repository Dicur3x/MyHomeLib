(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors             Oleksiy Penkov (oleksiy.penkov@gmail.com)
  *                     Nick Rymanov   (nrymanov@gmail.com)
  * Created             20.08.2008
  * Description
  *
  * $Id: frm_main.pas 1183 2015-04-01 04:32:39Z koreec $
  *
  * History
  * NickR 06.05.2010    Для уменьшения размера dfm и единообразия интерфейса некоторые компоненты
  *                     заменены своими версиями с заранее настроенными свойствами.
  *
  ****************************************************************************** *)

unit frm_main;

interface

uses
  Windows,
  Messages,
  SysUtils,
  Variants,
  Classes,
  Graphics,
  Controls,
  Forms,
  Dialogs,
  VirtualTrees,
  VirtualTrees.Types,
  StdCtrls,
  ComCtrls,
  Mask,
  ExtCtrls,
  ToolWin,
  ImgList,
  Clipbrd,
  Menus,
  ShellAPI,
  unit_Globals,
  unit_ProgramUpdates,
  frm_ProgramUpdate,
  frm_OPDS,
  unit_Interfaces,
  XMLIntf,
  XMLDoc,
  pngimage,
  jpeg,
  DB,
  unit_DownloadManagerThread,
  unit_DownloadView,
  unit_Messages,
  files_list,
  ActiveX,
  Buttons,
  MHLSplitter,
  ActnList,
  BookInfoPanel,
  ActnMan,
  MHLSimplePanel,
  BookTreeView,
  unit_SearchPresets,
  unit_SearchQueryModeControl, unit_BookSearchPanel,
  MHLButtonedEdit,
  unit_UserData,
  unit_treeController,
  unit_ColorTabs,
  unit_PublisherSeriesView,
  System.Actions,
  System.ImageList,
  Vcl.Themes,
  dm_Images, VirtualTrees.BaseAncestorVCL, VirtualTrees.BaseTree,
  VirtualTrees.AncestorVCL,
  unit_Localization, unit_BookInfoPreview, System.Generics.Collections,
  unit_AuthorFavorites, unit_AuthorFavoriteRefresh, unit_ReaderAnnotations;

type
  TfrmMain = class(TForm, IDownloadView)
    MainMenu: TMainMenu;
    miBook: TMenuItem;
    miQuitApp: TMenuItem;
    pmMain: TPopupMenu;
    pmiReadBook: TMenuItem;
    pmiSendToDevice: TMenuItem;
    N19: TMenuItem;
    miAddFavorites: TMenuItem;
    miDelFavorites: TMenuItem;
    miRate: TMenuItem;
    miSetRate1: TMenuItem;
    miSetRate2: TMenuItem;
    miSetRate3: TMenuItem;
    miSetRate4: TMenuItem;
    miSetRate5: TMenuItem;
    N11: TMenuItem;
    miClearRate: TMenuItem;
    N20: TMenuItem;
    pmiCheckAll: TMenuItem;
    pmiDeselectAll: TMenuItem;
    N23: TMenuItem;
    miCopyClBrd: TMenuItem;
    pmiBookInfo: TMenuItem;
    N2: TMenuItem;
    miTools: TMenuItem;
    miSettings: TMenuItem;
    N5: TMenuItem;
    miCollSelect: TMenuItem;
    miDeleteCol: TMenuItem;
    N18: TMenuItem;
    miStat: TMenuItem;
    miRead: TMenuItem;
    miDevice: TMenuItem;
    N7: TMenuItem;
    miCollsettings: TMenuItem;
    miCopyToCollection: TMenuItem;
    miFb2Import: TMenuItem;
    miAbout: TMenuItem;
    miCheckUpdates: TMenuItem;
    N30: TMenuItem;
    miShowHelp: TMenuItem;
    N17: TMenuItem;
    pmAuthor: TPopupMenu;
    miCopyAuthor: TMenuItem;
    miPdfdjvu: TMenuItem;
    miBookEdit: TMenuItem;
    miRefreshGenres: TMenuItem;
    miDownloadBooks: TMenuItem;
    pmiDownloadBooks: TMenuItem;
    pmCollection: TPopupMenu;
    miUpdate: TMenuItem;
    miUpdateFromFile: TMenuItem;
    miGoToAuthor: TMenuItem;
    tlbrMain: TToolBar;
    tbtnRead: TToolButton;
    tbSendToDevice: TToolButton;
    tbtnRus: TToolButton;
    tbtnEng: TToolButton;
    tbSelectAll: TToolButton;
    tbCollapse: TToolButton;
    tbtnShowCover: TToolButton;
    tbtnShowDeleted: TToolButton;
    RzSep1: TToolButton;
    RzSep2: TToolButton;
    RzSep3: TToolButton;
    RzSep4: TToolButton;
    RzSep5: TToolButton;
    RzSep6: TToolButton;
    BtnFav_add: TToolButton;
    tbtnSettings: TToolButton;
    pmScripts: TPopupMenu;
    MenuItem1: TMenuItem;
    MenuItem2: TMenuItem;
    MenuItem3: TMenuItem;
    pmiScripts: TMenuItem;
    mmiScripts: TMenuItem;
    miSyncOnline: TMenuItem;
    btnSwitchTreeMode: TToolButton;
    tbtnWizard: TToolButton;
    tbtnShowLocalOnly: TToolButton;
    tbtnDownloadList_Add: TToolButton;
    N1: TMenuItem;
    miGoSite: TMenuItem;
    pgControl: TPageControl;
    tsSearch: TTabSheet;
    tsByGroup: TTabSheet;
    ilFileTypes: TImageList;
    tsByAuthor: TTabSheet;
    tvAuthors: TVirtualStringTree;
    pnAuthorSearch: TMHLSimplePanel;
    lblAuthorsSearch: TLabel;
    tbClearEdAuthor: TSpeedButton;
    edLocateAuthor: TEdit;
    pnAuthorBooksTitle: TMHLSimplePanel;
    lblBooksTotalA: TLabel;
    ipnlAuthors: TInfoPanel;
    pmHeaders: TPopupMenu;
    N3: TMenuItem;
    N4: TMenuItem;
    N8: TMenuItem;
    N10: TMenuItem;
    N12: TMenuItem;
    N13: TMenuItem;
    N15: TMenuItem;
    N21: TMenuItem;
    N22: TMenuItem;
    N25: TMenuItem;
    N27: TMenuItem;
    tsBySerie: TTabSheet;
    pnSeriesView: TMHLSimplePanel;
    tvSeries: TVirtualStringTree;
    pnSerieSearch: TMHLSimplePanel;
    lblSerieSearch: TLabel;
    btnClearEdSeries: TSpeedButton;
    edLocateSeries: TEdit;
    pnSerieBooksView: TMHLSimplePanel;
    pnSerieBooksTitle: TMHLSimplePanel;
    lblBooksTotalS: TLabel;
    ipnlSeries: TInfoPanel;
    tsByGenre: TTabSheet;
    pnGenresView: TMHLSimplePanel;
    tvGenres: TVirtualStringTree;
    pnGenreBooksView: TMHLSimplePanel;
    pnGenreBooksTitle: TMHLSimplePanel;
    lblBooksTotalG: TLabel;
    lblGenreTitle: TLabel;
    btnShowGenreBooks: TButton;
    ipnlGenres: TInfoPanel;
    TrayIcon: TTrayIcon;
    pmTray: TPopupMenu;
    N29: TMenuItem;
    N32: TMenuItem;
    N33: TMenuItem;
    tsDownload: TTabSheet;
    pmDownloadList: TPopupMenu;
    mi_dwnl_LocateAuthor: TMenuItem;
    N35: TMenuItem;
    mi_dwnl_Delete: TMenuItem;
    N34: TMenuItem;
    tlbrDownloadList: TToolBar;
    BtnDwnldUp: TToolButton;
    BtnDwnldDown: TToolButton;
    BtnDelete: TToolButton;
    BtnFirstRecord: TToolButton;
    BtnLastRecord: TToolButton;
    DlSep1: TToolButton;
    DlSep2: TToolButton;
    lblAuthor: TLabel;
    lblSeries: TLabel;
    btnStartDownload: TToolButton;
    btnPauseDownload: TToolButton;
    Panel1: TMHLSimplePanel;
    RzPanel2: TMHLSimplePanel;
    lblDownloadState: TLabel;
    lblDnldAuthor: TLabel;
    lblDnldTitle: TLabel;
    lblDownloadCount: TLabel;
    BtnSave: TToolButton;
    N28: TMenuItem;
    N37: TMenuItem;
    miAddToSearch: TMenuItem;
    miINPXCollectionExport: TMenuItem;
    N38: TMenuItem;
    pnGroupsView: TMHLSimplePanel;
    tvGroups: TVirtualStringTree;
    RzPanel8: TMHLSimplePanel;
    pnGroupBooksView: TMHLSimplePanel;
    ipnlFavorites: TInfoPanel;
    lblTotalBooksF: TLabel;
    pmGroups: TPopupMenu;
    GroupMenuItem: TMenuItem;
    btnAddGroup: TButton;
    btnDeleteGroup: TButton;
    btnClearGroup: TButton;
    pmiGroups: TMenuItem;
    pnGroupBooksTitle: TMHLSimplePanel;
    lblBooksTotalF: TLabel;
    lblGroups: TLabel;
    N39: TMenuItem;
    N40: TMenuItem;
    N41: TMenuItem;
    N14: TMenuItem;
    miImportUserData: TMenuItem;
    miExportUserData: TMenuItem;
    miReaded: TMenuItem;
    N44: TMenuItem;
    N42: TMenuItem;
    N45: TMenuItem;
    SearchParams: TCategoryPanelGroup;
    ctpOther: TCategoryPanel;
    Label30: TLabel;
    Label2: TLabel;
    Label4: TLabel;
    cbDate: TComboBox;
    cbLang: TComboBox;
    cbDownloaded: TComboBox;
    cbDeleted: TCheckBox;
    cbCollapseMultiSeriesResults: TCheckBox;
    ctpFile: TCategoryPanel;
    Label27: TLabel;
    Label29: TLabel;
    Label28: TLabel;
    edFFile: TMHLButtonedEdit;
    edFFolder: TMHLButtonedEdit;
    edFExt: TMHLButtonedEdit;
    pnSearchBooksView: TMHLSimplePanel;
    ipnlSearch: TInfoPanel;
    pnlFullSearch: TMHLSimplePanel;
    lblTotalBooksFL: TLabel;
    Label1: TLabel;
    cbPresetName: TComboBox;
    btnDeletePreset: TButton;
    btnSavePreset: TButton;
    btnClearFilterEdits: TButton;
    btnApplyFilter: TButton;
    BalloonHint1: TBalloonHint;
    miRepairDataBase: TMenuItem;
    N6: TMenuItem;
    miCompactDataBase: TMenuItem;
    ctpBook: TCategoryPanel;
    Label5: TLabel;
    edFFullName: TMHLButtonedEdit;
    Label24: TLabel;
    edFTitle: TMHLButtonedEdit;
    Label26: TLabel;
    edFSeries: TMHLButtonedEdit;
    edFGenre: TMHLButtonedEdit;
    Label6: TLabel;
    N31: TMenuItem;
    miFastBookSearch: TMenuItem;
    pmiSelectAll: TMenuItem;
    pbDownloadProgress: TProgressBar;
    miFBDImport: TMenuItem;
    miShowEditToolbar: TMenuItem;
    tlbrEdit: TToolBar;
    tbtnEditAuthor: TToolButton;
    tbtnEditSeries: TToolButton;
    tbtnEditGenre: TToolButton;
    tbtnEditBook: TToolButton;
    tbtnSplitter1: TToolButton;
    tbtnFBD: TToolButton;
    tbtnSplitter2: TToolButton;
    tbtnDeleteBook: TToolButton;
    tbtnAutoFBD: TToolButton;
    tbtnHelp: TToolButton;
    N46: TMenuItem;
    miExportToHTML: TMenuItem;
    txt1: TMenuItem;
    RTF1: TMenuItem;
    edFAnnotation: TMHLButtonedEdit;
    Label7: TLabel;
    pnAuthorsView: TMHLSimplePanel;
    pnAuthorBooksView: TMHLSimplePanel;
    AuthorsViewSplitter: TMHLSplitter;
    AuthorBookInfoSplitter: TMHLSplitter;
    ilAlphabetNormal: TImageList;
    ilAlphabetActive: TImageList;
    Actions: TActionList;
    acShowRusAlphabet: TAction;
    acShowEngAlphabet: TAction;
    miShowRusAlphabet: TMenuItem;
    miShowEngAlphabet: TMenuItem;
    acShowEditToolbar: TAction;
    N49: TMenuItem;
    acShowMainToolbar: TAction;
    acShowStatusbar: TAction;
    miShowMainToolbar: TMenuItem;
    miShowStatusbar: TMenuItem;
    miView: TMenuItem;
    acShowBookInfoPanel: TAction;
    miShowBookInfo: TMenuItem;
    SeriesViewSplitter: TMHLSplitter;
    SerieBookInfoSplitter: TMHLSplitter;
    GenresViewSplitter: TMHLSplitter;
    GenreBookInfoSplitter: TMHLSplitter;
    SearchViewSplitter: TMHLSplitter;
    SearchBookInfoSplitter: TMHLSplitter;
    pnSearchView: TMHLSimplePanel;
    pnSearchControl: TMHLSimplePanel;
    GroupsViewSplitter: TMHLSplitter;
    GroupBookInfoSplitter: TMHLSplitter;
    tbtnClear: TToolButton;
    tvBooksA: TBookTree;
    tvBooksS: TBookTree;
    tvBooksG: TBookTree;
    tvBooksSR: TBookTree;
    tvBooksF: TBookTree;
    tvDownloadList: TBookTree;
    acShowBookCover: TAction;
    acShowBookAnnotation: TAction;
    miViewExtra: TMenuItem;
    miShowBookCover: TMenuItem;
    miShowBookAnnotation: TMenuItem;
    acBookSetRate1: TAction;
    acBookSetRate2: TAction;
    acBookSetRate3: TAction;
    acBookSetRate4: TAction;
    acBookSetRate5: TAction;
    acBookSetRateClear: TAction;
    acGroupCreate: TAction;
    acGroupDelete: TAction;
    acGroupClear: TAction;
    acGroupExportMetabib: TAction;
    acGroupExportDestination: TAction;
    miGroupExportMetabib: TMenuItem;
    miGroupExportDestination: TMenuItem;
    miPopupGroupExportMetabib: TMenuItem;
    miPopupGroupExportDestination: TMenuItem;
    StatusBar: TPanel;
    spStatus: TLabel;
    spHint: TLabel;
    spInfo: TLabel;
    acSavePreset: TAction;
    acDeletePreset: TAction;
    acApplyPreset: TAction;
    acClearPreset: TAction;
    acEditAuthor: TAction;
    acEditSerie: TAction;
    acEditGenre: TAction;
    acEditBook: TAction;
    acEditConvert2FBD: TAction;
    acEditAutoConvert2FBD: TAction;
    N36: TMenuItem;
    N47: TMenuItem;
    N48: TMenuItem;
    N50: TMenuItem;
    N51: TMenuItem;
    N52: TMenuItem;
    FBD1: TMenuItem;
    FBD2: TMenuItem;
    acGroupEdit: TAction;
    pmGroupActions: TPopupMenu;
    N9: TMenuItem;
    N26: TMenuItem;
    N58: TMenuItem;
    N59: TMenuItem;
    tbarAuthorsRus: TToolBar;
    tbarAuthorsEng: TToolBar;
    tbarSeriesEng: TToolBar;
    tbarSeriesRus: TToolBar;
    acBookRead: TAction;
    acBookSend2Device: TAction;
    acBookAdd2DownloadList: TAction;
    acBookMarkAsRead: TAction;
    acBookAdd2Favorites: TAction;
    acBookAdd2Group: TAction;
    acBookRemoveFromGroup: TAction;
    acBookShowInfo: TAction;
    acBookCopy2Collection: TAction;
    acBookDelete: TAction;
    acApplicationExit: TAction;
    acCollectionNew: TAction;
    acCollectionSelect: TAction;
    acCollectionProperties: TAction;
    acCollectionStatistics: TAction;
    acCollectionDelete: TAction;
    acViewTreeView: TAction;
    acViewTableView: TAction;
    acViewHideDeletedBooks: TAction;
    acViewShowLocalOnly: TAction;
    acToolsQuickSearch: TAction;
    acToolsUpdateOnlineCollections: TAction;
    acCollectionUpdateFromFile: TAction;
    N83: TMenuItem;
    acToolsClearReadFolder: TAction;
    acToolsRunScript: TAction;
    acToolsSettings: TAction;
    acHelpHelp: TAction;
    acHelpCheckUpdates: TAction;
    acHelpProgramSite: TAction;
    acHelpAbout: TAction;
    N60: TMenuItem;
    N61: TMenuItem;
    N62: TMenuItem;
    N63: TMenuItem;
    N64: TMenuItem;
    N65: TMenuItem;
    N66: TMenuItem;
    N67: TMenuItem;
    N68: TMenuItem;
    N69: TMenuItem;
    miAdd2Favorites: TMenuItem;
    miAddToGroup: TMenuItem;
    miRemoveFromGroup: TMenuItem;
    N73: TMenuItem;
    N74: TMenuItem;
    N75: TMenuItem;
    N76: TMenuItem;
    acViewTreeView1: TMenuItem;
    acViewTableView1: TMenuItem;
    acViewSelectColumns: TAction;
    N77: TMenuItem;
    N78: TMenuItem;
    N79: TMenuItem;
    N16: TMenuItem;
    acImportFb2Zip: TAction;
    acImportFb2: TAction;
    acImportNonFB2: TAction;
    acImportFBD: TAction;
    acImportUserData: TAction;
    acExport2HTML: TAction;
    acExport2Txt: TAction;
    acExport2RTF: TAction;
    acExport2INPX: TAction;
    acExportUserData: TAction;
    acCollectionUpdateGenres: TAction;
    acCollectionSyncFiles: TAction;
    acCollectionRepair: TAction;
    acCollectionCompact: TAction;
    N24: TMenuItem;
    N43: TMenuItem;
    N80: TMenuItem;
    N81: TMenuItem;
    N82: TMenuItem;
    Label8: TLabel;
    cbLibRate: TComboBox;
    edFKeyWords: TMHLButtonedEdit;
    Label3: TLabel;
    tmrCheckUpdates: TTimer;
    BookID1: TMenuItem;
    miBookInfoPriority: TMenuItem;
    acViewSetInfoPriority: TAction;
    tmrSearchA: TTimer;
    tmrSearchS: TTimer;
    cbLangSelectA: TComboBox;
    cbReaded: TCheckBox;
    cbLangSelectS: TComboBox;
    cbLangSelectG: TComboBox;
    cbLangSelectF: TComboBox;
    lblLang: TLabel;
    lbl1: TLabel;
    lbl2: TLabel;
    lbl3: TLabel;
    pmMarkSelected: TMenuItem;
    ToolButton4: TToolButton;
    ToolButton6: TToolButton;

    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroy(Sender: TObject);
    procedure FormAfterMonitorDpiChanged(Sender: TObject; OldDPI, NewDPI: Integer);
    procedure FormShortCut(var Msg: TWMKey; var Handled: Boolean);

    procedure tvAuthorsChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure tvAuthorsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);

    procedure tvSeriesChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure tvSeriesKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);

    procedure tvGenresChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure tvGenresKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure btnShowGenreBooksClick(Sender: TObject);

    procedure tvGroupsChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure tvGroupsDragDrop(Sender: TBaseVirtualTree; Source: TObject; DataObject: IDataObject; Formats: TFormatArray; Shift: TShiftState; Pt: TPoint; var Effect: Integer; Mode: TDropMode);
    procedure tvGroupsDragOver(Sender: TBaseVirtualTree; Source: TObject; Shift: TShiftState; State: TDragState; Pt: TPoint; Mode: TDropMode; var Effect: Integer; var Accept: Boolean);
    procedure tvGroupsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);

    procedure tvBooksTreeHeaderClick(Sender: TVTHeader; HitInfo: TVTHeaderHitInfo);
    procedure tvBooksTreeMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure tvBooksTreeKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure tvBooksTreeChange(Sender: TBaseVirtualTree; Node: PVirtualNode);

    procedure ReadBookExecute(Sender: TObject);
    procedure SendToDeviceExecute(Sender: TObject);
    procedure Add2DownloadListExecute(Sender: TObject);
    procedure MarkAsReadedExecute(Sender: TObject);
    procedure BookSetRateExecute(Sender: TObject);
    procedure DeleteBookExecute(Sender: TObject);
    procedure QuitAppExecute(Sender: TObject);

    procedure ShowNewCollectionWizard(Sender: TObject);
    procedure ShowCollectionSettingsExecute(Sender: TObject);
    procedure ShowCollectionStatisticsExecute(Sender: TObject);
    procedure ImportFb2Execute(Sender: TObject);
    procedure ImportFb2Update(Sender: TObject);
    procedure ImportNonFB2Execute(Sender: TObject);
    procedure ImportFBDExecute(Sender: TObject);
    procedure ImportNonFB2Update(Sender: TObject);
    procedure ImportUserDataExecute(Sender: TObject);
    procedure Export2HTMLExecute(Sender: TObject);
    procedure Export2INPXExecute(Sender: TObject);
    procedure ExportUserDataExecute(Sender: TObject);
    procedure UpdateGenresExecute(Sender: TObject);
    procedure SyncFilesExecute(Sender: TObject);
    procedure RepairDataBaseExecute(Sender: TObject);
    procedure CompactDataBaseExecute(Sender: TObject);
    procedure DeleteCollectionExecute(Sender: TObject);
    procedure AddGroupExecute(Sender: TObject);
    procedure AddGroupUpdate(Sender: TObject);
    procedure RenameGroupExecute(Sender: TObject);
    procedure EditGroupUpdate(Sender: TObject);
    procedure ClearGroupExecute(Sender: TObject);
    procedure ClearGroupUpdate(Sender: TObject);
    procedure DeleteGroupExecute(Sender: TObject);
    procedure ExportGroupMetabibExecute(Sender: TObject);
    procedure GroupExportDestinationExecute(Sender: TObject);
    procedure GroupExportMetabibUpdate(Sender: TObject);

    procedure EditBookExecute(Sender: TObject);
    procedure Conver2FBDExecute(Sender: TObject);
    procedure EditAuthorExecute(Sender: TObject);
    procedure EditAuthorUpdate(Sender: TObject);
    procedure EditSeriesExecute(Sender: TObject);
    procedure EditSerieUpdate(Sender: TObject);
    procedure EditGenresExecute(Sender: TObject);
    procedure EditGenreUpdate(Sender: TObject);

    procedure ShowMainToolbarExecute(Sender: TObject);
    procedure ShowMainToolbarUpdate(Sender: TObject);
    procedure ShowEditToolbarExecute(Sender: TObject);
    procedure ShowEditToolbarUpdate(Sender: TObject);
    procedure ShowRusAlphabetExecute(Sender: TObject);
    procedure ShowRusAlphabetUpdate(Sender: TObject);
    procedure ShowEngAlphabetExecute(Sender: TObject);
    procedure ShowEngAlphabetUpdate(Sender: TObject);
    procedure ShowStatusbarExecute(Sender: TObject);
    procedure ShowStatusbarUpdate(Sender: TObject);
    procedure ShowBookInfoPanelExecute(Sender: TObject);
    procedure ShowBookInfoPanelUpdate(Sender: TObject);
    procedure ShowBookCoverExecute(Sender: TObject);
    procedure ShowBookCoverUpdate(Sender: TObject);
    procedure ShowBookAnnotationExecute(Sender: TObject);
    procedure ShowBookAnnotationUpdate(Sender: TObject);
    procedure HideDeletedBooksExecute(Sender: TObject);
    procedure HideDeletedBooksUpdate(Sender: TObject);
    procedure ShowLocalOnlyExecute(Sender: TObject);
    procedure ShowLocalOnlyUpdate(Sender: TObject);

    procedure QuickSearchExecute(Sender: TObject);
    procedure UpdateOnlineCollectionExecute(Sender: TObject);
    procedure UpdateCollectionFromFileExecute(Sender: TObject);
    procedure UpdateCollectionFromFileUpdate(Sender: TObject);
    procedure ClearReadFolderExecute(Sender: TObject);
    procedure BookCacheActionUpdate(Sender: TObject);
    procedure ChangeSettingsExecute(Sender: TObject);

    procedure ShowHelpExecute(Sender: TObject);
    procedure CheckUpdatesExecute(Sender: TObject);
    procedure GoSiteExecute(Sender: TObject);
    procedure ShowAboutExecute(Sender: TObject);

    procedure tbSelectAllClick(Sender: TObject);
    procedure pmiCheckAllClick(Sender: TObject);
    procedure pmiDeselectAllClick(Sender: TObject);
    procedure miCopyClBrdClick(Sender: TObject);

    procedure AddBookToGroup(Sender: TObject);
    procedure DeleteBookFromGroup(Sender: TObject);

    procedure cbPresetNameSelect(Sender: TObject);
    procedure DoClearFilter(KeepPreset: boolean);
    procedure DoApplyFilter(Sender: TObject);
    procedure PresetFieldKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ShowGenreEditor(Sender: TObject);
    procedure edFGenreKeyPress(Sender: TObject; var Key: Char);
    procedure ShowExpressionEditor(Sender: TObject);
    procedure SaveSearchPreset(Sender: TObject);
    procedure DeleteSearchPreset(Sender: TObject);
    procedure SavePresetUpdate(Sender: TObject);
    procedure DeletePresetUpdate(Sender: TObject);

    procedure tbCollapseClick(Sender: TObject);
    procedure edLocateAuthorChange(Sender: TObject);
    procedure miActiveCollectionClick(Sender: TObject);
    procedure CopyToCollectionClick(Sender: TObject);
    procedure miGoToAuthorClick(Sender: TObject);
    procedure ShowBookInfo(Sender: TObject);
    procedure miCopyAuthorClick(Sender: TObject);
    procedure pgControlChange(Sender: TObject);

    procedure btnSwitchTreeModeClick(Sender: TObject);
    procedure tbClearEdAuthorClick(Sender: TObject);
    procedure btnClearEdSeriesClick(Sender: TObject);
    procedure HeaderPopupItemClick(Sender: TObject);
    procedure SelectColumnsExecute(Sender: TObject);
    procedure SelectColumnsUpdate(Sender: TObject);
    procedure N27Click(Sender: TObject);
    procedure InfoPanelResize(Sender: TObject);
    procedure TrayIconDblClick(Sender: TObject);
    procedure N33Click(Sender: TObject);
    procedure btnStartDownloadClick(Sender: TObject);
    procedure btnPauseDownloadClick(Sender: TObject);
    procedure btnDeleteDownloadClick(Sender: TObject);
    procedure mi_dwnl_LocateAuthorClick(Sender: TObject);
    procedure btnClearDownloadClick(Sender: TObject);
    procedure MoveDwnldListNodes(Sender: TObject);
    procedure BtnSaveClick(Sender: TObject);
    procedure edLocateAuthorKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure miAddToSearchClick(Sender: TObject);
    procedure pmAuthorPopup(Sender: TObject);
    procedure GroupMenuItemClick(Sender: TObject);
    procedure miDeleteFilesClick(Sender: TObject);
    procedure pmiSelectAllClick(Sender: TObject);
    procedure tbtnAutoFBDClick(Sender: TObject);
    procedure AuthorLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure GenreLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure SeriesLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure UpdateBookAction(Sender: TObject);
    procedure tmrCheckUpdatesTimer(Sender: TObject);
    procedure acBookAdd2FavoritesExecute(Sender: TObject);
    procedure acBookAdd2GroupExecute(Sender: TObject);
    procedure acBookRemoveFromGroupExecute(Sender: TObject);
    procedure tbtnWizardClick(Sender: TObject);
    procedure acViewSetInfoPriorityExecute(Sender: TObject);
    procedure tmrSearchSTimer(Sender: TObject);
    procedure tmrSearchATimer(Sender: TObject);
    procedure edLocateSeriesChange(Sender: TObject);
    procedure cbLangSelectAChange(Sender: TObject);
    procedure btnClearFilterEditsClick(Sender: TObject);
    procedure pmMarkSelectedClick(Sender: TObject);
    procedure tvAuthorsMeasureTextHeight(Sender: TBaseVirtualTree;
      TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
      const Text: string; var Extent: Integer);

  protected
    procedure DoCreate; override;
    procedure DrawNavigationTab(Control: TCustomTabControl; TabIndex: Integer;
      const Rect: TRect; Active: Boolean);
    procedure WMGetSysCommand(var Message: TMessage); message WM_SYSCOMMAND;
    procedure OnChangeLocalStatus(var Message: TLocalStatusChangedMessage); message WM_MHL_CHANGELOCALSTATUS;

  private type
    TView = (AuthorsView, SeriesView, GenresView, SearchView, FavoritesView, DownloadView, PublisherSeriesView);

    TSortSetting = record
      Column: TColumnIndex;
      Direction: TSortDirection;
    end;

  private
    FDMThread: TDownloadManagerThread;

    // Узел очереди, который сейчас загружается. Курсор принадлежит форме, а не
    // потоку: только форма знает, когда узел исчезает из дерева.
    FDownloadNode: PVirtualNode;

    FCurrentBookOnly: Boolean;
    FReadBuiltinAction, FReadExternalAction, FOpenArchiveAction, FLocationAction, FChooseReaderAction: TAction;
    FMetadataFillAction: TAction;
    FInvisible: Boolean;
    FThemeToolbar: TToolBar;
    FThemeButton: TToolButton;
    FWindowsThemeOffer, FWindowsThemeOfferContent: TPanel;
    FWindowsThemeOfferText: TLabel;
    FWindowsThemeOfferApply, FWindowsThemeOfferDismiss: TButton;
    FUpdatingWindowsThemeOfferLayout: Boolean;
    FLoadedBookViews: set of TView;
    FPendingLangFilters: array[TView] of Integer;
    FPendingAuthorBookID: Integer;
    FPendingSeriesBookID: Integer;
    FPublisher: TPublisherSeriesView;
    FPublisherListLoaded: Boolean;
    FBookInfoUpdateCount: Integer;
    FBookPreviews: array[0..6] of TBookInfoPreview;
    FBookListCancel: TButton;
    FBookListLoading, FBookListCancelled: Boolean;
    FBookListLastPump, FCacheMenuUpdated: UInt64;
    FStaleSelectors: set of TView;
    FLastPublisherSeriesID: Integer;
    FLastPublisherBookID: TBookKey;
    FPendingPublisherBookID: Integer;
    FTimerDone: Boolean;
    FIgnoreAuthorChange: Boolean;
    FViewLanguageSelected: array[TView] of Boolean;
    FLocales: TArray<TLocaleInfo>;
    FOPDSForm: TfrmOPDS;
    procedure UpdateThemeToolbar;
    procedure UpdateWindowsThemeOfferLayout;
    procedure WindowsThemeOfferResize(Sender: TObject);
    procedure WindowsThemeOfferAccept(Sender: TObject);
    procedure WindowsThemeOfferDismiss(Sender: TObject);
    procedure WMSettingChange(var Message: TMessage); message WM_SETTINGCHANGE;
    procedure ShowOPDS(Sender: TObject);

    function IsSelectedBookNode(Node: PVirtualNode; Data: PBookRecord): Boolean;



    procedure ReadINIData;

    function GetViewTree(view: TView): TBookTree;
    procedure GetActiveTree(var Tree: TBookTree);
    procedure Selection(SelState: Boolean);
    procedure LocateAuthor(const Text: string);
    procedure LocateSeries(const Text: string);
    procedure CreatePublisherSeriesView;
    procedure ReloadPublisherSeries;
    procedure PublisherSeriesChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure PublisherSeriesKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PublisherSearchChanged(Sender: TObject);
    procedure PublisherSearchTimer(Sender: TObject);
    procedure PublisherSearchClear(Sender: TObject);
    procedure IndexPublisherSeries(Sender: TObject);
    procedure RefreshBookMetadataViews(const CollectionID: Integer);
    procedure FillBookMetadataExecute(Sender: TObject);
    procedure FillBookMetadataUpdate(Sender: TObject);
    procedure PublisherSeriesLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
    procedure ActivateView(View: TView);

    procedure CloseCollection;
    procedure InitCollection;
    procedure SyncGenreLanguage;
    procedure SyncSystemGroupNames;

    procedure CreateCollectionMenu;
    procedure CreateScriptMenu;
    procedure CreateExternalToolsMenu;
    procedure ExternalToolClick(Sender: TObject);
    procedure UpdateConversionMenu(Sender: TObject);
    procedure SetColors;
    procedure ToggleApplicationTheme(Sender: TObject);
    procedure CreateAlphabetToolbar;

    procedure CreateLanguageMenu;
    procedure LanguageItemClick(Sender: TObject);

    procedure RefreshBookInfo(const Tree: TBookTree);
    procedure RefreshActiveBookInfo;
    procedure EnsureActiveBookViewLoaded;
    procedure SetHideDeletedMode(Value: Boolean; RefreshCurrent: Boolean = True);
    procedure SearchDeletedClick(Sender: TObject);
    procedure ReloadAppliedSearch;
    function FrameControl(AControl: TWinControl): Boolean;
    procedure FrameTree(ATree: TVirtualStringTree); overload;
    procedure FrameTree(ATree: TBookTree); overload;
    procedure FrameTrees;

    procedure OnReadBookHandler(const BookRecord: TBookRecord);
    procedure ReadBuiltinExecute(Sender: TObject);
    procedure ReadExternalExecute(Sender: TObject);
    procedure ReadBuiltinUpdate(Sender: TObject);
    procedure OpenArchiveExecute(Sender: TObject);
    procedure OpenArchiveUpdate(Sender: TObject);
    procedure BookLocationUpdate(Sender: TObject);
    procedure BookLocationExecute(Sender: TObject);
    procedure ChooseReaderExecute(Sender: TObject);
    procedure ReadPreparedBook(const BookRecord: TBookRecord; UseBuiltin: Boolean; ChooseReader: Boolean = False; ForceChoice: Boolean = False;
      const ReaderPathOverride: string = ''; KeepKindlePreparation: Boolean = False; FromNotes: Boolean = False);
    procedure OnSelectBookHandler(MoveForward: Boolean);
    procedure OnGetBookHandler(var BookRecord: TBookRecord);
    procedure OnUpdateBookHandler(const BookRecord: TBookRecord);
    procedure OnChangeBook2ZipHandler(const BookRecord: TBookRecord);
    function OnHelpHandler(Command: Word; Data: NativeInt; var CallHelp: Boolean): Boolean;
    procedure OnImportUserDataHandler(const UserDataSource: TUserData);

  private type
    TNodeProcessProc = reference to procedure(Tree: TBookTree; Node: PVirtualNode);
    TNodeUpdateProc = reference to procedure(Data: PBookRecord);

  strict private
    procedure ProgramUpdateChecked(var Message: TMessage); message WM_PROGRAM_UPDATE_CHECKED;
    procedure UpdateDownloadToolbarSize;
    function IsLibRusecEdit(const BookKey: TBookKey): Boolean;

    // Note: После применения ноды автоматически не обновляются!!!
    procedure ProcessNodes(ProcessProc: TNodeProcessProc);

    // Обновления не должны менять положение ноды в дереве.
    procedure UpdateNodes(const BookKey: TBookKey; UpdateProc: TNodeUpdateProc);

    procedure SetBookLocalStatus(const BookKey: TBookKey; IsLocal: Boolean);

    procedure ChangeToolbarVisability(ToolBars: array of TWinControl; ToolBar: TWinControl; ShowToolbar: Boolean);

    function UpdateEditAction(Action: TAction): Boolean;

    function InternalUpdateGroupAction(Action: TAction): Boolean;

    function GetFilterButton(ToolBars: array of TWinControl; const Filter: string): TToolButton;

    function InternalSetAuthorFilter(Button: TToolButton): string;
    procedure OnSetAuthorFilter(Sender: TObject);

    function InternalSetSeriesFilter(Button: TToolButton): string;
    procedure OnSetSerieFilter(Sender: TObject);

  protected
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; IsDpiChange: Boolean); override;
  public
    procedure ScaleForPPI(NewPPI: Integer); override;
    procedure UpdateWindowsThemeOffer(WindowsDark: Boolean);
    // Notify only after a durable catalog commit, including partial updates.
    procedure NotifyFavoriteCatalogChanged(const CollectionIDs: TArray<Integer>);
    function ImportSearchPresetsFromFile(const FileName: string): Integer;
    procedure ExportSearchPresetsToFile(const FileName: string; AllPresets: Boolean);
    procedure FillBooksTree(
      const Tree: TBookTree;
      const LangSelector: TComboBox;
      const BookIterator: IBookIterator;
      ShowAuth: Boolean;
      ShowSer: Boolean;
      SelectedID: PBookKey
    ); overload;
    procedure FillBooksTree(const Tree: TBookTree; const LangSelector: TComboBox;
      const Factory: TFunc<IBookIterator>; ShowAuth, ShowSer: Boolean;
      SelectedID: PBookKey); overload;
    property BookListCancelled: Boolean read FBookListCancelled;
    procedure OnSetControlsStateHandler(State: Boolean);
    procedure ShowBookColumnFilters(Sender: TObject);
    procedure ShowCatalogSources(Sender: TObject);
    procedure ApplyBookColumnFilters(Tree: TBookTree);
    procedure ResetColumnFiltersClick(Sender: TObject);
    procedure ClearBookSorting(Sender: TObject);
    procedure SortLoadedBooks(Tree: TBookTree);
    procedure SetBookListTotals(Tree: TBookTree; VisibleCount, TotalCount: Integer);

    procedure LocateBook(const Text: string; MoveForward: Boolean);
    procedure LocateAuthorAndBook(const FullAuthorName: string; const BookKey: TBookKey);

    procedure SetFormState;

  private
    FController: TTreeController;
    FCollection: IBookCollection;

    FSelectionState: Boolean;

    FAutoCheck: Boolean;
    FProgramUpdateThread: TProgramUpdateThread;
    FProgramUpdateForm: TfrmProgramUpdate;
    FBookActionTree: TBookTree;
    FBookActionVersion: UInt64;
    FBookActionCached, FBookActionAvailable: Boolean;
    FProgramUpdateTimer: TTimer;
    procedure ProgramUpdateSchedule(Sender: TObject);
    procedure RestartForProgramUpdate(Sender: TObject);
  private
    FLastNotifiedRelease: string;
    FFormBusy: Boolean;

    FFileOpMode: (fmFb2Zip, fmFb2);

    FMainBars: array [0 .. 1] of TWinControl;
    FAuthorBars: array [0 .. 1] of TWinControl;
    FSerieBars: array [0 .. 1] of TWinControl;

    FLastLetterA: TToolButton;
    FLastLetterS: TToolButton;

    FColumnReset: array[0..6] of TButton;
    FSortSettings: array [0 .. 6] of TSortSetting;

    FLastFoundBook: PVirtualNode;
    FFirstFoundBook: PVirtualNode;
    FLastDeviceDir: string;

    // автор и серия, которым _реально_ принадлежат книги, показываемые сейчас в списке
    // т. к. обновление списка происходит с задержкой, значения могут не совпадать в ID выбранных элементов
    FLastAuthorID: Integer;
    FLastAuthorStr: String;
    FLastAuthorBookID: TBookKey;
    FLastSeriesID: Integer;
    FLastSeriesStr: string;
    FLastSeriesBookID: TBookKey;
    FLastGenreCode: string;
    FLastGenreIsContainer: Boolean;
    FLastGenreIsTopLevelContainer: Boolean;
    FRootGenreBooksRequested: Boolean;
    FLastGenreBookID: TBookKey;
    FLastGroupID: Integer;
    FLastGroupBookID: TBookKey;

    FStatusProgressBar: TProgressBar;

    FDownloadsReady, FDownloadsLoadFailed: Boolean;
    FPresets: TSearchPresets;
    FSearchMode: TSearchQueryModeControl;
    FSearchFields: TBookSearchControls;
    FPresetTransferMenu: TPopupMenu;
    FPresetTransferButton: TButton;
    FPresetImportItem, FPresetExportItem, FPresetExportAllItem: TMenuItem;

    FSearchCriteria: TBookSearchCriteria;
    FHasAppliedSearch: Boolean;
    FUpdatingDeletedControls: Boolean;
    FPublisherSearchEdit: TMHLButtonedEdit;
    FPublisherSearchLabel: TLabel;
    FTranslatorSearchEdit, FCitySearchEdit, FPubYearSearchEdit, FISBNSearchEdit: TMHLButtonedEdit;
    FUpdatingSearchLayout: Boolean;
    FNotesOnlySearchCheck: TCheckBox;
    FReaderNotesAction: TAction;

    FSystemData: ISystemData;
    FInSetInfoPanelHeight: Boolean;
    FFavoriteStore: TAuthorFavorites;
    FFavoriteWorker: TAuthorFavoriteRefreshThread;
    FBackgroundMessageWindow: HWND;
    FFavoriteQueue: TQueue<TAuthorFavoriteCollection>;
    FExternalToolsMenu: TPopupMenu;
    FExternalToolsItem: TMenuItem;
    FExternalToolsButton: TToolButton;
    FFavoriteDescriptor: TAuthorFavoriteCollection;
    FFavoriteGeneration: Cardinal;
    FFavoriteDirtyCollections: TDictionary<Integer, Cardinal>;
    FFavoriteSearchPending: Boolean;
    FFavoritePendingCID: Integer;
    FFavoritePendingCriteria: TBookSearchCriteria;
    FSearchFavoriteCheck, FFavoriteListCheck: TCheckBox;
    FFavoriteAuthorHeart, FFavoriteNewButton, FFavoriteMenuButton: TButton;
    FFavoriteMenu: TPopupMenu;
    FFavoriteToggleMenu, FFavoriteNewMenu, FFavoriteViewedMenu, FFavoriteStopMenu, FFavoriteContextMenu: TMenuItem;
    FFavoriteOriginalGetText: TVSTGetTextEvent;
    FFavoriteOriginalBeforeCellPaint: TVTBeforeCellPaintEvent;
    FFavoriteOriginalAfterCellPaint: TVTAfterCellPaintEvent;
    FOnlyNewFavoriteBooks: Boolean;

    function FavoriteProfileFile: string;
    function FavoriteStore: TAuthorFavorites;
    function FavoriteDescriptor(const Collection: IBookCollection): TAuthorFavoriteCollection;
    function FavoriteBindingsReady(const Descriptor: TAuthorFavoriteCollection): Boolean;
    procedure QueueFavoriteRefresh(const Descriptor: TAuthorFavoriteCollection; ForceRefresh: Boolean = False);
    procedure StartFavoriteRefresh;
    procedure EnsureBackgroundMessageWindow;
    procedure BackgroundMessageWindowProc(var Message: TMessage);
    procedure StopFavoriteRefresh(ClearQueue: Boolean);
    procedure CheckFavoriteCollection;
    function PrepareFavoriteSearch(var Criteria: TBookSearchCriteria): Boolean;
    procedure WMFavoriteReady(var Message: TMessage); message WM_AUTHOR_FAVORITES_READY;
    procedure WMFavoriteProgress(var Message: TMessage); message WM_AUTHOR_FAVORITES_PROGRESS;
    procedure WMFavoriteLayout(var Message: TMessage); message WM_AUTHOR_FAVORITES_LAYOUT;
    function SelectedFavoriteAuthor(out Author: TAuthorData; out Key: string): Boolean;
    procedure UpdateFavoriteControls;
    procedure FavoriteSelectedAuthorClick(Sender: TObject);
    procedure FavoriteListClick(Sender: TObject);
    procedure FavoriteNewClick(Sender: TObject);
    procedure FavoriteViewedClick(Sender: TObject);
    procedure FavoriteStopClick(Sender: TObject);
    procedure FavoriteMenuClick(Sender: TObject);
    procedure FavoriteTransferClick(Sender: TObject);
    procedure AuthorNameStyleClick(Sender: TObject);
    function AuthorSelectorIterator: IAuthorIterator;
    procedure FillCurrentAuthorBooks;
    procedure FavoriteAuthorGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    function IsFavoriteAuthorNode(Sender: TBaseVirtualTree; Node: PVirtualNode): Boolean;
    procedure FavoriteAuthorBeforeCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas;
      Node: PVirtualNode; Column: TColumnIndex; CellPaintMode: TVTCellPaintMode;
      CellRect: TRect; var ContentRect: TRect);
    procedure FavoriteAuthorAfterCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas;
      Node: PVirtualNode; Column: TColumnIndex; CellRect: TRect);
    procedure SearchFavoriteClick(Sender: TObject);
    procedure UpdateBookFilterIndicators(Tree: TBookTree);
    procedure SearchFavoriteEditResize(Sender: TObject);
    procedure UpdateFavoriteSearchLayout;
    procedure CreateFavoriteAuthorControls;
    procedure ApplySearchCriteria(const Criteria: TBookSearchCriteria; SelectedID: PBookKey = nil);
    procedure PublishFavoriteFilterKeys;
    function CatalogBookAvailable(const Book: TBookRecord; Notify: Boolean = True): Boolean;
    function CatalogBookMatchesSaved(const Book: TBookRecord; Notify: Boolean = True): Boolean;
    function SearchPresetIndex(const Name: string): Integer;
    procedure CreatePublisherSearchField;
    procedure CreateSearchPanelAdapter;
    procedure BrowseAllReaderNotes(Sender: TObject);
    procedure OpenReaderNote(const Note: TReaderAnnotation);
    procedure RefreshNotesSearch;
    procedure UpdateSearchBookLayout;
    procedure SearchBookExpanded(Sender: TObject);

    function AuthorBookFilter: TFilterValue;
    function SeriesBookFilter: TFilterValue;
    function GenreBookFilter: TFilterValue;
    procedure FillCurrentGenreBooks;
    function ChooseGroupExportDestination(ForcePrompt: Boolean): Boolean;

    function GetBookNode(const Tree: TBookTree; const BookKey: TBookKey): PVirtualNode; overload;

    procedure FillBookIdList(const Tree: TBookTree; var BookIDList: TBookIdList; const Uncheck: Boolean = True);
    procedure ClearLabels(Tag: Integer; Full: Boolean);
    procedure FillAllBooksTree;
    function CheckLibUpdates(Auto: Boolean): Boolean;
    procedure SetInfoPanelHeight(Height: Integer);
    procedure SetInfoPanelVisible(State: Boolean);
    procedure SetShowBookCover(State: Boolean);
    procedure SetShowBookAnnotation(State: Boolean);
    procedure SetColumns;
    procedure SaveColumns;
    procedure SetHeaderPopUp;
    procedure DownloadBooks(CurrentBookOnly: boolean = False);
    function CheckActiveDownloads: Boolean;
    procedure PurgeDownloadsForCollection(const DatabaseID: Integer);
    procedure UpdateDownloadCount;

    // IDownloadView - единственный путь, которым поток загрузки касается интерфейса.
    // Все методы выполняются в главном потоке (поток вызывает их через Synchronize).
    function SelectNextDownload(out Item: TDownloadItem): Boolean;
    procedure CompleteCurrentDownload(Success: Boolean);
    procedure CancelCurrentDownload;
    function IsMainFormVisible: Boolean;
    procedure ShowDownloadInfo(const Author, Title: string);
    procedure ShowDownloadState(const State: string);
    procedure ShowDownloadProgress(Position: Integer);
    procedure ResetDownloadState;
    procedure SetTrayHint(const Hint: string);
    procedure SetDownloadRunning(Running: Boolean);
    procedure SetQueueControlsEnabled(Enabled: Boolean);
    function AskIgnoreDownloadErrors: Integer;

    function GetActiveView: TView;
    procedure StartLibUpdate;
    procedure CreateGroupsMenu;
    procedure SaveMainFormSettings;

    procedure UpdatePositions;

    function ShowNCWizard: Boolean;
    function LoadLastCollection: boolean;
    procedure SetShowStatusProgress(const Value: Boolean);
    procedure CancelBookList(Sender: TObject);
    function PollBookListCancel: Boolean;
    procedure FillBooksTreeCore(const Tree: TBookTree; const LangSelector: TComboBox;
      const BookIterator: IBookIterator; ShowAuth, ShowSer: Boolean; SelectedID: PBookKey);
    procedure SetStatusProgress(const Value: Integer);
    function GetShowStatusProgress: Boolean;
    function GetStatusProgress: Integer;
    function GetStatusMessage: string;
    procedure SetStatusMessage(const Value: string);
    procedure UpdateAllEditActions;
    procedure AddCurrentToList(const Tree: TBookTree; var BookIDList: TBookIdList);
    procedure SavePositions;
    procedure SetBookInfoPriority(State: Boolean);
    procedure ShowBookDelete(Sender: TObject);
    procedure LoadPresets;
    procedure CreatePresetTransferMenu;
    procedure PresetTransferMenuClick(Sender: TObject);
    procedure PresetTransferMenuPopup(Sender: TObject);
    procedure ImportSearchPresetsClick(Sender: TObject);
    procedure ExportSearchPresetsClick(Sender: TObject);
    function CreatePresetExportSnapshot(AllPresets: Boolean): TSearchPresets;
    procedure SavePresetExportSnapshot(const FileName: string; Snapshot: TSearchPresets);
    procedure ConnectTreeControllers;
    procedure InitFormFileds;
    procedure UpdateSplashScreen(const AStatus: string);
    procedure LoadDownloadsList;
    procedure SaveDownloadsList;
    procedure ClearDataFolder;
    property ActiveView: TView read GetActiveView;

    property ShowStatusProgress: Boolean read GetShowStatusProgress write SetShowStatusProgress;
    property StatusMessage: string read GetStatusMessage write SetStatusMessage;
    property StatusProgress: Integer read GetStatusProgress write SetStatusProgress;
  end;

var
  frmMain: TfrmMain;

const
  CHECK_FILE = 'TheFirstRun.check';

implementation

uses
  SQLiteWrap,
  StrUtils,
  DateUtils,
  IOUtils,
  System.Hash,
  unit_AtomicIniFile, System.IniFiles,
  Character,
  unit_HelpTopics,
  unit_MHLHttpClient,
  Math,
  fictionbook_21,
  unit_FB2Utils,
  unit_Columns,
  frm_statistic,
  frm_splash,
  frm_settings,
  frm_genre_tree,
  frm_edit_book_info,
  frm_edit_author,
  frm_book_info,
  frm_bases,
  frm_add_nonfb2,
  frm_about,
  unit_MHLHelpers,
  unit_MHLGenerics,
  unit_TreeUtils,
  unit_MHL_strings,
  unit_Settings,
  unit_MHLTheme, unit_Readers, unit_ReaderCache, unit_ReaderFormats, unit_ReaderOffice, unit_ReaderLaunch, unit_BookMetadataCache,
  unit_ReaderDocument, unit_ReaderNoteBooks, unit_BookConversion,
  frm_BuiltinReader,
  dm_user,
  unit_Import,
  unit_IndexPublisherSeriesThread, frm_BookMetadataFill,
  frm_ImportProgressFormEx,
  unit_Consts,
  unit_Export,
  unit_ExportMetabibThread,
  unit_Utils,
  ShlObj,
  unit_ExportToDevice,
  unit_BookExportResults, unit_BookExportSelection, unit_BookExportPlan,
  unit_Helpers,
  unit_Errors,
  unit_Logger,
  frm_NewCollectionWizard,
  frm_editor,
  unit_SearchUtils,
  frm_LegacyUserDataPreview,
  unit_WriteFb2Info,
  frm_ConverToFBD,
  unit_Lib_Updates,
  frm_EditGroup,
  unit_SystemDatabase_Abstract,
  unit_MHLArchiveHelpers,
  unit_BookCache, unit_MHLOperationStatus, frm_DeleteCollection, unit_ImportOldUserData, unit_BookColumnFilters, frm_CatalogSources;

type
  TBookTreeAccess = class(TBookTree);
  TFavoriteEditAccess = class(TMHLButtonedEdit)
  public
    property OnResize;
  end;

resourcestring
rstrFileNotFoundMsg = 'Файл %s не найден!' + CRLF + 'Проверьте настройки коллекции!';
   rstrCreatingFilter = 'Подготовка фильтра...';
   rstrApplyingFilter = 'Применяем фильтр...';
   rstrNoUpdatesAvailable = 'Нет обновлений';
   rstrUpdateConnectionError = 'Невозможно подключиться к серверу обновлений:' + CRLF + '%s';
   rstrVersionInfo = '%s' + CRLF + 'Сервер: %d, локальный: %d';
   rstrNotFromDownloadsError = 'Операция недоступна из списка загрузок.';
   rstrAutoFBDConfirmation = 'Создать FBD для всех книг в списке?' + CRLF +
                             'Книги, файлы которых заняты, будут пропущены.';
   rstrDownloadDone = 'Готово';
   rstrIgnoreDownloadErrors = 'Игнорировать ошибки загрузки?';
   rstrNotForExtension = 'Операция недоступна для файлов с расширением %s';
   rstrUnableDeleteBuiltinGroupError = 'Нельзя удалить встроенную группу!';
   rstrCheckingUpdates = 'Проверка обновлений...';
   rstrProgramLatestVersion = 'У вас установлена актуальная версия HomeLib Ru.';
   rstrProgramUpdateCheckFailed = 'Не удалось проверить наличие обновлений. Попробуйте позже.';
   rstrProgramReleaseAvailable = 'Доступна новая версия HomeLib Ru: %s.' + CRLF + CRLF +
     'Открыть страницу релиза, чтобы скачать обновление?';
   rstrGroupAlreadyExists = 'Группа с таким именем уже существует!';
   rstrAdding2GroupMessage = 'Добавляем книги в группу...';
   rstrRemovingFromGroupMessage = 'Удаляем книги из группы...';
   rstrBuildingListMessage = 'Построение списка...';

   rstrHintTable = 'Переключиться в режим "Таблица"';
   rstrHintTree = 'Переключиться в режим "Дерево"';
   rstrShuttingDown = 'отключаемся';
   rstrNeedDBUpgrade = 'Вы успешно обновили приложение. Для нормальной работы необходимо обновить структуру таблиц БД. Сделать это прямо сейчас?';
   rstrFirstRun = 'HomeLib Ru - первый запуск';
// rstrToConvertChangeTab = 'Для конвертации книги перейдите на другую страницу.';
   rstrCollectionFileNotFound = 'Файл коллекции не найден.' + CRLF + 'Невозможно запустить программу.';
   // rstrStartCollectionUpdate = 'Доступно обновление коллекций.' + CRLF + 'Начать обновление?';
   rstrStarting = 'Старт...';
   rstrUnfinishedDownloads = 'В списке есть незавершённые загрузки!' + CRLF + 'Вы всё ещё хотите выйти из приложения?';
   rstrSingleSeries = 'Серия:';
   rstrDownloadStateWaiting = 'Ожидание';
   rstrDownloadStateDownloading = 'Загрузка';
   rstrDownloadStateDone = 'Готово';
   rstrDownloadStateError = 'Ошибка';
   rstrNoBookSelected = 'Ни одна книга не выбрана!';
   rstrProvideThePath = 'Укажите путь';
   rstrCheckUsage = 'Проверить использование, возможна ошибка';
   rstrBuildingTheList = 'Построение списка...';
   rstrChangeCollectionToRemoveABook = 'Для удаления книги перейдите в соответствующую коллекцию';
   rstrRemoveSelectedBooks = 'Удалить выбранные книги из базы?';
   rstrRemoveSelectedBooksFiles = 'Удалить выбранные книги из базы вместе с файлами?';
   rstrRemoveSelectedBooksOnLine = 'Удалить загруженные файлы?';
   rstrRemoveCollection = 'Удалить коллекцию';
   rstrGoToLibrarySite = 'Изменение информации о книгах в онлайн-коллекциях возможно только на сайте.' + CRLF + 'Перейти на сайт электронной библиотеки "%s"?';
   rstrUnableToEditBooksFromFavourites = 'Редактировать книги из избранного невозможно.';
   rstrCreateMoveSeries = 'Создание серии / Перенос в серию';
   rstrTitle = 'Название:';
   rstrEditSeries = 'Редактирование серии';
   rstrAddingBookToGroup = 'Добавляем книги в группу...';
   rstrRemovingBookFromGroup = 'Удаляем книги из группы...';
   rstrNeedSpecialDataTypeForSeries = 'Необходимо использовать отдельный тип данных для серии';
   rstrBookNotFoundInArchive = 'В архиве %s не найдено описания книги!';
   rstrCollectionNotRegistered = 'Коллекция не зарегистрирована!';
   rstrRemoveFromGroup = 'Удалить из группы';
   rstrRemoveFromDownloadList = 'Удалить из списка загрузок';
   rstrAddToFavorites = 'Добавить в избранное';
   rstrAddToDownloads = 'Добавить в список загрузок';
   rstrCollectionUpdateAvailable = 'Доступно обновление для коллекций.' + CRLF + 'Начать обновление?';
   rsrtNewCollectin = 'Новая коллекция...';
   rstrSelectFolder = 'Выбор папки...';
   rstrSpecifyPath = 'Укажите путь';
   // Deliberately NOT 'Язык': that is already a catalog source whose English
   // target was shortened to "Lang" so it would fit the search panel, and the
   // runtime looks translations up by source text. Reusing it would put
   // "Lang" in the menu bar.
   rstrInterfaceLanguage = 'Язык интерфейса';
   rstrLanguageChangeOnRestart = 'Язык изменится при следующем запуске программы.';
{$R *.dfm}


var
  IsPrivate: Boolean;
  IsOnline: Boolean;
  IsLocal: Boolean;
  IsFB2: Boolean;
  IsNonFB2: Boolean;

const
  TreeIcons: array [0 .. 1] of Integer = (10, 11);
  TreeHints: array [0 .. 1] of string = (rstrHintTable, rstrHintTree);

function TfrmMain.CheckActiveDownloads: Boolean;
var
  Data: PDownloadData;
  Node: PVirtualNode;
begin
  Result := False;
  Node := tvDownloadList.GetFirst;
  while Assigned(Node) do
  begin
    Data := tvDownloadList.GetNodeData(Node);
    if Data.State = dsRun then
    begin
      Result := True;
      Break;
    end;
    Node := tvDownloadList.GetNext(Node);
  end;
end;

procedure TfrmMain.PurgeDownloadsForCollection(const DatabaseID: Integer);
var
  Node, Next: PVirtualNode;
  Data: PDownloadData;
  HasActive: Boolean;
begin
  HasActive := False;
  Node := tvDownloadList.GetFirst;
  while Assigned(Node) do
  begin
    Data := tvDownloadList.GetNodeData(Node);
    if Assigned(Data) and (Data^.BookKey.DatabaseID = DatabaseID) and (Data^.State = dsRun) then
    begin
      HasActive := True;
      Break;
    end;
    Node := tvDownloadList.GetNext(Node);
  end;

  if HasActive then
    btnPauseDownloadClick(Self);

  Node := tvDownloadList.GetFirst;
  while Assigned(Node) do
  begin
    Next := tvDownloadList.GetNext(Node);
    Data := tvDownloadList.GetNodeData(Node);
    if Assigned(Data) and (Data^.BookKey.DatabaseID = DatabaseID) then
    begin
      if Node = FDownloadNode then
        FDownloadNode := nil;
      tvDownloadList.DeleteNode(Node);
    end;
    Node := Next;
  end;

  UpdateDownloadCount;
end;

procedure TfrmMain.DoCreate;
begin
  inherited;
  Localize(Self);
  // After Localize: the container's caption comes from a resourcestring, which
  // the LoadResStringFunc hook translates when it is read, so the menu needs
  // no second pass and Localize has nothing to do to it.
  CreateLanguageMenu;
  pgControl.OwnerDraw := True;
  pgControl.OnDrawTab := DrawNavigationTab;
  pgControl.TabHeight := MulDiv(28, Screen.PixelsPerInch, 96);
  pgControl.DoubleBuffered := True;
end;

procedure TfrmMain.DrawNavigationTab(Control: TCustomTabControl; TabIndex: Integer;
  const Rect: TRect; Active: Boolean);
var Area: TRect; Canvas: TCanvas; Text: string;
begin
  Canvas := Control.Canvas; Canvas.Font.Assign(pgControl.Font);
  Canvas.Font.Color := MHLThemeText; Canvas.Brush.Color := MHLThemeBackground;
  if Active then
  begin
    if MHLThemeDark then Canvas.Brush.Color:=RGB(49,51,55) else Canvas.Brush.Color:=clWindow;
    Canvas.Font.Style := Canvas.Font.Style + [fsBold];
  end;
  Canvas.FillRect(Rect); Area := Rect;
  if Active then
  begin
    if MHLThemeDark then Canvas.Brush.Color:=MHLThemeLink else Canvas.Brush.Color:=clHighlight;
    Area.Top := Area.Bottom - MulDiv(3, Screen.PixelsPerInch, 96); Canvas.FillRect(Area);
    Canvas.Brush.Style:=bsClear;
  end;
  Area := Rect; InflateRect(Area, -3, -3);
  Text := pgControl.Pages[TabIndex].Caption;
  DrawText(Canvas.Handle, PChar(Text), Length(Text), Area,
    DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
  Canvas.Brush.Style:=bsSolid;
end;

procedure TfrmMain.WMGetSysCommand(var Message: TMessage);
begin
  if Message.Msg = WM_Destroy then
  begin
    ShowMessage(rstrShuttingDown);
    inherited;
  end;

  if (Message.wParam = SC_MINIMIZE) and Settings.MinimizeToTray then
  begin
    TrayIcon.Visible := True;
    Hide;
  end
  else
    inherited;
end;

procedure TfrmMain.SetColumns;
var
  Columns: TColumns;
  Tree: TBookTree;
begin
  Columns := TColumns.Create(Settings.SystemFileName[sfColumnsStore]);
  try

    if Settings.TreeModes[PAGE_AUTHORS] = tmTree then
      Columns.Load(SECTION_A_TREE, tmTree)
    else
      Columns.Load(SECTION_A_FLAT, tmFlat);
    Columns.SetColumns(tvBooksA.Header.Columns);

    if Settings.TreeModes[PAGE_SERIES] = tmTree then
      Columns.Load(SECTION_S_TREE, tmTree)
    else
      Columns.Load(SECTION_S_FLAT, tmFlat);
    Columns.SetColumns(tvBooksS.Header.Columns);
    Columns.Load(SECTION_PUBLISHER_S_FLAT, tmFlat);
    Columns.SetColumns(FPublisher.Books.Header.Columns);
    FPublisher.Books.Header.MainColumn := 1;

    if Settings.TreeModes[PAGE_GENRES] = tmTree then
      Columns.Load(SECTION_G_TREE, tmTree)
    else
      Columns.Load(SECTION_G_FLAT, tmFlat);
    Columns.SetColumns(tvBooksG.Header.Columns);

    if Settings.TreeModes[PAGE_FAVORITES] = tmTree then
      Columns.Load(SECTION_F_TREE, tmTree)
    else
      Columns.Load(SECTION_F_FLAT, tmFlat);
    Columns.SetColumns(tvBooksF.Header.Columns);

    if Settings.TreeModes[PAGE_SEARCH] = tmTree then
      Columns.Load(SECTION_SR_TREE, tmTree)
    else
      Columns.Load(SECTION_SR_FLAT, tmFlat);
    Columns.SetColumns(tvBooksSR.Header.Columns);
    for Tree in TArray<TBookTree>.Create(tvBooksA, tvBooksS, tvBooksG, tvBooksF, tvBooksSR, FPublisher.Books) do
    begin
      Tree.HeaderFilterTags := TArray<Integer>.Create(COL_AUTHOR, COL_TITLE, COL_SERIES, COL_PUBLISHER_SERIES, COL_PUBLISHER,
        COL_TRANSLATORS, COL_CITY, COL_PUBYEAR, COL_ISBN,
        COL_NO, COL_GENRE, COL_SIZE, COL_RATE, COL_DATE, COL_TYPE, COL_COLLECTION, COL_LANG,
        COL_LIBRATE, COL_LIBID);
      Tree.Header.Height := Max(Tree.Header.Height, MulDiv(24, Tree.CurrentPPI, 96));
    end;


    tvBooksA.Header.MainColumn := 1;
    tvBooksS.Header.MainColumn := 1;
    tvBooksG.Header.MainColumn := 1;
    tvBooksF.Header.MainColumn := 1;
    tvBooksSR.Header.MainColumn := 1;

  finally
    Columns.Free;
  end;
end;

procedure TfrmMain.SaveColumns;
var
  Columns: TColumns;
begin
  Columns := TColumns.Create(Settings.SystemFileName[sfColumnsStore]);
  try
    Columns.GetColumns(tvBooksA.Header.Columns);
    if Settings.TreeModes[PAGE_AUTHORS] = tmTree then
      Columns.Save(SECTION_A_TREE)
    else
      Columns.Save(SECTION_A_FLAT);

    Columns.GetColumns(tvBooksS.Header.Columns);
    if Settings.TreeModes[PAGE_SERIES] = tmTree then
      Columns.Save(SECTION_S_TREE)
    else
      Columns.Save(SECTION_S_FLAT);

    Columns.GetColumns(FPublisher.Books.Header.Columns);
    Columns.Save(SECTION_PUBLISHER_S_FLAT);
    Columns.GetColumns(tvBooksG.Header.Columns);
    if Settings.TreeModes[PAGE_GENRES] = tmTree then
      Columns.Save(SECTION_G_TREE)
    else
      Columns.Save(SECTION_G_FLAT);

    Columns.GetColumns(tvBooksF.Header.Columns);
    if Settings.TreeModes[PAGE_FAVORITES] = tmTree then
      Columns.Save(SECTION_F_TREE)
    else
      Columns.Save(SECTION_F_FLAT);


    Columns.GetColumns(tvBooksSR.Header.Columns);
    if Settings.TreeModes[PAGE_SEARCH] = tmTree then
      Columns.Save(SECTION_SR_TREE)
    else
      Columns.Save(SECTION_SR_FLAT);
  finally
    Columns.Free;
  end;
end;

// The trees only know how to draw a square border, so the border is turned off
// and the hosting panel paints a rounded frame in the gap left by the tree's
// margins. Nothing is reparented: the control tree in frm_main.dfm, splitters
// included, stays exactly as designed.
function TfrmMain.FrameControl(AControl: TWinControl): Boolean;
begin
  Result := AControl.Parent is TMHLSimplePanel;
  if Result then
    TMHLSimplePanel(AControl.Parent).FramedControl := AControl;
end;

procedure TfrmMain.FrameTree(ATree: TVirtualStringTree);
begin
  if FrameControl(ATree) then
    ATree.BorderStyle := bsNone;
end;

procedure TfrmMain.FrameTree(ATree: TBookTree);
begin
  if FrameControl(ATree) then
    ATree.BorderStyle := bsNone;
end;

procedure TfrmMain.FrameTrees;
begin
  FrameTree(tvAuthors);
  FrameTree(tvSeries);
  FrameTree(FPublisher.SeriesTree);
  FrameTree(FPublisher.Books);
  FrameTree(tvGenres);
  FrameTree(tvGroups);

  FrameTree(tvBooksA);
  FrameTree(tvBooksS);
  FrameTree(tvBooksG);
  FrameTree(tvBooksSR);
  FrameTree(tvBooksF);
  FrameTree(tvDownloadList);
end;

procedure TfrmMain.SetColors;
var
  BGColor: TColor;
  TreeFontSize: Integer;
  FontColor: TColor;
  ShortFontSize : Integer;

  procedure SetTreeViewColor(AControl: TBookTree);
  var
    Height, NodeHeight: Cardinal;
    MetricsChanged: Boolean;
  begin
    MetricsChanged := not SameText(AControl.Font.Name, 'Segoe UI') or
      (AControl.Font.Size <> TreeFontSize) or (AControl.Font.Quality <> fqClearTypeNatural);
    AControl.Color := BGColor;
    AControl.Font.Name := 'Segoe UI';
    AControl.Font.Quality := fqClearTypeNatural;
    AControl.Header.Font.Name := 'Segoe UI';
    AControl.Header.Font.Quality := fqClearTypeNatural;
    AControl.Header.Font.Size := TreeFontSize;
    AControl.Font.Size := TreeFontSize;
    if MetricsChanged then
    begin
      // Drawing callbacks can leave a different font in the cached canvas.
      // Measure the actual chosen font only when its metrics have changed.
      AControl.Canvas.Font.Assign(AControl.Font);
      Height := AControl.Canvas.TextHeight('Щ');
      NodeHeight := Round(Height + Height div 4);
      AControl.DefaultNodeHeight := NodeHeight;
      AControl.Header.Height := Round(Height * 1.5);
    end;
    SetMHLControlFontColor(AControl, FontColor);
    // Color-only changes neither resize nor reinitialize the loaded rows.
    if MetricsChanged then AControl.ReinitNode(AControl.GetFirst, True);
  end;

  procedure SetTreeViewColor2(AControl: TVirtualStringTree);
  var
    Height, NodeHeight: Cardinal;
    MetricsChanged: Boolean;
  begin
    MetricsChanged := not SameText(AControl.Font.Name, 'Segoe UI') or
      (AControl.Font.Size <> TreeFontSize) or (AControl.Font.Quality <> fqClearTypeNatural);
    AControl.Color := BGColor;
    AControl.Font.Name := 'Segoe UI';
    AControl.Font.Quality := fqClearTypeNatural;
    AControl.Font.Size := TreeFontSize;
    if MetricsChanged then
    begin
      AControl.Canvas.Font.Assign(AControl.Font);
      Height := AControl.Canvas.TextHeight('Щ');
      NodeHeight := Round(Height + Height div 4);
      AControl.DefaultNodeHeight := NodeHeight;
    end;
    SetMHLControlFontColor(AControl, FontColor);
    if MetricsChanged then AControl.ReinitNode(AControl.GetFirst, True);
  end;

  procedure SetPnlColor(AControl: TInfoPanel);
  begin
    AControl.Color := BGColor;
    AControl.Font.Name := 'Segoe UI';
    AControl.Font.Quality := fqClearTypeNatural;
    AControl.Font.Size := ShortFontSize;
    AControl.Font.Color := FontColor;
  end;

begin
  BGColor := Settings.BGColor;
  TreeFontSize := Settings.TreeFontSize;
  FontColor := Settings.FontColor;
  ShortFontSize := Settings.ShortFontSize;

  SetTreeViewColor2(tvAuthors);
  SetTreeViewColor(tvBooksA);
  SetTreeViewColor2(tvSeries);
  SetTreeViewColor(tvBooksS);
  SetTreeViewColor2(FPublisher.SeriesTree);
  SetTreeViewColor(FPublisher.Books);
  SetPnlColor(FPublisher.Info);
  FPublisher.Search.Color := BGColor;
  FPublisher.Tab.Color := clMenuBar;
  SetTreeViewColor2(tvGenres);
  SetTreeViewColor(tvBooksG);
  SetTreeViewColor(tvBooksSR);
  SetTreeViewColor2(tvGroups);
  SetTreeViewColor(tvBooksF);
  SetTreeViewColor(tvDownloadList);

  edFFullName.Color := BGColor;
  edFTitle.Color := BGColor;
  edFSeries.Color := BGColor;
  edFGenre.Color := BGColor;
  edFFile.Color := BGColor;
  edFFolder.Color := BGColor;
  edFExt.Color := BGColor;
  edFKeyWords.Color := BGColor;
  edFAnnotation.Color := BGColor;
  if Assigned(FPublisherSearchEdit) then FPublisherSearchEdit.Color := BGColor;
  if Assigned(FTranslatorSearchEdit) then FTranslatorSearchEdit.Color := BGColor;
  if Assigned(FCitySearchEdit) then FCitySearchEdit.Color := BGColor;
  if Assigned(FPubYearSearchEdit) then FPubYearSearchEdit.Color := BGColor;
  if Assigned(FISBNSearchEdit) then FISBNSearchEdit.Color := BGColor;

  cbDate.Color := BGColor;
  cbLang.Color := BGColor;
  cbLibrate.Color := BGColor;

  tsByAuthor.Color := clMenuBar;
  tsBySerie.Color := clMenuBar;
  tsByGenre.Color := clMenuBar;
  tsByGroup.Color := clMenuBar;
  tsSearch.Color := clMenuBar;
  tsDownload.Color := clMenuBar;

  edLocateAuthor.Color := BGColor;
  edLocateSeries.Color := BGColor;
  cbPresetName.Color := BGColor;

  SetPnlColor(ipnlAuthors);
  SetPnlColor(ipnlSeries);
  SetPnlColor(ipnlGenres);
  SetPnlColor(ipnlFavorites);
  SetPnlColor(ipnlSearch);
  if MHLThemeDark then ApplyMHLControlTheme(Self);

end;

procedure TfrmMain.ReadINIData;
begin
  tlbrMain.Visible := Settings.ShowToolbar;
  UpdateThemeToolbar;
  tlbrEdit.Visible := Settings.EditToolBarVisible;
  tbarAuthorsRus.Visible := Settings.ShowRusBar;
  tbarSeriesRus.Visible := Settings.ShowRusBar;
  tbarAuthorsEng.Visible := Settings.ShowEngBar;
  tbarSeriesEng.Visible := Settings.ShowEngBar;
  StatusBar.Visible := Settings.ShowStatusBar;
  SetInfoPanelHeight(Settings.InfoPanelHeight);
  SetInfoPanelVisible(Settings.ShowInfoPanel);
  SetShowBookCover(Settings.ShowBookCover);
  SetShowBookAnnotation(Settings.ShowBookAnnotation);
  SetBookInfoPriority(Settings.Fb2InfoPriority);
  miBookInfoPriority.Checked := Settings.Fb2InfoPriority;

  if Settings.DefaultScript <> 0 then
  begin
    tbSendToDevice.Tag := 900 + Settings.DefaultScript;
    pmiSendToDevice.Tag := 900 + Settings.DefaultScript;
    miDevice.Tag := 900 + Settings.DefaultScript;
  end
  else
  begin
    tbSendToDevice.Tag := 0;
    pmiSendToDevice.Tag := 0;
    miDevice.Tag := 0;
  end;

  ipnlAuthors.Font.Size := Settings.ShortFontSize;
  ipnlSeries.Font.Size := Settings.ShortFontSize;
  ipnlGenres.Font.Size := Settings.ShortFontSize;
  ipnlFavorites.Font.Size := Settings.ShortFontSize;
  ipnlSearch.Font.Size := Settings.ShortFontSize;

  pnAuthorsView.Width := Settings.Splitters[0];
  pnSeriesView.Width := Settings.Splitters[1];
  pnGenresView.Width := Settings.Splitters[2];
  pnSearchView.Width := Settings.Splitters[3];
  pnGroupsView.Width := Settings.Splitters[4];
  FPublisher.Sidebar.Width := Settings.Splitters[5];

  ctpBook.Collapsed := Settings.BookSRCollapsed;
  ctpFile.Collapsed := Settings.FileSRCollapsed;
  ctpOther.Collapsed := Settings.OtherSRCollapsed;
  cbCollapseMultiSeriesResults.Checked :=
    Settings.CollapseMultiSeriesSearchResults;

  if (Settings.ActivePage >= Ord(Low(TView))) and
     (Settings.ActivePage <= Ord(High(TView))) then
    ActivateView(TView(Settings.ActivePage))
  else
    ActivateView(AuthorsView);
  pgControlChange(nil);

  SetColors;
end;

procedure TfrmMain.DoApplyFilter(Sender: TObject);
var
  SavedCursor: TCursor;
  Criteria: TBookSearchCriteria;
begin
  if not Assigned(FCollection) or FInvisible or FBookListLoading then Exit;
  SavedCursor := Screen.Cursor;
  Screen.Cursor := crSQLWait;
  try
    StatusMessage := rstrCreatingFilter;
    try
      try
        Criteria := ReadBookSearchPanel(FSearchFields, FSearchMode.Mode,
          Settings.HideDeletedBooks);
        if Criteria.NotesOnly then Criteria.NoteBookIDs:=ReaderNoteBookIDs(FSystemData,
          ResolveReaderSettingsFile(Settings.DataDir),FCollection.CollectionID);

        Assert(Assigned(FCollection));


        FFavoriteSearchPending := False;
        if not PrepareFavoriteSearch(Criteria) then
        begin
          FFavoritePendingCriteria := Criteria;
          FFavoritePendingCID := FCollection.CollectionID;
          FFavoriteSearchPending := True;
          Exit;
        end;
        StatusMessage := rstrApplyingFilter;
        ApplySearchCriteria(Criteria);
      except
        on E: Exception do
          MHLShowError(rstrFilterParamError);
      end;
    finally
      if FFavoriteSearchPending then StatusMessage := 'Подготовка любимых авторов...'
      else StatusMessage := rstrReadyMessage;
    end;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.DoClearFilter(KeepPreset: boolean);
begin
  if Assigned(FSearchMode) then FSearchMode.Reset;
  FFavoriteSearchPending := False;
  if Assigned(FSearchFavoriteCheck) then FSearchFavoriteCheck.Checked := False;
  FHasAppliedSearch := False;
  FSearchCriteria := Default(TBookSearchCriteria);
  FSearchCriteria.Deleted := Settings.HideDeletedBooks;
  Exclude(FLoadedBookViews, SearchView);
  if not KeepPreset then   cbPresetName.ItemIndex := -1;

  edFFullName.Text := '';
  edFTitle.Text := '';
  edFSeries.Text := '';
  if Assigned(FPublisherSearchEdit) then FPublisherSearchEdit.Text := '';
  if Assigned(FTranslatorSearchEdit) then FTranslatorSearchEdit.Text := '';
  if Assigned(FCitySearchEdit) then FCitySearchEdit.Text := '';
  if Assigned(FPubYearSearchEdit) then FPubYearSearchEdit.Text := '';
  if Assigned(FISBNSearchEdit) then FISBNSearchEdit.Text := '';
  if Assigned(FNotesOnlySearchCheck) then FNotesOnlySearchCheck.Checked:=False;
  edFGenre.Text := '';
  edFGenre.Hint := '';
  edFAnnotation.Text := '';

  edFFile.Text := '';
  edFFolder.Text := '';
  edFExt.Text := '';

  cbDownloaded.ItemIndex := 0;
  edFKeyWords.Text := '';
  SetHideDeletedMode(Settings.HideDeletedBooks, False);
  cbDate.ItemIndex := -1;
  cbDate.Text := '';
  cbLang.ItemIndex := -1;
  cbLang.Text := '';
  cbLibRate.ItemIndex := -1;
  cbLibRate.Text := '';
  cbReaded.Checked := False;

  tvBooksSR.Clear;
  ClearLabels(PAGE_SEARCH, True);
end;

function TfrmMain.GetActiveView: TView;
begin
  if pgControl.ActivePage = tsBySerie then Result := SeriesView
  else if pgControl.ActivePage = tsByGenre then Result := GenresView
  else if pgControl.ActivePage = tsSearch then Result := SearchView
  else if pgControl.ActivePage = tsByGroup then Result := FavoritesView
  else if pgControl.ActivePage = tsDownload then Result := DownloadView
  else if Assigned(FPublisher) and (pgControl.ActivePage = FPublisher.Tab) then Result := PublisherSeriesView
  else Result := AuthorsView;
end;

procedure TfrmMain.CreatePublisherSeriesView;
begin
  FPublisher := TPublisherSeriesView.CreateView(Self, pgControl, tvSeries, tvBooksS, PAGE_PUBLISHER_SERIES);
  FPublisher.Tab.PageIndex := tsBySerie.PageIndex + 1;
  FPublisher.SeriesTree.OnChange := PublisherSeriesChange;
  FPublisher.SeriesTree.OnKeyDown := PublisherSeriesKeyDown;
  FPublisher.SeriesTree.PopupMenu := pmAuthor;
  FPublisher.Books.Header.PopupMenu := pmHeaders;
  FPublisher.Search.OnChange := PublisherSearchChanged;
  FPublisher.Search.OnKeyDown := PublisherSeriesKeyDown;
  FPublisher.ClearSearch.OnClick := PublisherSearchClear;
  FPublisher.SearchTimer.OnTimer := PublisherSearchTimer;
  FPublisher.IndexButton.OnClick := IndexPublisherSeries;
  FPublisher.Language.OnChange := cbLangSelectAChange;
  FPublisher.Info.OnResize := InfoPanelResize;
  FPublisher.Info.OnAuthorLinkClicked := AuthorLinkClicked;
  FPublisher.Info.OnSeriesLinkClicked := SeriesLinkClicked;
  FPublisher.Info.OnGenreLinkClicked := GenreLinkClicked;
  FPublisher.Info.OnPublisherSeriesLinkClicked := PublisherSeriesLinkClicked;
  ipnlAuthors.OnPublisherSeriesLinkClicked := PublisherSeriesLinkClicked;
  ipnlSeries.OnPublisherSeriesLinkClicked := PublisherSeriesLinkClicked;
  ipnlGenres.OnPublisherSeriesLinkClicked := PublisherSeriesLinkClicked;
  ipnlSearch.OnPublisherSeriesLinkClicked := PublisherSeriesLinkClicked;
  ipnlFavorites.OnPublisherSeriesLinkClicked := PublisherSeriesLinkClicked;
  FLastPublisherSeriesID := MHL_INVALID_ID;
  Settings.TreeModes[PAGE_PUBLISHER_SERIES] := tmFlat;
  FSortSettings[PAGE_PUBLISHER_SERIES].Column := NoColumn;
end;

procedure TfrmMain.ReloadPublisherSeries;
var
  WasInvisible: Boolean;
begin
  if not Assigned(FCollection) then Exit;
  WasInvisible := FInvisible;
  FInvisible := True;
  try
    FillSeriesTree(FPublisher.SeriesTree,
      FCollection.GetPublisherSeriesIterator(Trim(FPublisher.Search.Text)), FLastPublisherSeriesID);
    FPublisherListLoaded := True;
    Exclude(FLoadedBookViews, PublisherSeriesView);
  finally
    FInvisible := WasInvisible;
  end;
  if not FInvisible and (ActiveView = PublisherSeriesView) then
    PublisherSeriesChange(FPublisher.SeriesTree, FPublisher.SeriesTree.GetFirstSelected);
end;

procedure TfrmMain.PublisherSeriesChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  Data: PSeriesData;
  Filter: TFilterValue;
  WasLangSelected: Boolean;
begin
  if FInvisible or not Assigned(FCollection) then Exit;
  if ActiveView <> PublisherSeriesView then
  begin
    Exclude(FLoadedBookViews, PublisherSeriesView);
    Exit;
  end;
  Data := nil;
  if Assigned(Node) then Data := FPublisher.SeriesTree.GetNodeData(Node);
  if not Assigned(Data) then
  begin
    ClearLabels(PAGE_PUBLISHER_SERIES, True);
    FPublisher.Books.Clear;
    FLastPublisherSeriesID := MHL_INVALID_ID;
    FLastPublisherBookID.Clear;
    Include(FLoadedBookViews, PublisherSeriesView);
    Exit;
  end;
  if FLastPublisherSeriesID <> Data^.SeriesID then
  begin
    FLastPublisherBookID.Clear;
    FPendingPublisherBookID := 0;
    FPublisher.Language.Items.Clear;
    FPublisher.Language.Items.Add('-');
    FPublisher.Language.ItemIndex := 0;
  end;
  FLastPublisherSeriesID := Data^.SeriesID;
  FPublisher.Title.Caption := Data^.SeriesTitle;
  Filter := Default(TFilterValue);
  Filter.ValueInt := FLastPublisherSeriesID;
  WasLangSelected := FViewLanguageSelected[PublisherSeriesView];
  FViewLanguageSelected[PublisherSeriesView] := True;
  try
    FillBooksTree(FPublisher.Books, FPublisher.Language,
        function: IBookIterator begin Result := FCollection.GetBookIterator(bmByPublisherSeries, False, @Filter); end, False, False, @FLastPublisherBookID);
  finally
    FViewLanguageSelected[PublisherSeriesView] := WasLangSelected;
  end;
end;

procedure TfrmMain.PublisherSeriesKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Sender = FPublisher.Search) and (Key in [VK_UP, VK_DOWN]) then
  begin
    FPublisher.SeriesTree.Perform(WM_KEYDOWN, Key, 0);
    Key := 0;
  end;
  if Key = VK_RETURN then
  begin
    if Sender = FPublisher.Search then PublisherSearchTimer(nil);
    ActiveControl := FPublisher.Books;
    Key := 0;
  end;
end;

procedure TfrmMain.PublisherSearchChanged(Sender: TObject);
begin
  FPublisher.SearchTimer.Enabled := False;
  FPublisher.SearchTimer.Enabled := Assigned(FCollection) and not FInvisible;
end;

procedure TfrmMain.PublisherSearchTimer(Sender: TObject);
begin
  FPublisher.SearchTimer.Enabled := False;
  ReloadPublisherSeries;
end;

procedure TfrmMain.PublisherSearchClear(Sender: TObject);
begin
  SetTextNoChange(FPublisher.Search, '');
  PublisherSearchTimer(nil);
  ActiveControl := FPublisher.Search;
end;

procedure TfrmMain.IndexPublisherSeries(Sender: TObject);
var
  Worker: TIndexPublisherSeriesThread;
  ProgressForm: TImportProgressFormEx;
  IndexedCID: Integer;
  ChangesCommitted: Boolean;
begin
  if not Assigned(FCollection) or FFormBusy then Exit;
  IndexedCID := FCollection.CollectionID;
  ChangesCommitted := False;
  UpdatePositions;
  Worker := TIndexPublisherSeriesThread.Create(IndexedCID,
    FPublisher.FullScan.Checked);
  FFormBusy := True;
  FPublisher.SearchTimer.Enabled := False;
  try
    ProgressForm := TImportProgressFormEx.Create(Application);
    try
      ProgressForm.Caption := 'Заполнение издательств и книжных серий';
      ProgressForm.WorkerThread := Worker;
      ProgressForm.FullErrorLogFileName := Worker.ErrorLogFileName;
      ProgressForm.ShowModal;
    finally
      ProgressForm.Free;
    end;
    Worker.WaitFor;
    ChangesCommitted := Worker.CommittedChanges;
    if Assigned(Worker.FatalException) then
      MHLShowError(Exception(Worker.FatalException).Message);
  finally
    if Worker.Finished then
    begin
      Worker.WaitFor;
      ChangesCommitted := Worker.CommittedChanges;
    end;
    Worker.Free;
    FFormBusy := False;
    if ChangesCommitted and Assigned(FCollection) and
       (FCollection.CollectionID = IndexedCID) then
    begin
      RefreshBookMetadataViews(IndexedCID);
    end;
  end;
end;

procedure TfrmMain.RefreshBookMetadataViews(const CollectionID: Integer);
begin
  if not Assigned(FCollection) or (FCollection.CollectionID<>CollectionID) then Exit;
  // Only the visible list is rebuilt, from its applied search snapshot.
  // Inactive lists consume the new row metadata when next opened.
  FLoadedBookViews:=[]; FPublisherListLoaded:=False;
  EnsureActiveBookViewLoaded; RefreshActiveBookInfo;
end;

procedure TfrmMain.FillBookMetadataExecute(Sender: TObject);
var CollectionID: Integer; Changed: Boolean;
begin
  if not Assigned(FCollection) or FFormBusy then Exit;
  CollectionID:=FCollection.CollectionID; Changed:=False; UpdatePositions;
  FFormBusy:=True;
  try Changed:=FillMissingBookMetadata(Self,CollectionID);
  finally
    FFormBusy:=False;
    if Changed then RefreshBookMetadataViews(CollectionID);
  end;
end;

procedure TfrmMain.FillBookMetadataUpdate(Sender: TObject);
begin
  TAction(Sender).Enabled:=False;
  if Assigned(FCollection) then TAction(Sender).Enabled:=not FFormBusy and
    not isOnlineCollection(FCollection.CollectionCode);
end;

procedure TfrmMain.PublisherSeriesLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
var
  Tree: TBookTree;
  Data: PBookRecord;
  BookKey: TBookKey;
  SeriesID: Integer;
  WasInvisible: Boolean;
begin
  SeriesID := StrToIntDef(Link, MHL_INVALID_ID);
  if (SeriesID <= 0) or not Assigned(FCollection) then Exit;
  GetActiveTree(Tree);
  Data := Tree.GetNodeData(Tree.GetFirstSelected);
  if not Assigned(Data) or (Data^.nodeType <> ntBookInfo) then Exit;
  BookKey := Data^.BookKey;
  if BookKey.DatabaseID <> FCollection.CollectionID then
  begin
    Settings.ActiveCollection := BookKey.DatabaseID;
    InitCollection;
  end;
  // The current book is already visible in this series: keep its card and scroll.
  if (ActiveView = PublisherSeriesView) and
     (BookKey.DatabaseID = FCollection.CollectionID) and
     (FLastPublisherSeriesID = SeriesID) then Exit;
  WasInvisible := FInvisible;
  FInvisible := True;
  try
  FLastPublisherSeriesID := SeriesID;
  FLastPublisherBookID := BookKey;
  FPublisher.SearchTimer.Enabled := False;
  SetTextNoChange(FPublisher.Search, '');
  FPublisher.Language.ItemIndex := 0;
  FPendingLangFilters[PublisherSeriesView] := -1;
  ReloadPublisherSeries;
  ActivateView(PublisherSeriesView);
  finally
    FInvisible := WasInvisible;
  end;
  pgControlChange(nil);
end;

procedure TfrmMain.ActivateView(View: TView);
begin
  case View of
    AuthorsView: pgControl.ActivePage := tsByAuthor;
    SeriesView: pgControl.ActivePage := tsBySerie;
    GenresView: pgControl.ActivePage := tsByGenre;
    SearchView: pgControl.ActivePage := tsSearch;
    FavoritesView: pgControl.ActivePage := tsByGroup;
    DownloadView: pgControl.ActivePage := tsDownload;
    PublisherSeriesView: pgControl.ActivePage := FPublisher.Tab;
  end;
end;

procedure TfrmMain.OnSetControlsStateHandler(State: Boolean);
begin
  frmMain.Enabled := State;
end;

procedure TfrmMain.SavePositions;
begin
  if FCollection <> nil then
  begin
    FCollection.SetProperty(PROP_LAST_AUTHOR, FLastAuthorStr);
    if FPendingAuthorBookID <> 0 then
      FCollection.SetProperty(PROP_LAST_AUTHOR_BOOK, FPendingAuthorBookID)
    else
      FCollection.SetProperty(PROP_LAST_AUTHOR_BOOK, FLastAuthorBookID.BookID);
    FCollection.SetProperty(PROP_LAST_SERIES, FLastSeriesStr);
    FCollection.SetProperty(PROP_LAST_PUBLISHER_SERIES, FLastPublisherSeriesID);
    if FPendingPublisherBookID <> 0 then
      FCollection.SetProperty(PROP_LAST_PUBLISHER_BOOK, FPendingPublisherBookID)
    else
      FCollection.SetProperty(PROP_LAST_PUBLISHER_BOOK, FLastPublisherBookID.BookID);
    if FPendingLangFilters[PublisherSeriesView] >= 0 then
      FCollection.SetProperty(PROP_PUBLISHER_LANG_FILTER, FPendingLangFilters[PublisherSeriesView])
    else
      FCollection.SetProperty(PROP_PUBLISHER_LANG_FILTER, FPublisher.Language.ItemIndex);
    if FPendingSeriesBookID <> 0 then
      FCollection.SetProperty(PROP_LAST_SERIES_BOOK, FPendingSeriesBookID)
    else
      FCollection.SetProperty(PROP_LAST_SERIES_BOOK, FLastSeriesBookID.BookID);

    if FPendingLangFilters[AuthorsView] >= 0 then
      FCollection.SetProperty(PROP_BOOKS_LANG_FILTER, FPendingLangFilters[AuthorsView])
    else
      FCollection.SetProperty(PROP_BOOKS_LANG_FILTER, cbLangSelectA.ItemIndex);
    if FPendingLangFilters[SeriesView] >= 0 then
      FCollection.SetProperty(PROP_SERIES_LANG_FILTER, FPendingLangFilters[SeriesView])
    else
      FCollection.SetProperty(PROP_SERIES_LANG_FILTER, cbLangSelectS.ItemIndex);
    if FPendingLangFilters[GenresView] >= 0 then
      FCollection.SetProperty(PROP_GENRES_LANG_FILTER, FPendingLangFilters[GenresView])
    else
      FCollection.SetProperty(PROP_GENRES_LANG_FILTER, cbLangSelectG.ItemIndex);
    if FPendingLangFilters[FavoritesView] >= 0 then
      FCollection.SetProperty(PROP_GROUPS_LANG_FILTER, FPendingLangFilters[FavoritesView])
    else
      FCollection.SetProperty(PROP_GROUPS_LANG_FILTER, cbLangSelectF.ItemIndex);
  end;
end;

procedure TfrmMain.CloseCollection;
var
  FCursor: TCursor; I: Integer;
begin
  for I:=Low(FBookPreviews) to High(FBookPreviews) do
    if Assigned(FBookPreviews[I]) then FBookPreviews[I].Cancel;
  FStaleSelectors := [];
  FBookListCancelled := False;
  if Assigned(FOPDSForm) then FOPDSForm.StopServer;
  FCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    SavePositions;

    tvAuthors.Clear;
    tvSeries.Clear;
    FPublisher.SearchTimer.Enabled := False;
    FPublisher.SeriesTree.Clear;
    FPublisher.Books.Clear;
    SetTextNoChange(FPublisher.Search, '');
    FPublisherListLoaded := False;
    FLastPublisherSeriesID := MHL_INVALID_ID;
    FLastPublisherBookID.Clear;
    FPendingPublisherBookID := 0;
    tvGenres.Clear;
    tvBooksA.Clear;
    tvBooksS.Clear;
    tvBooksG.Clear;
    tvBooksSR.Clear;
    tvBooksF.Clear;
    ClearLabels(PAGE_ALL, True);

    FLoadedBookViews := [];
    FHasAppliedSearch := False;
    FFavoriteSearchPending := False;
    FOnlyNewFavoriteBooks := False;
    FFavoriteDescriptor := Default(TAuthorFavoriteCollection);
    FSearchCriteria := Default(TBookSearchCriteria);
    FSearchCriteria.Deleted := Settings.HideDeletedBooks;
    FPendingAuthorBookID := 0;
    FPendingSeriesBookID := 0;

    SetTextNoChange(edLocateAuthor, '');
    SetTextNoChange(edLocateSeries, '');

    FLastAuthorID := MHL_INVALID_ID;
    FLastAuthorBookID.Clear;

    FLastSeriesID := MHL_INVALID_ID;
    FLastSeriesBookID.Clear;

    FLastGenreCode := '';
    FLastGenreIsContainer := False;
    FLastGenreIsTopLevelContainer := False;
    FRootGenreBooksRequested := False;
    FLastGenreBookID.Clear;
    btnShowGenreBooks.Visible := False;

    FLastGroupID := MHL_INVALID_ID;
    FLastGroupBookID.Clear;

    FCollection := nil;
  finally
    Screen.Cursor := FCursor;
  end;
end;

// Keeps the two seeded group names in step with the interface language.
// AddGroup writes rstrFavoritesGroupName and rstrToReadGroupName into
// user.dbs2 when the system database is created, so like genre names they
// keep the language that created them.
// Renames only a group still carrying a name this build shipped, in any of
// its languages. CanDelete = False marks the two seeded groups, but it does
// not stop the user renaming them -- so a group whose name matches none of
// the shipped spellings was named by the user and is left alone permanently.
// That test also identifies which of the two a group is, without depending on
// GroupID ordering.
procedure TfrmMain.SyncSystemGroupNames;

  procedure SyncOne(const AKey, AWanted: string; const ALegacy: array of string);
  var
    Renderings: TArray<string>;
    Iterator: IGroupIterator;
    GroupData: TGroupData;
    Legacy: string;
  begin
    if AWanted = '' then
      Exit;

    // Shipped spellings alone are not enough. A profile created before the
    // interface was translated holds a name no current catalog contains --
    // Russian is no longer shipped -- and would be mistaken for the user's
    // own choice and left in Russian for good.
    Renderings := ShippedRenderings(AKey);
    for Legacy in ALegacy do
      if not MatchStr(Legacy, Renderings) then
      begin
        SetLength(Renderings, Length(Renderings) + 1);
        Renderings[High(Renderings)] := Legacy;
      end;

    if Length(Renderings) = 0 then
      Exit;

    Iterator := FSystemData.GetGroupIterator;
    while Iterator.Next(GroupData) do
    begin
      if GroupData.CanDelete then
        Continue;
      if GroupData.Text = AWanted then
        Continue;
      if MatchStr(GroupData.Text, Renderings) then
      begin
        FSystemData.RenameGroup(GroupData.GroupID, AWanted);
        Break;
      end;
    end;
  end;

begin
  Assert(Assigned(FSystemData));

  SyncOne('unit_SystemDatabase_Abstract_rstrFavoritesGroupName',
    rstrFavoritesGroupName, LegacyFavoritesGroupNames);
  SyncOne('unit_SystemDatabase_Abstract_rstrToReadGroupName',
    rstrToReadGroupName, LegacyToReadGroupNames);
end;

// Keeps a collection's genre names in step with the interface language.
// Genre names are collection data: they are written into the Genres table
// when the collection is created and never revisited, so switching the
// interface language used to leave the genre tree in the old language until
// the user found the Update genres command.
// Safe to run unconditionally for the lists we ship. tools/lang/glst_translate.js
// rebuilds every translated list from the original and substitutes only the
// name, so GenreCode and FB2Code are identical across locales -- which matters
// because ReloadGenres drops Genre_List rows whose GenreCode disappeared. A
// locale swap therefore cannot orphan a book's genre links.
procedure TfrmMain.SyncGenreLanguage;
var
  Wanted: string;
  Current: string;
  SourceGenres: Variant;
begin
  Assert(Assigned(FCollection));

  // Only FB2 collections get a list chosen for them. A non-FB2 collection's
  // list is picked by hand, so second-guessing it would discard the user's
  // own choice.
  if not isFB2Collection(FCollection.CollectionCode) then
    Exit;

  SourceGenres := FCollection.GetProperty(PROP_SOURCE_GENRES);
  if not VarIsEmpty(SourceGenres) and not VarIsNull(SourceGenres) then
    if Boolean(SourceGenres) then Exit;

  Wanted := ExtractFileName(Settings.SystemFileName[sfGenresFB2]);
  Current := VarToStr(FCollection.GetProperty(PROP_GENRE_FILE));

  if SameText(Current, Wanted) then
    Exit;

  // Collections predating PROP_GENRE_FILE record nothing. When the wanted
  // list is the untranslated original there is nothing to gain from rewriting
  // Russian names with the same Russian names, so only record where they came
  // from and leave the data alone.
  if (Current = '') and SameText(Wanted, GENRES_FB2_FILENAME) then
  begin
    FCollection.SetProperty(PROP_GENRE_FILE, Wanted);
    Exit;
  end;

  FCollection.ReloadGenres(Settings.SystemFileName[sfGenresFB2]);
end;

procedure TfrmMain.InitCollection;
var
  SavedCursor: TCursor;
  CollectionType: Integer;
  EmptySearchCriteria: TBookSearchCriteria;
  Acount, Scount, GCount: integer;
  Button: TToolButton;
  FSA, FSS: string;
  SelectedNode: PVirtualNode;
  AuthorData: PAuthorData;
  SeriesData: PSeriesData;
  View: TView;

  procedure ResetLangFilter(LangComboBox: TComboBox);
  begin
    LangComboBox.Items.Clear;
    LangComboBox.Items.Add('-');
    LangComboBox.ItemIndex := 0;
  end;


begin
  FIgnoreAuthorChange := True;
  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  FInvisible := True;
  try
    FSearchCriteria := EmptySearchCriteria;
    FSearchCriteria.Deleted := Settings.HideDeletedBooks;
    FHasAppliedSearch := False;

    CloseCollection;

    FLoadedBookViews := [];
    FPendingLangFilters[AuthorsView] := -1;
    FPendingLangFilters[SeriesView] := -1;
    FPendingLangFilters[GenresView] := -1;
    FPendingLangFilters[SearchView] := -1;
    FPendingLangFilters[FavoritesView] := -1;
    FPendingLangFilters[DownloadView] := -1;
    FPendingLangFilters[PublisherSeriesView] := -1;
    ResetLangFilter(FPublisher.Language);
    ResetLangFilter(cbLangSelectA);
    ResetLangFilter(cbLangSelectS);
    ResetLangFilter(cbLangSelectG);
    ResetLangFilter(cbLangSelectF);
    for View := Low(TView) to High(TView) do
      FViewLanguageSelected[View] := False;


    if (not LoadLastCollection)or (not FSystemData.HasCollections) then
    begin
      frmMain.Caption := 'HomeLib Ru';
      Screen.Cursor := SavedCursor;

      if not ShowNCWizard then
        Application.Terminate;

      DeleteFile(Settings.WorkPath + CHECK_FILE);
      Exit;
    end;

    FCollection := FSystemData.GetCollection(Settings.ActiveCollection);

    Assert(Assigned(FCollection));

    // Genre and seeded group names live in the databases, so they do not
    // follow a change of interface language on their own. Bring them into
    // line here, before the trees are built from them below.
    SyncGenreLanguage;
    SyncSystemGroupNames;

    frmMain.Caption := 'HomeLib Ru - ' + FCollection.CollectionDisplayName;

    CollectionType := FCollection.CollectionCode;
    IsPrivate := isPrivateCollection(CollectionType);
    IsOnline := isOnlineCollection(CollectionType);
    IsLocal := isLocalCollection(CollectionType);
    IsFB2 := isFB2Collection(CollectionType);
    IsNonFB2 := isNonFB2Collection(CollectionType);

    acEditConvert2FBD.Enabled := IsPrivate and not IsFB2;


    edFAnnotation.Enabled := True;
    edFAnnotation.ShowHint := True;
    edFAnnotation.Hint := 'Поиск по аннотациям, сохранённым в каталоге. INPX обычно не содержит аннотаций; текст внутри файлов здесь не просматривается.';


    tsDownload.TabVisible := IsOnline;
    acBookAdd2DownloadList.Visible := IsOnline;

    if not IsOnline and (ActiveView = DownloadView) then
      ActivateView(AuthorsView);

    CreateCollectionMenu;
    CreateScriptMenu;
    // Действия, видимость которых зависит от типа коллекции и которые доступны через тулбар, необходимо обновить вручную
    HideDeletedBooksUpdate(nil);
    ShowLocalOnlyUpdate(nil);
    ShowBookDelete(nil);

    FCollection.SetShowLocalOnly(IsOnline and Settings.ShowLocalOnly);
    SetHideDeletedMode(Settings.HideDeletedBooks, False);

    FCollection.GetStatistics(Acount, Scount, GCount);

    FSA := FCollection.GetProperty(PROP_LAST_AUTHOR);
    if FSA = '' then
      if Acount > 500 then FSA := 'А' else FSA := '*';

    FSS := FCollection.GetProperty(PROP_LAST_SERIES);
    if FSS = '' then
      if Scount > 500 then FSS := 'А' else FSS := '*';

    Button := GetFilterButton(FAuthorBars, Copy(FSA, 1, 1));
    InternalSetAuthorFilter(Button);

    FIgnoreAuthorChange := False;
    LocateAuthor(FSA);
    SelectedNode := tvAuthors.GetFirstSelected;
    if not Assigned(SelectedNode) then
    begin
      SelectedNode := tvAuthors.FocusedNode;
      if Assigned(SelectedNode) then tvAuthors.Selected[SelectedNode] := True;
    end;
    AuthorData := nil;
    if Assigned(SelectedNode) then
      AuthorData := tvAuthors.GetNodeData(SelectedNode);
    if Assigned(AuthorData) then
    begin
      FLastAuthorID := AuthorData^.AuthorID;
      FLastAuthorStr := AuthorData^.GetFullName;
      lblAuthor.Caption := FLastAuthorStr;
    end;

    Button := GetFilterButton(FSerieBars, Copy(FSS, 1, 1));
    InternalSetSeriesFilter(Button);
    LocateSeries(FSS);
    SelectedNode := tvSeries.GetFirstSelected;
    if not Assigned(SelectedNode) then
    begin
      SelectedNode := tvSeries.FocusedNode;
      if Assigned(SelectedNode) then tvSeries.Selected[SelectedNode] := True;
    end;
    SeriesData := nil;
    if Assigned(SelectedNode) then
      SeriesData := tvSeries.GetNodeData(SelectedNode);
    if Assigned(SeriesData) then
    begin
      FLastSeriesID := SeriesData^.SeriesID;
      FLastSeriesStr := SeriesData^.SeriesTitle;
      lblSeries.Caption := FLastSeriesStr;
    end;

    // поскольку убрали обязательный FillBooksTree, нужно принудительно чистить список книг в случе пустого списка авторов
    // в противном случае FillBooksTree вызывалъся повторно

    if tvAuthors.GetFirst = nil then tvAuthorsChange(tvAuthors, nil);
     if tvSeries.GetFirst = nil then tvAuthorsChange(tvSeries, nil);


    FillGenresTree(tvGenres, FCollection.GetGenreIterator(gmAll), False, FLastGenreCode);
    FillGroupsList(tvGroups, FSystemData.GetGroupIterator, FLastGroupID);
    CreateGroupsMenu;

    if ActiveView = AuthorsView then
      miGoToAuthor.Visible := False;

    UpdateActions;
    UpdateAllEditActions;

    // Restore each language filter when its book list is first built. Building
    // all four lists here makes startup depend on the size of hidden views.
    FPendingLangFilters[AuthorsView] := FCollection.GetProperty(PROP_BOOKS_LANG_FILTER);
    FPendingLangFilters[SeriesView] := FCollection.GetProperty(PROP_SERIES_LANG_FILTER);
    FPendingLangFilters[GenresView] := FCollection.GetProperty(PROP_GENRES_LANG_FILTER);
    FPendingLangFilters[FavoritesView] := FCollection.GetProperty(PROP_GROUPS_LANG_FILTER);
    FPendingAuthorBookID := FCollection.GetProperty(PROP_LAST_AUTHOR_BOOK);
    FPendingSeriesBookID := FCollection.GetProperty(PROP_LAST_SERIES_BOOK);
    FLastPublisherSeriesID := FCollection.GetProperty(PROP_LAST_PUBLISHER_SERIES);
    FPendingPublisherBookID := FCollection.GetProperty(PROP_LAST_PUBLISHER_BOOK);
    FPendingLangFilters[PublisherSeriesView] := FCollection.GetProperty(PROP_PUBLISHER_LANG_FILTER);
    FInvisible := False;
    CheckFavoriteCollection;
  EnsureActiveBookViewLoaded;

  finally
    FInvisible := False;
    FIgnoreAuthorChange := False;
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.SeriesLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
var
  savedCursor: TCursor;
  WasInvisible: Boolean;
  seriesID: Integer;
  seriesTitle: string;
  node: PVirtualNode;
  bookTree: TBookTree;
  bookData: PBookRecord;
  bookKey: TBookKey;
  Button : TToolButton;
  BookCollection: IBookCollection;
  BookSeries: TBookSeries;
  SeriesItem: TBookSeriesData;
begin
  Assert(Assigned(FCollection));

  GetActiveTree(bookTree);
  node := bookTree.GetFirstSelected;
  bookData := bookTree.GetNodeData(node);
  if not Assigned(bookData) or (bookData^.nodeType <> ntBookInfo) then
    Exit;
  bookKey := bookData^.BookKey;

  seriesID := StrToIntDef(Link, NO_SERIES_ID);
  if seriesID = NO_SERIES_ID then
    Exit;

  if (ActiveView = SeriesView) and (FLastSeriesID = seriesID) and
     (bookKey.DatabaseID = FCollection.CollectionID) then Exit;
  seriesTitle := '';
  if bookData.SeriesID = seriesID then
    seriesTitle := bookData^.Series;
  if seriesTitle = '' then
  begin
    BookCollection := FSystemData.GetCollection(bookKey.DatabaseID);
    BookSeries := BookCollection.GetBookSeries(bookKey);
    for SeriesItem in BookSeries do
      if SeriesItem.SeriesID = seriesID then
      begin
        seriesTitle := SeriesItem.SeriesTitle;
        Break;
      end;
  end;
  if seriesTitle = '' then
    Exit;

  savedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    if bookKey.DatabaseID <> FCollection.CollectionID then
    begin
      Settings.ActiveCollection := bookKey.DatabaseID;
      InitCollection;
    end;

    WasInvisible := FInvisible;
    FInvisible := True;
    try
    FLastSeriesID := seriesID;

    Button := GetFilterButton(FSerieBars, seriesTitle);
    if Assigned(Button) and (Button <> FLastLetterS) then
    begin
      InternalSetSeriesFilter(Button);
    end;
    LocateSeries(seriesTitle);


    FLastSeriesBookID := bookKey;
    Exclude(FLoadedBookViews, SeriesView);

    ActivateView(SeriesView);
    finally
      FInvisible := WasInvisible;
    end;
    pgControlChange(nil);

  finally
    Screen.Cursor := savedCursor;
  end;
end;

procedure TfrmMain.GenreLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
var
  savedCursor: TCursor;
  WasInvisible: Boolean;
  genreCode: string;
  node: PVirtualNode;
  genreData: PGenreData;
  bookTree: TBookTree;
  bookData: PBookRecord;
  bookKey: TBookKey;
begin
  Assert(Assigned(FCollection));

  GetActiveTree(bookTree);
  node := bookTree.GetFirstSelected;
  bookData := bookTree.GetNodeData(node);
  if not Assigned(bookData) or (bookData^.nodeType <> ntBookInfo) then
    Exit;
  bookKey := bookData^.BookKey;

  if (ActiveView = GenresView) and (FLastGenreCode = Link) and
     (bookKey.DatabaseID = FCollection.CollectionID) then Exit;
  savedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    if bookKey.DatabaseID <> FCollection.CollectionID then
    begin
      Settings.ActiveCollection := bookKey.DatabaseID;
      InitCollection;
    end;

    WasInvisible := FInvisible;
    FInvisible := True;
    try
    genreCode := Link;
    node := tvGenres.GetFirst;
    while Assigned(node) do
    begin
      genreData := tvGenres.GetNodeData(node);
      Assert(Assigned(genreData));
      if genreData^.GenreCode = genreCode then
      begin
        tvGenres.Selected[node] := True;
        tvGenres.FocusedNode := node;
        lblGenreTitle.Caption := genreData^.GenreAlias;
        FLastGenreCode := genreCode;
        FLastGenreIsContainer := (node^.ChildCount > 0);
        FLastGenreIsTopLevelContainer :=
          (genreData^.ParentCode = '0') and FLastGenreIsContainer;
        FRootGenreBooksRequested := False;
        Break;
      end;
      node := tvGenres.GetNext(node);
    end;

    // Concrete genres are loaded immediately. Top-level genres remain
    // collapsed and empty until the user explicitly asks to show them.
    FLastGenreBookID := bookKey;
    Exclude(FLoadedBookViews, GenresView);
    ActivateView(GenresView);
    finally
      FInvisible := WasInvisible;
    end;
    pgControlChange(nil);
  finally
    Screen.Cursor := savedCursor;
  end;
end;

procedure TfrmMain.AuthorLinkClicked(Sender: TObject; const Link: string; LinkType: TSysLinkType);
var
  node: PVirtualNode;
  bookTree: TBookTree;
  bookData: PBookRecord;
  bookKey: TBookKey;
  authorData: TAuthorData;
  authorID: Integer;
  authorFullName: string;
begin
  GetActiveTree(bookTree);
  node := bookTree.GetFirstSelected;
  bookData := bookTree.GetNodeData(node);
  if not Assigned(bookData) or (bookData^.nodeType <> ntBookInfo) then
    Exit;
  bookKey := bookData^.BookKey;

  authorID := StrToInt(Link);
  authorFullName := '';
  for authorData in bookData.Authors do
  begin
    if authorData.AuthorID = authorID then
      authorFullName := authorData.GetFullName;
  end;

  if authorFullName <> '' then
    LocateAuthorAndBook(authorFullName, bookKey);
end;

procedure TfrmMain.CreateAlphabetToolbar;
const
  EngAlphabet: string = ALPHA_FILTER_ALL + ALPHA_FILTER_NON_ALPHA + LATIN_ALPHABET;
  RusAlphabet: string = ALPHA_FILTER_ALL + ALPHA_FILTER_NON_ALPHA + CYRILLIC_ALPHABET;
var AlphaChar: Char; APos, SPos: Integer;
  procedure Prepare(Toolbar: TToolBar);
  begin
    // Native captions stay sharp on either background; masked light glyphs
    // retain coloured antialiasing fringes when reused in the dark theme.
    Toolbar.Images:=nil; Toolbar.HotImages:=nil; Toolbar.DisabledImages:=nil;
    Toolbar.ShowCaptions:=True; Toolbar.List:=True;
    Toolbar.Font.Name:='Segoe UI'; Toolbar.Font.Size:=9;
    Toolbar.Font.Style:=[fsBold]; Toolbar.Font.Quality:=fqClearTypeNatural;
    Toolbar.ButtonWidth:=MulDiv(20,CurrentPPI,96);
    Toolbar.ButtonHeight:=MulDiv(24,CurrentPPI,96);
  end;
  function AddLetter(Toolbar: TToolBar; Letter: Char; Action: TNotifyEvent; Position: Integer): Integer;
  var Button: TToolButton;
  begin
    Button:=TToolButton.Create(Toolbar); Button.Caption:=Letter; Button.ImageIndex:=-1;
    Button.OnClick:=Action; Button.Left:=Position; Button.Parent:=Toolbar;
    Result:=Button.Left+Button.Width;
  end;
begin
  Prepare(tbarAuthorsRus); Prepare(tbarAuthorsEng);
  Prepare(tbarSeriesRus); Prepare(tbarSeriesEng);
  APos:=0; SPos:=0;
  for AlphaChar in RusAlphabet do
  begin
    APos:=AddLetter(tbarAuthorsRus,AlphaChar,OnSetAuthorFilter,APos);
    SPos:=AddLetter(tbarSeriesRus,AlphaChar,OnSetSerieFilter,SPos);
  end;
  APos:=0; SPos:=0;
  for AlphaChar in EngAlphabet do
  begin
    APos:=AddLetter(tbarAuthorsEng,AlphaChar,OnSetAuthorFilter,APos);
    SPos:=AddLetter(tbarSeriesEng,AlphaChar,OnSetSerieFilter,SPos);
  end;
end;

procedure TfrmMain.CreateCollectionMenu;
var
  SubItem: TMenuItem;
  ActiveCollectionID: Integer;
  CollectionInfoIterator: ICollectionInfoIterator;
  CollectionInfo: TCollectionInfo;

  function GetCollectionTypeImageIndex(const CollectionType: COLLECTION_TYPE): Integer;
  begin
    case CollectionType of
      CT_PRIVATE_FB: Result := 18;
      CT_PRIVATE_NONFB: Result := 8;
      CT_EXTERNAL_LOCAL_FB: Result := 14;
      CT_EXTERNAL_LOCAL_NONFB: Result := 8;
      CT_EXTERNAL_ONLINE_FB: Result := 4;
      CT_EXTERNAL_ONLINE_NONFB: Result := 8;
    else
      Result := 8;
    end;
  end;

begin
  Assert(Assigned(FCollection));
  ActiveCollectionID := FCollection.CollectionID;

  miCollSelect.Clear;
  miCopyToCollection.Clear;
  pmCollection.Items.Clear;

  CollectionInfoIterator := FSystemData.GetCollectionInfoIterator;
  while CollectionInfoIterator.Next(CollectionInfo) do
  begin
    if ActiveCollectionID <> CollectionInfo.ID then
    begin
      SubItem := TMenuItem.Create(miCollSelect);
      SubItem.Caption := CollectionInfo.DisplayName;
      SubItem.Tag := CollectionInfo.ID;
      SubItem.OnClick := miActiveCollectionClick;
      SubItem.ImageIndex := GetCollectionTypeImageIndex(CollectionInfo.CollectionType);
      miCollSelect.Add(SubItem);

      SubItem := TMenuItem.Create(pmCollection);
      SubItem.Caption := CollectionInfo.DisplayName;
      SubItem.Tag := CollectionInfo.ID;
      SubItem.OnClick := miActiveCollectionClick;
      SubItem.ImageIndex := GetCollectionTypeImageIndex(CollectionInfo.CollectionType);
      pmCollection.Items.Add(SubItem);

      if
        isPrivateCollection(CollectionInfo.CollectionType) and
        isFB2Collection(CollectionInfo.CollectionType) and
        IsFB2
      then
      begin
        SubItem := TMenuItem.Create(miCopyToCollection);
        SubItem.Caption := CollectionInfo.DisplayName;
        SubItem.Tag := CollectionInfo.ID;
        SubItem.OnClick := CopyToCollectionClick;
        SubItem.ImageIndex := GetCollectionTypeImageIndex(CollectionInfo.CollectionType);

        miCopyToCollection.Add(SubItem);
      end;
    end;
  end;

  if pmCollection.Items.Count > 0 then
  begin
    SubItem := TMenuItem.Create(pmCollection);
    SubItem.Caption := '-';
    pmCollection.Items.Add(SubItem);
  end;

  SubItem := TMenuItem.Create(pmCollection);
  SubItem.Caption := rsrtNewCollectin;
  SubItem.Action := acCollectionNew;
  SubItem.ImageIndex := 1;
  pmCollection.Items.Add(SubItem);

  miCopyToCollection.Enabled := (miCopyToCollection.Count > 0);
  miCollSelect.Enabled := (miCollSelect.Count > 0);
end;

procedure TfrmMain.CreateLanguageMenu;
const
  LANGUAGE_GROUP_INDEX = 9;
var
  Separator, Container, Item: TMenuItem;
  I: Integer;
begin
  FLocales := AvailableLocales;

  // One locale is not a choice: with only Ukrainian available the submenu
  // would offer nothing but the language already in use, so build nothing at
  // all -- no separator, no container, no trace in the View menu.
  if Length(FLocales) < 2 then
    Exit;

  Separator := TMenuItem.Create(miView);
  Separator.Caption := '-';
  miView.Add(Separator);

  Container := TMenuItem.Create(miView);
  Container.Caption := rstrInterfaceLanguage;
  miView.Add(Container);

  for I := 0 to High(FLocales) do
  begin
    Item := TMenuItem.Create(Container);
    // The language's own name, never translated: these are not catalog
    // sources, so the walker misses them and each stays in its own script.
    Item.Caption := FLocales[I].Name;
    Item.RadioItem := True;
    Item.GroupIndex := LANGUAGE_GROUP_INDEX;
    Item.Tag := I;
    Item.OnClick := LanguageItemClick;
    Item.Checked := SameText(FLocales[I].Code, Settings.Locale);
    Container.Add(Item);
  end;
end;

procedure TfrmMain.LanguageItemClick(Sender: TObject);
var
  Index: Integer;
  Code: string;
begin
  Index := TMenuItem(Sender).Tag;
  if (Index < 0) or (Index > High(FLocales)) then
    Exit;

  Code := FLocales[Index].Code;
  if SameText(Code, Settings.Locale) then
    Exit; // clicking the ticked item is not a change

  Settings.Locale := Code;
  // Written now rather than at shutdown: the property is a plain field, and
  // the choice should survive even if the process never exits cleanly.
  Settings.SaveSettings;

  TMenuItem(Sender).Checked := True;
  MHLShowInfo(rstrLanguageChangeOnRestart);
end;

procedure TfrmMain.CreateGroupsMenu;
var
  Item, ItemP: TMenuItem;
  GroupIterator: IGroupIterator;
  Group: TGroupData;
begin
  pmGroups.Items.Clear;
  miAddToGroup.Clear;
  pmiGroups.Clear;

  GroupIterator := FSystemData.GetGroupIterator;
  while GroupIterator.Next(Group) do
  begin
    if Group.GroupID <> FAVORITES_GROUP_ID then
    begin
      Item := TMenuItem.Create(pmGroups);
      Item.Caption := Group.Text;
      Item.Tag := Group.GroupID;
      Item.OnClick := GroupMenuItemClick;
      pmGroups.Items.Add(Item);

      ItemP := TMenuItem.Create(pmMain);
      ItemP.Caption := Group.Text;
      ItemP.Tag := Group.GroupID;
      ItemP.OnClick := GroupMenuItemClick;
      pmiGroups.Add(ItemP);

      ItemP := TMenuItem.Create(pmMain);
      ItemP.Caption := Group.Text;
      ItemP.Tag := Group.GroupID;
      ItemP.OnClick := GroupMenuItemClick;
      miAddToGroup.Add(ItemP);
    end;
  end;
end;

procedure TfrmMain.CreateScriptMenu;
const
  ExpCount = 6;
  ExpTypes: array [0 .. ExpCount] of string = ('  fb2', '  fb2.zip', '  LRF', '  txt', ' epub', '  pdf', ' .mobi');
  IconsSmall: array [0 .. ExpCount] of Integer = (0, 1, 2, 3, 4, 5, 6);
var
  Item, ItemP, ItemM: TMenuItem;
  F: Integer;
  i: Integer;
  fb2Collection: Boolean;
  ExportItemCount: Integer;
  ExportScriptCount: Integer;
begin
  CreateExternalToolsMenu;
  pmScripts.Items.Clear;
  pmiScripts.Clear;
  mmiScripts.Clear;

  fb2Collection := Assigned(FCollection) and isFB2Collection(FCollection.CollectionCode);

  pmMain.OnPopup:=UpdateConversionMenu; pmScripts.OnPopup:=UpdateConversionMenu;
  miBook.OnClick:=UpdateConversionMenu;
  pmiScripts.OnClick:=UpdateConversionMenu; mmiScripts.OnClick:=UpdateConversionMenu;
  pmiScripts.Caption := 'Конвертировать / сохранить';
  mmiScripts.Caption := pmiScripts.Caption;
  ExportItemCount := 0;
  for i := 0 to ExpCount do
  begin
    // FB2 and EPUB are available in mixed/raw collections as well. Other
    // historical converters retain their FB2-collection restriction.
    if not (fb2Collection or Settings.AllowMixed) and not (i in [0, 4]) then
      Continue;
    Item := TMenuItem.Create(pmScripts);
    Item.OnClick := SendToDeviceExecute;
    Item.Caption := ExpTypes[i];
    if i = 0 then Item.Caption := 'Экспорт в FB2...';
    if i = 4 then Item.Caption := 'Экспорт в EPUB...';
    Item.Tag := 850 + i;
    Item.ImageIndex := IconsSmall[i];
    pmScripts.Items.Insert(ExportItemCount, Item);
    Inc(ExportItemCount);
    if i in [0, 4] then
    begin
      // Offer the bundled converter where books are selected, even when no
      // personal scripts are configured. Keep ordinary device sending intact.
      ItemP := TMenuItem.Create(pmiScripts); ItemP.OnClick := SendToDeviceExecute;
      ItemP.Caption := Item.Caption; ItemP.Tag := Item.Tag; ItemP.ImageIndex := Item.ImageIndex;
      pmiScripts.Add(ItemP);
      ItemM := TMenuItem.Create(MainMenu); ItemM.OnClick := SendToDeviceExecute;
      ItemM.Caption := Item.Caption; ItemM.Tag := Item.Tag; ItemM.ImageIndex := Item.ImageIndex;
      mmiScripts.Add(ItemM);
    end;
  end;

  F := ExportItemCount;
  ExportScriptCount := 0;
  for i := 0 to Settings.Scripts.Count - 1 do
    if not Settings.Scripts[i].Standalone then Inc(ExportScriptCount);
  if ExportScriptCount > 0 then
  begin
    Item := TMenuItem.Create(pmScripts);
    Item.Caption := '-';
    Item.Tag := 0;
    pmScripts.Items.Insert(F, Item);
    Inc(F);
    ItemP := TMenuItem.Create(pmiScripts); ItemP.Caption := '-'; pmiScripts.Add(ItemP);
    ItemM := TMenuItem.Create(MainMenu); ItemM.Caption := '-'; mmiScripts.Add(ItemM);
  end;

  for i := 0 to Settings.Scripts.Count - 1 do
  begin
    if Settings.Scripts[i].Standalone then Continue;
    Item := TMenuItem.Create(pmScripts);
    Item.Caption := Settings.Scripts[i].Title;
    Item.Tag := 901 + i;
    Item.OnClick := SendToDeviceExecute;
    Item.ImageIndex := 7;  // 'script' in CFileTypeOrder
    pmScripts.Items.Add(Item);

    ItemP := TMenuItem.Create(pmiScripts);
    ItemP.Caption := Settings.Scripts[i].Title;
    ItemP.Tag := 901 + i;
    ItemP.OnClick := SendToDeviceExecute;
    pmiScripts.Add(ItemP);

    ItemM := TMenuItem.Create(MainMenu);
    ItemM.Caption := Settings.Scripts[i].Title;
    ItemM.Tag := 901 + i;
    ItemM.OnClick := SendToDeviceExecute;
    mmiScripts.Add(ItemM);
  end;


  if pmScripts.Items.Count > 0 then
  begin
    Item := TMenuItem.Create(pmScripts);
    Item.Caption := '-';
    Item.tag := 0;
    pmScripts.Items.Add(Item);
  end;

  Item := TMenuItem.Create(pmScripts);
  Item.OnClick := SendToDeviceExecute;
  Item.Caption := rstrSelectFolder;
  Item.ImageIndex := 10;
  Item.tag := 799;
  pmScripts.Items.Add(Item);


  if pmiScripts.Count > 0 then
  begin
    mmiScripts.Visible := True;
    pmiScripts.Visible := True;
  end
  else
  begin
    mmiScripts.Visible := False;
    pmiScripts.Visible := False;
  end
end;

procedure TfrmMain.CreateExternalToolsMenu;
var Item: TMenuItem; Count: Integer;
begin
  if not Assigned(FExternalToolsMenu) then
  begin
    FExternalToolsMenu := TPopupMenu.Create(Self); FExternalToolsMenu.Name := 'pmExternalTools';
    FExternalToolsItem := TMenuItem.Create(Self); FExternalToolsItem.Name := 'miExternalTools';
    FExternalToolsItem.Caption := 'Внешние инструменты'; miTools.Add(FExternalToolsItem);
    FExternalToolsButton := TToolButton.Create(Self); FExternalToolsButton.Name := 'btnExternalTools';
    FExternalToolsButton.Parent := tlbrMain; FExternalToolsButton.Style := tbsDropDown;
    FExternalToolsButton.ImageIndex := tbtnSettings.ImageIndex;
    FExternalToolsButton.Caption := 'Скрипты'; FExternalToolsButton.ShowHint := True;
    FExternalToolsButton.Hint := 'Внешние инструменты: свои скрипты и программы';
    FExternalToolsButton.DropdownMenu := FExternalToolsMenu; FExternalToolsButton.OnClick := ExternalToolClick;
  end;
  FExternalToolsMenu.Items.Clear; FExternalToolsItem.Clear; Count := 0;
  for var I := 0 to Settings.Scripts.Count - 1 do
    if Settings.Scripts[I].Standalone then
    begin
      Inc(Count);
      Item := TMenuItem.Create(FExternalToolsMenu); Item.Caption := Settings.Scripts[I].Title;
      Item.Tag := I; Item.OnClick := ExternalToolClick; FExternalToolsMenu.Items.Add(Item);
      Item := TMenuItem.Create(FExternalToolsItem); Item.Caption := Settings.Scripts[I].Title;
      Item.Tag := I; Item.OnClick := ExternalToolClick; FExternalToolsItem.Add(Item);
    end;
  Item := TMenuItem.Create(FExternalToolsItem); Item.Name := 'miExternalToolsSetup';
  Item.Caption := 'Настроить скрипты…'; Item.OnClick := ChangeSettingsExecute; FExternalToolsItem.Add(Item);
  FExternalToolsButton.Visible := Count > 0;
end;

procedure TfrmMain.ExternalToolClick(Sender: TObject);
var Point: TPoint; Index: Integer;
begin
  if Sender = FExternalToolsButton then
  begin
    Point.X := 0; Point.Y := FExternalToolsButton.Height;
    Point := FExternalToolsButton.ClientToScreen(Point);
    FExternalToolsMenu.Popup(Point.X, Point.Y); Exit;
  end;
  Index := (Sender as TComponent).Tag;
  if (Index < 0) or (Index >= Settings.Scripts.Count) or not Settings.Scripts[Index].Standalone then Exit;
  Settings.Scripts[Index].Run;
end;

procedure TfrmMain.UpdateConversionMenu(Sender: TObject);
var Tree: TBookTree; Book: PBookRecord; SourceType: string;
  procedure UpdateItems(Parent: TMenuItem; HideEmptyParent: Boolean);
  var VisibleCount: Integer; Item: TMenuItem; Previous: TMenuItem;
  begin
    VisibleCount:=0; Previous:=nil;
    for var I:=0 to Parent.Count-1 do
    begin
      Item:=Parent.Items[I];
      if (Item.Tag>=850) and (Item.Tag<=856) then
      begin
        case Item.Tag of
          850: Item.Visible:=(SourceType<>'fb2') and (IsConversionCandidate(SourceType) or IsReaderArchive('book.'+SourceType));
          854: Item.Visible:=(SourceType<>'epub') and (IsConversionCandidate(SourceType) or IsReaderArchive('book.'+SourceType));
        else Item.Visible:=SourceType='fb2'; end;
      end;
      if Item.Caption='-' then
      begin
        Item.Visible:=Assigned(Previous) and (Previous.Caption<>'-');
        if Item.Visible then Previous:=Item;
      end
      else if Item.Visible then begin Inc(VisibleCount); Previous:=Item; end;
    end;
    if Assigned(Previous) and (Previous.Caption='-') then Previous.Visible:=False;
    if HideEmptyParent then Parent.Visible:=VisibleCount>0;
  end;
begin
  SourceType:='';
  if Assigned(FCollection) and (ActiveView in [AuthorsView,SeriesView,PublisherSeriesView,GenresView,SearchView,FavoritesView]) then
  begin
    GetActiveTree(Tree);
    if Assigned(Tree) then
    begin
      // Inspect the selected row only: opening a menu never scans the library
      // or starts extraction. The export worker validates every queued input.
      Book:=Tree.GetNodeData(Tree.GetFirstSelected);
      if Assigned(Book) and (Book^.NodeType=ntBookInfo) then
      begin
        SourceType:=Book^.GetFileType;
        // Numeric extensions are deliberately not presented as ordinary file
        // types. Conversion may inspect their content in its background job.
        if IsConversionCandidate(Book^.FileExt) then SourceType:=LowerCase(Book^.FileExt).TrimLeft(['.']);
      end;
    end;
  end;
  UpdateItems(pmiScripts,True); UpdateItems(mmiScripts,True); UpdateItems(pmScripts.Items,False);
end;

function TfrmMain.ShowNCWizard: Boolean;
var
  frmNCWizard: TNewCollectionWizard;
  WizardResult, CreatedCollectionID: Integer;
  ImportCommitted, MetadataRequested, MetadataChanged, WasBusy: Boolean;
  CreatedCollectionInfo: TCollectionInfo;
begin
  Result := False;
  frmNCWizard := TNewCollectionWizard.Create(Application);
  try
    WizardResult := frmNCWizard.ShowModal;
    CreatedCollectionID := frmNCWizard.NewCollectionID;
    MetadataRequested := frmNCWizard.RequestedMetadataFill;
    if frmNCWizard.CommittedChanges and (CreatedCollectionID > 0) and
      (FSystemData.FindFirstExistingCollectionID(CreatedCollectionID) = CreatedCollectionID) then
      NotifyFavoriteCatalogChanged(TArray<Integer>.Create(CreatedCollectionID));
    if (WizardResult = mrOk) and frmNCWizard.OperationSucceeded and
      (CreatedCollectionID > 0) and
      (FSystemData.FindFirstExistingCollectionID(CreatedCollectionID) = CreatedCollectionID) then
    begin
      Settings.ActiveCollection := CreatedCollectionID;
      InitCollection;
      if frmNCWizard.Autoimport and IsFB2 then
      begin
        Assert(Assigned(FCollection));
        unit_Import.ImportFB2(FCollection.CollectionID, afZip, ImportCommitted);
        if ImportCommitted then NotifyFavoriteCatalogChanged(TArray<Integer>.Create(FCollection.CollectionID));
        InitCollection;
      end;

      Result := True;
      // The finish button records a request only. Initialize the exact created
      // collection (and any existing optional import) before opening the same
      // explicit preview/fill dialog used by Collection and Sources commands.
      if MetadataRequested and frmNCWizard.CommittedChanges and
        (FSystemData.FindFirstExistingCollectionID(CreatedCollectionID) = CreatedCollectionID) then
      begin
        CreatedCollectionInfo := FSystemData.GetCollectionInfo(CreatedCollectionID);
        if (CreatedCollectionInfo.ID = CreatedCollectionID) and
          not isOnlineCollection(CreatedCollectionInfo.CollectionType) and
          (Trim(CreatedCollectionInfo.RootFolder) <> '') and DirectoryExists(CreatedCollectionInfo.RootFolder) then
        begin
          MetadataChanged := False; WasBusy := FFormBusy; FFormBusy := True;
          try MetadataChanged := FillMissingBookMetadata(Self, CreatedCollectionID);
          finally
            FFormBusy := WasBusy;
            if MetadataChanged then RefreshBookMetadataViews(CreatedCollectionID);
          end;
        end;
      end;
    end
    else
      Result := False;
  finally
    frmNCWizard.Free;
  end;
end;

procedure TfrmMain.ShowNewCollectionWizard(Sender: TObject);
begin
  ShowNCWizard;
end;

procedure TfrmMain.SetFormState;
begin
  WindowState := TWindowState(Settings.WindowState);
  if WindowState = wsNormal then
  begin
    Top := Settings.FormTop;
    Left := Settings.FormLeft;
    Width := Settings.FormWidth;
    Height := Settings.FormHeight;
  end;

  Visible := True;
  if WindowState = wsMinimized then
    WindowState := wsNormal;
  tmrCheckUpdates.Enabled := True;
end;

procedure TfrmMain.btnSwitchTreeModeClick(Sender: TObject);
var
  SavedCursor: TCursor;
  Page: Integer;
  FilterValue: TFilterValue;
begin
  if ActiveView in [PublisherSeriesView, DownloadView] then Exit;
  Assert(Assigned(FCollection));
  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    SaveColumns;

    Page := Ord(ActiveView);

    if Settings.TreeModes[Page] = tmFlat then
      Settings.TreeModes[Page] := tmTree
    else
      Settings.TreeModes[Page] := tmFlat;

    btnSwitchTreeMode.ImageIndex := TreeIcons[Ord(Settings.TreeModes[Page])];
    btnSwitchTreeMode.Hint := TreeHints[Ord(Settings.TreeModes[Page])];

    SetColumns;

    case Page of
      0:
      begin
        FillCurrentAuthorBooks; // авторы
      end;

      1:
      begin
        FilterValue := SeriesBookFilter;
        FillBooksTree(tvBooksS, cbLangSelectS,
        function: IBookIterator begin Result := FCollection.GetBookIterator(bmBySeries, False, @FilterValue); end, False, False, @FLastSeriesBookID); // серии
      end;

      2:
      begin
        FillCurrentGenreBooks; // жанры
      end;

      3: ReloadAppliedSearch; // поиск только по последнему применённому условию

      4: FillBooksTree(tvBooksF, cbLangSelectF,
        function: IBookIterator begin Result := FSystemData.GetBookIterator(FLastGroupID); end, True, True, @FLastGroupBookID);  // избранное
    end;

    SetHeaderPopUp;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.ClearLabels(Tag: Integer; Full: Boolean);
begin
  case Tag of
    PAGE_AUTHORS:
      begin
        ipnlAuthors.Clear;
        if Full then
        begin
          lblAuthor.Caption := '...';
          lblBooksTotalA.Caption := '(0)';
        end;
      end;

    PAGE_SERIES:
      begin
        ipnlSeries.Clear;
        if Full then
        begin
          lblSeries.Caption := '...';
          lblBooksTotalS.Caption := '(0)';
        end;
      end;

    PAGE_GENRES:
      begin
        ipnlGenres.Clear;
        if Full then
        begin
          lblGenreTitle.Caption := '...';
          lblBooksTotalG.Caption := '(0)';
        end;
      end;

    PAGE_FAVORITES:
      begin
        ipnlFavorites.Clear;
        if Full then
        begin
          lblGroups.Caption := '...';
          lblBooksTotalF.Caption := '(0)';
        end;
      end;

    PAGE_SEARCH:
      begin
        ipnlSearch.Clear;
        if Full then
          lblTotalBooksFL.Caption := '(0)';
      end;

    PAGE_PUBLISHER_SERIES:
      begin
        FPublisher.Info.Clear;
        FPublisher.Total.Caption := '';
        if Full then FPublisher.Title.Caption := '';
      end;
    PAGE_ALL:
      begin
        ClearLabels(PAGE_AUTHORS, Full);
        ClearLabels(PAGE_SERIES, Full);
        ClearLabels(PAGE_PUBLISHER_SERIES, Full);
        ClearLabels(PAGE_GENRES, Full);
        ClearLabels(PAGE_FAVORITES, Full);
        ClearLabels(PAGE_SEARCH, Full);
      end;
  end;
end;

procedure TfrmMain.FillAllBooksTree;
begin
  Assert(Assigned(FCollection));
  FLoadedBookViews := FLoadedBookViews -
    [AuthorsView, SeriesView, GenresView, FavoritesView, PublisherSeriesView];
  FPublisherListLoaded := False;
  EnsureActiveBookViewLoaded;
end;

function TfrmMain.CheckLibUpdates(Auto: Boolean): Boolean;
var
  i: Integer;
  UpdatesInfo: TUpdateInfoList;
  CollectionInfoIterator: ICollectionInfoIterator;
  CollectionInfo: TCollectionInfo;
  VersionDetails: string;
begin
  if not Auto then
    ShowPopup(rstrCheckingUpdates);

  Result := False;
  VersionDetails := '';

  UpdatesInfo := Settings.Updates;
  UpdatesInfo.URL := Settings.UpdateURL;

  // Local update packages can still be checked without a network server.
  if Settings.UpdateURL.Trim <> '' then UpdatesInfo.UpdateExternalVersions;

  CollectionInfoIterator := FSystemData.GetCollectionInfoIterator;
  while CollectionInfoIterator.Next(CollectionInfo) do
  begin
    for i := 0 to UpdatesInfo.Count - 1 do
      if UpdatesInfo[i].CheckCodes(CollectionInfo.DisplayName, CollectionInfo.CollectionType, CollectionInfo.ID) then
      begin
        if UpdatesInfo[i].ExternalVersion > 0 then
          VersionDetails := VersionDetails +
            Format(rstrVersionInfo, [CollectionInfo.DisplayName,
              UpdatesInfo[i].ExternalVersion, CollectionInfo.DataVersion]) + CRLF;

        if UpdatesInfo[i].CheckVersion(Settings.UpdatePath, CollectionInfo.DataVersion) then
        begin
          Result := True;
          Break;
        end;
      end;
  end;

  if not Auto then
  begin
    HidePopup;
    if not Result then
    begin
      if UpdatesInfo.ConnectionError then
        MHLShowWarning(Format(rstrUpdateConnectionError, [UpdatesInfo.URL]))
      else if VersionDetails <> '' then
        MHLShowInfo(rstrNoUpdatesAvailable + CRLF + CRLF + VersionDetails)
      else
        MHLShowInfo(rstrNoUpdatesAvailable);
    end;
  end;
end;

procedure TfrmMain.CheckUpdatesExecute(Sender: TObject);
begin
  if Assigned(Sender) then FAutoCheck := False;
  if Assigned(FProgramUpdateThread) then
    Exit;
  if Assigned(FProgramUpdateForm) then
  begin
    if not FProgramUpdateForm.StartCheckCycle(FAutoCheck) then Exit;
    FProgramUpdateForm.CheckComponents(FAutoCheck);
  end;
  Settings.ProgramUpdateLastCheckUTC := TTimeZone.Local.ToUniversalTime(Now);
  Settings.SaveSettings;
  EnsureBackgroundMessageWindow;
  FProgramUpdateThread := TProgramUpdateThread.Create(FBackgroundMessageWindow, CreateHTTPClientGlobal,
    PROGRAM_RELEASES_API, ProgramUpdateCache(Settings.AppPath));
  acHelpCheckUpdates.Enabled := False;
  FProgramUpdateThread.Start;
end;

procedure TfrmMain.ProgramUpdateChecked(var Message: TMessage);
var
  ReleaseInfo: TProgramRelease;
  Successful: Boolean;
  Comparison: Integer;
begin
  Message.Result := 0;
  if not Assigned(FProgramUpdateThread) then
    Exit;
  FProgramUpdateThread.WaitFor;
  Successful := FProgramUpdateThread.Successful;
  ReleaseInfo := FProgramUpdateThread.ReleaseInfo;
  FreeAndNil(FProgramUpdateThread);
  acHelpCheckUpdates.Enabled := True;
  FProgramUpdateForm.ApplicationChecked(ReleaseInfo, Successful, rstrProgramUpdateCheckFailed);
  FAutoCheck := False;
end;

procedure TfrmMain.tmrCheckUpdatesTimer(Sender: TObject);
begin
  if not frmMain.Active then
    Exit;

  tmrCheckUpdates.Enabled := False;
  StatusMessage := rstrCheckingUpdates;

  if Settings.CheckUpdate and not Assigned(FProgramUpdateThread) and
     ProgramUpdateDue(Settings.ProgramUpdateLastCheckUTC, TTimeZone.Local.ToUniversalTime(Now),
       Settings.ProgramUpdateMinutes) then
  begin
    FAutoCheck := True;
    CheckUpdatesExecute(nil);
  end;

  if Settings.CheckExternalLibUpdate then
    if CheckLibUpdates(True) then
      if Settings.AutoRunUpdate then
        StartLibUpdate
      else if MHLShowInfo(rstrCollectionUpdateAvailable, mbYesNo) = mrYes then
        StartLibUpdate;

  StatusMessage := rstrDownloadStateDone;
end;

procedure TfrmMain.ProgramUpdateSchedule(Sender: TObject);
begin
  if Settings.CheckUpdate and not Assigned(FProgramUpdateThread) and
     ProgramUpdateDue(Settings.ProgramUpdateLastCheckUTC, TTimeZone.Local.ToUniversalTime(Now),
       Settings.ProgramUpdateMinutes) then
  begin
    FLastNotifiedRelease := '';
    FAutoCheck := True;
    CheckUpdatesExecute(nil);
  end;
end;

procedure TfrmMain.RestartForProgramUpdate(Sender: TObject);
begin
  Close;
  if Assigned(FProgramUpdateForm) then FProgramUpdateForm.CancelInstallation;
end;

procedure TfrmMain.tmrSearchATimer(Sender: TObject);
var
  Button: TToolButton;
begin
  tmrSearchA.Enabled := False;
  FTimerDone := True;


  if FTimerDone then
  begin
    FTimerDone := False;

    Assert(Assigned(FLastLetterA));
    Button := GetFilterButton(FAuthorBars, edLocateAuthor.Text);

    if Assigned(Button) and (Button <> FLastLetterA) then
    begin
      InternalSetAuthorFilter(Button);
    end;
    LocateAuthor(edLocateAuthor.Text);
  end;
end;

procedure TfrmMain.edLocateAuthorChange(Sender: TObject);
begin
  if not tmrSearchA.Enabled then
  begin
    tmrSearchA.Enabled := True;
    FTimerDone := False;
  end;
end;


procedure TfrmMain.tmrSearchSTimer(Sender: TObject);
var
  Button: TToolButton;
begin
  tmrSearchS.Enabled := False;
  FTimerDone := True;


  if FTimerDone then
  begin
    Assert(Assigned(FLastLetterS));
    Button := GetFilterButton(FSerieBars, edLocateSeries.Text);
    if Assigned(Button) and (Button <> FLastLetterS) then
    begin
      InternalSetSeriesFilter(Button);
    end;

    LocateSeries(edLocateSeries.Text);
  end;
end;


procedure TfrmMain.tbtnAutoFBDClick(Sender: TObject);
var
  Tree: TBookTree;
  Node: PVirtualNode;
  Data: PBookRecord;
  frmConvert: TfrmConvertToFBD;
begin
  if (ActiveView = DownloadView) then
  begin
    MHLShowWarning(rstrNotFromDownloadsError);
    Exit;
  end;

  // Пакетный режим запускается с текущей книги и обходит всё дерево по кругу.
  GetActiveTree(Tree);
  Node := Tree.GetFirstSelected;
  Data := Tree.GetNodeData(Node);
  if not Assigned(Data) or (Data^.nodeType <> ntBookInfo) then
    Exit;

  if MHLShowWarning(rstrAutoFBDConfirmation, mbYesNo) <> mrYes then
    Exit;

  OnSetControlsStateHandler(False);
  try
    frmConvert := TfrmConvertToFBD.Create(Application);
    try
      frmConvert.OnGetBook := OnGetBookHandler;
      frmConvert.OnReadBook := OnReadBookHandler;
      frmConvert.OnSelectBook := OnSelectBookHandler;
      frmConvert.OnChangeBook2Zip := OnChangeBook2ZipHandler;

      frmConvert.AutoMode;
    finally
      frmConvert.Free;
    end;
  finally
    OnSetControlsStateHandler(True);
  end;
end;

procedure TfrmMain.tbtnWizardClick(Sender: TObject);
begin

end;


procedure TfrmMain.StartLibUpdate;
var ChangedCollections: TArray<Integer>;
begin
  if Assigned(FOPDSForm) then FOPDSForm.StopServer;
  unit_Utils.LibrusecUpdate(Settings.SystemFileName[sfUpdateLog], ChangedCollections);
  NotifyFavoriteCatalogChanged(ChangedCollections);
end;

function TfrmMain.GetShowStatusProgress: Boolean;
begin
  Result := FStatusProgressBar.Visible;
end;

procedure TfrmMain.SetShowStatusProgress(const Value: Boolean);
begin
  FStatusProgressBar.Visible := Value;
end;

function TfrmMain.GetStatusMessage: string;
begin
  Result := spStatus.Caption;
end;

procedure TfrmMain.SetStatusMessage(const Value: string);
begin
  spStatus.Caption := Value;
  if StatusBar.Visible then
    StatusBar.Repaint;
end;

function TfrmMain.GetStatusProgress: Integer;
begin
  Result := FStatusProgressBar.Position;
end;

procedure TfrmMain.SetStatusProgress(const Value: Integer);
begin
  if FStatusProgressBar.Position <> Value then
  begin
    FStatusProgressBar.Position := Value;
    if StatusBar.Visible and ShowStatusProgress then
      StatusBar.Repaint;
  end;
end;


function TfrmMain.LoadLastCollection: boolean;
var
  CollectionID: Integer;
begin
  Result := False;
  if FSystemData.HasCollections then
  begin
    CollectionID := FSystemData.FindFirstExistingCollectionID(Settings.ActiveCollection);
    if CollectionID < 0 then
    begin
      MHLShowError(rstrCollectionFileNotFound);
      Exit;
    end;
    // небольшой хак. Будет правильнее передавать ID коллекции в InitCollection
    Settings.ActiveCollection := CollectionID;
    Result := True;
  end;
end;

procedure TfrmMain.LoadPresets;
var
  PresetFile: string;
  preset: TSearchPreset;
begin
  FPresets := TSearchPresets.Create;
  PresetFile := Settings.SystemFileName[sfPresets];
  if TFile.Exists(PresetFile) then
  begin
    try
      FPresets.Load(PresetFile);

      for preset in FPresets do
        cbPresetName.Items.Add(preset.DisplayName);
    except
      on e: Exception do
        Application.ShowException(e);
    end;
  end;
end;

procedure TfrmMain.CreatePresetTransferMenu;
var PPI, ButtonWidth, Gap: Integer;
begin
  if Assigned(FPresetTransferMenu) then Exit;
  FPresetTransferMenu:=TPopupMenu.Create(Self); FPresetTransferMenu.Name:='SearchPresetTransferMenu';
  FPresetTransferMenu.OnPopup:=PresetTransferMenuPopup;
  FPresetImportItem:=TMenuItem.Create(Self); FPresetImportItem.Name:='miSearchPresetImport';
  FPresetImportItem.Caption:='Импорт пресетов…'; FPresetImportItem.OnClick:=ImportSearchPresetsClick;
  FPresetTransferMenu.Items.Add(FPresetImportItem);
  FPresetExportItem:=TMenuItem.Create(Self); FPresetExportItem.Name:='miSearchPresetExport';
  FPresetExportItem.Caption:='Экспорт выбранного пресета…'; FPresetExportItem.OnClick:=ExportSearchPresetsClick;
  FPresetTransferMenu.Items.Add(FPresetExportItem);
  FPresetExportAllItem:=TMenuItem.Create(Self); FPresetExportAllItem.Name:='miSearchPresetExportAll';
  FPresetExportAllItem.Caption:='Экспорт всех пресетов…'; FPresetExportAllItem.Tag:=1;
  FPresetExportAllItem.OnClick:=ExportSearchPresetsClick; FPresetTransferMenu.Items.Add(FPresetExportAllItem);
  PPI:=Max(96,cbPresetName.Font.PixelsPerInch); ButtonWidth:=MulDiv(24,PPI,96); Gap:=MulDiv(2,PPI,96);
  cbPresetName.Width:=Max(MulDiv(60,PPI,96),cbPresetName.Width-ButtonWidth-Gap);
  FPresetTransferButton:=TButton.Create(Self); FPresetTransferButton.Name:='btnSearchPresetTransfer';
  FPresetTransferButton.Parent:=cbPresetName.Parent; FPresetTransferButton.Caption:='⋮';
  FPresetTransferButton.SetBounds(cbPresetName.Left+cbPresetName.Width+Gap,btnSavePreset.Top,
    ButtonWidth,btnSavePreset.Height);
  FPresetTransferButton.Hint:='Импорт и экспорт пресетов поиска'; FPresetTransferButton.ShowHint:=True;
  FPresetTransferButton.OnClick:=PresetTransferMenuClick; cbPresetName.PopupMenu:=FPresetTransferMenu;
  PresetTransferMenuPopup(nil);
end;

procedure TfrmMain.PresetTransferMenuClick(Sender: TObject);
var At: TPoint;
begin
  At:=FPresetTransferButton.ClientToScreen(Point(0,FPresetTransferButton.Height));
  FPresetTransferMenu.Popup(At.X,At.Y);
end;

procedure TfrmMain.PresetTransferMenuPopup(Sender: TObject);
begin
  FPresetImportItem.Enabled:=not FFormBusy;
  FPresetExportItem.Enabled:=not FFormBusy and Assigned(FPresets) and (SearchPresetIndex(cbPresetName.Text)>=0);
  FPresetExportAllItem.Enabled:=not FFormBusy and Assigned(FPresets) and (FPresets.Count>0);
end;

function TfrmMain.ImportSearchPresetsFromFile(const FileName: string): Integer;
var Imported, Candidate, Previous: TSearchPresets; Source, Target: TSearchPreset;
  Names: TStringList; Field: TPair<string,string>; InternalFile, BeforeName, Name, BaseName, SourceStamp, TargetStamp: string;
  Suffix: Integer;

  function DiskStamp(const Path: string): string;
  begin
    if TFile.Exists(Path) then Result:=THashSHA2.GetHashStringFromFile(Path) else Result:='missing';
  end;

  function NameExists(const Value: string): Boolean;
  begin
    Result:=False;
    for var Existing in Candidate do
      if AnsiSameText(Trim(Existing.DisplayName),Trim(Value)) then Exit(True);
  end;

begin
  Result:=0; if not Assigned(FPresets) then Exit;
  InternalFile:=Settings.SystemFileName[sfPresets];
  if SameFileName(TPath.GetFullPath(FileName),TPath.GetFullPath(InternalFile)) then
    raise EArgumentException.Create('Это текущий файл пресетов. Для импорта выберите другой файл.');
  Imported:=TSearchPresets.Create; Candidate:=nil; Names:=TStringList.Create;
  try
    try
      SourceStamp:=DiskStamp(FileName); Imported.Load(FileName);
      if Imported.Count=0 then raise EArgumentException.Create('В файле нет пресетов поиска.');
      if DiskStamp(FileName)<>SourceStamp then raise EInOutError.Create('Файл импорта изменился. Повторите импорт.');
      TargetStamp:=DiskStamp(InternalFile);
      // Merge the latest complete disk snapshot, not a stale in-memory list.
      // A detected intervening file change aborts before publication.
      if TargetStamp='missing' then Candidate:=FPresets.Clone
      else begin Candidate:=TSearchPresets.Create; Candidate.Load(InternalFile); end;
      for Source in Imported do
      begin
        BaseName:=Trim(Source.DisplayName); Name:=BaseName; Suffix:=2;
        while NameExists(Name) do
        begin Name:=BaseName+' ('+IntToStr(Suffix)+')'; Inc(Suffix); end;
        Target:=Candidate.GetPreset(Name);
        for Field in Source do Target.AddOrSetValue(Field.Key,Field.Value);
        Inc(Result);
      end;
      for Source in Candidate do Names.Add(Source.DisplayName);
      if DiskStamp(InternalFile)<>TargetStamp then
        raise EInOutError.Create('Список пресетов изменился. Повторите импорт.');
      BeforeName:=cbPresetName.Text;
      Candidate.Save(InternalFile);
    except
      on E: Exception do raise EInOutError.Create('Не удалось импортировать пресеты. Прежние пресеты сохранены. '+E.Message);
    end;
    Previous:=FPresets; FPresets:=Candidate; Candidate:=nil; Previous.Free;
    cbPresetName.Items.BeginUpdate;
    try
      cbPresetName.Items.Assign(Names); cbPresetName.ItemIndex:=SearchPresetIndex(BeforeName); cbPresetName.Text:=BeforeName;
    finally cbPresetName.Items.EndUpdate; end;
    PresetTransferMenuPopup(nil);
  finally Names.Free; Candidate.Free; Imported.Free; end;
end;

function TfrmMain.CreatePresetExportSnapshot(AllPresets: Boolean): TSearchPresets;
var Index: Integer; Source, Target: TSearchPreset; Field: TPair<string,string>;
begin
  if not Assigned(FPresets) or (FPresets.Count=0) then raise EArgumentException.Create('Нет сохранённых пресетов.');
  if AllPresets then Exit(FPresets.Clone);
  Index:=SearchPresetIndex(cbPresetName.Text);
  if Index<0 then raise EArgumentException.Create('Выберите сохранённый пресет.');
  Source:=FPresets.GetPreset(cbPresetName.Items[Index]); Result:=TSearchPresets.Create;
  try
    Target:=Result.GetPreset(Source.DisplayName);
    for Field in Source do Target.AddOrSetValue(Field.Key,Field.Value);
  except Result.Free; raise; end;
end;

procedure TfrmMain.SavePresetExportSnapshot(const FileName: string; Snapshot: TSearchPresets);
begin
  if SameFileName(TPath.GetFullPath(FileName),TPath.GetFullPath(Settings.SystemFileName[sfPresets])) then
    raise EArgumentException.Create('Экспорт не заменяет текущий файл пресетов. Выберите другое имя файла.');
  try Snapshot.Save(FileName);
  except on E: Exception do raise EInOutError.Create('Не удалось экспортировать пресеты. '+E.Message); end;
end;

procedure TfrmMain.ExportSearchPresetsToFile(const FileName: string; AllPresets: Boolean);
var Snapshot: TSearchPresets;
begin
  Snapshot:=CreatePresetExportSnapshot(AllPresets);
  try SavePresetExportSnapshot(FileName,Snapshot); finally Snapshot.Free; end;
end;

procedure TfrmMain.ImportSearchPresetsClick(Sender: TObject);
var Dialog: TOpenDialog; Count: Integer;
begin
  Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Title:='Импорт пресетов поиска'; Dialog.DefaultExt:='xml'; Dialog.InitialDir:=Settings.WorkPath;
    Dialog.Filter:='Пресеты поиска XML (*.xml)|*.xml|Пресеты прежних версий (*.cxml2;*.cxml)|*.cxml2;*.cxml';
    Dialog.Options:=[ofFileMustExist,ofPathMustExist,ofHideReadOnly,ofEnableSizing];
    if not Dialog.Execute then Exit;
    Count:=ImportSearchPresetsFromFile(Dialog.FileName);
    StatusMessage:=Format('Добавлено пресетов: %d. Выберите пресет в списке и нажмите «Применить».',[Count]);
  finally Dialog.Free; end;
end;

procedure TfrmMain.ExportSearchPresetsClick(Sender: TObject);
var Dialog: TSaveDialog; Snapshot: TSearchPresets;
begin
  // Snapshot before opening the file picker: later selection changes must not
  // export another preset or unsaved search fields under the chosen filename.
  Snapshot:=CreatePresetExportSnapshot(TMenuItem(Sender).Tag=1);
  try
    Dialog:=TSaveDialog.Create(Self);
    try
      Dialog.Title:='Экспорт пресетов поиска'; Dialog.DefaultExt:='xml'; Dialog.InitialDir:=Settings.WorkPath;
      Dialog.Filter:='Пресеты поиска XML (*.xml)|*.xml'; Dialog.FileName:='Пресеты поиска.xml';
      Dialog.Options:=[ofOverwritePrompt,ofPathMustExist,ofHideReadOnly,ofEnableSizing];
      if not Dialog.Execute then Exit;
      SavePresetExportSnapshot(Dialog.FileName,Snapshot); StatusMessage:='Пресеты экспортированы.';
    finally Dialog.Free; end;
  finally Snapshot.Free; end;
end;

procedure TfrmMain.ConnectTreeControllers;
begin
  FController := TTreeController.Create(FSystemData);

  FController.ConnectAuthorsTree(tvAuthors);
  FController.ConnectSeriesTree(tvSeries);
  FController.ConnectGenresTree(tvGenres);
  FController.ConnectGroupsTree(tvGroups);

  FController.ConnectBooksTree(tvBooksA);
  FController.ConnectBooksTree(tvBooksS);
  FController.ConnectSeriesTree(FPublisher.SeriesTree);
  FController.ConnectBooksTree(FPublisher.Books);
  FController.ConnectBooksTree(tvBooksG);
  FController.ConnectBooksTree(tvBooksSR);
  FController.ConnectBooksTree(tvBooksF);

  FController.ConnectDownloadTree(tvDownloadList);

end;

procedure TfrmMain.CreatePublisherSearchField;
var
  Body: TWinControl;
  Ordered: TArray<TControl>;
  Control: TControl;
  Position: Integer;
  TranslatorsLabel, CityLabel, YearLabel, ISBNLabel: TLabel;
  procedure AddField(const Name, Caption, Hint: string; out Edit: TMHLButtonedEdit; out LabelControl: TLabel);
  begin
    LabelControl:=TLabel.Create(Self); LabelControl.Name:='lblSearch'+Name;
    LabelControl.Parent:=Body; LabelControl.Caption:=Caption; LabelControl.Font.Assign(Label6.Font);
    LabelControl.AutoSize:=True; LabelControl.Margins.Assign(Label6.Margins);
    LabelControl.AlignWithMargins:=True; LabelControl.Align:=alTop;
    Edit:=TMHLButtonedEdit.Create(Self); Edit.Name:='edF'+Name; Edit.Parent:=Body; Edit.Text:='';
    Edit.Font.Assign(edFSeries.Font); Edit.Height:=edFSeries.Height; Edit.Margins.Assign(edFSeries.Margins);
    Edit.AlignWithMargins:=True; Edit.Align:=alTop; Edit.ShowHint:=True; Edit.Hint:=Hint;
    Edit.OnKeyDown:=PresetFieldKeyDown; Edit.OnRightButtonClick:=ShowExpressionEditor;
    LabelControl.FocusControl:=Edit;
  end;
begin
  Body:=edFSeries.Parent; Body.DisableAlign;
  try
    AddField('Publisher','Издательство',
      'Поиск по издательству, сохранённому в каталоге. Если INPX не содержит этих сведений, файлы книг автоматически не просматриваются.',
      FPublisherSearchEdit,FPublisherSearchLabel);
    AddField('Translators','Переводчики','Имя переводчика из сведений каталога.',FTranslatorSearchEdit,TranslatorsLabel);
    AddField('City','Город издания','Город издания из сведений каталога.',FCitySearchEdit,CityLabel);
    AddField('PubYear','Год издания','Например: 2020 или >= 2010 AND <= 2025. Это год издания, а не дата добавления.',FPubYearSearchEdit,YearLabel);
    AddField('ISBN','ISBN','Полный ISBN или его часть. Пробелы и дефисы можно не вводить.',FISBNSearchEdit,ISBNLabel);
    FNotesOnlySearchCheck:=TCheckBox.Create(Self); FNotesOnlySearchCheck.Name:='cbSearchWithNotes';
    FNotesOnlySearchCheck.Parent:=Body; FNotesOnlySearchCheck.Caption:='Книги с заметками';
    FNotesOnlySearchCheck.Font.Assign(cbCollapseMultiSeriesResults.Font);
    FNotesOnlySearchCheck.Height:=cbCollapseMultiSeriesResults.Height;
    FNotesOnlySearchCheck.AlignWithMargins:=True; FNotesOnlySearchCheck.Margins.Assign(cbCollapseMultiSeriesResults.Margins);
    FNotesOnlySearchCheck.Align:=alTop;
    Ordered:=TArray<TControl>.Create(Label5,edFFullName,Label24,edFTitle,
      cbCollapseMultiSeriesResults,FNotesOnlySearchCheck,Label6,edFSeries,FPublisherSearchLabel,FPublisherSearchEdit,
      TranslatorsLabel,FTranslatorSearchEdit,CityLabel,FCitySearchEdit,YearLabel,FPubYearSearchEdit,
      ISBNLabel,FISBNSearchEdit,Label26,edFGenre,Label3,edFKeyWords,Label7,edFAnnotation);
    Position:=Body.Padding.Top;
    for Control in Ordered do
    begin
      Control.Top:=Position; Inc(Position,Control.Height);
      if Control.AlignWithMargins then Inc(Position,Control.Margins.Top+Control.Margins.Bottom);
    end;
    FPublisherSearchEdit.TabOrder:=edFSeries.TabOrder+1;
    FTranslatorSearchEdit.TabOrder:=FPublisherSearchEdit.TabOrder+1;
    FCitySearchEdit.TabOrder:=FTranslatorSearchEdit.TabOrder+1;
    FPubYearSearchEdit.TabOrder:=FCitySearchEdit.TabOrder+1;
    FISBNSearchEdit.TabOrder:=FPubYearSearchEdit.TabOrder+1;
    edFGenre.TabOrder:=FISBNSearchEdit.TabOrder+1;
    edFKeyWords.TabOrder:=edFGenre.TabOrder+1; edFAnnotation.TabOrder:=edFKeyWords.TabOrder+1;
  finally Body.EnableAlign; end;
  ctpBook.OnExpand:=SearchBookExpanded; UpdateSearchBookLayout;
end;

procedure TfrmMain.CreateSearchPanelAdapter;
begin
  FSearchMode := TSearchQueryModeControl.CreateFor(Self, pnSearchView);
  // Keep fresh keyboard input in Author; the mode remains in the Tab sequence.
  SearchParams.TabOrder := 0;
  FSearchMode.TabOrder := 1;
  pnSearchControl.TabOrder := 2;
  FSearchFields := Default(TBookSearchControls);
  FSearchFields.Author := edFFullName;
  FSearchFields.Series := edFSeries;
  FSearchFields.Publisher := FPublisherSearchEdit;
  FSearchFields.Translators := FTranslatorSearchEdit;
  FSearchFields.City := FCitySearchEdit;
  FSearchFields.PubYear := FPubYearSearchEdit;
  FSearchFields.ISBN := FISBNSearchEdit;
  FSearchFields.Annotation := edFAnnotation;
  FSearchFields.Genre := edFGenre;
  FSearchFields.Title := edFTitle;
  FSearchFields.FileName := edFFile;
  FSearchFields.Folder := edFFolder;
  FSearchFields.FileExt := edFExt;
  FSearchFields.Keyword := edFKeyWords;
  FSearchFields.Language := cbLang;
  FSearchFields.Downloaded := cbDownloaded;
  FSearchFields.LibRate := cbLibRate;
  FSearchFields.AddedDate := cbDate;
  FSearchFields.FavoriteAuthors := FSearchFavoriteCheck;
  FSearchFields.NotesOnly := FNotesOnlySearchCheck;
  FSearchFields.Readed := cbReaded;
  FSearchFields.CollapseSeries := cbCollapseMultiSeriesResults;
end;

procedure TfrmMain.UpdateSearchBookLayout;
var
  Body: TWinControl;
  Control: TControl;
  NeededHeight: Integer;
begin
  if FUpdatingSearchLayout or not Assigned(FPublisherSearchEdit) or
    not Assigned(ctpBook) or ctpBook.Collapsed then Exit;
  FUpdatingSearchLayout := True;
  try
    Body := edFAnnotation.Parent;
    ctpBook.Realign;
    Body.Realign;
    NeededHeight := Body.Padding.Top + Body.Padding.Bottom +
      Max(0, ctpBook.Height - Body.ClientHeight);
    for var I := 0 to Body.ControlCount - 1 do
    begin
      Control := Body.Controls[I];
      if Control.Visible and (Control.Align = alTop) then
      begin
        Inc(NeededHeight, Control.Height);
        if Control.AlignWithMargins then
          Inc(NeededHeight, Control.Margins.Top + Control.Margins.Bottom);
      end;
    end;
    if ctpBook.Height <> NeededHeight then ctpBook.Height := NeededHeight;
  finally FUpdatingSearchLayout := False; end;
end;

procedure TfrmMain.SearchBookExpanded(Sender: TObject);
begin
  UpdateSearchBookLayout;
end;

procedure TfrmMain.InitFormFileds;
begin
  Application.OnHelp := OnHelpHandler;
  UseLatestCommonDialogs := True;

  // Follow the visual order when VCL selects the first Search control.
  // The inherited reverse tab order focused Date and scrolled Author offscreen.
  ctpBook.TabOrder := 0;
  ctpFile.TabOrder := 1;
  ctpOther.TabOrder := 2;

  FSelectionState := False;
  FAutoCheck := False;
  FFormBusy := False;

  FFileOpMode := fmFb2Zip;

  FMainBars[0] := tlbrMain;
  FMainBars[1] := tlbrEdit;

  FAuthorBars[0] := tbarAuthorsRus;
  FAuthorBars[1] := tbarAuthorsEng;

  FSerieBars[0] := tbarSeriesRus;
  FSerieBars[1] := tbarSeriesEng;

  CreateAlphabetToolbar;

  FLastLetterA := tbarAuthorsRus.Buttons[0];
  FLastLetterS := tbarSeriesRus.Buttons[0];

  FLastAuthorID := MHL_INVALID_ID;
  FLastAuthorBookID.Clear;

  FLastSeriesID := MHL_INVALID_ID;
  FLastSeriesBookID.Clear;

  FLastGenreCode := '';
  FLastGenreIsContainer := False;
  FLastGenreIsTopLevelContainer := False;
  FRootGenreBooksRequested := False;
  FLastGenreBookID.Clear;

  FLastGroupID := MHL_INVALID_ID;
  FLastGroupBookID.Clear;

  FStatusProgressBar := TProgressBar.Create(Self);
  FStatusProgressBar.Parent := StatusBar;
  FStatusProgressBar.Visible := False;
  FStatusProgressBar.SetBounds(0, 0, 150, StatusBar.Height);
  FBookListCancel := TButton.Create(Self);
  FBookListCancel.Name := 'BookListCancel';
  FBookListCancel.Parent := StatusBar;
  FBookListCancel.SetBounds(152, 0, 26, StatusBar.Height);
  FBookListCancel.Caption := '×';
  FBookListCancel.Hint := 'Остановить загрузку списка';
  FBookListCancel.ShowHint := True;
  FBookListCancel.Visible := False;
  FBookListCancel.OnClick := CancelBookList;
  StatusMessage := '';
  ShowStatusProgress := False;
  StatusProgress := 0;

  spInfo.Caption := unit_MHLHelpers.GetFileVersion(Application.ExeName);
end;

procedure TfrmMain.UpdateSplashScreen(const AStatus: string);
begin
  frmSplash.SetStatus(AStatus);
end;

procedure TfrmMain.LoadDownloadsList;
var
  FileName: string; Attributes, Code: DWORD; Node: PVirtualNode; Data: PDownloadData;
begin
  FDownloadsReady := False;
  FileName := Settings.SystemFileName[sfDownloadsStore];
  try
    Attributes := GetFileAttributes(PChar(FileName));
    if Attributes = INVALID_FILE_ATTRIBUTES then
    begin
      Code := GetLastError;
      if (Code <> ERROR_FILE_NOT_FOUND) and (Code <> ERROR_PATH_NOT_FOUND) then RaiseLastOSError(Code);
    end
    else
    begin
      tvDownloadList.LoadFromFile(FileName);
      // A zero UserChunk skips VT's load callback. Reject uninitialized nodes
      // after the entire tree loads, while retaining stale negative book keys.
      Node := tvDownloadList.GetFirst;
      while Assigned(Node) do
      begin
        Data := tvDownloadList.GetNodeData(Node);
        if not Assigned(Data) or (Data^.BookKey.DatabaseID <= 0) or (Data^.BookKey.BookID = 0) then
          raise EReadError.Create('В очереди загрузок найдена неполная запись книги.');
        Node := tvDownloadList.GetNext(Node);
      end;
    end;
    UpdateDownloadCount;
    FDownloadsLoadFailed := False;
    FDownloadsReady := True;
  except
    on E: Exception do
    begin
      // Failed startup or partial VT loads never replace the source queue file.
      FDownloadsLoadFailed := True;
      FDownloadNode := nil;
      tvDownloadList.Clear;
      UpdateDownloadCount;
      BtnSave.Enabled := False;
      SetDownloadRunning(False);
      MHLShowError('Не удалось восстановить очередь загрузок. Файл сохранён без изменений: ' +
        FileName + sLineBreak + 'Автозапуск и сохранение очереди отключены на этот сеанс.' +
        sLineBreak + E.Message);
      Exit;
    end;
  end;

  // This is a session guard, not a change to the user's persistent preference.
  if Settings.AutoStartDwnld then
    btnStartDownloadClick(frmMain);
end;

procedure TfrmMain.SaveDownloadsList;
var Stream: TMemoryStream;
begin
  if not FDownloadsReady or FDownloadsLoadFailed then Exit;
  Stream := TMemoryStream.Create;
  try
    // The serializer completes before any adjacent temporary or target exists.
    // Errors retain both the old disk file and this session's queue for retry.
    tvDownloadList.SaveToStream(Stream);
    SaveStreamAtomically(Stream, Settings.SystemFileName[sfDownloadsStore]);
  finally Stream.Free; end;
end;

procedure TfrmMain.ClearDataFolder;
begin
  if (ParamCount > 0) and (ParamStr(1) = '/clear') then
    ClearDir(Settings.DataDir);
end;

procedure TfrmMain.ShowOPDS(Sender: TObject);
begin
  if not Assigned(FCollection) then
  begin
    MessageDlg('Сначала выберите коллекцию для каталога читалки.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if not Assigned(FOPDSForm) then FOPDSForm := TfrmOPDS.Create(Self);
  FOPDSForm.SetCollection(FSystemData.GetCollectionInfo(FCollection.CollectionID));
  FOPDSForm.Show;
  FOPDSForm.BringToFront;
end;

procedure TfrmMain.ShowCatalogSources(Sender: TObject);
var Dialog: TfrmCatalogSources; Changed, MetadataChanged: Boolean; CollectionID: Integer;
begin
  if not Assigned(FCollection) then Exit;
  if isOnlineCollection(FCollection.CollectionCode) then
  begin
    Application.MessageBox('Источники и объединение доступны для локальных коллекций.', 'HomeLib Ru', MB_OK or MB_ICONINFORMATION);
    Exit;
  end;
  CollectionID:=FCollection.CollectionID;
  Dialog := TfrmCatalogSources.CreateForCollection(Self,FCollection);
  try Dialog.ShowModal; Changed := Dialog.CatalogChanged; MetadataChanged:=Dialog.MetadataChanged;
  finally Dialog.Free; end;
  if Changed then
  begin
    NotifyFavoriteCatalogChanged(TArray<Integer>.Create(FCollection.CollectionID));
    FCollection := FSystemData.GetCollection(Settings.ActiveCollection,True);
    InitCollection;
  end
  else if MetadataChanged then RefreshBookMetadataViews(CollectionID);
end;

procedure TfrmMain.UpdateThemeToolbar;
var I, ButtonBottom, DesiredHeight: Integer;
begin
  if Assigned(tlbrMain) and tlbrMain.HandleAllocated then
  begin
    // Native image/style scaling can make a button taller than the scaled
    // designed row. Preserve the base row while fitting its actual buttons.
    ButtonBottom := 0;
    for I := 0 to tlbrMain.ButtonCount - 1 do
      if tlbrMain.Buttons[I].Visible then
        ButtonBottom := Max(ButtonBottom, tlbrMain.Buttons[I].BoundsRect.Bottom);
    DesiredHeight := Max(MulDiv(44, tlbrMain.CurrentPPI, 96),
      ButtonBottom + tlbrMain.Height - tlbrMain.ClientHeight);
    if tlbrMain.Height <> DesiredHeight then tlbrMain.Height := DesiredHeight;
  end;
  if not Assigned(FThemeToolbar) then Exit;
  FThemeToolbar.SetBounds(ClientWidth-FThemeToolbar.Width-MulDiv(3,CurrentPPI,96),
    tlbrMain.Top,FThemeToolbar.Width,tlbrMain.Height);
  FThemeToolbar.Visible:=tlbrMain.Visible;
  FThemeToolbar.BringToFront;
end;

procedure TfrmMain.Resize;
begin
  inherited;
  UpdateThemeToolbar;
  UpdateSearchBookLayout;
  UpdateFavoriteSearchLayout;
end;

procedure TfrmMain.ChangeScale(M, D: Integer; IsDpiChange: Boolean);
var WasUpdating: Boolean;
begin
  // Resize can run before VCL has scaled the child labels and edits. Keep
  // their category height intact until this complete scaling pass finishes.
  WasUpdating := FUpdatingSearchLayout;
  FUpdatingSearchLayout := True;
  try inherited ChangeScale(M, D, IsDpiChange);
  finally FUpdatingSearchLayout := WasUpdating; end;
  if not WasUpdating then
  begin
    UpdateSearchBookLayout;
    UpdateFavoriteSearchLayout;
    UpdateWindowsThemeOfferLayout;
  end;
end;

procedure TfrmMain.ScaleForPPI(NewPPI: Integer);
var WasUpdating: Boolean;
begin
  // Explicit ScaleForPPI also restores anchors/fonts after ChangeScale.
  // Measure the final controls once, as with a monitor DPI transition.
  WasUpdating := FUpdatingSearchLayout;
  FUpdatingSearchLayout := True;
  try inherited ScaleForPPI(NewPPI);
  finally FUpdatingSearchLayout := WasUpdating; end;
  if not WasUpdating then
  begin
    UpdateSearchBookLayout;
    UpdateFavoriteSearchLayout;
    UpdateWindowsThemeOfferLayout;
  end;
end;

procedure TfrmMain.UpdateWindowsThemeOfferLayout;
var PPI, Padding, Gap, AvailableWidth, TextWidth, ApplyWidth, DismissWidth,
  ButtonHeight, RowHeight, ContentWidth: Integer; TextBounds: TRect;
begin
  if FUpdatingSearchLayout or FUpdatingWindowsThemeOfferLayout or
    not Assigned(FWindowsThemeOfferText) then Exit;
  FUpdatingWindowsThemeOfferLayout:=True;
  try
    // Explicit VCL scaling updates the final child font before the monitor PPI.
    PPI:=FWindowsThemeOfferText.Font.PixelsPerInch;
    Padding:=MulDiv(12,PPI,96); Gap:=MulDiv(8,PPI,96);
    AvailableWidth:=Max(1,FWindowsThemeOffer.ClientWidth-2*Padding);
    FWindowsThemeOfferText.Canvas.Font.Assign(FWindowsThemeOfferText.Font);
    ApplyWidth:=Max(MulDiv(144,PPI,96),
      FWindowsThemeOfferText.Canvas.TextWidth(FWindowsThemeOfferApply.Caption)+2*Padding);
    DismissWidth:=MulDiv(32,PPI,96);
    ButtonHeight:=Max(MulDiv(30,PPI,96),
      FWindowsThemeOfferText.Canvas.TextHeight('Mg')+MulDiv(12,PPI,96));
    TextWidth:=Min(FWindowsThemeOfferText.Canvas.TextWidth(FWindowsThemeOfferText.Caption),
      Max(1,AvailableWidth-ApplyWidth-DismissWidth-2*Gap));
    TextBounds:=Rect(0,0,TextWidth,0);
    DrawText(FWindowsThemeOfferText.Canvas.Handle,PChar(FWindowsThemeOfferText.Caption),-1,
      TextBounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    RowHeight:=Max(ButtonHeight,TextBounds.Height);
    ContentWidth:=TextWidth+ApplyWidth+DismissWidth+2*Gap;
    FWindowsThemeOffer.Height:=Max(MulDiv(42,PPI,96),RowHeight+2*Gap);
    FWindowsThemeOfferContent.SetBounds(FWindowsThemeOffer.ClientWidth-Padding-ContentWidth,
      (FWindowsThemeOffer.ClientHeight-RowHeight) div 2,ContentWidth,RowHeight);
    FWindowsThemeOfferText.SetBounds(0,0,TextWidth,RowHeight);
    FWindowsThemeOfferApply.SetBounds(TextWidth+Gap,(RowHeight-ButtonHeight) div 2,ApplyWidth,ButtonHeight);
    FWindowsThemeOfferDismiss.SetBounds(TextWidth+Gap+ApplyWidth+Gap,
      (RowHeight-ButtonHeight) div 2,DismissWidth,ButtonHeight);
  finally FUpdatingWindowsThemeOfferLayout:=False; end;
end;

procedure TfrmMain.WindowsThemeOfferResize(Sender: TObject);
begin
  UpdateWindowsThemeOfferLayout;
end;

procedure TfrmMain.UpdateWindowsThemeOffer(WindowsDark: Boolean);
begin
  if not WindowsDark then Settings.WindowsDarkThemeOfferDismissed:=False;
  if not MHLShouldOfferWindowsDarkTheme(WindowsDark,Settings.DarkTheme,Settings.WindowsDarkThemeOfferDismissed) then
  begin
    if Assigned(FWindowsThemeOffer) then FWindowsThemeOffer.Visible:=False;
    Exit;
  end;
  if not Assigned(FWindowsThemeOffer) then
  begin
    FWindowsThemeOffer:=TPanel.Create(Self); FWindowsThemeOffer.Name:='pnWindowsThemeOffer';
    FWindowsThemeOffer.Parent:=Self; FWindowsThemeOffer.BevelOuter:=bvNone; FWindowsThemeOffer.Caption:='';
    FWindowsThemeOffer.Height:=MulDiv(42,CurrentPPI,96);
    FWindowsThemeOffer.Top:=tlbrMain.BoundsRect.Bottom+1; FWindowsThemeOffer.Align:=alTop;
    FWindowsThemeOffer.OnResize:=WindowsThemeOfferResize;
    FWindowsThemeOfferContent:=TPanel.Create(Self);
    FWindowsThemeOfferContent.Name:='pnWindowsThemeOfferContent';
    FWindowsThemeOfferContent.Parent:=FWindowsThemeOffer;
    FWindowsThemeOfferContent.BevelOuter:=bvNone; FWindowsThemeOfferContent.Caption:='';
    FWindowsThemeOfferDismiss:=TButton.Create(Self);
    FWindowsThemeOfferDismiss.Parent:=FWindowsThemeOfferContent;
    FWindowsThemeOfferDismiss.Name:='btnDismissWindowsTheme'; FWindowsThemeOfferDismiss.Caption:='×';
    FWindowsThemeOfferDismiss.Hint:='Больше не предлагать для текущей темы Windows';
    FWindowsThemeOfferDismiss.ShowHint:=True; FWindowsThemeOfferDismiss.OnClick:=WindowsThemeOfferDismiss;
    FWindowsThemeOfferApply:=TButton.Create(Self); FWindowsThemeOfferApply.Parent:=FWindowsThemeOfferContent;
    FWindowsThemeOfferApply.Name:='btnApplyWindowsTheme'; FWindowsThemeOfferApply.Caption:='Включить тёмную тему';
    FWindowsThemeOfferApply.OnClick:=WindowsThemeOfferAccept;
    FWindowsThemeOfferText:=TLabel.Create(Self); FWindowsThemeOfferText.Parent:=FWindowsThemeOfferContent;
    FWindowsThemeOfferText.Name:='lblWindowsThemeOffer'; FWindowsThemeOfferText.AutoSize:=False;
    FWindowsThemeOfferText.Layout:=tlCenter; FWindowsThemeOfferText.WordWrap:=True;
    FWindowsThemeOfferText.ShowAccelChar:=False;
    FWindowsThemeOfferText.Caption:='В Windows выбрана тёмная тема. Включить её и в HomeLib Ru?';
  end;
  UpdateWindowsThemeOfferLayout;
  FWindowsThemeOffer.Visible:=True;
end;

procedure TfrmMain.WindowsThemeOfferAccept(Sender: TObject);
begin
  if not Settings.DarkTheme then ToggleApplicationTheme(Sender);
end;

procedure TfrmMain.WindowsThemeOfferDismiss(Sender: TObject);
begin
  Settings.WindowsDarkThemeOfferDismissed:=True;
  if Assigned(FWindowsThemeOffer) then FWindowsThemeOffer.Visible:=False;
  Settings.SaveSettings;
end;

procedure TfrmMain.WMSettingChange(var Message: TMessage);
var WindowsDark: Boolean;
begin
  inherited;
  if Assigned(FThemeButton) and TryMHLWindowsDarkTheme(WindowsDark) then
    UpdateWindowsThemeOffer(WindowsDark);
end;

procedure TfrmMain.ToggleApplicationTheme(Sender: TObject);
var WindowsDark: Boolean;
begin
  SetMHLTheme(not Settings.DarkTheme);
  Settings.DarkTheme:=MHLThemeDark;
  if TryMHLWindowsDarkTheme(WindowsDark) and WindowsDark then
    Settings.WindowsDarkThemeOfferDismissed:=True;
  if Assigned(FWindowsThemeOffer) then FWindowsThemeOffer.Visible:=False;
  if Settings.DarkTheme then FThemeButton.Hint:='Переключить на светлую тему'
  else FThemeButton.Hint:='Переключить на тёмную тему';
  dmImages.ApplyThemeIcons;
  UpdateThemeToolbar;
  if not Settings.DarkTheme then SetColors;
  Settings.SaveSettings;
end;

procedure TfrmMain.FormCreate(Sender: TObject);
var
  OPDSMenu, FilterMenu: TMenuItem;
  WindowsDark: Boolean;
  I: Integer;
begin
  OnShortCut := FormShortCut;
  FSystemData := SystemDB;
  OPDSMenu := TMenuItem.Create(Self);
  OPDSMenu.Caption := 'Каталог для читалки (OPDS)...';
  OPDSMenu.OnClick := ShowOPDS;
  miTools.Insert(0, OPDSMenu);
  FReadBuiltinAction := TAction.Create(Self);
  FReadBuiltinAction.Name := 'acReadBuiltin';
  FReadBuiltinAction.ActionList := Actions;
  FReadBuiltinAction.Caption := 'Читать во встроенной читалке (тестовая)';
  FReadBuiltinAction.ShortCut := ShortCut(Ord('R'), [ssCtrl, ssAlt]);
  FReadBuiltinAction.ImageIndex := 12;
  FReadBuiltinAction.OnExecute := ReadBuiltinExecute;
  FReadBuiltinAction.OnUpdate := ReadBuiltinUpdate;
  acToolsClearReadFolder.OnUpdate := BookCacheActionUpdate;
  FilterMenu := TMenuItem.Create(Self);
  FilterMenu.Action := FReadBuiltinAction;
  miBook.Insert(0, FilterMenu);
  FilterMenu := TMenuItem.Create(Self);
  FilterMenu.Action := FReadBuiltinAction;
  pmiReadBook.Parent.Insert(pmiReadBook.MenuIndex, FilterMenu);
  // Double-click/Enter retain their configured reader, but the menus offer
  // exactly two explicit destinations, with the built-in reader first.
  pmiReadBook.Visible := False;
  miRead.Visible := False;
  FOpenArchiveAction := TAction.Create(Self);
  FOpenArchiveAction.Name := 'acOpenBookArchive'; FOpenArchiveAction.ActionList := Actions;
  FOpenArchiveAction.Caption := 'Посмотреть содержимое архива'; FOpenArchiveAction.ImageIndex := 19;
  FOpenArchiveAction.OnExecute := OpenArchiveExecute; FOpenArchiveAction.OnUpdate := OpenArchiveUpdate;
  FilterMenu := TMenuItem.Create(Self); FilterMenu.Action := FOpenArchiveAction;
  pmiReadBook.Parent.Insert(pmiReadBook.MenuIndex+2,FilterMenu);
  FilterMenu := TMenuItem.Create(Self); FilterMenu.Action := FOpenArchiveAction; miBook.Insert(1,FilterMenu);
  FLocationAction:=TAction.Create(Self); FLocationAction.Name:='acBookLocation'; FLocationAction.ActionList:=Actions;
  FLocationAction.Caption:='Где хранится книга…'; FLocationAction.OnExecute:=BookLocationExecute; FLocationAction.OnUpdate:=BookLocationUpdate;
  FilterMenu:=TMenuItem.Create(Self); FilterMenu.Action:=FLocationAction; miBook.Insert(2,FilterMenu);
  FilterMenu:=TMenuItem.Create(Self); FilterMenu.Action:=FLocationAction; pmiReadBook.Parent.Insert(pmiReadBook.MenuIndex+3,FilterMenu);
  FChooseReaderAction:=TAction.Create(Self); FChooseReaderAction.Name:='acChooseReader'; FChooseReaderAction.ActionList:=Actions;
  FChooseReaderAction.Caption:='Выбрать читалку…'; FChooseReaderAction.OnExecute:=ChooseReaderExecute; FChooseReaderAction.OnUpdate:=BookLocationUpdate;
  FilterMenu:=TMenuItem.Create(Self); FilterMenu.Action:=FChooseReaderAction; miBook.Insert(3,FilterMenu);
  FilterMenu:=TMenuItem.Create(Self); FilterMenu.Action:=FChooseReaderAction; pmiReadBook.Parent.Insert(pmiReadBook.MenuIndex+4,FilterMenu);
  FReadExternalAction:=TAction.Create(Self); FReadExternalAction.Name:='acReadExternal';
  FReadExternalAction.ActionList:=Actions; FReadExternalAction.Caption:='Читать во внешней программе';
  FReadExternalAction.OnExecute:=ReadExternalExecute; FReadExternalAction.OnUpdate:=BookLocationUpdate;
  FilterMenu:=TMenuItem.Create(Self); FilterMenu.Action:=FReadExternalAction; miBook.Insert(1,FilterMenu);
  FilterMenu:=TMenuItem.Create(Self); FilterMenu.Action:=FReadExternalAction;
  pmiReadBook.Parent.Insert(pmiReadBook.MenuIndex+1,FilterMenu);
  for I := 0 to 1 do
  begin
    FilterMenu := TMenuItem.Create(Self);
    FilterMenu.Caption := 'Фильтры столбцов...';
    FilterMenu.OnClick := ShowBookColumnFilters;
    if I = 0 then pmHeaders.Items.Add(FilterMenu) else miView.Add(FilterMenu);
    FilterMenu := TMenuItem.Create(Self);
    FilterMenu.Caption := 'Сбросить фильтры столбцов';
    FilterMenu.Tag := 1;
    FilterMenu.OnClick := ShowBookColumnFilters;
    if I = 0 then pmHeaders.Items.Add(FilterMenu) else miView.Add(FilterMenu);
  end;

  FilterMenu := TMenuItem.Create(Self); FilterMenu.Caption := 'Сбросить сортировку';
  FilterMenu.OnClick := ClearBookSorting; pmHeaders.Items.Add(FilterMenu);
  FilterMenu := TMenuItem.Create(Self); FilterMenu.Caption := 'Shift + щелчок: добавить 2-й или 3-й столбец';
  FilterMenu.Enabled := False; pmHeaders.Items.Add(FilterMenu);
  FilterMenu := TMenuItem.Create(Self); FilterMenu.Caption := 'Книжная серия';
  FilterMenu.Tag := COL_PUBLISHER_SERIES; FilterMenu.OnClick := HeaderPopupItemClick;
  pmHeaders.Items.Add(FilterMenu);
  FilterMenu := TMenuItem.Create(Self);
  FilterMenu.Name := 'miColumnPublisher'; FilterMenu.Caption := 'Издательство';
  FilterMenu.Tag := COL_PUBLISHER; FilterMenu.OnClick := HeaderPopupItemClick;
  pmHeaders.Items.Add(FilterMenu);
  FilterMenu := TMenuItem.Create(Self);
  FilterMenu.Name := 'miColumnTranslators'; FilterMenu.Caption := 'Переводчики';
  FilterMenu.Tag := COL_TRANSLATORS; FilterMenu.OnClick := HeaderPopupItemClick;
  pmHeaders.Items.Add(FilterMenu);
  FilterMenu := TMenuItem.Create(Self);
  FilterMenu.Name := 'miColumnCity'; FilterMenu.Caption := 'Город издания';
  FilterMenu.Tag := COL_CITY; FilterMenu.OnClick := HeaderPopupItemClick;
  pmHeaders.Items.Add(FilterMenu);
  FilterMenu := TMenuItem.Create(Self);
  FilterMenu.Name := 'miColumnPubYear'; FilterMenu.Caption := 'Год издания';
  FilterMenu.Tag := COL_PUBYEAR; FilterMenu.OnClick := HeaderPopupItemClick;
  pmHeaders.Items.Add(FilterMenu);
  FilterMenu := TMenuItem.Create(Self);
  FilterMenu.Name := 'miColumnISBN'; FilterMenu.Caption := 'ISBN';
  FilterMenu.Tag := COL_ISBN; FilterMenu.OnClick := HeaderPopupItemClick;
  pmHeaders.Items.Add(FilterMenu);

  FilterMenu := TMenuItem.Create(Self);
  FilterMenu.Caption := 'Источники и объединение коллекции...';
  FilterMenu.OnClick := ShowCatalogSources;
  N2.Insert(3, FilterMenu);

  FMetadataFillAction:=TAction.Create(Self); FMetadataFillAction.Name:='acFillBookMetadata';
  FMetadataFillAction.ActionList:=Actions; FMetadataFillAction.Category:='Коллекция';
  FMetadataFillAction.Caption:='Заполнить сведения из книг…';
  FMetadataFillAction.Hint:='Из метаданных местных книг, только пустые поля каталога. Проверка запускается только по вашей команде.';
  FMetadataFillAction.OnExecute:=FillBookMetadataExecute; FMetadataFillAction.OnUpdate:=FillBookMetadataUpdate;
  FReaderNotesAction:=TAction.Create(Self); FReaderNotesAction.Name:='acAllReaderNotes';
  FReaderNotesAction.ActionList:=Actions; FReaderNotesAction.Caption:='Заметки всех книг…';
  FReaderNotesAction.OnExecute:=BrowseAllReaderNotes;
  FilterMenu:=TMenuItem.Create(Self); FilterMenu.Action:=FReaderNotesAction; miTools.Add(FilterMenu);
  FilterMenu:=TMenuItem.Create(Self); FilterMenu.Name:='miFillBookMetadata'; FilterMenu.Action:=FMetadataFillAction;
  miUpdateFromFile.Parent.Insert(miUpdateFromFile.MenuIndex+1,FilterMenu);

  CreatePublisherSeriesView;

  FrameTrees;

  dmImages.ScaleForDPI(Self.CurrentPPI);
  // VCL uses the existing AlignWithMargins gap above this toolbar.
  // Keep that gap at each monitor DPI while holding the designed row height.
  tlbrMain.AutoSize := False;
  tlbrMain.Margins.Top := MulDiv(4, CurrentPPI, 96);
  UpdateDownloadToolbarSize;

  ConnectTreeControllers;
  acBookRead.OnUpdate := BookLocationUpdate;

  InitFormFileds;
  CreatePublisherSearchField;
  CreateFavoriteAuthorControls;
  CreateSearchPanelAdapter;
  cbDeleted.OnClick := SearchDeletedClick;
  cbDeleted.ShowHint := True;
  cbDeleted.Hint := 'Общий режим с кнопкой «Скрыть удалённые книги». Обновляет применённый поиск, не применяя изменения в других полях.';

  ReadINIData;

  ClearDataFolder;

  LoadPresets;
  CreatePresetTransferMenu;

  SetColumns;

  SetHeaderPopUp;

  UpdateSplashScreen(rstrMainLoadingCollection);

  InitCollection;

  LoadDownloadsList;

  SetFormState;

  UpdateSplashScreen(rstrStarting);
  // A small toolbar aligned to the right keeps the theme switch at the edge,
  // regardless of the number of regular toolbar buttons or window width.
  FThemeToolbar:=TToolBar.Create(Self); FThemeToolbar.Parent:=Self;
  FThemeToolbar.Align:=alNone; FThemeToolbar.Anchors:=[akTop,akRight]; FThemeToolbar.Width:=MulDiv(42,CurrentPPI,96);
  FThemeToolbar.Flat:=True; FThemeToolbar.Wrapable:=False; FThemeToolbar.AutoSize:=False;
  FThemeToolbar.Transparent:=True;
  FThemeToolbar.Images:=dmImages.vilToolbar; FThemeToolbar.ButtonWidth:=MulDiv(36,CurrentPPI,96);
  FThemeToolbar.ButtonHeight:=tlbrMain.ButtonHeight; FThemeToolbar.ShowHint:=True;
  FThemeButton:=TToolButton.Create(Self); FThemeButton.Parent:=FThemeToolbar;
  FThemeButton.ImageIndex:=25; FThemeButton.OnClick:=ToggleApplicationTheme;
  UpdateThemeToolbar;
  if Settings.DarkTheme then
  begin
    if not MHLThemeDark then SetMHLTheme(True)
    else ApplyMHLControlTheme(Self);
  end;
  dmImages.ApplyThemeIcons;
  if Settings.DarkTheme then FThemeButton.Hint:='Переключить на светлую тему'
  else FThemeButton.Hint:='Переключить на тёмную тему';
  if TryMHLWindowsDarkTheme(WindowsDark) then UpdateWindowsThemeOffer(WindowsDark);
  FProgramUpdateTimer := TTimer.Create(Self);
  FProgramUpdateTimer.Interval := 30000;
  FProgramUpdateTimer.OnTimer := ProgramUpdateSchedule;
  FProgramUpdateTimer.Enabled := True;
  FProgramUpdateForm := TfrmProgramUpdate.Create(Self);
  FProgramUpdateForm.OnRestart := RestartForProgramUpdate;
  FProgramUpdateForm.OnCheck := CheckUpdatesExecute;
  if FProgramUpdateForm.RestoreReady then FProgramUpdateForm.Show;

end;

procedure TfrmMain.FormShortCut(var Msg: TWMKey; var Handled: Boolean);
begin
  // Ctrl+A is also the global "mark all books" shortcut. Text editing takes
  // precedence while an edit control has focus, matching standard Windows
  // behaviour without removing the existing shortcut from the book list.
  if (Msg.CharCode = Ord('A'))
    and (GetKeyState(VK_CONTROL) < 0)
    and (GetKeyState(VK_MENU) >= 0)
    and (ActiveControl is TCustomEdit) then
  begin
    TCustomEdit(ActiveControl).SelectAll;
    Handled := True;
  end;
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := True;
  if CheckActiveDownloads then
    if MHLShowWarning(rstrUnfinishedDownloads, mbYesNo) = mrYes then
    begin
      if Assigned(FDMThread) then
        FDMThread.TerminateNow;
    end
    else
      CanClose := False;
  if CanClose and Assigned(FProgramUpdateForm) and FProgramUpdateForm.PendingInstall then
    CanClose := FProgramUpdateForm.LaunchInstallation
end;

procedure TfrmMain.FormAfterMonitorDpiChanged(Sender: TObject; OldDPI, NewDPI: Integer);
begin
  dmImages.ScaleForDPI(NewDPI);
  if Assigned(FThemeToolbar) then
  begin
    FThemeToolbar.Width:=MulDiv(42,NewDPI,96);
    FThemeToolbar.ButtonWidth:=MulDiv(36,NewDPI,96);
  end;
  tlbrMain.Margins.Top := MulDiv(4, NewDPI, 96);
  UpdateDownloadToolbarSize;
  UpdateThemeToolbar;
  UpdateSearchBookLayout;
  UpdateFavoriteSearchLayout;
end;

procedure TfrmMain.UpdateDownloadToolbarSize;
begin
  // Recompute native button padding after image-list scaling.
  tlbrDownloadList.ButtonHeight := dmImages.vilDownload.Height + MulDiv(8, CurrentPPI, 96);
  tlbrDownloadList.ButtonWidth := dmImages.vilDownload.Width + MulDiv(8, CurrentPPI, 96);
  tlbrDownloadList.Height := tlbrDownloadList.ButtonHeight + MulDiv(4, CurrentPPI, 96);
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
var I: Integer; Message: TMsg;
begin
  StopFavoriteRefresh(True);
  if Assigned(FProgramUpdateThread) then
  begin
    FProgramUpdateThread.Terminate;
    // Destroy also resumes an unstarted canceled thread before joining it.
    FreeAndNil(FProgramUpdateThread);
  end;
  // Both producers finish before their notifier or callback state is destroyed.
  if FBackgroundMessageWindow <> 0 then
  begin
    while PeekMessage(Message, FBackgroundMessageWindow, WM_PROGRAM_UPDATE_CHECKED,
      WM_PROGRAM_UPDATE_CHECKED, PM_REMOVE) do ;
    DeallocateHWnd(FBackgroundMessageWindow);
    FBackgroundMessageWindow := 0;
  end;
  FreeAndNil(FFavoriteQueue);
  FreeAndNil(FFavoriteDirtyCollections);
  FreeAndNil(FFavoriteStore);
  CancelReaderPreparations(Self);
  for I:=Low(FBookPreviews) to High(FBookPreviews) do FreeAndNil(FBookPreviews[I]);
  FreeAndNil(FOPDSForm);
  FreeAndNil(FProgramUpdateTimer);
  FreeAndNil(FProgramUpdateForm);
  FreeAndNil(FPresets);

  try SaveDownloadsList;
  except
    on E: Exception do MHLShowError('Не удалось сохранить очередь загрузок. Предыдущий файл сохранён.' +
      sLineBreak + E.Message);
  end;

  SavePositions;
  SaveMainFormSettings;
  Settings.SaveSettings;

  FreeAndNil(FController);
  FreeAndNil(FDMThread);

  // Persistent custom reading folders keep their files across sessions.
  if DirectoryExists(Settings.TempDir) then
    ClearReadFolder(Settings.TempDir);
  FinishBookCacheSession;
end;

procedure TfrmMain.UpdatePositions;
var
  AuthorData: PAuthorData;
  SerieData: PSeriesData;
  GenreData: PGenreData;
  GroupData: PGroupData;
begin
  AuthorData := tvAuthors.GetNodeData(tvAuthors.GetFirstSelected);
  if not Assigned(AuthorData) or (FLastAuthorID <> AuthorData^.AuthorID) then
  begin
    if Assigned(AuthorData) then
      FLastAuthorID := AuthorData^.AuthorID
    else
      FLastAuthorID := MHL_INVALID_ID;
    FLastAuthorBookID.Clear;
  end
  else
    FLastAuthorStr := AuthorData^.GetFullName;

  SerieData := tvSeries.GetNodeData(tvSeries.GetFirstSelected);
  if not Assigned(SerieData) or (FLastSeriesID <> SerieData^.SeriesID) then
  begin
    if Assigned(SerieData) then
      FLastSeriesID := SerieData^.SeriesID
    else
      FLastSeriesID := MHL_INVALID_ID;
    FLastSeriesBookID.Clear;
  end
  else
    FLastseriesStr:= SerieData^.SeriesTitle;

  GenreData := tvGenres.GetNodeData(tvGenres.GetFirstSelected);
  if not Assigned(GenreData) or (FLastGenreCode <> GenreData^.GenreCode) then
  begin
    if Assigned(GenreData) then
    begin
      FLastGenreCode := GenreData^.GenreCode;
      Assert(Assigned(tvGenres.GetFirstSelected()));
      FLastGenreIsContainer := (tvGenres.GetFirstSelected^.ChildCount > 0);
      FLastGenreIsTopLevelContainer :=
        (GenreData^.ParentCode = '0') and FLastGenreIsContainer;
      FRootGenreBooksRequested := False;
    end
    else
    begin
      FLastGenreCode := '';
      FLastGenreIsContainer := False;
      FLastGenreIsTopLevelContainer := False;
      FRootGenreBooksRequested := False;
    end;
    FLastGenreBookID.Clear;
  end;

  GroupData := tvGroups.GetNodeData(tvGroups.GetFirstSelected);
  if not Assigned(GroupData) or (FLastGroupID <> GroupData^.GroupID) then
  begin
    if Assigned(GroupData) then
      FLastGroupID := GroupData^.GroupID
    else
      FLastGroupID := MHL_INVALID_ID;
    FLastGroupBookID.Clear;
  end;
end;

procedure TfrmMain.SaveMainFormSettings;
begin
  SaveColumns;

  UpdatePositions;

  Settings.Splitters[0] := pnAuthorsView.Width;
  Settings.Splitters[1] := pnSeriesView.Width;
  Settings.Splitters[5] := FPublisher.Sidebar.Width;
  Settings.Splitters[2] := pnGenresView.Width;
  Settings.Splitters[3] := pnSearchView.Width;
  Settings.Splitters[4] := pnGroupsView.Width;

  Settings.BookSRCollapsed := ctpBook.Collapsed;
  Settings.FileSRCollapsed := ctpFile.Collapsed;
  Settings.OtherSRCollapsed := ctpOther.Collapsed;
  Settings.CollapseMultiSeriesSearchResults :=
    cbCollapseMultiSeriesResults.Checked;

  Settings.InfoPanelHeight := ipnlAuthors.Height;

  Settings.WindowState := Ord(Self.WindowState);
  if WindowState = wsNormal then
  begin
    Settings.FormWidth := Width;
    Settings.FormHeight := Height;

    Settings.FormTop := Top;
    Settings.FormLeft := Left;
  end;

end;

procedure TfrmMain.ClearBookSorting(Sender: TObject);
var Tree: TBookTree;
begin
  if FBookListLoading or (ActiveView = DownloadView) then Exit;
  GetActiveTree(Tree); Tree.SortKeys := nil;
  SortLoadedBooks(Tree);
end;

procedure TfrmMain.SortLoadedBooks(Tree: TBookTree);
var I, Primary: Integer; SavedCursor: TCursor;
begin
  if FBookListLoading then Exit;
  Primary := NoColumn;
  if Length(Tree.SortKeys) > 0 then
    for I := 0 to Tree.Header.Columns.Count-1 do
      if Tree.Header.Columns[I].Tag = Tree.SortKeys[0].Tag then Primary := I;
  Tree.Header.SortColumn := Primary;
  if Primary >= 0 then Tree.Header.SortDirection := Tree.SortKeys[0].Direction
  else begin Tree.Header.SortDirection := sdAscending; Tree.SortKeys := nil; end;
  FSortSettings[Tree.Tag].Column := Primary; FSortSettings[Tree.Tag].Direction := Tree.Header.SortDirection;
  FBookListLoading := True; FBookListCancelled := False; FBookListLastPump := 0;
  SavedCursor := Screen.Cursor; Screen.Cursor := crDefault; Inc(FBookInfoUpdateCount);
  FBookListCancel.Visible := True; FBookListCancel.BringToFront;
  FController.CancelCheck := function: Boolean begin Result := PollBookListCancel; end;
  try
    try Tree.SortTree(Primary,Tree.Header.SortDirection);
    except on E: EAbort do if not FBookListCancelled then raise; end;
  finally
    FController.CancelCheck := nil; FBookListCancel.Visible := False;
    FBookListLoading := False; Dec(FBookInfoUpdateCount); Screen.Cursor := SavedCursor;
  end;
  Tree.Invalidate;
end;

procedure TfrmMain.tvBooksTreeHeaderClick(Sender: TVTHeader; HitInfo: TVTHeaderHitInfo);
var
  Tree: TBookTree;
  LeftEdge, RightEdge: TDimension;
  ColumnTag: Integer;
begin
  Tree := Sender.Treeview as TBookTree;
  if HitInfo.Column < 0 then Exit;
  ColumnTag := Tree.Header.Columns[HitInfo.Column].Tag;
  Tree.Header.Columns.GetColumnBounds(HitInfo.Column, LeftEdge, RightEdge);
  if not (coFixed in Tree.Header.Columns[HitInfo.Column].Options) then
    Dec(RightEdge, TBookTreeAccess(Tree).EffectiveOffsetX);
  if (ColumnTag <> COL_STATE) and
    ((HitInfo.Button = mbLeft) and
     (HitInfo.X >= RightEdge - MulDiv(28, Tree.CurrentPPI, 96)) and
     (HitInfo.X < RightEdge - MulDiv(8, Tree.CurrentPPI, 96))) then
  begin
    if EditBookColumnFilter(Tree, ColumnTag) then ApplyBookColumnFilters(Tree);
    Exit;
  end;
  if HitInfo.Button = mbLeft then
  begin
    if Settings.TreeModes[Tree.Tag] = tmTree then Exit;
    Tree.UpdateSortKey(ColumnTag, (GetKeyState(VK_SHIFT) and $8000) <> 0);
    SortLoadedBooks(Tree);
  end;
end;

procedure TfrmMain.tvAuthorsChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  SavedCursor: TCursor;
  Data: PAuthorData;
  FilterValue: TFilterValue;
{$IFDEF USELOGGER}
  logger: IScopeLogger;
{$ENDIF}

  procedure ClearScreen;
  begin
    lblAuthor.Caption := '...';
    lblBooksTotalA.Caption := '(0)';
    ipnlAuthors.Clear;
    tvBooksA.Clear;
  end;

begin
{$IFDEF USELOGGER}
{$ENDIF}

  if FInvisible then Exit;
  if ActiveView <> AuthorsView then
  begin
    Exclude(FLoadedBookViews, AuthorsView);
    Exit;
  end;
  if tvAuthors.RootNodeCount = 0 then
  begin
    ClearScreen; FLastAuthorID := MHL_INVALID_ID; FLastAuthorBookID.Clear;
    FOnlyNewFavoriteBooks := False; UpdateFavoriteControls;
  end;
  if (FIgnoreAuthorChange) or (Node = nil) then Exit;

  // finally восстанавливает курсор даже на пути Exit ниже, так что сохраняем до try
  SavedCursor := Screen.Cursor;
  try
    Data := tvAuthors.GetNodeData(Node);
    if not Assigned(Data) then
    begin
      ClearScreen;
      Exit;
    end;

    Screen.Cursor := crHourGlass;

    if FOnlyNewFavoriteBooks then
      try
        if not Assigned(FFavoriteStore) or not FFavoriteStore.IsFavorite(Data^) then FOnlyNewFavoriteBooks := False;
      except on E: EAuthorFavorites do FOnlyNewFavoriteBooks := False; end;
    if FLastAuthorID <> Data^.AuthorID then
    begin
      lblAuthor.Caption := Data^.GetFullName;
      FLastAuthorID := Data^.AuthorID;
      FLastAuthorStr:= Data^.GetFullName;
      FLastAuthorBookID.Clear;
    end;

    if Assigned(FCollection) then FillCurrentAuthorBooks;
    UpdateFavoriteControls;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.tvAuthorsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    frmMain.ActiveControl := tvBooksA;
  end;
end;

procedure TfrmMain.tvAuthorsMeasureTextHeight(Sender: TBaseVirtualTree;
  TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
  const Text: string; var Extent: Integer);
begin
end;

procedure TfrmMain.tvSeriesChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  SavedCursor: TCursor;
  Data: PSeriesData;
  FilterValue: TFilterValue;
{$IFDEF USELOGGER}
  logger: IScopeLogger;
{$ENDIF}

  procedure ClearScreen;
  begin
    lblSeries.Caption := '...';
    lblBooksTotalS.Caption := '(0)';
    ipnlSeries.Clear;
    tvBooksS.Clear;
  end;

begin
{$IFDEF USELOGGER}
  logger := GetScopeLogger('TfrmMain.tvSeriesChange');
{$ENDIF}

  if FInvisible then Exit;
  if ActiveView <> SeriesView then
  begin
    Exclude(FLoadedBookViews, SeriesView);
    Exit;
  end;
  if tvSeries.RootNodeCount = 0 then ClearScreen;
  if (Node = nil) then Exit;

  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    Data := tvSeries.GetNodeData(Node);
    if not Assigned(Data) then
    begin
      ClearScreen;
      Exit;
    end;

    if FLastSeriesID <> Data^.SeriesID then
    begin
      lblSeries.Caption := Data^.SeriesTitle;
      FLastSeriesID := Data^.SeriesID;
      FLastSeriesStr := Data^.SeriesTitle;
      FLastSeriesBookID.Clear;
    end;

    FilterValue := SeriesBookFilter;
    if Assigned(FCollection) then
      FillBooksTree(tvBooksS, cbLangSelectS,
        function: IBookIterator begin Result := FCollection.GetBookIterator(bmBySeries, False, @FilterValue); end, False, False, @FLastSeriesBookID); // авторы
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.tvSeriesKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    frmMain.ActiveControl := tvBooksS;
  end;
end;

procedure TfrmMain.tvGenresChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  SavedCursor: TCursor;
  Data: PGenreData;
{$IFDEF USELOGGER}
  logger: IScopeLogger;
{$ENDIF}
begin
{$IFDEF USELOGGER}
  logger := GetScopeLogger('TfrmMain.tvGenresChange');
{$ENDIF}

  if FInvisible then Exit;
  if ActiveView <> GenresView then
  begin
    Exclude(FLoadedBookViews, GenresView);
    Exit;
  end;

  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    Data := tvGenres.GetNodeData(Node);
    if not Assigned(Data) then
    begin
      FLastGenreCode := '';
      FLastGenreIsContainer := False;
      FLastGenreIsTopLevelContainer := False;
      FRootGenreBooksRequested := False;
      btnShowGenreBooks.Visible := False;
      lblGenreTitle.Caption := '...';
      lblBooksTotalG.Caption := '(0)';
      ipnlGenres.Clear;
      tvBooksG.Clear;
      Exit;
    end;

    if FLastGenreCode <> Data^.GenreCode then
    begin
      lblGenreTitle.Caption := Data^.GenreAlias;
      FLastGenreCode := Data^.GenreCode;
      FLastGenreIsContainer := (Node^.ChildCount > 0);
      FLastGenreIsTopLevelContainer :=
        (Data^.ParentCode = '0') and FLastGenreIsContainer;
      FRootGenreBooksRequested := False;
      FLastGenreBookID.Clear;
    end;

    // A root genre can represent hundreds of thousands of books. Selecting it
    // is therefore navigation-only: do not expand it and do not build the
    // combined result until the user presses the explicit button.
    FillCurrentGenreBooks;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.btnShowGenreBooksClick(Sender: TObject);
begin
  if not FLastGenreIsTopLevelContainer or not Assigned(FCollection) then
    Exit;

  FRootGenreBooksRequested := True;
  btnShowGenreBooks.Enabled := False;
  try
    try
      // First actual load also restores the language deferred by root navigation.
      Exclude(FLoadedBookViews, GenresView);
      EnsureActiveBookViewLoaded;
    except
      FRootGenreBooksRequested := False;
      Exclude(FLoadedBookViews, GenresView);
      raise;
    end;
  finally
    btnShowGenreBooks.Enabled := True;
  end;
end;

procedure TfrmMain.tvGenresKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    frmMain.ActiveControl := tvBooksG;
  end;
end;


procedure TfrmMain.tvGroupsChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  SavedCursor: TCursor;
  Data: PGroupData;
{$IFDEF USELOGGER}
  logger: IScopeLogger;
{$ENDIF}
begin
{$IFDEF USELOGGER}
  logger := GetScopeLogger('TfrmMain.tvGroupsChange');
{$ENDIF}

  if FInvisible then Exit;
  if ActiveView <> FavoritesView then
  begin
    Exclude(FLoadedBookViews, FavoritesView);
    Exit;
  end;

  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    Data := tvGroups.GetNodeData(Node);
    if not Assigned(Data) then
    begin
      lblGroups.Caption := '...';
      lblBooksTotalF.Caption := '(0)';
      ipnlFavorites.Clear;
      tvBooksF.Clear;
      Exit;
    end;

    if FLastGroupID <> Data^.GroupID then
    begin
      lblGroups.Caption := FSystemData.GetGroup(Data^.GroupID).Text;
      FLastGroupID := Data^.GroupID;
      FLastGroupBookID.Clear;
    end;

    FillBooksTree(tvBooksF, cbLangSelectF,
        function: IBookIterator begin Result := FSystemData.GetBookIterator(FLastGroupID); end, True, True, @FLastGroupBookID);
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.tvGroupsDragDrop(
  Sender: TBaseVirtualTree;
  Source: TObject;
  DataObject: IDataObject;
  Formats: TFormatArray;
  Shift: TShiftState;
  Pt: TPoint;
  var Effect: Integer;
  Mode: TDropMode
  );
var
  Nodes: TNodeArray;
  i: Integer;
  GroupData: PGroupData;
  SourceGroupID: Integer;
  TargetGroupID: Integer;
  BookData: PBookRecord;

  procedure SelectChildNodes(ParentNode: PVirtualNode);
  var
    Node: PVirtualNode;
  begin
    if ParentNode.ChildCount = 0 then
      Exit;
    Node := ParentNode.FirstChild;
    while Assigned(Node) do
    begin
      SelectChildNodes(Node);
      tvBooksF.Selected[Node] := True;
      Node := tvBooksF.GetNextSibling(Node);
    end;
  end;

begin

  SourceGroupID := FLastGroupID;

  GroupData := tvGroups.GetNodeData(tvGroups.DropTargetNode);
  Assert(Assigned(GroupData));
  TargetGroupID := GroupData^.GroupID;

  Nodes := tvBooksF.GetSortedSelection(False);

  for i := 0 to High(Nodes) do
    SelectChildNodes(Nodes[i]);

  Nodes := tvBooksF.GetSortedSelection(False);

  for i := 0 to High(Nodes) do
  begin
    BookData := tvBooksF.GetNodeData(Nodes[i]);
    if BookData^.nodeType = ntBookInfo then
    begin
      FSystemData.CopyBookToGroup(BookData^.BookKey, SourceGroupID, TargetGroupID, ssShift in Shift);
    end;
  end;
  Exclude(FLoadedBookViews, FavoritesView);
  if ActiveView = FavoritesView then EnsureActiveBookViewLoaded;
end;

procedure TfrmMain.tvGroupsDragOver(Sender: TBaseVirtualTree; Source: TObject; Shift: TShiftState; State: TDragState; Pt: TPoint; Mode: TDropMode; var Effect: Integer; var Accept: Boolean);
var
 Data: PGroupData;
begin

  Data := tvGroups.GetNodeData(tvGroups.DropTargetNode);
  if Assigned(Data) then
    if Data^.GroupID <> FLastGroupID then
      Accept := True;
end;

procedure TfrmMain.tvGroupsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    frmMain.ActiveControl := tvBooksF;
  end;
end;

procedure TfrmMain.tvBooksTreeChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  Data: PBookRecord;
  Tree: TBookTree;
  InfoPanel: TInfoPanel;
  isFBDDocument, LocalReadable: Boolean;
  StoredBookKey: PBookKey;
  BookCollection: IBookCollection;
  BookSeries: TBookSeries;
  SeriesLinks: string;
  GalleryBook: TBookRecord;

begin
  if FInvisible or (FBookInfoUpdateCount > 0) then Exit;

  Tree := Sender as TBookTree;

  StoredBookKey := nil;

  if Tree = tvBooksA then
  begin
    InfoPanel := ipnlAuthors;
    StoredBookKey := @FLastAuthorBookID;
  end
  else if Tree = tvBooksS then
  begin
    InfoPanel := ipnlSeries;
    StoredBookKey := @FLastSeriesBookID;
  end
  else if Tree = FPublisher.Books then
  begin
    InfoPanel := FPublisher.Info;
    StoredBookKey := @FLastPublisherBookID;
  end
  else if Tree = tvBooksG then
  begin
    InfoPanel := ipnlGenres;
    StoredBookKey := @FLastGenreBookID;
  end
  else if Tree = tvBooksSR then
    InfoPanel := ipnlSearch
  else if Tree = tvBooksF then
  begin
    InfoPanel := ipnlFavorites;
    StoredBookKey := @FLastGroupBookID;
  end
  else
  begin
    Assert(False);
    Exit;
  end;


  if not Assigned(FBookPreviews[Tree.Tag]) then
    FBookPreviews[Tree.Tag]:=TBookInfoPreview.CreateFor(Self,InfoPanel);
  FBookPreviews[Tree.Tag].Cancel;
  InfoPanel.BeginUpdate;
  try
  InfoPanel.Clear;
  if not Assigned(Node) then
  begin
    if Assigned(StoredBookKey) then StoredBookKey^.Clear;
    Exit;
  end;
  Data := Tree.GetNodeData(Node);

  if not Assigned(Data) or (Data^.nodeType <> ntBookInfo) then
  begin
    if Assigned(StoredBookKey) then
      StoredBookKey^.Clear;
    Exit;
  end;

  if Assigned(StoredBookKey) then
    StoredBookKey^ := Data^.BookKey;

  if Settings.ShowInfoPanel then
  begin
    SeriesLinks := TSeriesHelper.GetLink(Data^.SeriesID, Data^.Series);
    try
      BookCollection := FSystemData.GetCollection(Data^.BookKey.DatabaseID);
      BookSeries := BookCollection.GetBookSeries(Data^.BookKey);
      if Length(BookSeries) > 0 then
        SeriesLinks := TSeriesHelper.GetLinkList(BookSeries);
    except
      // The information panel must remain usable when a removable or network
      // collection is temporarily unavailable; the primary series is already
      // present in the tree record and is a safe fallback.
    end;

    InfoPanel.SetBookInfo(
      Data^.Title,
      TAuthorsHelper.GetLinkList(Data^.Authors),
      SeriesLinks,
      TGenresHelper.GetLinkList(Data^.Genres)
    );
    InfoPanel.SetReadingSupport(ReaderAvailability(Data^.FileExt));
    InfoPanel.DetailsButton.OnClick := ShowBookInfo;
    InfoPanel.DetailsButton.Visible := True;
    if (bpIsLocal in Data^.BookProps) and CatalogBookAvailable(Data^, False) then
    begin
      GalleryBook := Data^;
      InfoPanel.Gallery.PreviewSettingsFile := Settings.DataPath + 'gallery-window.ini';
      InfoPanel.Gallery.SetBook(IntToStr(GalleryBook.BookKey.DatabaseID) + ':' +
        IntToStr(GalleryBook.BookKey.BookID),
        IfThen(IsArchiveExt(GalleryBook.FileName+GalleryBook.FileExt),FB2_EXTENSION,GalleryBook.FileExt),
        function: TStream
        begin
          Result := OpenBookImageSource(GalleryBook);
        end);
    end;
    try
      if Assigned(BookCollection) then
        InfoPanel.SetPublisherSeriesLinks(TSeriesHelper.GetLinkList(
          BookCollection.GetBookPublisherSeries(Data^.BookKey), True));
    except
      // Keep the rest of the panel usable for temporarily unavailable collections.
    end;

    LocalReadable:=(bpIsLocal in Data^.BookProps) and CatalogBookAvailable(Data^,False);
    FBookPreviews[Tree.Tag].Load(Data^, LocalReadable and Settings.ShowBookCover,
      Settings.ShowBookAnnotation, LocalReadable and Settings.Fb2InfoPriority,LocalReadable);

  end;

  finally
    InfoPanel.EndUpdate;
  end;

  if IsPrivate and IsNonFB2 then
  begin
    isFBDDocument := Data^.GetBookFormat = bfFbd;
    tbtnFBD.Caption := IfThen(isFBDDocument, rstrEditFBD, rstrConvert2FBD);
    tbtnAutoFBD.Visible := isFBDDocument;
  end;
end;

procedure TfrmMain.tvBooksTreeKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
const
  CheckState: array [Boolean] of TCheckState = (csCheckedNormal, csUncheckedNormal);
var
  Tree: TBookTree;
  Left: TVirtualStringTree;
  Node: PVirtualNode;
  Data: PBookRecord;
begin
  if Key = VK_INSERT then
  begin
    Tree := (Sender as TBookTree);
    Node := Tree.FocusedNode;
    if Assigned(Node) then
    begin
      Data := Tree.GetNodeData(Node);
      if Data^.nodeType = ntBookInfo then
        Tree.CheckState[Node] := CheckState[Tree.CheckState[Node] = csCheckedNormal];
      Tree.Selected[Node] := False;
      Node := Tree.GetNext(Node);

      if Assigned(Node) then
      begin
        Tree.Selected[Node] := True;
        Tree.FocusedNode := Node;
      end;
    end;
  end
  else if (Key in [VK_RIGHT, VK_LEFT]) and (ssCtrl in Shift) then
  begin
    case ActiveView of
      AuthorsView:
        Left := tvAuthors;
      SeriesView:
        Left := tvSeries;
      PublisherSeriesView:
        Left := FPublisher.SeriesTree;
      GenresView:
        Left := tvGenres;
      FavoritesView:
        Left := tvGroups;
    else
      // SearchView и DownloadView не имеют левого дерева
      Exit;
    end;

    Node := Left.FocusedNode;
    Left.Selected[Node] := False;

    if (Key = VK_RIGHT) then
      Node := Left.GetNext(Node)
    else
      Node := Left.GetPrevious(Node);

    if Assigned(Node) then
    begin
      Left.Selected[Node] := True;
      Left.FocusedNode := Node;
    end;

    Tree := (Sender as TBookTree);
    Node := Tree.GetFirst;
    if Assigned(Node) then
      Tree.Selected[Node] := True;
  end;
end;

procedure TfrmMain.tvBooksTreeMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Node: PVirtualNode;
  Data: PBookRecord;
  Tree: TBookTree;
  Selected: PVirtualNode;
begin
  if (Button = mbLeft) and (ssShift in Shift) then
  begin
    Tree := Sender as TBookTree;
    Selected := nil;
    try
      ClearLabels(Tree.Tag, True);
      Node := Tree.GetFirstSelected;
      Selected := Node;
      while Assigned(Node) do
      begin
        Data := Tree.GetNodeData(Node);
        if Data^.nodeType = ntBookInfo then
        begin
          if Tree.CheckState[Node] = csCheckedNormal then
            Tree.CheckState[Node] := csUncheckedNormal
          else
            Tree.CheckState[Node] := csCheckedNormal;
          Tree.Selected[Node] := False;
        end;
        Node := Tree.GetNextSelected(Node);
      end;
    finally
      if Assigned(Selected) then
        Tree.Selected[Selected] := True;
    end;
  end;
end;

procedure TfrmMain.btnClearDownloadClick(Sender: TObject);
begin
  btnPauseDownloadClick(Sender);
  FDownloadNode := nil;
  tvDownloadList.Clear;
  UpdateDownloadCount;
end;

procedure TfrmMain.btnClearEdSeriesClick(Sender: TObject);
begin
  edLocateSeries.Clear;
  frmMain.ActiveControl := edLocateSeries;
end;

procedure TfrmMain.btnClearFilterEditsClick(Sender: TObject);
begin
  DoClearFilter(False);
end;

procedure TfrmMain.MoveDwnldListNodes(Sender: TObject);
var
  i: Integer;
  List: TSelectionList;
begin
  GetSelections(tvDownloadList, List);
  for i := 0 to tvDownloadList.SelectedCount - 1 do
    case (Sender as TToolButton).Tag of
      20: tvDownloadList.MoveTo(List[tvDownloadList.SelectedCount - i - 1], tvDownloadList.GetFirst, amInsertBefore, False);
      21: tvDownloadList.MoveTo(List[i], tvDownloadList.GetPrevious(List[i]), amInsertBefore, False);
      22: tvDownloadList.MoveTo(List[tvDownloadList.SelectedCount - i - 1], tvDownloadList.GetNext(List[tvDownloadList.SelectedCount - i - 1]), amInsertAfter, False);
      23: tvDownloadList.MoveTo(List[i], tvDownloadList.GetLast, amInsertAfter, False);
    end;
end;

procedure TfrmMain.CopyToCollectionClick(Sender: TObject);
var
  R: TBookRecord;
  ID: Integer;
  Tree: TBookTree;
  Node: PVirtualNode;
  Data: PBookRecord;
  SavedCursor: TCursor;
  targetCollection: IBookCollection;
  bookIDList: TBookIdList;
  bookIDStruct: TBookIdStruct;
begin
  Assert(Assigned(FCollection));
  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    if ActiveView = FavoritesView then
    begin
      MHLShowWarning(rstrMainUnableToCopy);
      Exit;
    end;

    GetActiveTree(Tree);
    ID := (Sender as TMenuItem).Tag;
    targetCollection := FSystemData.GetCollection(ID);

    FillBookIdList(Tree, bookIDList, False);

    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Data := Tree.GetNodeData(Node);
      for bookIDStruct in bookIDList do
      begin
        if bookIDStruct.BookKey.IsSameAs(Data^.BookKey) then
          break;
      end;
      if bookIDStruct.BookKey.IsSameAs(Data^.BookKey) then
      begin
        FCollection.GetBookRecord(Data^.BookKey, R, True);
        targetCollection.InsertBook(R, True, True);
      end;

      Node := Tree.GetNext(Node);
    end;

    SetLength(BookIDList, 0);
    FillBookIdList(Tree, bookIDList, True);
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.InfoPanelResize(Sender: TObject);
begin
  SetInfoPanelHeight((Sender as TWinControl).Height);
end;

procedure TfrmMain.AddCurrentToList(const Tree: TBookTree; var BookIDList: TBookIdList);
var
  Data: PBookRecord;
begin
  SetLength(BookIDList, 0);
  Data := Tree.GetNodeData(Tree.FocusedNode);
  if not Assigned(Data) or (Data^.NodeType <> ntBookInfo) then Exit;
  if (Tree = tvBooksF) and not CatalogBookMatchesSaved(Data^) then Exit;
  SetLength(BookIDList, 1); BookIDList[0] := Default(TBookIdStruct);
  BookIDList[0].BookKey := Data^.BookKey;
  // Every queued export/download keeps the selected row's identity, even
  // when an ordinary catalog refresh replaces its key before worker lookup.
  BookIDList[0].HasExpectedIdentity := True;
  BookIDList[0].ExpectedLibID := Data^.LibID;
  BookIDList[0].ExpectedPhysicalIdentity := ReaderBookPhysicalIdentity(Data^);
end;

procedure TfrmMain.FillBookIdList(const Tree: TBookTree; var BookIDList: TBookIdList; const Uncheck: Boolean);
var Skipped: Integer;
begin
  BookIDList := BuildBookSelectionSnapshot(Tree,
    function(Node: PVirtualNode; Book: PBookRecord): Boolean
    begin Result := IsSelectedBookNode(Node, Book); end,
    function(const Book: TBookRecord): Boolean
    begin Result := (Tree <> tvBooksF) or CatalogBookMatchesSaved(Book, False); end,
    Uncheck, Skipped);
  if Skipped > 0 then MHLShowInfo(Format('Пропущено книг из группы: %d. ' +
    'Они больше не совпадают с каталогом. Записи и заметки сохранены; ' +
    'экспорт и скачивание для них не выполняются.', [Skipped]));
end;

procedure TfrmMain.SendToDeviceExecute(Sender: TObject);
var
  AFolder: string;
  SaveFolderTemplate: string;
  ScriptID: Integer;
  BookIDList: TBookIdList;
  Results: TBookExportResults;
  Plan: TBookExportScriptPlan;
  Files: string;
  Tree: TBookTree;
  ExportMode: TExportMode;
  ExplicitFormat, ExternalScript: Boolean;
  UseMTP: Boolean;
  DeviceShellItem: IShellItem;
  GroupData: PGroupData;
begin
  ScriptID := (Sender as TComponent).Tag - 901;
  if (ScriptID >= 0) and (ScriptID < Settings.Scripts.Count) and Settings.Scripts[ScriptID].Standalone then
  begin
    Settings.Scripts[ScriptID].Run; Exit;
  end;
  if ScriptID >= Settings.Scripts.Count then
    raise EArgumentException.Create('Команда экспорта больше не существует. Откройте меню повторно.');
  Assert(Assigned(FCollection));
  GetActiveTree(Tree);
  // Keep the selection while the destination dialog can still be canceled.
  FillBookIdList(Tree, BookIDList, False);

  UseMTP := False;

  if pgControl.ActivePage = tsByAuthor then
    CurrentSelectedAuthor := lblAuthor.Caption
  else
    CurrentSelectedAuthor := '';

  if ActiveView = FavoritesView then
  begin
    GroupData := tvGroups.GetNodeData(tvGroups.GetFirstSelected);
    if Assigned(GroupData) then
      CurrentSelectedGroup := GroupData^.Text
    else
      CurrentSelectedGroup := '';
  end
  else
    CurrentSelectedGroup := '';

  if Length(BookIDList) = 0 then
  begin
    MHLShowError(rstrNoBookSelected);
    Exit;
  end;

  AFolder := Settings.DeviceDir;
  SaveFolderTemplate := Settings.FolderTemplate;
  ScriptID := (Sender as TComponent).Tag;
  ExplicitFormat := (ScriptID = 850) or (ScriptID = 854);

  ExportMode := ResolveBookExportMode(ScriptID, Settings.ExportMode,
    isFB2Collection(FCollection.CollectionCode) or Settings.AllowMixed);

  if ScriptID = 799 then
  begin
    if FLastDeviceDir = '' then
      FLastDeviceDir := Settings.DeviceDir;
    if not GetFolderShellItem(Handle, rstrSpecifyPath, FLastDeviceDir, DeviceShellItem) then
      Exit;
    AFolder := FLastDeviceDir;
    UseMTP := IsShellPath(AFolder);
    Dec(ScriptID, 901);
  end
  else
  begin
    Dec(ScriptID, 901);

    if (ScriptID < 1) and (Settings.PromptDevicePath) then
    begin
      if FLastDeviceDir = '' then
        FLastDeviceDir := Settings.DeviceDir;
      if not GetFolderShellItem(Handle, rstrProvideThePath, FLastDeviceDir, DeviceShellItem) then
        Exit
      else
      begin
        AFolder := FLastDeviceDir;
        UseMTP := IsShellPath(AFolder);
      end;
    end;
  end;

  Results := nil;
  ExternalScript := (ScriptID >= 0) and (Settings.Scripts[ScriptID].Path <> '%COPY%');
  try
    if ScriptID >= 0 then
    begin
      Plan := PrepareBookExportScript(Settings.Scripts[ScriptID].Path,
        Settings.Scripts[ScriptID].Params, AFolder, Settings.TempPath, SaveFolderTemplate);
      AFolder := Plan.Destination;
      Settings.FolderTemplate := Plan.FolderTemplate;
    end;

    if isOnlineCollection(FCollection.CollectionCode) and
      not unit_ExportToDevice.DownloadBooksForExport(BookIDList) then
    begin
      StatusMessage := 'Подготовка экспорта отменена. Отметки книг сохранены.';
      Exit;
    end;

    if ExternalScript then
    begin
      unit_ExportToDevice.ExportToDevice(AFolder, BookIDList, ExportMode, True,
        Files, Results, DeviceShellItem, UseMTP);
      if not AllBooksPreparedForScript(Results) then
      begin
        StatusMessage := 'Инструмент не запущен: подготовлены не все книги. Отметки сохранены.';
        Exit;
      end;
      Settings.Scripts[ScriptID].TMPParams := StringReplace(Plan.Parameters,
        '%FILENAME%', Files, [rfReplaceAll]);
      Settings.Scripts[ScriptID].Run;
      StatusMessage := 'Внешний инструмент запущен. Отметки сохранены; итог работы проверьте в инструменте.';
    end
    else
    begin
      unit_ExportToDevice.ExportToDevice(AFolder, BookIDList, ExportMode, False,
        Files, Results, DeviceShellItem, UseMTP, ExplicitFormat);
      StatusMessage := Format('Экспортировано книг: %d из %d. Остальные отметки сохранены.',
        [SuccessfulBookExportCount(Results), Length(BookIDList)]);
    end;
  finally
    if not ExternalScript then ApplySuccessfulExportMarks(Tree, Results);
    Settings.FolderTemplate := SaveFolderTemplate;
    if (ScriptID >= 0) and (ScriptID < Settings.Scripts.Count) then
      Settings.Scripts[ScriptID].TMPParams := '';
  end;
end;

procedure TfrmMain.DownloadBooks;
var
  BookIDList: TBookIdList;
  Tree: TBookTree;
begin
  GetActiveTree(Tree);

  if CurrentBookOnly then
    AddCurrentToList(Tree, BookIDList)
  else
    FillBookIdList(Tree, BookIDList);
  unit_ExportToDevice.DownloadBooks(BookIDList);
end;

procedure TfrmMain.ReadBookExecute(Sender: TObject);
var
  Tree: TBookTree;
  Data: PBookRecord;
begin
  GetActiveTree(Tree);

  Data := Tree.GetNodeData(Tree.GetFirstSelected);
  if Assigned(Data) and (Data^.nodeType = ntBookInfo) then
  begin
    FCurrentBookOnly := True;
    try
      OnReadBookHandler(Data^);
    finally
      FCurrentBookOnly := False;
    end;
  end;
end;

procedure TfrmMain.OnReadBookHandler;
begin
  ReadPreparedBook(BookRecord, False, True);
end;

procedure TfrmMain.ReadBuiltinUpdate(Sender: TObject);
var Tree: TBookTree; Data: PBookRecord;
begin
  FReadBuiltinAction.Enabled := False;
  if not Assigned(FCollection) or not (ActiveView in [AuthorsView, SeriesView,
    PublisherSeriesView, GenresView, SearchView, FavoritesView]) then Exit;
  GetActiveTree(Tree);
  if not Assigned(Tree) then Exit;
  Data := Tree.GetNodeData(Tree.GetFirstSelected);
  if Assigned(Data) and (Data^.nodeType=ntBookInfo) and CatalogBookAvailable(Data^, False) then
    FReadBuiltinAction.Enabled:=IsBuiltinReaderFormat(Data^.FileExt) or
      (IsOfficeReaderFormat(Data^.FileExt) and OfficeReaderAvailable(Data^.FileExt)) or
      IsReaderArchive(Data^.FileName+Data^.FileExt) or
      (Pos('|'+LowerCase(Data^.FileExt)+'|','|.mobi|.azw|.azw3|.prc|.fb|.original_fb2|.xml|')>0) or
      (Data^.GetFileType='Некорректный тип') or (Data^.GetFileType='Без расширения');
end;

procedure TfrmMain.ReadBuiltinExecute(Sender: TObject);
var Tree: TBookTree; Data: PBookRecord; Book: TBookRecord;
begin
  if not (ActiveView in [AuthorsView, SeriesView, PublisherSeriesView,
    GenresView, SearchView, FavoritesView]) then Exit;
  GetActiveTree(Tree);
  if not Assigned(Tree) then Exit;
  Data := Tree.GetNodeData(Tree.GetFirstSelected);
  if not Assigned(Data) or (Data^.nodeType <> ntBookInfo) then Exit;
  Book := Data^;
  FCurrentBookOnly := True;
  try ReadPreparedBook(Book, True); finally FCurrentBookOnly := False; end;
end;

procedure TfrmMain.ReadExternalExecute(Sender: TObject);
var Tree: TBookTree; Data: PBookRecord;
begin
  GetActiveTree(Tree); if not Assigned(Tree) then Exit; Data:=Tree.GetNodeData(Tree.GetFirstSelected);
  if Assigned(Data) and (Data^.NodeType=ntBookInfo) then ReadPreparedBook(Data^,False);
end;

procedure TfrmMain.OpenArchiveUpdate(Sender: TObject);
var Tree: TBookTree; Book: PBookRecord;
begin
  TAction(Sender).Enabled := False; GetActiveTree(Tree);
  if not Assigned(Tree) then Exit;
  Book := Tree.GetNodeData(Tree.GetFirstSelected);
  if Assigned(Book) and (Book^.NodeType = ntBookInfo) and CatalogBookAvailable(Book^, False) then
    TAction(Sender).Enabled := IsReaderArchive(Book^.FileName+Book^.FileExt);
end;

procedure TfrmMain.OpenArchiveExecute(Sender: TObject);
var Tree: TBookTree; Data: PBookRecord; Book: TBookRecord;
begin
  GetActiveTree(Tree); if not Assigned(Tree) then Exit;
  Data := Tree.GetNodeData(Tree.GetFirstSelected);
  if not Assigned(Data) or (Data^.NodeType <> ntBookInfo) then Exit;
  if not CatalogBookAvailable(Data^) then Exit;
  Book := ResolveReaderBook(FSystemData.GetCollection(Data^.BookKey.DatabaseID),Data^);
  PrepareReaderFileInBackground(Self,Book,True,
    procedure(WorkFile: string)
    begin
      WorkFile := ExistingBookCacheFile(WorkFile); PinReaderCacheFile(WorkFile);
      OpenInArchiveManager(WorkFile);
    end,True);
end;

procedure TfrmMain.BookLocationUpdate(Sender: TObject);
var Tree: TBookTree; Data: PBookRecord;
begin
  TAction(Sender).Enabled:=False;
  if not Assigned(FCollection) or not (ActiveView in [AuthorsView,SeriesView,PublisherSeriesView,GenresView,SearchView,FavoritesView]) then Exit;
  GetActiveTree(Tree); if not Assigned(Tree) then Exit;
  Data:=Tree.GetNodeData(Tree.GetFirstSelected);
  TAction(Sender).Enabled:=Assigned(Data) and (Data^.NodeType=ntBookInfo) and CatalogBookAvailable(Data^, False);
end;

procedure TfrmMain.BookLocationExecute(Sender: TObject);
var Tree: TBookTree; Data: PBookRecord;
begin
  GetActiveTree(Tree); if not Assigned(Tree) then Exit; Data:=Tree.GetNodeData(Tree.GetFirstSelected);
  if Assigned(Data) and (Data^.NodeType=ntBookInfo) and CatalogBookAvailable(Data^) then ShowBookLocation(Self,Data^);
end;

procedure TfrmMain.ChooseReaderExecute(Sender: TObject);
var Tree: TBookTree; Data: PBookRecord;
begin
  GetActiveTree(Tree); if not Assigned(Tree) then Exit; Data:=Tree.GetNodeData(Tree.GetFirstSelected);
  if Assigned(Data) and (Data^.NodeType=ntBookInfo) then ReadPreparedBook(Data^,False,True,True);
end;

procedure TfrmMain.BrowseAllReaderNotes(Sender: TObject);
var Note: TReaderAnnotation;
begin
  try
    if BrowseReaderNotes(Self,ResolveReaderSettingsFile(Settings.DataDir),Note) then OpenReaderNote(Note);
  finally RefreshNotesSearch; end;
end;

procedure TfrmMain.RefreshNotesSearch;
var Criteria: TBookSearchCriteria;
begin
  if not Assigned(FCollection) or not FHasAppliedSearch or not FSearchCriteria.NotesOnly then Exit;
  Criteria:=FSearchCriteria;
  Criteria.NoteBookIDs:=ReaderNoteBookIDs(FSystemData,ResolveReaderSettingsFile(Settings.DataDir),FCollection.CollectionID);
  FSearchCriteria:=Criteria; Exclude(FLoadedBookViews,SearchView);
  if ActiveView=SearchView then ApplySearchCriteria(Criteria);
end;

procedure TfrmMain.OpenReaderNote(const Note: TReaderAnnotation);
var Book: TBookRecord; Ini: TMemIniFile; SettingsFile: string; Preferred: Integer;
begin
  Preferred:=-1; if Assigned(FCollection) then Preferred:=FCollection.CollectionID;
  SettingsFile:=ResolveReaderSettingsFile(Settings.DataDir);
  if not FindReaderNoteBook(FSystemData,SettingsFile,Note,Preferred,Book) then
  begin
    MHLShowInfo('Книга этой заметки не найдена в подключённых коллекциях. Сама заметка сохранена.'); Exit;
  end;
  if not Assigned(FCollection) or not CatalogBookAvailable(Book) then Exit;
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try
    Ini.WriteInteger('Book.'+Note.BookID,'Position',Note.Position); SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
  // This is a resolved catalog note, independent of the selected group row.
  ReadPreparedBook(Book,True,False,False,'',False,True);
end;

procedure TfrmMain.ReadPreparedBook(const BookRecord: TBookRecord; UseBuiltin, ChooseReader, ForceChoice: Boolean;
  const ReaderPathOverride: string; KeepKindlePreparation, FromNotes: Boolean);
var
  BookFileName: string;
  BookFormat: TBookFormat;
  CollectionInfo: TCollectionInfo;
  ReaderBook: TBookRecord;
  ReaderCollection: IBookCollection;
  ReaderKey: TBookKey;
  Snapshot: TBookRecord;
  KindleReader: TReaderDesc;
  PrepareKindle, RequirePersonalProgress: Boolean;
  ReaderNamespace: string;
  ReaderDownloads: TBookIdList;
begin
  if not CatalogBookAvailable(BookRecord) then Exit;
  Assert(Assigned(FCollection));

  Assert(BookRecord.nodeType = ntBookInfo);

  Snapshot := BookRecord; RequirePersonalProgress := (ActiveView = FavoritesView) and not FromNotes;
  KindleReader := Settings.Readers.Find(BookRecord.FileExt);
  PrepareKindle := KeepKindlePreparation or UseBuiltin or ChooseReader or (Assigned(KindleReader) and
    SameText(ExtractFileName(KindleReader.Path),'SumatraPDF.exe'));
  ReaderCollection := FSystemData.GetCollection(BookRecord.BookKey.DatabaseID);
  ReaderNamespace := ''; try ReaderNamespace := VarToStr(ReaderCollection.GetProperty(PROP_SOURCE_LIBRARY)); except end;
  ReaderKey := BookRecord.BookKey;
  ReaderBook := ResolveReaderBook(ReaderCollection, BookRecord);
  BookFileName := ReaderBook.GetBookFileName;
  BookFormat := ReaderBook.GetBookFormat;

  // Download remote FB2 before reading its bytes for reader compatibility.
  if (BookFormat in [bfFb2, bfFb2Archive]) and
    not (bpIsLocal in ReaderBook.BookProps) then
  begin
    CollectionInfo := FSystemData.GetCollectionInfo(BookRecord.BookKey.DatabaseID);
    if isOnlineCollection(CollectionInfo.CollectionType) then
    begin
      SetLength(ReaderDownloads,1); ReaderDownloads[0]:=Default(TBookIdStruct);
      ReaderDownloads[0].BookKey:=Snapshot.BookKey; ReaderDownloads[0].HasExpectedIdentity:=True;
      ReaderDownloads[0].ExpectedLibID:=Snapshot.LibID;
      ReaderDownloads[0].ExpectedPhysicalIdentity:=ReaderBookPhysicalIdentity(Snapshot);
      unit_ExportToDevice.DownloadBooks(ReaderDownloads);
      if not FileExists(BookFileName) then
        Exit; // The download already reported its failure or was cancelled.
    end;
  end;

  PrepareReaderFileInBackground(Self, ReaderBook, UseBuiltin or ChooseReader,
    procedure(WorkFile: string)
    var ChosenBuiltin, RewriteFB2: Boolean; ExternalPath: string;
    begin
      try
        if WorkFile = '' then Exit;
        WorkFile := ExistingBookCacheFile(WorkFile);
        PinReaderCacheFile(WorkFile);

        ChosenBuiltin:=UseBuiltin; ExternalPath:=ReaderPathOverride;
        if ChooseReader and not ChooseBookReader(Self,WorkFile,Snapshot.FileExt,ChosenBuiltin,ExternalPath,ForceChoice) then Exit;
        if ChooseReader and not ChosenBuiltin then
        begin
          // The first preparation preserves originals for the reader choice.
          // Apply the external reader's WebP compatibility policy afterwards.
          ReadPreparedBook(Snapshot,False,False,False,ExternalPath,PrepareKindle);
          Exit;
        end;
        RewriteFB2:=not ChosenBuiltin and Settings.OverwriteFB2Info and (BookFormat=bfFb2);

        if ChosenBuiltin then
        begin
          if IsOfficeReaderFormat(ExtractFileExt(WorkFile)) then
          begin
            // The choice precedes conversion, so external Office opening stays immediate.
            ReadPreparedBook(Snapshot,True);
            Exit;
          end;
          if not ReaderSupportsReflow(WorkFile) and not SameText(ExtractFileExt(WorkFile), '.pdf') then
          begin
            MHLShowInfo('Этот формат пока не поддерживается встроенной читалкой. Выберите «Читать во внешней программе» в меню книги.');
            Exit;
          end;
          RegisterReaderNoteBook(ResolveReaderSettingsFile(Settings.DataDir),Snapshot,ReaderNamespace);
          OpenBuiltinReader(Self, WorkFile, Snapshot.Title, ReaderHistoryName(Snapshot, ReaderNamespace),
            ResolveReaderSettingsFile(Settings.DataDir), Settings.AppPath + 'tools\pdfium\pdfium.dll',
            procedure(Progress: Integer)
            var Changed: TBookRecord; Outcome: TReaderPersonalWriteResult;
              GroupNode: PVirtualNode; GroupData: PBookRecord;
            begin
              Changed := Snapshot; Changed.Progress := Progress;
              Outcome := TryStoreReaderBookPersonal(ReaderCollection, FSystemData, Changed,
                [bpfProgress], RequirePersonalProgress);
              if Outcome = rpwCatalog then
                UpdateNodes(ReaderKey,
                  procedure(BookData: PBookRecord)
                  begin
                    if Assigned(BookData) and ReaderBookMatchesExpectedIdentity(Snapshot.LibID,
                      ReaderBookPhysicalIdentity(Snapshot), BookData^, ReaderNamespace) then
                      BookData^.Progress := Progress;
                  end)
              else if Outcome = rpwPersonal then
              begin
                GroupNode := tvBooksF.GetFirst;
                while Assigned(GroupNode) do
                begin
                  GroupData := tvBooksF.GetNodeData(GroupNode);
                  if Assigned(GroupData) and GroupData^.BookKey.IsSameAs(ReaderKey) and
                    ReaderBookMatchesExpectedIdentity(Snapshot.LibID, ReaderBookPhysicalIdentity(Snapshot),
                      GroupData^, ReaderNamespace) then
                  begin GroupData^.Progress := Progress; tvBooksF.InvalidateNode(GroupNode); end;
                  GroupNode := tvBooksF.GetNext(GroupNode);
                end;
                if not (csDestroying in ComponentState) then
                  StatusMessage := 'Позиция и личный прогресс сохранены. Каталог книги не обновлён.';
              end
              else if not (csDestroying in ComponentState) then
                StatusMessage := 'Позиция сохранена в читалке. Карточка книги недоступна; прогресс каталога не обновлён.';
            end,
            procedure(Note: TReaderAnnotation) begin OpenReaderNote(Note); end);
          RefreshNotesSearch;
        end
        else if ExternalPath<>'' then
          PrepareExternalReaderFileInBackground(Self,ReaderBook,WorkFile,ReaderNamespace,
            procedure(NamedFile: string)
            begin
              if RewriteFB2 and not WriteFb2InfoToFile(Snapshot,NamedFile) then
                raise Exception.Create('Не удалось обновить сведения FB2 в копии для читалки. Оригинал книги не изменён.');
              if SimpleShellExecute(Handle,ExternalPath,NamedFile)<=32 then
                raise Exception.Create('Не удалось открыть читалку: '+ExternalPath);
            end,RewriteFB2)
        else
          PrepareExternalReaderFileInBackground(Self,ReaderBook,WorkFile,ReaderNamespace,
            procedure(NamedFile: string)
            begin
              if RewriteFB2 and not WriteFb2InfoToFile(Snapshot,NamedFile) then
                raise Exception.Create('Не удалось обновить сведения FB2 в копии для читалки. Оригинал книги не изменён.');
              Settings.Readers.RunReader(NamedFile);
            end,RewriteFB2);
      finally
        TrimBookCache;
      end;
    end, False, PrepareKindle, UseBuiltin);
end;

procedure TfrmMain.SetHideDeletedMode(Value: Boolean; RefreshCurrent: Boolean);
var
  Changed: Boolean;
  SavedCursor: TCursor;
begin
  if FUpdatingDeletedControls then Exit;
  Changed := Settings.HideDeletedBooks <> Value;
  SavedCursor := Screen.Cursor;
  FUpdatingDeletedControls := True;
  try
    if Changed and Assigned(FCollection) and not FInvisible then UpdatePositions;
    Settings.HideDeletedBooks := Value;
    if Assigned(FCollection) then FCollection.SetHideDeleted(Value);
    cbDeleted.Checked := Value;
    acViewHideDeletedBooks.Checked := Value;
    // Only this condition changes; unfinished search text stays in the controls.
    FSearchCriteria.Deleted := Value;
    if FFavoriteSearchPending then FFavoritePendingCriteria.Deleted := Value;
    if not Changed then Exit;

    FLoadedBookViews := FLoadedBookViews -
      [AuthorsView, SeriesView, GenresView, PublisherSeriesView, FavoritesView, SearchView];
    FPublisherListLoaded := False;
    FStaleSelectors := FStaleSelectors + [AuthorsView, SeriesView];
    if RefreshCurrent and Assigned(FCollection) and not FInvisible then
    begin
      Screen.Cursor := crHourGlass;
      EnsureActiveBookViewLoaded;
    end;
  finally
    FUpdatingDeletedControls := False;
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.SearchDeletedClick(Sender: TObject);
begin
  if FUpdatingDeletedControls or FInvisible or not Assigned(FCollection) then Exit;
  SetHideDeletedMode(cbDeleted.Checked);
end;

procedure TfrmMain.HideDeletedBooksExecute(Sender: TObject);
begin
  if not Assigned(FCollection) or FInvisible then Exit;
  SetHideDeletedMode(not Settings.HideDeletedBooks);
end;

procedure TfrmMain.ReloadAppliedSearch;
var
  Criteria: TBookSearchCriteria;
  SelectedKey: TBookKey;
  Data: PBookRecord;
begin
  if not FHasAppliedSearch then
  begin
    tvBooksSR.Clear;
    SetBookListTotals(tvBooksSR, 0, 0);
    ClearLabels(PAGE_SEARCH, True);
    FBookListCancelled := False;
    Exit;
  end;

  SelectedKey.Clear;
  Data := tvBooksSR.GetNodeData(tvBooksSR.GetFirstSelected);
  if Assigned(Data) and (Data^.nodeType = ntBookInfo) then SelectedKey := Data^.BookKey;
  Criteria := FSearchCriteria;
  if not PrepareFavoriteSearch(Criteria) then
  begin
    FFavoritePendingCriteria := Criteria;
    FFavoritePendingCID := FCollection.CollectionID;
    FFavoriteSearchPending := True;
    tvBooksSR.Clear;
    SetBookListTotals(tvBooksSR, 0, 0);
    StatusMessage := 'Подготовка любимых авторов...';
    Exit;
  end;
  FillBooksTree(tvBooksSR, nil,
    function: IBookIterator begin Result := FCollection.Search(Criteria, False); end,
    True, True, @SelectedKey);
end;

procedure TfrmMain.HideDeletedBooksUpdate(Sender: TObject);
begin
  acViewHideDeletedBooks.Visible := True;
  acViewHideDeletedBooks.Enabled := Assigned(FCollection);
  acViewHideDeletedBooks.Checked := Settings.HideDeletedBooks;
end;

function TfrmMain.GetFilterButton(ToolBars: array of TWinControl; const Filter: string): TToolButton;
var
  RealFilter: string;
  barIndex: Integer;
  bar: TWinControl;
  i: Integer;
begin
  Result := nil;

  if Filter = '' then
    Exit;

  RealFilter := Char.ToUpper(Copy(Filter, 1, 1));

  // Внимание: индекс в TCharHelper отсчитывается с нуля, в отличие от строк Delphi
  if not Char.IsLetter(RealFilter, 0) then
    RealFilter := ALPHA_FILTER_ALL;

  for barIndex := 0 to High(ToolBars) do
  begin
    bar := ToolBars[barIndex];

    for i := 0 to bar.ControlCount - 1 do
    begin
      if (bar.Controls[i] is TToolButton) and ((bar.Controls[i] as TToolButton).Caption = RealFilter) then
      begin
        Result := bar.Controls[i] as TToolButton;
        Exit;
      end;
    end;
  end;

  // Names may start with letters absent from the Russian and Latin toolbars.
  // Keep the saved name for LocateAuthor/LocateSeries, using the full list.
  if RealFilter <> ALPHA_FILTER_ALL then
    Result := GetFilterButton(ToolBars, ALPHA_FILTER_ALL);
  Assert(Assigned(Result));
end;

function TfrmMain.InternalSetAuthorFilter(Button: TToolButton): string;
begin
  Assert(Assigned(FCollection));
  if Assigned(FLastLetterA) then
    FLastLetterA.Down := False;
  FLastLetterA := Button;
  FLastLetterA.Down := True;

  Result := Char.ToUpper(Button.Caption);

  FCollection.SetAuthorFilterType(Result);

  FillAuthorTree(tvAuthors, AuthorSelectorIterator, FLastAuthorID);

  if (Result = ALPHA_FILTER_ALL) or (Result = ALPHA_FILTER_NON_ALPHA) then
  begin
    Result := '';
  end
  else
  begin
    Assert(Length(Result) = 1);
  end;
end;

procedure TfrmMain.OnSetAuthorFilter(Sender: TObject);
var
  SavedCursor: TCursor;
  Button: TToolButton;
  AFilter: string;
begin
  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    UpdatePositions;

    Assert(Sender is TToolButton);
    Button := Sender as TToolButton;

    AFilter := InternalSetAuthorFilter(Button);

    Assert(Length(AFilter) < 2);
    SetTextNoChange(edLocateAuthor, AFilter);
    if AFilter <> '' then
    begin
      edLocateAuthor.SelStart := 1;
      edLocateAuthor.SelLength := 0;
    end;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

function TfrmMain.InternalSetSeriesFilter(Button: TToolButton): string;
begin
  Assert(Assigned(FCollection));
  if Assigned(FLastLetterS) then
    FLastLetterS.Down := False;
  FLastLetterS := Button;
  FLastLetterS.Down := True;

  Result := Char.ToUpper(Button.Caption);

  FCollection.SetSeriesFilterType(Result);

  FillSeriesTree(tvSeries, FCollection.GetSeriesIterator(smFullFilter), FLastSeriesID);

  if (Result = ALPHA_FILTER_ALL) or (Result = ALPHA_FILTER_NON_ALPHA) then
  begin
    Result := '';
  end
  else
  begin
    Assert(Length(Result) = 1);
  end;
end;

procedure TfrmMain.OnSetSerieFilter(Sender: TObject);
var
  SaveCursor: TCursor;
  Button: TToolButton;
  AFilter: string;
begin
  Assert(Assigned(FCollection));
  SaveCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    UpdatePositions;

    Assert(Sender is TToolButton);
    Button := Sender as TToolButton;

    AFilter := InternalSetSeriesFilter(Button);

    FillSeriesTree(tvSeries, FCollection.GetSeriesIterator(smFullFilter), FLastSeriesID);

    Assert(Length(AFilter) < 2);
    SetTextNoChange(edLocateSeries, AFilter);
    if AFilter <> '' then
    begin
      edLocateSeries.SelStart := 1;
      edLocateSeries.SelLength := 0;
    end;
  finally
    Screen.Cursor := SaveCursor;
  end;
end;

procedure TfrmMain.TrayIconDblClick(Sender: TObject);
begin
  Visible := not Visible;
  TrayIcon.Visible := not Visible;
end;

procedure TfrmMain.ShowLocalOnlyExecute(Sender: TObject);
var
  SavedCursor: TCursor;
begin
  Assert(Assigned(FCollection));
  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    UpdatePositions;

    Settings.ShowLocalOnly := not Settings.ShowLocalOnly;

    FCollection.SetShowLocalOnly(Settings.ShowLocalOnly);

    FillAuthorTree(tvAuthors, AuthorSelectorIterator, FLastAuthorID);
    FillSeriesTree(tvSeries, FCollection.GetSeriesIterator(smFullFilter), FLastSeriesID);
    FillAllBooksTree;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.ShowLocalOnlyUpdate(Sender: TObject);
begin
  acViewShowLocalOnly.Visible := IsOnline;
  acViewShowLocalOnly.Checked := Settings.ShowLocalOnly;
end;

procedure TfrmMain.ShowBookDelete(Sender: TObject);
begin
  acBookDelete.Visible := IsPrivate or IsOnline;
  acCollectionSyncFiles.Visible := IsPrivate or IsOnline;
end;

procedure TfrmMain.SetInfoPanelHeight(Height: Integer);
begin
  // Every panel's OnResize calls back in here, so without the guard each
  // assignment below re-enters and changes the panels' bounds while their
  // parent is still inside AlignControls. That leaves the splitter's bottom
  // edge below the info panel's, and since the VCL orders alBottom siblings by
  // that edge, the splitter gets parked at the bottom of the view for good.
  if FInSetInfoPanelHeight then
    Exit;

  FInSetInfoPanelHeight := True;
  try
    ipnlAuthors.Height := Height;
    ipnlSeries.Height := Height;
    ipnlGenres.Height := Height;
    ipnlSearch.Height := Height;
    ipnlFavorites.Height := Height;
    if Assigned(FPublisher) then FPublisher.Info.Height := Height;
  finally
    FInSetInfoPanelHeight := False;
  end;
end;

procedure TfrmMain.SetInfoPanelVisible(State: Boolean);
begin
  ipnlAuthors.Visible := State;
  AuthorBookInfoSplitter.Visible := State;

  ipnlSeries.Visible := State;
  SerieBookInfoSplitter.Visible := State;

  ipnlGenres.Visible := State;
  GenreBookInfoSplitter.Visible := State;

  ipnlSearch.Visible := State;
  SearchBookInfoSplitter.Visible := State;

  ipnlFavorites.Visible := State;
  GroupBookInfoSplitter.Visible := State;
  FPublisher.Info.Visible := State;
  FPublisher.InfoSplitter.Visible := State;
end;

procedure TfrmMain.SetShowBookCover(State: Boolean);
begin
  ipnlAuthors.ShowCover := State;
  ipnlSeries.ShowCover := State;
  ipnlGenres.ShowCover := State;
  ipnlSearch.ShowCover := State;
  ipnlFavorites.ShowCover := State;
  FPublisher.Info.ShowCover := State;
end;

procedure TfrmMain.SetShowBookAnnotation(State: Boolean);
begin
  ipnlAuthors.ShowAnnotation := State;
  ipnlSeries.ShowAnnotation := State;
  ipnlGenres.ShowAnnotation := State;
  ipnlSearch.ShowAnnotation := State;
  ipnlFavorites.ShowAnnotation := State;
  FPublisher.Info.ShowAnnotation := State;
end;

procedure TfrmMain.SetBookInfoPriority(State: Boolean);
begin
  ipnlAuthors.InfoPriority := State;
  ipnlSeries.InfoPriority := State;
  ipnlGenres.InfoPriority := State;
  ipnlSearch.InfoPriority := State;
  ipnlFavorites.InfoPriority := State;
  FPublisher.Info.InfoPriority := State;
end;

procedure TfrmMain.tbClearEdAuthorClick(Sender: TObject);
begin
  SetTextNoChange(edLocateAuthor, '');
  frmMain.ActiveControl := edLocateAuthor;
end;

procedure TfrmMain.tbCollapseClick(Sender: TObject);
var
  Tree: TBookTree;
begin
  GetActiveTree(Tree);
  if Tree.Expanded[Tree.GetFirst] then
    Tree.FullCollapse(nil)
  else
    Tree.FullExpand(nil);
end;

// Fills the info panel from whatever book the tree has focused. Only for the
// view on screen. Covers and annotations are read by the background preview.
procedure TfrmMain.RefreshBookInfo(const Tree: TBookTree);
begin
  if FInvisible or not Assigned(Tree) then
    Exit;

  if (ActiveView <> DownloadView) and (Tree = GetViewTree(ActiveView)) then
    tvBooksTreeChange(Tree, Tree.FocusedNode);
end;

procedure TfrmMain.RefreshActiveBookInfo;
begin
  if ActiveView <> DownloadView then
    RefreshBookInfo(GetViewTree(ActiveView));
end;

// Build only the book list that has actually become visible. Large imported
// collections can contain tens of thousands of books in the default genre, so
// eagerly building the hidden Genres page used to dominate application startup.
procedure TfrmMain.EnsureActiveBookViewLoaded;
var
  View: TView;
  Tree: TBookTree;
  LangSelector: TComboBox;
  PendingLangIndex: Integer;
  PendingBookID: Integer;
  AlreadyLoaded: Boolean;

  procedure RestoreBookSelection;
  var
    Node: PVirtualNode;
    Data: PBookRecord;
  begin
    if (PendingBookID = 0) or not Assigned(Tree) then Exit;

    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Data := Tree.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType = ntBookInfo) and
         (Data^.BookKey.BookID = PendingBookID) then
      begin
        if Tree.Selected[Node] and (Tree.FocusedNode = Node) then Exit;
        Tree.ClearSelection;
        Tree.Selected[Node] := True;
        Tree.FocusedNode := Node;
        Tree.ScrollIntoView(Node, True);
        Break;
      end;
      Node := Tree.GetNext(Node);
    end;
  end;

begin
  if FInvisible or not Assigned(FCollection) then Exit;

  Inc(FBookInfoUpdateCount);
  try
  View := ActiveView;
  AlreadyLoaded := View in FLoadedBookViews;
  if View in FStaleSelectors then
  begin
    FInvisible := True;
    try
      if View = AuthorsView then
        FillAuthorTree(tvAuthors, AuthorSelectorIterator, FLastAuthorID)
      else if View = SeriesView then
        FillSeriesTree(tvSeries, FCollection.GetSeriesIterator(smFullFilter), FLastSeriesID);
      Exclude(FStaleSelectors, View);
    finally FInvisible := False; end;
  end;

  Tree := nil;
  LangSelector := nil;
  PendingBookID := 0;

  case View of
    AuthorsView:
      begin
        Tree := tvBooksA;
        LangSelector := cbLangSelectA;
        if FLastAuthorBookID.BookID > 0 then
          PendingBookID := FLastAuthorBookID.BookID
        else
          PendingBookID := FPendingAuthorBookID;
        if not AlreadyLoaded then
          tvAuthorsChange(tvAuthors, tvAuthors.GetFirstSelected);
      end;
    SeriesView:
      begin
        Tree := tvBooksS;
        LangSelector := cbLangSelectS;
        if FLastSeriesBookID.BookID > 0 then
          PendingBookID := FLastSeriesBookID.BookID
        else
          PendingBookID := FPendingSeriesBookID;
        if not AlreadyLoaded then
          tvSeriesChange(tvSeries, tvSeries.GetFirstSelected);
      end;
    PublisherSeriesView:
      begin
        Tree := FPublisher.Books;
        LangSelector := FPublisher.Language;
        if FLastPublisherBookID.BookID > 0 then
          PendingBookID := FLastPublisherBookID.BookID
        else
          PendingBookID := FPendingPublisherBookID;
        if not FPublisherListLoaded then
          ReloadPublisherSeries
        else if not AlreadyLoaded then
          PublisherSeriesChange(FPublisher.SeriesTree, FPublisher.SeriesTree.GetFirstSelected);
      end;
    GenresView:
      begin
        Tree := tvBooksG;
        LangSelector := cbLangSelectG;
        if not AlreadyLoaded then
          tvGenresChange(tvGenres, tvGenres.GetFirstSelected);
      end;
    SearchView:
      begin
        Tree := tvBooksSR;
        if not AlreadyLoaded then ReloadAppliedSearch;
      end;
    FavoritesView:
      begin
        Tree := tvBooksF;
        LangSelector := cbLangSelectF;
        if not AlreadyLoaded then
          tvGroupsChange(tvGroups, tvGroups.GetFirstSelected);
      end;
  end;

  if FBookListCancelled then Exit;
  Include(FLoadedBookViews, View);

  // A root genre has not built a language list until the explicit Show action.
  // Preserve the stored filter instead of treating the navigation-only list as data.
  if Assigned(LangSelector) and
    not ((View = GenresView) and FLastGenreIsTopLevelContainer and
      not FRootGenreBooksRequested) then
  begin
    PendingLangIndex := FPendingLangFilters[View];
    FPendingLangFilters[View] := -1;
    if (PendingLangIndex >= 0) and
       (PendingLangIndex < LangSelector.Items.Count) and
       (PendingLangIndex <> LangSelector.ItemIndex) then
    begin
      LangSelector.ItemIndex := PendingLangIndex;
      cbLangSelectAChange(LangSelector);
    end;
  end;

  RestoreBookSelection;
  if View = AuthorsView then FPendingAuthorBookID := 0;
  if View = SeriesView then FPendingSeriesBookID := 0;
  if View = PublisherSeriesView then FPendingPublisherBookID := 0;
  finally
    Dec(FBookInfoUpdateCount);
  end;
  RefreshActiveBookInfo;
end;

function TfrmMain.GetViewTree(view: TView): TBookTree;
begin
  case view of
    AuthorsView:
      Result := tvBooksA;
    SeriesView:
      Result := tvBooksS;
    PublisherSeriesView:
      Result := FPublisher.Books;
    GenresView:
      Result := tvBooksG;
    SearchView:
      Result := tvBooksSR;
    FavoritesView:
      Result := tvBooksF;
  else
    begin
      Assert(False, rstrCheckUsage);
      Result := nil;
    end;
  end;
end;

procedure TfrmMain.GroupMenuItemClick(Sender: TObject);
begin
  AddBookToGroup(Sender);
end;

procedure TfrmMain.GetActiveTree(var Tree: TBookTree);
begin
  Tree := GetViewTree(ActiveView);
end;

procedure TfrmMain.Selection(SelState: Boolean);
var
  Node: PVirtualNode;
  Tree: TBookTree;
begin
  GetActiveTree(Tree);
  Tree.BeginUpdate;
  try
    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      if SelState and not Tree.IsEffectivelyFiltered[Node] then
        Node.CheckState := csCheckedNormal
      else
        Node.CheckState := csUncheckedNormal;
      Node := Tree.GetNext(Node);
    end;
  finally
    Tree.EndUpdate;
  end;
end;

procedure TfrmMain.OnSelectBookHandler(MoveForward: Boolean);
var
  Tree: TBookTree; Node, OldNode: PVirtualNode;
  Data: PBookRecord; Attempts: Cardinal;
begin
  GetActiveTree(Tree); OldNode := Tree.GetFirstSelected; Node := OldNode;
  for Attempts := 1 to Tree.TotalCount do
  begin
    if MoveForward then
    begin
      Node := Tree.GetNext(Node);
      if not Assigned(Node) then Node := Tree.GetFirst;
    end
    else
    begin
      Node := Tree.GetPrevious(Node);
      if not Assigned(Node) then Node := Tree.GetLast;
    end;
    if not Assigned(Node) then Exit;
    Data := Tree.GetNodeData(Node);
    if (Data.nodeType = ntBookInfo) and not Tree.IsEffectivelyFiltered[Node] then
    begin
      if Assigned(OldNode) then Tree.Selected[OldNode] := False;
      Tree.Selected[Node] := True; Tree.FocusedNode := Node; Exit;
    end;
  end;
end;

procedure TfrmMain.tbSelectAllClick(Sender: TObject);
begin
  FSelectionState := not FSelectionState;
  Selection(FSelectionState);
end;


procedure TfrmMain.CancelBookList(Sender: TObject);
begin
  FBookListCancelled := True;
end;

function TfrmMain.PollBookListCancel: Boolean;
var Message: TMsg; Now: UInt64;

  function IsLocateInput(Window: HWND): Boolean;
  begin
    Result := (edLocateAuthor.HandleAllocated and (Window = edLocateAuthor.Handle)) or
      (edLocateSeries.HandleAllocated and (Window = edLocateSeries.Handle)) or
      (Assigned(FPublisher) and FPublisher.Search.HandleAllocated and
        (Window = FPublisher.Search.Handle));
  end;

begin
  Now:=GetTickCount64;
  if Now-FBookListLastPump>=16 then
  begin
    FBookListLastPump:=Now;
    // Check the complete queue so Windows sees the UI as responsive, even
    // while actions and timers are intentionally left pending.
    PeekMessage(Message,0,0,0,PM_NOREMOVE);
    // Repaint every owned window and accept normal mouse input on Cancel.
    // Timers, actions and queued callbacks remain deferred while SQLite runs.
    while PeekMessage(Message,0,WM_PAINT,WM_PAINT,PM_REMOVE) do DispatchMessage(Message);
    while PeekMessage(Message,0,WM_MOUSEFIRST,WM_MOUSELAST,PM_REMOVE) do
      if Message.hwnd=FBookListCancel.Handle then
      begin
        // VCL can defer the button's command notification. Recognize the
        // actual release here as well, before the restricted pump returns.
        if (Message.message=WM_LBUTTONUP) and PtInRect(FBookListCancel.ClientRect,
          Point(SmallInt(LOWORD(Message.lParam)),SmallInt(HIWORD(Message.lParam)))) then
          FBookListCancelled:=True;
        DispatchMessage(Message);
      end;
    while PeekMessage(Message,0,WM_COMMAND,WM_COMMAND,PM_REMOVE) do
      if HWND(Message.lParam)=FBookListCancel.Handle then DispatchMessage(Message);
    while PeekMessage(Message,0,WM_KEYFIRST,WM_KEYLAST,PM_REMOVE) do
      if (Message.message=WM_KEYDOWN) and (Message.wParam=VK_ESCAPE) then FBookListCancelled:=True
      else if IsLocateInput(Message.hwnd) and
        ((Message.message = WM_KEYDOWN) or (Message.message = WM_KEYUP) or (Message.message = WM_CHAR)) then
      begin
        // Preserve typing/editing while its previous book query runs. Navigation
        // keys and system shortcuts must not re-enter selectors or actions.
        if ((Message.message = WM_KEYDOWN) or (Message.message = WM_KEYUP)) and
          (Message.wParam in [VK_TAB, VK_RETURN, VK_UP, VK_DOWN, VK_ESCAPE]) then Continue;
        if (Message.message = WM_CHAR) and (Message.wParam in [9, 13, 27]) then Continue;
        if Message.message = WM_KEYDOWN then TranslateMessage(Message);
        DispatchMessage(Message);
      end;
  end;
  Result:=FBookListCancelled;
end;

procedure TfrmMain.FillBooksTree(const Tree: TBookTree; const LangSelector: TComboBox;
  const BookIterator: IBookIterator; ShowAuth, ShowSer: Boolean; SelectedID: PBookKey);
begin
  FillBooksTree(Tree, LangSelector,
    function: IBookIterator begin Result := BookIterator; end, ShowAuth, ShowSer, SelectedID);
end;

procedure TfrmMain.FillBooksTree(const Tree: TBookTree; const LangSelector: TComboBox;
  const Factory: TFunc<IBookIterator>; ShowAuth, ShowSer: Boolean; SelectedID: PBookKey);
var Iterator: IBookIterator; SavedCursor: TCursor;
begin
  if FBookListLoading then Exit;
  FBookListLoading := True;
  FBookListCancelled := False;
  Inc(FBookInfoUpdateCount);
  SavedCursor := Screen.Cursor;
  Screen.Cursor := crDefault;
  FBookListLastPump:=0;
  FController.CancelCheck:=function: Boolean begin Result:=PollBookListCancel; end;
  ShowStatusProgress := True;
  StatusProgress := 0;
  FBookListCancel.Visible := True;
  FBookListCancel.BringToFront;
  FStatusProgressBar.BringToFront;
  FBookListCancel.Update;
  SQLiteCancelCallback := PollBookListCancel;
  try
    try
      Iterator := Factory();
      FillBooksTreeCore(Tree, LangSelector, Iterator, ShowAuth, ShowSer, SelectedID);
    except
      on E: Exception do
      begin
        if not FBookListCancelled then raise;
        SQLiteCancelCallback := nil;
        Tree.Clear;
        SetBookListTotals(Tree, 0, 0);
        Exclude(FLoadedBookViews, TView(Tree.Tag));
      end;
    end;
  finally
    // Cleanup queries must remain possible after SQLITE_INTERRUPT.
    SQLiteCancelCallback := nil;
    FController.CancelCheck:=nil;
    Iterator := nil;
    FBookListCancel.Visible := False;
    ShowStatusProgress := False;
    Screen.Cursor := SavedCursor;
    FBookListLoading := False;
    Dec(FBookInfoUpdateCount);
  end;
  if FBookListCancelled then StatusMessage := 'Загрузка списка отменена';
  RefreshBookInfo(Tree);
end;

procedure TfrmMain.FillBooksTreeCore(
  const Tree: TBookTree;
  const LangSelector: TComboBox;
  const BookIterator: IBookIterator;
  ShowAuth: Boolean;
  ShowSer: Boolean;
  SelectedID: PBookKey
);
var
  AuthorNode: PVirtualNode;
  SerieNode: PVirtualNode;
  BookNode: PVirtualNode;
  SelectedNode: PVirtualNode;

  Data: PBookRecord;
  Max, i, VisibleCount: Integer;
  Author: string;

  AuthorNodes: TDictionary<string, PVirtualNode>;
  SeriesNodes: TObjectDictionary<PVirtualNode, TDictionary<Integer, PVirtualNode>>;
  AuthorSeries: TDictionary<Integer, PVirtualNode>;
  Languages: TDictionary<string, Boolean>;
  Language: string;

  SeriesID: Integer;

  BookRecord: TBookRecord;
  SavedCursor: TCursor;

  SelectedLang: string;
  SelectedKey: TBookKey;

begin
  Assert(Assigned(Tree));
  Assert(Assigned(BookIterator));

  if Settings.TreeModes[Tree.Tag] = tmFlat then
  begin
    ShowAuth := False;
    ShowSer := False;
  end;

  SelectedKey.Clear;
  if Assigned(SelectedID) then SelectedKey := SelectedID^;
  ShowStatusProgress := True;
  StatusProgress := 0;

  SavedCursor := Tree.Cursor;
  Tree.Cursor := crHourGlass;
  try
    Tree.BeginUpdate;
    try
      Tree.Clear;
      Tree.NodeDataSize := SizeOf(TBookRecord);

      SelectedNode := nil;

      StatusMessage := rstrBuildingTheList;

      if LangSelector <> nil then
      begin
        SelectedLang := LangSelector.Text;

        if not FViewLanguageSelected[TView(Tree.Tag)] then
        begin
          LangSelector.Items.Clear;
          LangSelector.Items.Add('-');
          LangSelector.ItemIndex := 0;
        end;

      end;

      i := 0;
      try
        AuthorNodes := TDictionary<string, PVirtualNode>.Create;
        try
          SeriesNodes := TObjectDictionary<PVirtualNode, TDictionary<Integer, PVirtualNode>>.Create([doOwnsValues]);
          Languages := TDictionary<string, Boolean>.Create;
          try
          if Assigned(LangSelector) then
            for Language in LangSelector.Items do Languages.AddOrSetValue(Language, True);
          Max := BookIterator.RecordCount;

          while BookIterator.Next(BookRecord) do
          begin
            if ((i and 255) = 0) and PollBookListCancel then Abort;
            if LangSelector <> nil then
            begin
              if not Languages.ContainsKey(BookRecord.Lang) then
              begin
                LangSelector.Items.Add(BookRecord.Lang);
                Languages.Add(BookRecord.Lang, True);
              end;

              if (BookRecord.Lang <> SelectedLang) AND (SelectedLang <> '-')then Continue;
            end;

            // Серия берется из текущей книги и не зависит от LangSelector
            SeriesID := BookRecord.SeriesID;

            AuthorNode := nil;
            if ShowAuth then
            begin
              Author := TAuthorsHelper.GetList(BookRecord.Authors);
              if not AuthorNodes.TryGetValue(Author, AuthorNode) then
              begin
                AuthorNode := Tree.AddChild(nil);
                Data := Tree.GetNodeData(AuthorNode);

                Initialize(Data^);
                Data^.nodeType := ntAuthorInfo;
                Data^.Authors := BookRecord.Authors;

                AuthorNodes.Add(Author, AuthorNode);
              end;
            end
            else
              AuthorNode := nil;

            Assert(ShowAuth = Assigned(AuthorNode));

            if ShowSer then
            begin
              if SeriesID = NO_SERIES_ID then
              begin
                SerieNode := AuthorNode;
              end
              else
              begin
                if not SeriesNodes.TryGetValue(AuthorNode, AuthorSeries) then
                begin
                  AuthorSeries := TDictionary<Integer, PVirtualNode>.Create;
                  SeriesNodes.Add(AuthorNode, AuthorSeries);
                end;
                if not AuthorSeries.TryGetValue(SeriesID, SerieNode) then
                begin
                  Assert(not Assigned(SerieNode));

                  SerieNode := Tree.AddChild(AuthorNode);

                  Data := Tree.GetNodeData(SerieNode);

                  Data^.nodeType := ntSeriesInfo;
                  Data^.SeriesID := SeriesID;
                  Data^.Series := BookRecord.Series;
                  AuthorSeries.Add(SeriesID, SerieNode);
                end;
              end;
            end
            else
              SerieNode := AuthorNode;

            BookNode := Tree.AddChild(SerieNode);
            Data := Tree.GetNodeData(BookNode);
            Data^ := BookRecord; Data^.ListOrder := i;

            if (SelectedKey.BookID > 0) and SelectedKey.IsSameAs(Data^.BookKey) then
              SelectedNode := BookNode;

            Inc(i);
            if Max > 0 then StatusProgress := i * 100 div Max;
          end;
          if PollBookListCancel then Abort;
          if (Settings.TreeModes[Tree.Tag] = tmFlat) then
            Tree.SortTree(FSortSettings[Tree.Tag].Column, FSortSettings[Tree.Tag].Direction)
          else
            Tree.SortTree(NoColumn, sdAscending);
          finally
            Languages.Free; SeriesNodes.Free;
          end;
        finally
          FreeAndNil(AuthorNodes);
        end;
      finally
        ShowStatusProgress := False;
        StatusMessage := rstrReadyMessage;
      end;

      VisibleCount := i;
      if TBookColumnFilters.ForTree(Tree).Count > 0 then
        VisibleCount := TBookColumnFilters.ForTree(Tree).Apply(False,
          function: Boolean begin Result:=PollBookListCancel; end);
      if Assigned(SelectedNode) and Tree.IsEffectivelyFiltered[SelectedNode] then SelectedNode := nil;
      if not Assigned(SelectedNode) then
      begin
        SelectedNode := Tree.GetFirst;
        while Assigned(SelectedNode) do
        begin
          Data := Tree.GetNodeData(SelectedNode);
          if (Data^.nodeType = ntBookInfo) and not Tree.IsEffectivelyFiltered[SelectedNode] then
            Break;
          SelectedNode := Tree.GetNext(SelectedNode);
        end;
      end;

      if Assigned(SelectedNode) then
      begin
        Tree.Selected[SelectedNode] := True;
        Tree.FocusedNode := SelectedNode;
        Tree.FullyVisible[SelectedNode] := True;
        Tree.ScrollIntoView(SelectedNode, True);
      end;
    finally
      Tree.EndUpdate;
    end;

    SetBookListTotals(Tree, VisibleCount, i);

    case Tree.Tag of
      PAGE_AUTHORS:
        begin
          Include(FLoadedBookViews, AuthorsView);
          FPendingAuthorBookID := 0;
        end;
      PAGE_SERIES:
        begin
          Include(FLoadedBookViews, SeriesView);
          FPendingSeriesBookID := 0;
        end;
      PAGE_GENRES: Include(FLoadedBookViews, GenresView);
      PAGE_SEARCH: Include(FLoadedBookViews, SearchView);
      PAGE_FAVORITES: Include(FLoadedBookViews, FavoritesView);
      PAGE_PUBLISHER_SERIES: Include(FLoadedBookViews, PublisherSeriesView);
    end;

    // The book above was focused inside BeginUpdate/EndUpdate, where the tree
    // swallows OnChange - so the info panel would keep showing nothing until
    // the user clicked a book.

  finally
    Tree.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.miCopyAuthorClick(Sender: TObject);
var
  AuthorData: PAuthorData;
  SerieData: PSeriesData;
  GenreData: PGenreData;
  strText: string;

  Node: PVirtualNode;
  SeriesTree: TVirtualStringTree;

begin
  strText := '';

  case ActiveView of
    AuthorsView:
      begin
        Node := tvAuthors.GetFirstSelected;
        while Assigned(Node) do
        begin
          AuthorData := tvAuthors.GetNodeData(Node);
          if strText = '' then
            strText := AuthorData^.GetFullName
          else
            strText := strText + CRLF + AuthorData^.GetFullName;
          Node := tvAuthors.GetNextSelected(Node);
        end;
      end;

    SeriesView, PublisherSeriesView:
      begin
        if ActiveView = PublisherSeriesView then SeriesTree := FPublisher.SeriesTree
        else SeriesTree := tvSeries;
        Node := SeriesTree.GetFirstSelected;
        while Assigned(Node) do
        begin
          SerieData := SeriesTree.GetNodeData(Node);
          if strText = '' then
            strText := SerieData^.SeriesTitle
          else
            strText := strText + CRLF + SerieData^.SeriesTitle;
          Node := SeriesTree.GetNextSelected(Node);
        end;
      end;

    GenresView:
      begin
        Node := tvGenres.GetFirstSelected;
        while Assigned(Node) do
        begin
          GenreData := tvGenres.GetNodeData(Node);
          if strText = '' then
            strText := GenreData.GenreAlias
          else
            strText := strText + CRLF + GenreData.GenreAlias;
          Node := tvGenres.GetNextSelected(Node);
        end;
      end;
  end;

  Clipboard.AsText := Trim(strText);
end;

procedure TfrmMain.miCopyClBrdClick(Sender: TObject);
var
  Tree: TBookTree;
  S, R: string;
  Data: PBookRecord;
  Node: PVirtualNode;

begin
  GetActiveTree(Tree);

  S := '';
  R := '';

  Node := Tree.GetFirstSelected;
  while Assigned(Node) do
  begin
    Data := Tree.GetNodeData(Node);

    case Data^.nodeType of
      ntSeriesInfo:
        S := TAuthorsHelper.GetList(Data^.Authors) + '. ' + rstrSingleSeries + Data^.Series;

      ntBookInfo:
        if NO_SERIES_TITLE = Data^.Series then
          S := TAuthorsHelper.GetList(Data^.Authors) + '. ' + Data^.Title
        else
          S := TAuthorsHelper.GetList(Data^.Authors) + '. ' + rstrSingleSeries + Data^.Series + '. ' + Data^.Title;
    end;
    if S = '' then
      R := S
    else
      R := R + CRLF + S;

    Node := Tree.GetNextSelected(Node);
  end;
  Clipboard.AsText := Trim(R);
end;

procedure TfrmMain.DeleteBookExecute(Sender: TObject);
var
  Tree: TBookTree;
  Node, OldNode: PVirtualNode;
  Data: PBookRecord;
  BookFileName: string;
  SavedCursor: TCursor;
  Msg: string;
  BookKey: TBookKey;
begin
  Assert(Assigned(FCollection));
  if ActiveView = FavoritesView then
  begin
    MHLShowWarning(rstrChangeCollectionToRemoveABook);
    Exit;
  end;

  if IsOnline then Msg :=  rstrRemoveSelectedBooksOnLine
    else if Settings.DeleteFiles then Msg := rstrRemoveSelectedBooksFiles
    else Msg := rstrRemoveSelectedBooks;

  if MessageDlg(Msg, mtConfirmation, [mbYes, mbNo], 0) = mrNo then
    Exit;

  GetActiveTree(Tree);

  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Data := Tree.GetNodeData(Node);
      Assert(Assigned(Data));

      if (Data.nodeType = ntBookInfo) and (IsSelectedBookNode(Node, Data)) then
      begin
        BookKey := Data^.BookKey;
        BookFileName := Data^.GetBookFileName;

        if IsOnline then
        begin
          if (bpIsLocal in Data^.BookProps) and DeleteFile(BookFileName) then
          begin
            FCollection.SetLocal(Data^.BookKey, False);
            SetBookLocalStatus(Data^.BookKey, False);
          end;
          Node := Tree.GetNext(Node);
        end
        else
        begin
          OldNode := Node;
          Node := Tree.GetNext(Node);
          Tree.DeleteNode(OldNode);
          ClearLabels(Tree.Tag, False);

          if Settings.DeleteFiles then
          begin
            if not IsFB2 then
              DeleteFile(BookFileName)
            else if IsFB2 and IsPrivate then
              DeleteFile(BookFileName);
          end;

          FCollection.BeginBulkOperation;
          try
            FCollection.DeleteBook(BookKey);
            FCollection.EndBulkOperation(True);
          except
            FCollection.EndBulkOperation(False);
          end;
        end;
      end
      else
        Node := Tree.GetNext(Node);
    end;
    FPublisherListLoaded := False;
    Exclude(FLoadedBookViews, PublisherSeriesView);
    if ActiveView = PublisherSeriesView then EnsureActiveBookViewLoaded;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.DeleteCollectionExecute(Sender: TObject);
var
  CollectionID: Integer;
  deleteAction: TDeleteCollectionAction;
  CollectionInfoIterator: ICollectionInfoIterator;
  CollectionInfo: TCollectionInfo;
begin
  Assert(Assigned(FCollection));

  deleteAction := AskDeleteCollectionAction;
  if deleteAction in [dcaDelete, dcaUnregister] then
  begin
    CollectionID := FCollection.CollectionID;

    PurgeDownloadsForCollection(CollectionID);
    CloseCollection;
    FSystemData.DeleteCollection(CollectionID, dcaDelete = deleteAction);

    CollectionInfoIterator := FSystemData.GetCollectionInfoIterator;
    if CollectionInfoIterator.Next(CollectionInfo) then
      Settings.ActiveCollection := CollectionInfo.ID
    else
      Settings.ActiveCollection := INVALID_COLLECTION_ID;

    InitCollection;
  end;

end;

procedure TfrmMain.miDeleteFilesClick(Sender: TObject);
var
  DatabaseID: Integer;
  FilePath: string;
begin
  Assert(Assigned(FCollection));
  DatabaseID := FCollection.CollectionID;

  ProcessNodes(
    procedure (Tree: TBookTree; Node: PVirtualNode)
    var
      Data: PBookRecord;
    begin
      Data := Tree.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType = ntBookInfo) and (Data^.BookKey.DatabaseID = DatabaseID) then
      begin
        FilePath := Data^.GetBookFileName;
        try
          if TFile.Exists(FilePath) then
            TFile.Delete(FilePath);
        except
        end;

        if (bpIsLocal in Data^.BookProps) then
          FCollection.SetLocal(Data^.BookKey, False);

        UpdateNodes(
          Data^.BookKey,
          procedure(BookData: PBookRecord)
          begin
            Assert(Assigned(BookData));
            Exclude(BookData^.BookProps, bpIsLocal);
          end
        );
      end;
    end
  );
end;



procedure TfrmMain.acBookAdd2FavoritesExecute(Sender: TObject);
begin
  if ActiveView = FavoritesView then
    DeleteBookFromGroup(Sender)
  else if FSystemData.ActivateGroup(FAVORITES_GROUP_ID) then
    AddBookToGroup(Sender);
end;

procedure TfrmMain.acBookAdd2GroupExecute(Sender: TObject);
begin
  if FSystemData.ActivateGroup(FAVORITES_GROUP_ID) then AddBookToGroup(Sender);
end;

procedure TfrmMain.acBookRemoveFromGroupExecute(Sender: TObject);
begin
  if ActiveView = FavoritesView then DeleteBookFromGroup(Sender)
end;

procedure TfrmMain.acViewSetInfoPriorityExecute(Sender: TObject);
begin
  Settings.Fb2InfoPriority := not Settings.Fb2InfoPriority ;
  SetBookInfoPriority(Settings.Fb2InfoPriority);
end;

procedure TfrmMain.Add2DownloadListExecute(Sender: TObject);
var
  Tree: TBookTree;

  BookNode: PVirtualNode;
  BookData: PBookRecord;

  DownloadNode: PVirtualNode;
  DownloadData: PDownloadData;
  Skipped: Integer;

  function BookInDownloadList(const BookKey: TBookKey): Boolean;
  var
    Node: PVirtualNode;
    Data: PDownloadData;
  begin
    Result := False;

    Node := tvDownloadList.GetFirst;
    while Assigned(Node) do
    begin
      Data := tvDownloadList.GetNodeData(Node);
      if (Data^.BookKey.IsSameAs(BookKey)) then
      begin
        Result := True;
        Break;
      end;

      Node := tvDownloadList.GetNext(Node);
    end;
  end;

begin
  Assert(Assigned(FCollection));
  if ActiveView = DownloadView then
  begin
    btnDeleteDownloadClick(Sender);
    Exit;
  end;

  GetActiveTree(Tree); Skipped := 0;

  BookNode := Tree.GetFirst;
  while Assigned(BookNode) do
  begin
    BookData := Tree.GetNodeData(BookNode);
    Assert(Assigned(BookData));
    if IsSelectedBookNode(BookNode, BookData) then
    begin
      if (Tree = tvBooksF) and not CatalogBookMatchesSaved(BookData^, False) then
      begin
        Inc(Skipped); BookNode := Tree.GetNext(BookNode); Continue;
      end;
      if CatalogBookAvailable(BookData^, False) and not (bpIsLocal in BookData^.BookProps) and (BookData^.BookKey.DatabaseID = FCollection.CollectionID) then
      begin
        if not BookInDownloadList(BookData^.BookKey) then
        begin
          DownloadNode := tvDownloadList.AddChild(nil);
          DownloadData := tvDownloadList.GetNodeData(DownloadNode);

          Initialize(DownloadData^);
          DownloadData^.BookKey := BookData^.BookKey;
          DownloadData^.Author := TAuthorsHelper.GetList(BookData^.Authors);
          DownloadData^.Title := BookData^.Title;
          DownloadData^.Size := BookData^.Size;
          DownloadData^.FileName := BookData^.GetBookFileName;
          DownloadData^.URL := Format(Settings.InpxURL + 'b/%s/get', [BookData^.LibID]);
          DownloadData^.State := dsWait;
          DownloadData^.HasExpectedIdentity := True;
          DownloadData^.ExpectedLibID := BookData^.LibID;
          DownloadData^.ExpectedPhysicalIdentity := ReaderBookPhysicalIdentity(BookData^);

        end;
      end;

      Tree.CheckState[BookNode] := csUncheckedNormal;
    end;
    BookNode := Tree.GetNext(BookNode);
  end;

  if Skipped > 0 then MHLShowInfo('Некоторые книги из группы больше не совпадают с каталогом. ' +
    'Записи, заметки и отметки выбора сохранены; скачивание для них пропущено.');
  UpdateDownloadCount;

  if Settings.AutoStartDwnld then
    btnStartDownloadClick(Sender);
end;

procedure TfrmMain.EditAuthorExecute(Sender: TObject);
var
  Data: PAuthorData;
begin
  Data := tvAuthors.GetNodeData(tvAuthors.GetFirstSelected);
  try
    frmEditAuthorData := TfrmEditAuthorData.Create(Self);
    with frmEditAuthorData do
    begin
      FirstName := Data.FirstName;
      LastName := Data.LastName;
      MidName := Data.MiddleName;
      if ShowModal = mrOK then
      begin
        Data.FirstName := FirstName;
        Data.LastName := LastName;
        Data.MiddleName := MidName;

        FCollection.UpdateAuthor(Data);
        tvAuthors.RepaintNode(tvAuthors.GetFirstSelected);
      end;
    end;
  finally
    FreeAndNil(frmEditAuthorData);
  end;
end;

function TfrmMain.IsLibRusecEdit(const BookKey: TBookKey): Boolean;
var
  BookRecord: TBookRecord;
  URL: string;
  BookCollection: IBookCollection;
begin
  if BookKey.DatabaseID <> FCollection.CollectionID then
    BookCollection := FSystemData.GetCollection(BookKey.DatabaseID)
  else
    BookCollection := FCollection;

  Assert(Assigned(BookCollection));
  if isExternalCollection(BookCollection.CollectionCode) then
  begin
    if MHLShowWarning(Format(rstrGoToLibrarySite, [BookCollection.CollectionURL]), mbYesNo) = mrYes then
    begin
      BookCollection.GetBookRecord(BookKey, BookRecord, False);
      URL := BookCollection.GetEditURL(BookRecord.LibID);
      SimpleShellExecute(Handle, URL);
    end;
    Result := True;
  end
  else
    Result := False;
end;

procedure TfrmMain.EditBookExecute(Sender: TObject);
var
  Tree: TBookTree;
  Data: PBookRecord;
  Node: PVirtualNode;
  frmEditBook: TfrmEditBookInfo;
begin
  Assert(Assigned(FCollection));
  if (ActiveView = DownloadView) then
  begin
    MHLShowWarning(rstrNotFromDownloadsError);
    Exit;
  end;

  GetActiveTree(Tree);
  Node := Tree.GetFirstSelected;
  Data := Tree.GetNodeData(Node);
  if not Assigned(Data) or (Data^.nodeType <> ntBookInfo) then
    Exit;

  if not CatalogBookAvailable(Data^) then Exit;
  if (Tree = tvBooksF) and not CatalogBookMatchesSaved(Data^) then Exit;
  if IsLibRusecEdit(Data^.BookKey) then
    Exit;

  frmEditBook := TfrmEditBookInfo.Create(Application);
  try
    if Data^.BookKey.DatabaseID <> FCollection.CollectionID then
      frmEditBook.Collection := FSystemData.GetCollection(Data^.BookKey.DatabaseID)
    else
      frmEditBook.Collection := FCollection;

    if ActiveView = AuthorsView then
       FCollection.SetProperty(PROP_LAST_AUTHOR_BOOK, Data.BookKey.BookID);

    if ActiveView = SeriesView then
       FCollection.SetProperty(PROP_LAST_SERIES_BOOK, Data.BookKey.BookID);

    frmEditBook.OnReadBook := OnReadBookHandler;
    frmEditBook.OnGetBook := OnGetBookHandler;
    frmEditBook.OnSelectBook := OnSelectBookHandler;
    frmEditBook.OnUpdateBook := OnUpdateBookHandler;
    frmEditBook.OnHelp := OnHelpHandler;

    if frmEditBook.ShowModal = mrOk then
    begin
      UpdatePositions;
      InitCollection;
    end;
  finally
    frmEditBook.Free;
  end;
end;

procedure TfrmMain.EditGenresExecute(Sender: TObject);
var
  NodeB: PVirtualNode;
  DataB: PBookRecord;
  Tree: TBookTree;
begin
  Assert(Assigned(FCollection));
  if ActiveView = FavoritesView then
  begin
    MHLShowWarning(rstrUnableToEditBooksFromFavourites);
    Exit;
  end;

  if IsLibRusecEdit(CreateBookKey(0, FCollection.CollectionID)) then
    Exit;

  GetActiveTree(Tree);

  FillGenresTree(frmGenreTree.tvGenresTree, FCollection.GetGenreIterator(gmAll));

  if frmGenreTree.ShowModal = mrOk then
  begin
    NodeB := Tree.GetFirst;
    while Assigned(NodeB) do
    begin
      DataB := Tree.GetNodeData(NodeB);
      if (DataB^.nodeType = ntBookInfo) and not Tree.IsEffectivelyFiltered[NodeB] and
        ((Tree.CheckState[NodeB] = csCheckedNormal) or (Tree.Selected[NodeB])) then
      begin
        frmGenreTree.GetSelectedGenres(DataB^);

        FCollection.BeginBulkOperation;
        try
          FCollection.SetBookGenres(DataB.BookKey.BookID, DataB^.Genres, True);

          FCollection.EndBulkOperation(True);
        except
          FCollection.EndBulkOperation(False);
        end;
      end;
      Tree.RepaintNode(NodeB);
      NodeB := Tree.GetNext(NodeB);
    end;
    UpdatePositions;
    InitCollection;
  end;
end;

procedure TfrmMain.EditSeriesExecute(Sender: TObject);
var
  Tree: TBookTree;
  Data: PBookRecord;
  Node: PVirtualNode;
  S: string;
  SeriesID: Integer;
begin
  Assert(Assigned(FCollection));
  if ActiveView = FavoritesView then
  begin
    MHLShowWarning(rstrUnableToEditBooksFromFavourites);
    Exit;
  end;

  GetActiveTree(Tree);
  Node := Tree.GetFirstSelected;
  Data := Tree.GetNodeData(Node);
  if not Assigned(Data) then
    Exit;

  if IsLibRusecEdit(Data^.BookKey) then
    Exit;



  S := Data^.Series;

  if Data^.nodeType = ntBookInfo then
  begin
    if InputQuery(rstrCreateMoveSeries, rstrTitle, S) then
    begin
      SeriesID := FCollection.FindOrCreateSeries(S);
      Node := Tree.GetFirst;
      while Assigned(Node) do
      begin
        Data := Tree.GetNodeData(Node);
        if not Tree.IsEffectivelyFiltered[Node] and
          ((Tree.CheckState[Node] = csCheckedNormal) or (Tree.Selected[Node])) then
          FCollection.SetSeriesID(Data^.BookKey, SeriesID);
        Node := Tree.GetNext(Node);
      end;

      FillAllBooksTree;
    end;
  end
  else if InputQuery(rstrEditSeries, rstrTitle, S) then
  begin
    if S = NO_SERIES_TITLE then
    begin
      FCollection.ChangeBookSeriesID(Data^.SeriesID, NO_SERIES_ID, FCollection.CollectionID);
      FillAllBooksTree;
    end
    else
    begin
      FCollection.SetSeriesTitle(Data^.SeriesID, S);
      Data^.Series := S;
      Tree.RepaintNode(Node);
    end;
  end;
end;

resourcestring
  rstrGroupExportDestination = 'Папка экспорта групп';
  rstrGroupExportDestinationUnavailable = 'Папка недоступна для записи: %s';

function TfrmMain.ChooseGroupExportDestination(ForcePrompt: Boolean): Boolean;
var
  Directory, ProbeName: string;
  ShellItem: IShellItem;
  GUID: TGUID;
  FileHandle: THandle;

  function CanWrite(const Path: string): Boolean;
  begin
    Result := False;
    if (Path = '') or IsShellPath(Path) or not DirectoryExists(Path) then
      Exit;
    CreateGUID(GUID);
    ProbeName := TPath.Combine(Path, '.mhl-export-check-' + GUIDToString(GUID));
    FileHandle := CreateFile(PChar(ProbeName), GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE, 0);
    if FileHandle <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(FileHandle);
      Result := True;
    end;
  end;

begin
  Directory := Settings.GroupExportDir;
  if not ForcePrompt and CanWrite(Directory) then
    Exit(True);
  Result := False;
  if not GetFolderShellItem(Handle, rstrGroupExportDestination, Directory, ShellItem) then
    Exit;
  if not CanWrite(Directory) then
  begin
    MHLShowError(Format(rstrGroupExportDestinationUnavailable, [Directory]));
    Exit;
  end;
  Settings.GroupExportDir := Directory;
  Settings.SaveSettings;
  Result := True;
end;

procedure TfrmMain.ExportGroupMetabibExecute(Sender: TObject);
var
  Group: PGroupData;
  GroupID: Integer;
  Info: TMetabibExportResult;
begin
  if ActiveView <> FavoritesView then
    Exit;
  Group := tvGroups.GetNodeData(tvGroups.GetFirstSelected);
  if not Assigned(Group) then
    Exit;
  GroupID := Group^.GroupID;
  if not ChooseGroupExportDestination(False) then
    Exit;
  Info := ExportGroupCollection(GroupID, Settings.GroupExportDir);
  if (Info.Status = mesFailed) and (Info.ErrorText <> '') then
    MHLShowError(Info.ErrorText);
end;

procedure TfrmMain.GroupExportDestinationExecute(Sender: TObject);
begin
  ChooseGroupExportDestination(True);
end;

procedure TfrmMain.GroupExportMetabibUpdate(Sender: TObject);
begin
  if InternalUpdateGroupAction(acGroupExportMetabib) then
    Exit;
  acGroupExportMetabib.Enabled := tvGroups.GetFirstSelected() <> nil;
end;

procedure TfrmMain.AddGroupExecute(Sender: TObject);
var
  GroupName: string;
begin
  if NewGroup(GroupName) then
  begin
    if FSystemData.AddGroup(GroupName) then
    begin
      CreateGroupsMenu;
      FillGroupsList(tvGroups, FSystemData.GetGroupIterator, FLastGroupID);
    end
    else
      MHLShowError(rstrGroupAlreadyExists);
  end;
end;

procedure TfrmMain.RenameGroupExecute(Sender: TObject);
var
  Data: PGroupData;
  GroupName: string;
begin
  Data := tvGroups.GetNodeData(tvGroups.GetFirstSelected());
  if not Assigned(Data) or not Data^.CanDelete then
    Exit;

  GroupName := Data^.Text;

  if EditGroup(GroupName) then
  begin
    if FSystemData.RenameGroup(Data^.GroupID, GroupName) then
    begin
      CreateGroupsMenu;
      FillGroupsList(tvGroups, FSystemData.GetGroupIterator, FLastGroupID);
    end
    else
      MHLShowError(rstrGroupAlreadyExists);
  end;
end;

procedure TfrmMain.DeleteGroupExecute(Sender: TObject);
var
  Data: PGroupData;
begin
  Data := tvGroups.GetNodeData(tvGroups.GetFirstSelected());
  if not Assigned(Data) then
    Exit;

  if Data^.CanDelete then
  begin
    FSystemData.DeleteGroup(Data^.GroupID);

    CreateGroupsMenu;
    FillGroupsList(tvGroups, FSystemData.GetGroupIterator, FLastGroupID);
  end
  else
    MHLShowError(rstrUnableDeleteBuiltinGroupError);
end;

procedure TfrmMain.ClearGroupExecute(Sender: TObject);
var
  GroupData: PGroupData;
  SavedCursor: TCursor;
begin
  GroupData := tvGroups.GetNodeData(tvGroups.GetFirstSelected());
  if not Assigned(GroupData) then
    Exit;

  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    FSystemData.ClearGroup(GroupData^.GroupID);

    Exclude(FLoadedBookViews, FavoritesView);

    if ActiveView = FavoritesView then EnsureActiveBookViewLoaded;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.ChangeToolbarVisability(ToolBars: array of TWinControl; ToolBar: TWinControl; ShowToolbar: Boolean);
var
  BarTop: Integer;
  i: Integer;
begin
  DisableAlign;
  try
    if ShowToolbar then
    begin
      // Располагаем текущий тулбар под первым видимым старшим
      // а все видимые младшие сдвигаем на 1 ниже
      BarTop := 0;
      for i := 0 to High(ToolBars) do
      begin
        if ToolBars[i] = ToolBar then
          Break;
        if ToolBars[i].Visible then
          BarTop := ToolBars[i].BoundsRect.Bottom;
      end;

      ToolBar.Top := BarTop;

      for i := High(ToolBars) downto 0 do
      begin
        if ToolBars[i] = ToolBar then
          Break;
        if ToolBars[i].Visible then
          ToolBars[i].Top := ToolBars[i].Top + 1;
      end;
    end;
    ToolBar.Visible := ShowToolbar;
  finally
    EnableAlign;
  end;
  UpdateThemeToolbar;
end;

procedure TfrmMain.ShowRusAlphabetUpdate(Sender: TObject);
begin
  acShowRusAlphabet.Checked := Settings.ShowRusBar;
end;

procedure TfrmMain.ShowRusAlphabetExecute(Sender: TObject);
begin
  Settings.ShowRusBar := not Settings.ShowRusBar;
  ChangeToolbarVisability(FAuthorBars, tbarAuthorsRus, Settings.ShowRusBar);
  ChangeToolbarVisability(FSerieBars, tbarSeriesRus, Settings.ShowRusBar);
end;

procedure TfrmMain.ShowEngAlphabetUpdate(Sender: TObject);
begin
  acShowEngAlphabet.Checked := Settings.ShowEngBar;
end;

procedure TfrmMain.ShowEngAlphabetExecute(Sender: TObject);
begin
  Settings.ShowEngBar := not Settings.ShowEngBar;
  ChangeToolbarVisability(FAuthorBars, tbarAuthorsEng, Settings.ShowEngBar);
  ChangeToolbarVisability(FSerieBars, tbarSeriesEng, Settings.ShowEngBar);
end;

procedure TfrmMain.ShowEditToolbarUpdate(Sender: TObject);
begin
  acShowEditToolbar.Checked := Settings.EditToolBarVisible;
end;

procedure TfrmMain.ShowEditToolbarExecute(Sender: TObject);
begin
  Settings.EditToolBarVisible := not Settings.EditToolBarVisible;
  ChangeToolbarVisability(FMainBars, tlbrEdit, Settings.EditToolBarVisible);
end;

procedure TfrmMain.ShowMainToolbarUpdate(Sender: TObject);
begin
  acShowMainToolbar.Checked := Settings.ShowToolbar;
end;

procedure TfrmMain.ShowMainToolbarExecute(Sender: TObject);
begin
  Settings.ShowToolbar := not Settings.ShowToolbar;
  ChangeToolbarVisability(FMainBars, tlbrMain, Settings.ShowToolbar);
end;

procedure TfrmMain.ShowStatusbarUpdate(Sender: TObject);
begin
  acShowStatusbar.Checked := Settings.ShowStatusBar;
end;

procedure TfrmMain.ShowStatusbarExecute(Sender: TObject);
begin
  Settings.ShowStatusBar := not Settings.ShowStatusBar;
  StatusBar.Visible := Settings.ShowStatusBar;
end;

procedure TfrmMain.ShowBookInfoPanelUpdate(Sender: TObject);
begin
  acShowBookInfoPanel.Checked := Settings.ShowInfoPanel;
end;

procedure TfrmMain.ShowBookInfoPanelExecute(Sender: TObject);
var
  Tree: TBookTree;
begin
  Settings.ShowInfoPanel := not Settings.ShowInfoPanel;
  SetInfoPanelVisible(Settings.ShowInfoPanel);

  if Settings.ShowInfoPanel and (ActiveView <> DownloadView) then
  begin
    GetActiveTree(Tree);
    if Assigned(Tree) and Assigned(Tree.FocusedNode) then
      tvBooksTreeChange(Tree, Tree.FocusedNode);
  end;
end;

procedure TfrmMain.ShowBookCoverExecute(Sender: TObject);
var
  Tree: TBookTree;
begin
  Settings.ShowBookCover := not Settings.ShowBookCover;
  SetShowBookCover(Settings.ShowBookCover);

  if Settings.ShowInfoPanel and Settings.ShowBookCover and (ActiveView <> DownloadView) then
  begin
    GetActiveTree(Tree);
    if Assigned(Tree) and Assigned(Tree.FocusedNode) then
      tvBooksTreeChange(Tree, Tree.FocusedNode);
  end;
end;

procedure TfrmMain.ShowBookCoverUpdate(Sender: TObject);
begin
  acShowBookCover.Checked := Settings.ShowBookCover;
  acShowBookCover.Enabled := Settings.ShowInfoPanel;
end;

procedure TfrmMain.ShowBookAnnotationExecute(Sender: TObject);
var
  Tree: TBookTree;
begin
  Settings.ShowBookAnnotation := not Settings.ShowBookAnnotation;
  SetShowBookAnnotation(Settings.ShowBookAnnotation);

  if Settings.ShowInfoPanel and Settings.ShowBookAnnotation and (ActiveView <> DownloadView) then
  begin
    GetActiveTree(Tree);
    if Assigned(Tree) and Assigned(Tree.FocusedNode) then
      tvBooksTreeChange(Tree, Tree.FocusedNode);
  end;
end;

procedure TfrmMain.ShowBookAnnotationUpdate(Sender: TObject);
begin
  acShowBookAnnotation.Checked := Settings.ShowBookAnnotation;
  acShowBookAnnotation.Enabled := Settings.ShowInfoPanel;
end;

procedure TfrmMain.BookSetRateExecute(Sender: TObject);
var
  NewRate: Integer;
begin
  Assert(Assigned(FCollection));
  if Sender = acBookSetRate1 then
    NewRate := 1
  else if Sender = acBookSetRate2 then
    NewRate := 2
  else if Sender = acBookSetRate3 then
    NewRate := 3
  else if Sender = acBookSetRate4 then
    NewRate := 4
  else if Sender = acBookSetRate5 then
    NewRate := 5
  else
    NewRate := 0;

  ProcessNodes(
    procedure (Tree: TBookTree; Node: PVirtualNode)
    var
      Data: PBookRecord; Changed: TBookRecord;
    begin
      Data := Tree.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType = ntBookInfo) then
      begin
        if Tree = tvBooksF then
        begin
          Changed := Data^; Changed.Rate := NewRate;
          if TryStoreReaderBookPersonal(FSystemData.GetCollection(Data^.BookKey.DatabaseID), FSystemData,
            Changed, [bpfRate]) <> rpwRejected then
          begin Data^.Rate := NewRate; Tree.InvalidateNode(Node); end
          else MHLShowInfo('Не удалось подтвердить личную карточку книги. Оценка не изменена.');
          Exit;
        end;
        FCollection.SetRate(Data^.BookKey, NewRate);
        UpdateNodes(
          Data^.BookKey,
          procedure(BookData: PBookRecord)
          begin
            Assert(Assigned(BookData));
            BookData^.Rate := NewRate;
          end
        );
      end;
    end
  );
end;

procedure TfrmMain.UpdateBookAction(Sender: TObject);
var Tree: TBookTree; Node: PVirtualNode; Data: PBookRecord; Available: Boolean;
begin
  GetActiveTree(Tree); Available:=False;
  if Assigned(Tree) and (Tree.VisibleCount>0) then
  begin
    // Action updates run repeatedly during idle and after every selection.
    // A focused visible book already answers the question; enumerating all
    // checked nodes here scanned the entire loaded catalogue six times.
    Node:=Tree.FocusedNode;
    if Assigned(Node) and not Tree.IsEffectivelyFiltered[Node] then
    begin
      Data:=Tree.GetNodeData(Node); Available:=Assigned(Data) and (Data.NodeType=ntBookInfo);
    end;
    if not Available then
    begin
      // A group or empty focus still permits operations on checked books.
      // Reuse that answer until checks, filters or rows actually change.
      if not FBookActionCached or (FBookActionTree<>Tree) or
        (FBookActionVersion<>Tree.ActionVersion) then
      begin
        Node:=Tree.GetFirstChecked;
        while Assigned(Node) do
        begin
          Data:=Tree.GetNodeData(Node);
          if not Tree.IsEffectivelyFiltered[Node] and Assigned(Data) and (Data.NodeType=ntBookInfo) then
          begin Available:=True; Break; end;
          Node:=Tree.GetNextChecked(Node);
        end;
        FBookActionTree:=Tree; FBookActionVersion:=Tree.ActionVersion;
        FBookActionAvailable:=Available; FBookActionCached:=True;
      end
      else Available:=FBookActionAvailable;
    end;
  end;
  (Sender as TAction).Enabled:=Available;
end;

procedure TfrmMain.SavePresetUpdate(Sender: TObject);
begin
  acSavePreset.Enabled := Assigned(FPresets) and (Trim(cbPresetName.Text) <> '');
end;

procedure TfrmMain.DeletePresetUpdate(Sender: TObject);
begin
  acDeletePreset.Enabled := Assigned(FPresets) and
    (SearchPresetIndex(cbPresetName.Text) >= 0);
end;

procedure TfrmMain.UpdateAllEditActions;
begin
  UpdateEditAction(acEditAuthor);
  UpdateEditAction(acEditSerie);
  UpdateEditAction(acEditGenre);

  tbtnAutoFBD.Visible := IsPrivate and not IsFB2;
  tbtnFBD.Visible := IsPrivate and not IsFB2;

  ChangeToolbarVisability(FMainBars, tlbrEdit, Settings.EditToolBarVisible);
end;

function TfrmMain.UpdateEditAction(Action: TAction): Boolean;
begin
  Assert(Assigned(FCollection));
  Result := isPrivateCollection(FCollection.CollectionCode);

  if Result then
    Action.Enabled := True;

  Action.Visible := Result;
end;

procedure TfrmMain.EditAuthorUpdate(Sender: TObject);
var
  Data: PAuthorData;
begin
  if UpdateEditAction(acEditAuthor) then
    Exit;

  if ActiveView <> AuthorsView then
  begin
    acEditAuthor.Enabled := False;
    Exit;
  end;

  Data := tvAuthors.GetNodeData(tvAuthors.GetFirstSelected);
  acEditAuthor.Enabled := Assigned(Data);
end;

procedure TfrmMain.EditSerieUpdate(Sender: TObject);
var
  Data: PSeriesData;
begin
  if UpdateEditAction(acEditSerie) then
    Exit;

  if ActiveView <> SeriesView then
  begin
    acEditSerie.Enabled := False;
    Exit;
  end;

  Data := tvSeries.GetNodeData(tvSeries.GetFirstSelected);
  acEditSerie.Enabled := Assigned(Data);
end;

procedure TfrmMain.EditGenreUpdate(Sender: TObject);
var
  Data: PGenreData;
begin
  if UpdateEditAction(acEditGenre) then
    Exit;

  if ActiveView <> GenresView then
  begin
    acEditGenre.Enabled := False;
    Exit;
  end;

  Data := tvGenres.GetNodeData(tvGenres.GetFirstSelected);
  acEditGenre.Enabled := Assigned(Data);
end;

function TfrmMain.InternalUpdateGroupAction(Action: TAction): Boolean;
begin
  Result := ActiveView <> FavoritesView;
  if Result then
    Action.Enabled := False;
end;

procedure TfrmMain.AddGroupUpdate(Sender: TObject);
begin
  if InternalUpdateGroupAction(acGroupCreate) then
    Exit;

  acGroupCreate.Enabled := True;
end;

procedure TfrmMain.EditGroupUpdate(Sender: TObject);
var
  Data: PGroupData;
begin
  if InternalUpdateGroupAction(Sender as TAction) then
    Exit;

  Data := tvGroups.GetNodeData(tvGroups.GetFirstSelected);
  (Sender as TAction).Enabled := Assigned(Data) and Data^.CanDelete;
end;

procedure TfrmMain.ClearGroupUpdate(Sender: TObject);
var
  Data: PGroupData;
begin
  if InternalUpdateGroupAction(acGroupClear) then
    Exit;

  Data := tvGroups.GetNodeData(tvGroups.GetFirstSelected);
  acGroupClear.Enabled := Assigned(Data);
end;

procedure TfrmMain.AddBookToGroup(Sender: TObject);
var
  Tree: TBookTree;
  booksToProcess: Integer;
  booksProcessed: Integer;
  GroupID: Integer;
  GroupData: PGroupData;
  SavedCursor: TCursor;
begin
  Assert(Assigned(FCollection));
  GetActiveTree(Tree);
  Assert(Assigned(Tree));

  booksToProcess := Tree.CheckedCount;
  if Assigned(Tree.FocusedNode) and (Tree.CheckState[Tree.FocusedNode] <> csCheckedNormal) then
    Inc(booksToProcess);
  if booksToProcess = 0 then
    Exit;
  booksProcessed := 0;

  if Sender is TMenuItem then
    GroupID := (Sender as TMenuItem).Tag
  else
    GroupID := FAVORITES_GROUP_ID;

  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    StatusMessage := rstrAddingBookToGroup;
    StatusProgress := 0;
    ShowStatusProgress := True;
    try
      ProcessNodes(
        procedure (Tree: TBookTree; Node: PVirtualNode)
        var
          Data: PBookRecord;
        begin
          Data := Tree.GetNodeData(Node);
          if Assigned(Data) and (Data^.nodeType = ntBookInfo) then
          begin
            FCollection.AddBookToGroup(Data^.BookKey, GroupID);
            Tree.CheckState[Node] := csUncheckedNormal;
            Inc(booksProcessed);
            StatusProgress := booksProcessed * 100 div booksToProcess;
          end;
        end
      );
    finally
      ShowStatusProgress := False;
    end;
  finally
    Screen.Cursor := SavedCursor;
  end;

  // если выделенная группа совпадает с той, куда добавляем книги, нужно перерисовать список
  GroupData := tvGroups.GetNodeData(tvGroups.GetFirstSelected);
  if Assigned(GroupData) and (GroupData^.GroupID = GroupID) then
  begin
    Exclude(FLoadedBookViews, FavoritesView);
    if ActiveView = FavoritesView then EnsureActiveBookViewLoaded;
  end;
end;

procedure TfrmMain.DeleteBookFromGroup(Sender: TObject);
var
  GroupData: PGroupData;
  booksToProcess: Integer;
  booksProcessed: Integer;
  SavedCursor: TCursor;
begin
  Assert(ActiveView = FavoritesView);

  booksToProcess := tvBooksF.CheckedCount;
  if Assigned(tvBooksF.FocusedNode) and (tvBooksF.CheckState[tvBooksF.FocusedNode] <> csCheckedNormal) then
    Inc(booksToProcess);
  if booksToProcess = 0 then
    Exit;
  booksProcessed := 0;

  GroupData := tvGroups.GetNodeData(tvGroups.GetFirstSelected);
  if not Assigned(GroupData) then
    Exit;

  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    StatusMessage := rstrRemovingBookFromGroup;
    StatusProgress := 0;
    ShowStatusProgress := True;
    try
      ProcessNodes(
        procedure (Tree: TBookTree; Node: PVirtualNode)
        var
          Data: PBookRecord;
        begin
          Data := Tree.GetNodeData(Node);
          if Assigned(Data) and (Data^.nodeType = ntBookInfo) then
          begin
            FSystemData.DeleteFromGroup(Data.BookKey, GroupData^.GroupID);

            Inc(booksProcessed);
            StatusProgress := booksProcessed * 100 div booksToProcess;
          end;
        end
      );

      FSystemData.RemoveUnusedBooks;

      Exclude(FLoadedBookViews, FavoritesView);

      if ActiveView = FavoritesView then EnsureActiveBookViewLoaded;
    finally
      ShowStatusProgress := False;
    end;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.miAddToSearchClick(Sender: TObject);
var
  Edit: TMHLButtonedEdit;
  treeView: TVirtualStringTree;
  Node: PVirtualNode;
  Data: PAuthorData;
  Expression, AuthorCondition: string;
  QueryMode: TSearchQueryMode;
  Added: Boolean;
begin
  case ActiveView of
    AuthorsView:
      begin
        treeView := tvAuthors;
        Edit := edFFullName;
      end;
    SeriesView:
      begin
        Assert(False, rstrNeedSpecialDataTypeForSeries);
        Exit;
      end
    else
      // Assert убирается в Release, так что выходим явно: для других видов
      // treeView и Edit остались бы неинициализированными
      Assert(False);
      Exit;
  end;

  Node := treeView.GetFirstSelected;
  if not Assigned(Node) then Exit;
  Expression := Edit.Text;
  QueryMode := sqmLegacy;
  if Assigned(FSearchMode) then QueryMode := FSearchMode.Mode;
  if Trim(Expression) <> '' then
  begin
    if QueryMode = sqmText then
      Expression := PrepareSearchQuery(Expression, False, sqmText)
    else if QueryMode = sqmLegacy then
      Expression := PrepareQuery(Expression, True);
    Expression := '(' + Expression + ')';
  end
  else Expression := '';
  Added := False;
  while Assigned(Node) do
  begin
    Data := treeView.GetNodeData(Node);
    if Assigned(Data) then
    begin
      AuthorCondition := '="' + StringReplace(Data^.GetFullName, '"', '""', [rfReplaceAll]) + '"';
      if Expression = '' then Expression := AuthorCondition
      else Expression := Expression + ' OR' + CRLF + AuthorCondition;
      Added := True;
    end;
    Node := treeView.GetNextSelected(Node);
  end;
  if Added then
  begin
    Edit.Text := Expression;
    if Assigned(FSearchMode) then FSearchMode.Mode := sqmExpression;
  end;
end;

procedure TfrmMain.QuickSearchExecute(Sender: TObject);
begin
  unit_Utils.LocateBook;
end;

procedure TfrmMain.ImportFb2Execute(Sender: TObject);
var CommittedChanges: Boolean;
begin
  Assert(Assigned(FCollection));
  unit_Import.ImportFB2(FCollection.CollectionID, afZip, CommittedChanges);
  if CommittedChanges then NotifyFavoriteCatalogChanged(TArray<Integer>.Create(FCollection.CollectionID));

  InitCollection;
end;

procedure TfrmMain.ImportFb2Update(Sender: TObject);
var
  Action: TAction;
begin
  Assert(Sender is TAction);

  Action := Sender as TAction;
  Action.Visible := IsPrivate and (IsFB2 or Settings.AllowMixed);
  Action.Enabled := Action.Visible;
end;

procedure TfrmMain.ImportFBDExecute(Sender: TObject);
var CommittedChanges: Boolean;
begin
  Assert(Assigned(FCollection));
  unit_Import.ImportFBD(FCollection.CollectionID, CommittedChanges);
  if CommittedChanges then NotifyFavoriteCatalogChanged(TArray<Integer>.Create(FCollection.CollectionID));

  InitCollection;
end;

function TfrmMain.CatalogBookAvailable(const Book: TBookRecord; Notify: Boolean): Boolean;
begin
  Result := Book.BookKey.BookID > 0;
  if not Result and Notify then
    MHLShowInfo('Книга больше не найдена в каталоге. Заметки и запись в группе сохранены.');
end;

function TfrmMain.CatalogBookMatchesSaved(const Book: TBookRecord; Notify: Boolean): Boolean;
begin
  Result := False;
  try
    Result := ReaderBookMatchesCatalog(FSystemData.GetCollection(Book.BookKey.DatabaseID), Book);
  except on E: Exception do Result := False; end;
  if not Result and Notify then MHLShowInfo('Книга из группы больше не совпадает с каталогом. ' +
    'Её запись и заметки сохранены; операция с каталогом не выполнена.');
end;

procedure TfrmMain.PublishFavoriteFilterKeys;
var Tree: TBookTree; Filters: TBookColumnFilters; Visible: Integer; Changed: Boolean;
begin
  if Assigned(FFavoriteStore) then Changed := SetFavoriteAuthorFilterKeys(FFavoriteStore.Keys)
  else Changed := SetFavoriteAuthorFilterKeys(nil);
  if not Changed then Exit;
  for var View := Low(TView) to High(TView) do
    if View in FLoadedBookViews then
    begin
      Tree := nil;
      case View of
        AuthorsView: Tree := tvBooksA;
        SeriesView: Tree := tvBooksS;
        GenresView: Tree := tvBooksG;
        SearchView: Tree := tvBooksSR;
        FavoritesView: Tree := tvBooksF;
        PublisherSeriesView: if Assigned(FPublisher) then Tree := FPublisher.Books;
      end;
      if Assigned(Tree) then
      begin
        Filters := TBookColumnFilters.ForTree(Tree);
        if Filters.FavoriteAuthorsOnly then
        begin
          Visible := Filters.Apply(False);
          SetBookListTotals(Tree, Visible, Filters.Total);
          if Ord(View) = Ord(ActiveView) then RefreshBookInfo(Tree);
        end;
      end;
    end;
end;

function TfrmMain.FavoriteProfileFile: string;
begin
  Result := IncludeTrailingPathDelimiter(Settings.DataPath) + AUTHOR_FAVORITES_FILE_NAME;
end;

function TfrmMain.FavoriteStore: TAuthorFavorites;
begin
  if not Assigned(FFavoriteStore) then FFavoriteStore := TAuthorFavorites.Create(FavoriteProfileFile);
  Result := FFavoriteStore;
end;

function TfrmMain.FavoriteDescriptor(const Collection: IBookCollection): TAuthorFavoriteCollection;
var Info: TCollectionInfo;
  function Stamp(const Name: string): string;
  var Data: WIN32_FILE_ATTRIBUTE_DATA;
  begin
    if GetFileAttributesEx(PChar(Name), GetFileExInfoStandard, @Data) then
      Result := IntToStr(Data.ftLastWriteTime.dwHighDateTime) + ':' +
        IntToStr(Data.ftLastWriteTime.dwLowDateTime) + ':' +
        IntToStr(Data.nFileSizeHigh) + ':' + IntToStr(Data.nFileSizeLow)
    else if GetLastError in [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND] then Result := '-'
    else RaiseLastOSError;
  end;
begin
  Info := FSystemData.GetCollectionInfo(Collection.CollectionID);
  Result.ID := Info.ID;
  Result.DatabaseFile := Info.DBFileName;
  Result.RootFolder := Info.RootFolder;
  Result.LibraryNamespace := VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
  // These stamps survive process restarts. Connection total_changes() also
  // counts TEMP search rows and is deliberately not a persistent revision.
  Result.Revision := Stamp(Info.DBFileName) + '/' + Stamp(Info.DBFileName + '-wal');
end;

function TfrmMain.FavoriteBindingsReady(const Descriptor: TAuthorFavoriteCollection): Boolean;
begin
  Result := not FFavoriteDirtyCollections.ContainsKey(Descriptor.ID) and
    (FavoriteStore.CollectionRevision(Descriptor.ID) = Descriptor.Revision);
  if Length(FavoriteStore.Entries) = 0 then Exit(True);
  if Result then
    for var Entry in FavoriteStore.Entries do
      if not FavoriteStore.State(Descriptor.ID, Entry.Key).HasBaseline then Exit(False);
end;

procedure TfrmMain.QueueFavoriteRefresh(const Descriptor: TAuthorFavoriteCollection; ForceRefresh: Boolean);
begin
  if Length(FavoriteStore.Entries) = 0 then Exit;
  if not ForceRefresh and Assigned(FFavoriteWorker) and (FFavoriteWorker.Collection.ID = Descriptor.ID) and
    (FFavoriteWorker.Collection.Revision = Descriptor.Revision) then Exit;
  for var Queued in FFavoriteQueue do
    if (Queued.ID = Descriptor.ID) and (Queued.Revision = Descriptor.Revision) then Exit;
  FFavoriteQueue.Enqueue(Descriptor);
  StartFavoriteRefresh;
end;

procedure TfrmMain.StartFavoriteRefresh;
var Descriptor: TAuthorFavoriteCollection;
begin
  if Assigned(FFavoriteWorker) or (FFavoriteQueue.Count = 0) or (csDestroying in ComponentState) then Exit;
  EnsureBackgroundMessageWindow;
  Descriptor := FFavoriteQueue.Dequeue;
  Inc(FFavoriteGeneration);
  FFavoriteWorker := TAuthorFavoriteRefreshThread.Create(FBackgroundMessageWindow, FFavoriteGeneration, FavoriteProfileFile, Descriptor);
  FFavoriteWorker.Start;
  UpdateFavoriteControls;
end;

procedure TfrmMain.EnsureBackgroundMessageWindow;
begin
  // Main's HWND can be recreated asynchronously by VCL style/DPI changes.
  // A separate owned message window preserves producer delivery across that gap.
  if FBackgroundMessageWindow = 0 then
    FBackgroundMessageWindow := AllocateHWnd(BackgroundMessageWindowProc);
end;

procedure TfrmMain.BackgroundMessageWindowProc(var Message: TMessage);
begin
  case Message.Msg of
    WM_AUTHOR_FAVORITES_READY: WMFavoriteReady(Message);
    WM_AUTHOR_FAVORITES_PROGRESS: WMFavoriteProgress(Message);
    WM_PROGRAM_UPDATE_CHECKED: ProgramUpdateChecked(Message);
  else
    Message.Result := DefWindowProc(FBackgroundMessageWindow, Message.Msg, Message.WParam, Message.LParam);
  end;
end;

procedure TfrmMain.StopFavoriteRefresh(ClearQueue: Boolean);
var Message: TMsg;
begin
  FFavoriteSearchPending := False;
  if ClearQueue and Assigned(FFavoriteQueue) then FFavoriteQueue.Clear;
  if Assigned(FFavoriteWorker) then
  begin
    FFavoriteWorker.Terminate;
    // The worker never synchronizes with the GUI; SQLite cancellation is bounded.
    FFavoriteWorker.WaitFor;
    FreeAndNil(FFavoriteWorker);
  end;
  Inc(FFavoriteGeneration);
  if FBackgroundMessageWindow <> 0 then
    while PeekMessage(Message, FBackgroundMessageWindow, WM_AUTHOR_FAVORITES_READY, WM_AUTHOR_FAVORITES_PROGRESS, PM_REMOVE) do ;
end;

procedure TfrmMain.CheckFavoriteCollection;
begin
  if not Assigned(FCollection) or not Assigned(FFavoriteQueue) then Exit;
  if not Assigned(FFavoriteStore) then
  begin
    if not FileExists(FavoriteProfileFile) then Exit;
    FavoriteStore;
    PublishFavoriteFilterKeys;
  end;
  if Length(FFavoriteStore.Entries) = 0 then Exit;
  try
    FFavoriteDescriptor := FavoriteDescriptor(FCollection);
    if not FavoriteBindingsReady(FFavoriteDescriptor) then QueueFavoriteRefresh(FFavoriteDescriptor);
  except on E: Exception do StatusMessage := 'Не удалось проверить любимых авторов: ' + E.Message; end;
  UpdateFavoriteControls;
end;

procedure TfrmMain.NotifyFavoriteCatalogChanged(const CollectionIDs: TArray<Integer>);
var Collection: IBookCollection; Descriptor: TAuthorFavoriteCollection; Seen: TDictionary<Integer, Boolean>;
begin
  if not Assigned(FFavoriteQueue) or (csDestroying in ComponentState) then Exit;
  if not Assigned(FFavoriteStore) then
  begin
    if not FileExists(FavoriteProfileFile) then Exit;
    FavoriteStore;
    PublishFavoriteFilterKeys;
  end;
  if Length(FFavoriteStore.Entries) = 0 then Exit;
  Seen := TDictionary<Integer, Boolean>.Create;
  try
    for var CID in CollectionIDs do
      if (CID > 0) and not Seen.ContainsKey(CID) then
      begin
        Seen.Add(CID, True);
        try
          if FSystemData.GetCollectionInfo(CID).ID <> CID then Continue;
          Collection := FSystemData.GetCollection(CID);
          if not Assigned(Collection) then Continue;
          Descriptor := FavoriteDescriptor(Collection);
          // A known commit invalidates bindings even when NTFS has not yet
          // changed the write-time stamp of an open catalog/WAL handle.
          Inc(FFavoriteGeneration);
          FFavoriteDirtyCollections.AddOrSetValue(CID, FFavoriteGeneration);
          QueueFavoriteRefresh(Descriptor, True);
        except
          on E: Exception do StatusMessage := 'Не удалось проверить любимых авторов: ' + E.Message;
        end;
      end;
  finally Seen.Free; end;
  UpdateFavoriteControls;
end;

function TfrmMain.PrepareFavoriteSearch(var Criteria: TBookSearchCriteria): Boolean;
begin
  Result := True;
  if not Criteria.FavoriteAuthorsOnly then Exit;
  FFavoriteDescriptor := FavoriteDescriptor(FCollection);
  if not FavoriteBindingsReady(FFavoriteDescriptor) then
  begin
    QueueFavoriteRefresh(FFavoriteDescriptor);
    Exit(False);
  end;
  Criteria.FavoriteAuthorIDs := FavoriteStore.BoundAuthorIDs(FCollection.CollectionID);
end;

procedure TfrmMain.WMFavoriteProgress(var Message: TMessage);
begin
  if not Assigned(FFavoriteWorker) or (Message.WParam <> WPARAM(NativeUInt(FFavoriteWorker))) or
    (Cardinal(Message.LParam) <> FFavoriteWorker.Generation) then Exit;
  if (FFavoriteWorker.Collection.ID = Settings.ActiveCollection) and
    ((ActiveView = AuthorsView) or FFavoriteSearchPending) then
    StatusMessage := Format('Любимые авторы: %d из %d · книг проверено %d',
      [FFavoriteWorker.AuthorsDone, FFavoriteWorker.AuthorsTotal, FFavoriteWorker.BooksRead]);
end;

procedure TfrmMain.WMFavoriteReady(var Message: TMessage);
var Worker: TAuthorFavoriteRefreshThread; Criteria: TBookSearchCriteria; Matching: Boolean; DirtyGeneration: Cardinal;
begin
  if not Assigned(FFavoriteWorker) or (Message.WParam <> WPARAM(NativeUInt(FFavoriteWorker))) or
    (Cardinal(Message.LParam) <> FFavoriteWorker.Generation) then Exit;
  Worker := FFavoriteWorker;
  FFavoriteWorker := nil;
  Worker.WaitFor;
  try
    Matching := Assigned(FCollection) and (Worker.Collection.ID = FCollection.CollectionID);
    if Worker.Succeeded then
    begin
      if FFavoriteDirtyCollections.TryGetValue(Worker.Collection.ID, DirtyGeneration) and
        (Worker.Generation >= DirtyGeneration) then FFavoriteDirtyCollections.Remove(Worker.Collection.ID);
      FavoriteStore.Reload;
      PublishFavoriteFilterKeys;
      if Matching then
      begin
        FFavoriteDescriptor := FavoriteDescriptor(FCollection);
        if not FavoriteBindingsReady(FFavoriteDescriptor) then QueueFavoriteRefresh(FFavoriteDescriptor)
        else
        begin
          Include(FStaleSelectors, AuthorsView);
          Exclude(FLoadedBookViews, AuthorsView);
          if FFavoriteSearchPending and (FFavoritePendingCID = FCollection.CollectionID) then
          begin
            Criteria := FFavoritePendingCriteria;
            Criteria.FavoriteAuthorIDs := FavoriteStore.BoundAuthorIDs(FCollection.CollectionID);
            FFavoriteSearchPending := False;
            ApplySearchCriteria(Criteria);
          end
          else if FHasAppliedSearch and FSearchCriteria.FavoriteAuthorsOnly then
          begin
            FSearchCriteria.FavoriteAuthorIDs := FavoriteStore.BoundAuthorIDs(FCollection.CollectionID);
            Exclude(FLoadedBookViews, SearchView);
          end;
          EnsureActiveBookViewLoaded;
          StatusMessage := rstrReadyMessage;
        end;
      end;
    end
    else if Matching then
    begin
      FFavoriteSearchPending := False;
      if Worker.ErrorMessage <> '' then
        StatusMessage := 'Не удалось проверить любимых авторов: ' + Worker.ErrorMessage
      else StatusMessage := 'Проверка любимых авторов отменена';
    end;
  finally Worker.Free; end;
  UpdateFavoriteControls;
  StartFavoriteRefresh;
end;

function TfrmMain.SelectedFavoriteAuthor(out Author: TAuthorData; out Key: string): Boolean;
var Data: PAuthorData;
begin
  Result := False; Key := '';
  if not Assigned(FCollection) then Exit;
  Data := tvAuthors.GetNodeData(tvAuthors.GetFirstSelected);
  if not Assigned(Data) or (Data^.AuthorID <= 0) then Exit;
  Author := Data^;
  try Key := AuthorFavoriteKey(Author.LastName, Author.FirstName, Author.MiddleName);
  except on E: EAuthorFavorites do Exit; end;
  Result := Key <> '';
end;

procedure TfrmMain.UpdateFavoriteControls;
var Author: TAuthorData; Key: string; Selected, Marked, Ready: Boolean; NewCount: Integer;
begin
  if not Assigned(FFavoriteListCheck) then Exit;
  Selected := SelectedFavoriteAuthor(Author, Key);
  Marked := Selected and Assigned(FFavoriteStore) and FFavoriteStore.IsFavorite(Author);
  Ready := Marked and FFavoriteStore.State(Settings.ActiveCollection, Key).HasBaseline and
    not FFavoriteDirtyCollections.ContainsKey(Settings.ActiveCollection) and
    (FFavoriteStore.CollectionRevision(Settings.ActiveCollection) = FFavoriteDescriptor.Revision);
  FFavoriteAuthorHeart.Enabled := Selected;
  if Marked then FFavoriteAuthorHeart.Caption := '♥' else FFavoriteAuthorHeart.Caption := '♡';
  if Marked then FFavoriteAuthorHeart.Hint := 'Убрать автора из любимых'
  else FFavoriteAuthorHeart.Hint := 'Добавить автора в любимые';
  FFavoriteToggleMenu.Caption := FFavoriteAuthorHeart.Hint;
  FFavoriteToggleMenu.Enabled := Selected;
  FFavoriteNewMenu.Enabled := Ready;
  FFavoriteViewedMenu.Enabled := Ready;
  FFavoriteNewMenu.Checked := FOnlyNewFavoriteBooks;
  FFavoriteNewButton.Enabled := Ready;
  FFavoriteNewButton.Font.Style := [];
  if FOnlyNewFavoriteBooks then FFavoriteNewButton.Font.Style := [fsBold];
  if Ready then
  begin
    NewCount := FFavoriteStore.NewCount(Settings.ActiveCollection, Key);
    if FOnlyNewFavoriteBooks then FFavoriteNewButton.Caption := '✓ ' + IntToStr(NewCount)
    else if NewCount > 0 then FFavoriteNewButton.Caption := '+' + IntToStr(NewCount)
    else FFavoriteNewButton.Caption := 'Новые';
    FFavoriteViewedMenu.Enabled := NewCount > 0;
  end
  else if Assigned(FFavoriteWorker) then FFavoriteNewButton.Caption := '…'
  else FFavoriteNewButton.Caption := 'Новые';
  if FOnlyNewFavoriteBooks then
    FFavoriteNewButton.Hint := 'Показаны только новые книги. Нажмите, чтобы показать все книги автора.'
  else FFavoriteNewButton.Hint := 'Показать только новые книги выбранного любимого автора';
  FFavoriteStopMenu.Enabled := Assigned(FFavoriteWorker);
  FFavoriteListCheck.Font.Color := clGrayText;
  if FFavoriteListCheck.Checked then FFavoriteListCheck.Font.Color := clWindowText;
end;

procedure TfrmMain.FavoriteSelectedAuthorClick(Sender: TObject);
var Author: TAuthorData; Key: string; Enabled: Boolean;
begin
  if (ActiveView <> AuthorsView) or not SelectedFavoriteAuthor(Author, Key) then Exit;
  Enabled := not FavoriteStore.IsFavorite(Author);
  StopFavoriteRefresh(True);
  FavoriteStore.SetFavorite(Author.LastName, Author.FirstName, Author.MiddleName, Enabled);
  PublishFavoriteFilterKeys;
  FOnlyNewFavoriteBooks := False;
  CheckFavoriteCollection;
  Include(FStaleSelectors, AuthorsView);
  Exclude(FLoadedBookViews, AuthorsView);
  if FHasAppliedSearch and FSearchCriteria.FavoriteAuthorsOnly then
  begin
    FSearchCriteria.FavoriteAuthorIDs := FavoriteStore.BoundAuthorIDs(FCollection.CollectionID);
    Exclude(FLoadedBookViews, SearchView);
  end;
  EnsureActiveBookViewLoaded;
  tvAuthors.Invalidate;
  UpdateFavoriteControls;
end;

procedure TfrmMain.FavoriteListClick(Sender: TObject);
begin
  FOnlyNewFavoriteBooks := False;
  if FFavoriteListCheck.Checked then CheckFavoriteCollection;
  Include(FStaleSelectors, AuthorsView);
  Exclude(FLoadedBookViews, AuthorsView);
  if ActiveView = AuthorsView then EnsureActiveBookViewLoaded;
  UpdateFavoriteControls;
end;

procedure TfrmMain.FavoriteNewClick(Sender: TObject);
var Author: TAuthorData; Key: string;
begin
  if not SelectedFavoriteAuthor(Author, Key) or not FavoriteStore.IsFavorite(Author) then Exit;
  FOnlyNewFavoriteBooks := not FOnlyNewFavoriteBooks;
  Exclude(FLoadedBookViews, AuthorsView);
  if ActiveView = AuthorsView then EnsureActiveBookViewLoaded;
  UpdateFavoriteControls;
end;

procedure TfrmMain.FavoriteViewedClick(Sender: TObject);
var Author: TAuthorData; Key: string;
begin
  if not SelectedFavoriteAuthor(Author, Key) or not FavoriteStore.IsFavorite(Author) then Exit;
  StopFavoriteRefresh(True);
  FavoriteStore.MarkViewed(FCollection.CollectionID, Key);
  Exclude(FLoadedBookViews, AuthorsView);
  if ActiveView = AuthorsView then EnsureActiveBookViewLoaded;
  tvAuthors.Invalidate;
  UpdateFavoriteControls;
end;

procedure TfrmMain.FavoriteStopClick(Sender: TObject);
begin
  StopFavoriteRefresh(True);
  StatusMessage := 'Проверка любимых авторов остановлена';
  UpdateFavoriteControls;
end;

procedure TfrmMain.FavoriteMenuClick(Sender: TObject);
var Position: TPoint;
begin
  UpdateFavoriteControls;
  Position := FFavoriteMenuButton.ClientToScreen(Point(0, FFavoriteMenuButton.Height));
  FFavoriteMenu.Popup(Position.X, Position.Y);
end;

procedure TfrmMain.FavoriteTransferClick(Sender: TObject);
var FileName: string; Data: TUserData;
begin
  if TMenuItem(Sender).Tag=0 then
  begin
    if not GetFileName(fnSaveUserData,FileName) then Exit;
    Data:=TUserData.Create;
    try Data.FavoriteAuthors:=FavoriteStore.Entries; Data.Save(FileName);
    finally Data.Free; end;
    StatusMessage:='Любимые авторы экспортированы: '+FileName;
  end
  else
  begin
    if not GetFileName(fnOpenUserData,FileName) then Exit;
    Data:=TUserData.Create;
    try
      Data.Load(FileName);
      if Length(Data.FavoriteAuthors)=0 then
      begin MHLShowInfo('В этом файле нет любимых авторов. Старые экспорты не включали этот список.'); Exit; end;
      StopFavoriteRefresh(True); FavoriteStore.ImportFavorites(Data.FavoriteAuthors);
      PublishFavoriteFilterKeys; FOnlyNewFavoriteBooks:=False;
      Include(FStaleSelectors,AuthorsView); Exclude(FLoadedBookViews,AuthorsView);
      CheckFavoriteCollection; EnsureActiveBookViewLoaded;
      tvAuthors.Invalidate; UpdateFavoriteControls;
      StatusMessage:='Любимые авторы импортированы. Имеющийся список сохранён.';
    finally Data.Free; end;
  end;
end;

function TfrmMain.AuthorSelectorIterator: IAuthorIterator;
var View: IAuthorFavoriteCollectionView; IDs: TArray<Integer>;
begin
  if not Assigned(FFavoriteListCheck) or not FFavoriteListCheck.Checked then
    Exit(FCollection.GetAuthorIterator(amFullFilter));
  if not Supports(FCollection, IAuthorFavoriteCollectionView, View) then
    raise EAuthorFavorites.Create('Любимые авторы недоступны для этого типа каталога.');
  FFavoriteDescriptor := FavoriteDescriptor(FCollection);
  if FavoriteBindingsReady(FFavoriteDescriptor) then IDs := FavoriteStore.BoundAuthorIDs(FCollection.CollectionID)
  else QueueFavoriteRefresh(FFavoriteDescriptor);
  Result := View.GetFavoriteAuthorIterator(IDs);
end;

procedure TfrmMain.FillCurrentAuthorBooks;
var Filter: TFilterValue; Criteria: TBookSearchCriteria; Author: TAuthorData; Key: string;
begin
  if not FOnlyNewFavoriteBooks then
  begin
    Filter := AuthorBookFilter;
    FillBooksTree(tvBooksA, cbLangSelectA,
      function: IBookIterator begin Result := FCollection.GetBookIterator(bmByAuthor, False, @Filter); end,
      False, True, @FLastAuthorBookID);
    Exit;
  end;
  Criteria := Default(TBookSearchCriteria);
  Criteria.DateIdx := -1;
  Criteria.Deleted := Settings.HideDeletedBooks;
  Criteria.CollapseMultiSeriesResults := True;
  Criteria.FavoriteAuthorsOnly := True;
  Criteria.FavoriteAuthorIDs := TArray<Integer>.Create(FLastAuthorID);
  Criteria.RestrictBookIDs := True;
  if FCollection.GetShowLocalOnly then Criteria.DownloadedIdx := 1;
  if SelectedFavoriteAuthor(Author, Key) and FavoriteStore.IsFavorite(Author) then
  begin
    FFavoriteDescriptor := FavoriteDescriptor(FCollection);
    if FavoriteBindingsReady(FFavoriteDescriptor) then
      Criteria.BookIDs := FavoriteStore.NewBookIDs(FCollection.CollectionID, Key)
    else QueueFavoriteRefresh(FFavoriteDescriptor);
  end;
  FillBooksTree(tvBooksA, cbLangSelectA,
    function: IBookIterator begin Result := FCollection.Search(Criteria, False); end,
    False, True, @FLastAuthorBookID);
end;

procedure TfrmMain.FavoriteAuthorGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
  Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var Data: PAuthorData; Count: Integer;
begin
  if Assigned(FFavoriteOriginalGetText) then FFavoriteOriginalGetText(Sender, Node, Column, TextType, CellText);
  Data := Sender.GetNodeData(Node);
  if Settings.AuthorInitials and Assigned(Data) then CellText := Data^.GetFullName(True);
  if not Assigned(FFavoriteStore) then Exit;
  try
  if Assigned(Data) and FFavoriteStore.IsFavorite(Data^) and
    not FFavoriteDirtyCollections.ContainsKey(Settings.ActiveCollection) and
    (FFavoriteStore.CollectionRevision(Settings.ActiveCollection) = FFavoriteDescriptor.Revision) then
  begin
    Count := FFavoriteStore.NewCount(Settings.ActiveCollection,
      AuthorFavoriteKey(Data^.LastName, Data^.FirstName, Data^.MiddleName));
    if Count > 0 then CellText := CellText + '  +' + IntToStr(Count);
  end;
  except
    // Keep the ordinary author text usable when source metadata cannot form
    // a valid favorite key. A malformed row must not interrupt UI painting.
    on E: EAuthorFavorites do Exit;
  end;
end;

procedure TfrmMain.AuthorNameStyleClick(Sender: TObject);
begin
  Settings.AuthorInitials := not Settings.AuthorInitials;
  for var Name in TArray<string>.Create('miAuthorInitials', 'miAuthorInitialsFavorite') do
  begin
    var Item := FindComponent(Name) as TMenuItem;
    if Assigned(Item) then Item.Checked := Settings.AuthorInitials;
  end;
  // Only paint changes: IDs, ordering, exact author expressions and search
  // continue to use the full names from the catalogue.
  tvAuthors.Invalidate;
  Settings.SaveSettings;
end;

function TfrmMain.IsFavoriteAuthorNode(Sender: TBaseVirtualTree; Node: PVirtualNode): Boolean;
var Data: PAuthorData;
begin
  Result := False;
  if not Assigned(FFavoriteStore) or not Assigned(Node) then Exit;
  Data := Sender.GetNodeData(Node);
  if not Assigned(Data) then Exit;
  try Result := FFavoriteStore.IsFavorite(Data^);
  except on E: EAuthorFavorites do Exit; end;
end;

procedure TfrmMain.FavoriteAuthorBeforeCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas;
  Node: PVirtualNode; Column: TColumnIndex; CellPaintMode: TVTCellPaintMode;
  CellRect: TRect; var ContentRect: TRect);
var PPI: Integer;
begin
  if Assigned(FFavoriteOriginalBeforeCellPaint) then
    FFavoriteOriginalBeforeCellPaint(Sender, TargetCanvas, Node, Column, CellPaintMode, CellRect, ContentRect);
  if Column > 0 then Exit;
  PPI := tvAuthors.Font.PixelsPerInch; if PPI <= 0 then PPI := CurrentPPI;
  Inc(ContentRect.Left, Min(Max(0, ContentRect.Width), MulDiv(18, PPI, 96)));
end;

procedure TfrmMain.FavoriteAuthorAfterCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas;
  Node: PVirtualNode; Column: TColumnIndex; CellRect: TRect);
var PPI: Integer; Bounds: TRect; OldColor: TColor; OldBrush: TBrushStyle;
begin
  if Assigned(FFavoriteOriginalAfterCellPaint) then
    FFavoriteOriginalAfterCellPaint(Sender, TargetCanvas, Node, Column, CellRect);
  if (Column > 0) or not IsFavoriteAuthorNode(Sender, Node) then Exit;
  PPI := tvAuthors.Font.PixelsPerInch; if PPI <= 0 then PPI := CurrentPPI;
  Bounds := CellRect; Inc(Bounds.Left, MulDiv(2, PPI, 96));
  Bounds.Right := Min(CellRect.Right, Bounds.Left + MulDiv(14, PPI, 96));
  if Bounds.Width <= 0 then Exit;
  OldColor := TargetCanvas.Font.Color; OldBrush := TargetCanvas.Brush.Style;
  try
    if vsSelected in Node.States then TargetCanvas.Font.Color := clHighlightText
    else if MHLThemeDark then TargetCanvas.Font.Color := RGB(150, 166, 180)
    else TargetCanvas.Font.Color := RGB(90, 112, 130);
    TargetCanvas.Brush.Style := bsClear;
    DrawText(TargetCanvas.Handle, PChar('♥'), 1, Bounds, DT_SINGLELINE or DT_VCENTER or DT_CENTER or DT_NOPREFIX);
  finally
    TargetCanvas.Font.Color := OldColor; TargetCanvas.Brush.Style := OldBrush;
  end;
end;

procedure TfrmMain.SearchFavoriteClick(Sender: TObject);
begin
  // This is a draft condition: repaint its indicator without querying books.
  UpdateBookFilterIndicators(tvBooksSR);
end;

procedure TfrmMain.UpdateBookFilterIndicators(Tree: TBookTree);
var Filters: TBookColumnFilters; ActiveTags: TArray<Integer>; Tag: Integer;
begin
  Filters := TBookColumnFilters.ForTree(Tree);
  for var I := 0 to Tree.Header.Columns.Count - 1 do
  begin
    Tag := Tree.Header.Columns[I].Tag;
    if (Filters.Value(Tag) <> '') or ((Tag = COL_AUTHOR) and
      (Filters.FavoriteAuthorsOnly or ((Tree = tvBooksSR) and
        Assigned(FSearchFavoriteCheck) and FSearchFavoriteCheck.Checked))) then
      ActiveTags := ActiveTags + [Tag];
  end;
  Tree.HeaderFilteredTags := ActiveTags;
  Tree.Header.Invalidate(nil);
end;

procedure TfrmMain.SearchFavoriteEditResize(Sender: TObject);
begin
  if HandleAllocated then PostMessage(Handle, WM_AUTHOR_FAVORITES_LAYOUT, 0, 0);
end;

procedure TfrmMain.WMFavoriteLayout(var Message: TMessage);
begin UpdateFavoriteSearchLayout; end;

procedure TfrmMain.UpdateFavoriteSearchLayout;
var Size, Gap, RightWidth, PPI: Integer; Child: TControl;
begin
  if not Assigned(FSearchFavoriteCheck) then Exit;
  PPI := edFFullName.Font.PixelsPerInch;
  if PPI <= 0 then PPI := CurrentPPI;
  Size := MulDiv(18, PPI, 96);
  Gap := MulDiv(2, PPI, 96);
  FSearchFavoriteCheck.SetBounds(edFFullName.ClientWidth - Size - Gap, Gap,
    Size, Max(1, edFFullName.ClientHeight - 2 * Gap));
  RightWidth := 0;
  for var I := 0 to edFFullName.ControlCount - 1 do
  begin
    Child := edFFullName.Controls[I];
    // Buttoned edit contains its expression button plus our checkbox. Moving
    // by control identity also works at narrow widths and after DPI scaling.
    if (Child <> FSearchFavoriteCheck) and Child.Visible then
    begin
      Child.Left := FSearchFavoriteCheck.Left - Child.Width - Gap;
      RightWidth := Max(RightWidth, Child.Width);
    end;
  end;
  if edFFullName.HandleAllocated then
    SendMessage(edFFullName.Handle, EM_SETMARGINS, EC_RIGHTMARGIN, LPARAM(MakeLong(0, Size + RightWidth + 4 * Gap)));
end;

procedure TfrmMain.CreateFavoriteAuthorControls;
var Panel: TPanel; Item: TMenuItem; PPI: Integer;
begin
  PPI := Font.PixelsPerInch;
  if PPI <= 0 then PPI := CurrentPPI;
  FFavoriteQueue := TQueue<TAuthorFavoriteCollection>.Create;
  FFavoriteDirtyCollections := TDictionary<Integer, Cardinal>.Create;
  FSearchFavoriteCheck := TCheckBox.Create(Self);
  FSearchFavoriteCheck.Name := 'cbSearchFavoriteAuthorsOnly';
  FSearchFavoriteCheck.Parent := edFFullName;
  FSearchFavoriteCheck.Caption := '';
  FSearchFavoriteCheck.ShowHint := True;
  FSearchFavoriteCheck.Hint := 'Только книги любимых авторов. Синий значок автора отмечает выбранное условие; поиск запускается кнопкой «Применить».';
  FSearchFavoriteCheck.OnClick := SearchFavoriteClick;
  TFavoriteEditAccess(edFFullName).OnResize := SearchFavoriteEditResize;
  UpdateFavoriteSearchLayout;

  Panel := TPanel.Create(Self); Panel.Name := 'pnFavoriteAuthors';
  Panel.Parent := pnAuthorsView; Panel.BevelOuter := bvNone; Panel.Caption := '';
  Panel.Height := MulDiv(32, PPI, 96); Panel.Top := 0; Panel.Align := alTop;
  FFavoriteListCheck := TCheckBox.Create(Self); FFavoriteListCheck.Name := 'cbFavoriteAuthorsList';
  FFavoriteListCheck.Parent := Panel; FFavoriteListCheck.Caption := '♥ Любимые';
  FFavoriteListCheck.AlignWithMargins := True; FFavoriteListCheck.Align := alClient;
  FFavoriteListCheck.Font.Style := [fsBold]; FFavoriteListCheck.Font.Color := clGrayText;
  FFavoriteListCheck.OnClick := FavoriteListClick;
  FFavoriteMenuButton := TButton.Create(Self); FFavoriteMenuButton.Parent := Panel;
  FFavoriteMenuButton.Name := 'btnFavoriteAuthorMenu'; FFavoriteMenuButton.Caption := '⋮';
  FFavoriteMenuButton.Align := alRight; FFavoriteMenuButton.Width := MulDiv(26, PPI, 96);
  FFavoriteMenuButton.OnClick := FavoriteMenuClick;
  FFavoriteNewButton := TButton.Create(Self); FFavoriteNewButton.Parent := Panel;
  FFavoriteNewButton.Name := 'btnFavoriteAuthorNew'; FFavoriteNewButton.Caption := 'Новые';
  FFavoriteNewButton.Align := alRight; FFavoriteNewButton.Width := MulDiv(58, PPI, 96);
  FFavoriteNewButton.ShowHint := True; FFavoriteNewButton.Hint := 'Только новые книги выбранного любимого автора';
  FFavoriteNewButton.OnClick := FavoriteNewClick;
  FFavoriteAuthorHeart := TButton.Create(Self); FFavoriteAuthorHeart.Name := 'btnFavoriteSelectedAuthor';
  FFavoriteAuthorHeart.Parent := pnAuthorBooksTitle; FFavoriteAuthorHeart.Align := alRight;
  FFavoriteAuthorHeart.Width := MulDiv(32, PPI, 96); FFavoriteAuthorHeart.Caption := '♡';
  FFavoriteAuthorHeart.ShowHint := True; FFavoriteAuthorHeart.OnClick := FavoriteSelectedAuthorClick;

  FFavoriteMenu := TPopupMenu.Create(Self); FFavoriteMenu.Name := 'pmFavoriteAuthors';
  for var I := 0 to 3 do
  begin
    Item := TMenuItem.Create(Self);
    case I of
      0: begin Item.Caption := 'Добавить автора в любимые'; Item.OnClick := FavoriteSelectedAuthorClick; FFavoriteToggleMenu := Item; end;
      1: begin Item.Caption := 'Только новые книги'; Item.OnClick := FavoriteNewClick; FFavoriteNewMenu := Item; end;
      2: begin Item.Name := 'miFavoriteAuthorViewed'; Item.Caption := 'Отметить новые просмотренными'; Item.OnClick := FavoriteViewedClick; FFavoriteViewedMenu := Item; end;
      3: begin Item.Name := 'miFavoriteAuthorStop'; Item.Caption := 'Остановить проверку'; Item.OnClick := FavoriteStopClick; FFavoriteStopMenu := Item; end;
    end;
    FFavoriteMenu.Items.Add(Item);
  end;
  Item:=TMenuItem.Create(Self); Item.Caption:='-'; FFavoriteMenu.Items.Add(Item);
  for var I:=0 to 1 do
  begin
    Item:=TMenuItem.Create(Self); Item.Tag:=I;
    if I=0 then Item.Caption:='Экспорт любимых авторов…' else Item.Caption:='Импорт любимых авторов…';
    Item.OnClick:=FavoriteTransferClick; FFavoriteMenu.Items.Add(Item);
  end;
  Item := TMenuItem.Create(Self); Item.Name := 'miFavoriteSelectedAuthor';
  Item.Caption := 'Добавить автора в любимые'; Item.OnClick := FavoriteSelectedAuthorClick;
  pmAuthor.Items.Add(Item); FFavoriteContextMenu := Item;
  for var I := 0 to 1 do
  begin
    Item := TMenuItem.Create(Self);
    if I = 0 then Item.Name := 'miAuthorInitials' else Item.Name := 'miAuthorInitialsFavorite';
    Item.Caption := 'Фамилия и инициалы в списке авторов';
    Item.Checked := Settings.AuthorInitials; Item.OnClick := AuthorNameStyleClick;
    if I = 0 then miView.Add(Item) else FFavoriteMenu.Items.Add(Item);
  end;
  FFavoriteOriginalGetText := tvAuthors.OnGetText;
  tvAuthors.OnGetText := FavoriteAuthorGetText;
  FFavoriteOriginalBeforeCellPaint := tvAuthors.OnBeforeCellPaint;
  FFavoriteOriginalAfterCellPaint := tvAuthors.OnAfterCellPaint;
  tvAuthors.OnBeforeCellPaint := FavoriteAuthorBeforeCellPaint;
  tvAuthors.OnAfterCellPaint := FavoriteAuthorAfterCellPaint;
  UpdateFavoriteControls;
end;

procedure TfrmMain.ApplySearchCriteria(const Criteria: TBookSearchCriteria; SelectedID: PBookKey);
begin
  Exclude(FLoadedBookViews, SearchView);
  tvBooksSR.Clear;
  ClearLabels(PAGE_SEARCH, True);
  FillBooksTree(tvBooksSR, nil,
    function: IBookIterator begin Result := FCollection.Search(Criteria, False); end, True, True, SelectedID);
  if not FBookListCancelled then
  begin
    FSearchCriteria := Criteria;
    FHasAppliedSearch := True;
  end;
end;

function TfrmMain.SearchPresetIndex(const Name: string): Integer;
var
  TrimmedName: string;
begin
  TrimmedName := Trim(Name);
  Result := cbPresetName.ItemIndex;
  // Retain an explicitly selected legacy entry even if another differs only in case.
  if (Result >= 0) and (Result < cbPresetName.Items.Count) and
    (Trim(cbPresetName.Items[Result]) = TrimmedName) then Exit;
  for var I := 0 to cbPresetName.Items.Count - 1 do
    if Trim(cbPresetName.Items[I]) = TrimmedName then Exit(I);
  for var I := 0 to cbPresetName.Items.Count - 1 do
    if AnsiSameText(Trim(cbPresetName.Items[I]), TrimmedName) then Exit(I);
  Result := -1;
end;

procedure TfrmMain.SaveSearchPreset(Sender: TObject);
var
  presetName: string;
  preset, ExistingPreset, CopiedPreset: TSearchPreset;
  Candidate, Previous: TSearchPresets;
  Field: TPair<string, string>;
  PresetIndex: Integer;
begin
  presetName := Trim(cbPresetName.Text);
  if (presetName = '') or not Assigned(FPresets) then
    Exit;
  PresetIndex := SearchPresetIndex(presetName);
  if PresetIndex >= 0 then presetName := cbPresetName.Items[PresetIndex];

  // Keep the current presets and controls intact until the file is committed.
  Candidate := TSearchPresets.Create;
  try
    for ExistingPreset in FPresets do
    begin
      CopiedPreset := Candidate.GetPreset(ExistingPreset.DisplayName);
      for Field in ExistingPreset do
        CopiedPreset.AddOrSetValue(Field.Key, Field.Value);
    end;
    preset := Candidate.GetPreset(presetName);
    preset.Clear;
    FSearchMode.SavePreset(preset);

    preset.AddOrSetValue(SF_AUTHORS, edFFullName.Text);
    preset.AddOrSetValue(SF_FAVORITE_AUTHORS, BoolToStr(FSearchFavoriteCheck.Checked));
    preset.AddOrSetValue(SF_TITLE, edFTitle.Text);
    preset.AddOrSetValue(SF_SERIES, edFSeries.Text);
    preset.AddOrSetValue(SF_PUBLISHER, FPublisherSearchEdit.Text);
    preset.AddOrSetValue(SF_TRANSLATORS,FTranslatorSearchEdit.Text);
    preset.AddOrSetValue(SF_CITY,FCitySearchEdit.Text);
    preset.AddOrSetValue(SF_PUBYEAR,FPubYearSearchEdit.Text);
    preset.AddOrSetValue(SF_ISBN,FISBNSearchEdit.Text);
    preset.AddOrSetValue(SF_WITH_NOTES,BoolToStr(FNotesOnlySearchCheck.Checked));
    preset.AddOrSetValue(SF_GENRE_TITLE, edFGenre.Text);
    preset.AddOrSetValue(SF_GENRE_CODES, edFGenre.Hint);
    preset.AddOrSetValue(SF_ANNOTATION, edFAnnotation.Text);

    preset.AddOrSetValue(SF_FILE, edFFile.Text);
    preset.AddOrSetValue(SF_FOLDER, edFFolder.Text);
    preset.AddOrSetValue(SF_EXTENSION, edFExt.Text);

    preset.AddOrSetValue(SF_DOWNLOADED, IntToStr(cbDownloaded.ItemIndex));
    preset.AddOrSetValue(SF_KEYWORDS, edFKeyWords.Text);
    preset.AddOrSetValue(SF_DELETED, BoolToStr(cbDeleted.Checked));

    if cbDate.ItemIndex = -1 then
    begin
      preset.AddOrSetValue(SF_DATE, IntToStr(-1));
      preset.AddOrSetValue(SF_DATE_STR, cbDate.Text);
    end
    else begin
      preset.AddOrSetValue(SF_DATE, IntToStr(cbDate.ItemIndex));
      preset.AddOrSetValue(SF_DATE_STR, '');
    end;

    if cbLibRate.ItemIndex = -1 then
    begin
      preset.AddOrSetValue(SF_LIBRATE, IntToStr(-1));
      preset.AddOrSetValue(SF_LIBRATE_STR, cbLibRate.Text);
    end
    else begin
      preset.AddOrSetValue(SF_LIBRATE, IntToStr(cbLibRate.ItemIndex));
      preset.AddOrSetValue(SF_LIBRATE_STR, '');
    end;

    preset.AddOrSetValue(SF_LANG, IntToStr(cbLang.ItemIndex));
    preset.AddOrSetValue(SF_READED, BoolToStr(cbReaded.Checked));

    try
      Candidate.Save(Settings.SystemFileName[sfPresets]);
    except
      on E: Exception do
        raise EInOutError.Create('Не удалось сохранить пресет. Предыдущие пресеты сохранены. ' + E.Message);
    end;

    Previous := FPresets;
    FPresets := Candidate;
    Candidate := nil;
    Previous.Free;
    PresetIndex := SearchPresetIndex(presetName);
    if PresetIndex < 0 then
      PresetIndex := cbPresetName.Items.Add(presetName);
    cbPresetName.ItemIndex := PresetIndex;
  finally
    Candidate.Free;
  end;
end;

procedure TfrmMain.LocateAuthor(const Text: string);
var
  Node: PVirtualNode;
  Data: PAuthorData;
begin
  tvAuthors.ClearSelection;
  Node := tvAuthors.GetFirst;

  while Assigned(Node) do
  begin
    Data := tvAuthors.GetNodeData(Node);
    Assert(Assigned(Data));
    if StartsText(Text, Data^.GetFullName) then
    begin
      tvAuthors.Selected[Node] := True;
      tvAuthors.FocusedNode := Node;
      tvAuthors.TopNode := Node;
      tvAuthorsChange(tvAuthors, Node);
      Exit;
    end;
    Node := tvAuthors.GetNext(Node);
  end;
end;

procedure TfrmMain.LocateSeries(const Text: string);
var
  Node: PVirtualNode;
  Data: PSeriesData;
begin
  tvSeries.ClearSelection;
  Node := tvSeries.GetFirst;

  while Assigned(Node) do
  begin
    Data := tvSeries.GetNodeData(Node);
    Assert(Assigned(Data));
    if StartsText(Text, Data^.SeriesTitle) then
    begin
      tvSeries.Selected[Node] := True;
      tvSeries.FocusedNode := Node;
      tvSeries.TopNode := Node;
      tvSeriesChange(tvSeries, Node);
      Exit;
    end;
    Node := tvSeries.GetNext(Node);
  end;
end;

procedure TfrmMain.LocateBook(const Text: string; MoveForward: Boolean);
var
  Node: PVirtualNode;
  Data: PBookRecord;
  L: Integer;
  Tree: TBookTree;
  FixedText: string;
begin
  GetActiveTree(Tree);

  Tree.ClearSelection;

  if not MoveForward then
    FLastFoundBook := nil;

  if MoveForward and Assigned(FLastFoundBook) then
    Node := Tree.GetNext(FLastFoundBook)
  else
    Node := Tree.GetFirst;

  L := Length(Text);
  FixedText := AnsiUpperCase(Text);

  while Assigned(Node) do
  begin
    Data := Tree.GetNodeData(Node);
    Assert(Assigned(Data));
    if not Tree.IsEffectivelyFiltered[Node] and
      (FixedText = Copy(AnsiUpperCase(Data.Title), 1, L)) then
    begin
      Tree.Selected[Node] := True;
      Tree.FocusedNode := Node;
      Tree.TopNode     := Node;

      if not MoveForward then
        FFirstFoundBook := Node;

      FLastFoundBook := Node;

      Exit;
    end;
    Node := Tree.GetNext(Node);
  end;

  if Assigned(FFirstFoundBook) and not Tree.IsEffectivelyFiltered[FFirstFoundBook] then
  begin
    FLastFoundBook := FFirstFoundBook;

    Tree.FocusedNode := FLastFoundBook;
    Tree.Selected[FLastFoundBook] := True;
  end;
end;

procedure TfrmMain.LocateAuthorAndBook(const FullAuthorName: string; const BookKey: TBookKey);
var
  authorData: PAuthorData;
  savedCursor: TCursor;
  Button : TToolButton;

begin
  if Assigned(FFavoriteListCheck) then FFavoriteListCheck.Checked := False;
  savedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    if BookKey.DatabaseID <> FCollection.CollectionID then
    begin
      Settings.ActiveCollection := BookKey.DatabaseID;
      InitCollection;
    end;


    Button := GetFilterButton(FAuthorBars, FullAuthorName);
    if Assigned(Button) and (Button <> FLastLetterA) then
    begin
      FIgnoreAuthorChange := True;
      InternalSetAuthorFilter(Button);
    end;
    FIgnoreAuthorChange := False;
    LocateAuthor(FullAuthorName);

    authorData := tvAuthors.GetNodeData(tvAuthors.FocusedNode);
    FLastAuthorID := authorData.AuthorID;

    FLastAuthorBookID := BookKey;
    Exclude(FLoadedBookViews, AuthorsView);

    ActivateView(AuthorsView);
    pgControlChange(nil);


  finally
    Screen.Cursor := savedCursor;
  end;
end;


procedure TfrmMain.edLocateAuthorKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if ActiveView = AuthorsView then
  begin
    if Key = VK_UP then
      tvAuthors.Perform(WM_KEYDOWN, VK_UP, 0)
    else if Key = VK_DOWN then
      tvAuthors.Perform(WM_KEYDOWN, VK_DOWN, 0)
    else if Key = VK_RETURN then
      frmMain.ActiveControl := tvBooksA;
  end
  else if ActiveView = SeriesView then
  begin
    if Key = VK_UP then
      tvSeries.Perform(WM_KEYDOWN, VK_UP, 0)
    else if Key = VK_DOWN then
      tvSeries.Perform(WM_KEYDOWN, VK_DOWN, 0)
    else if Key = VK_RETURN then
      frmMain.ActiveControl := tvBooksS;
  end;
end;

procedure TfrmMain.edLocateSeriesChange(Sender: TObject);
begin
  if not tmrSearchS.Enabled then
  begin
    tmrSearchS.Enabled := True;
    FTimerDone := False;
  end;
end;

procedure TfrmMain.ShowExpressionEditor(Sender: TObject);
var
  frmEditor: TfrmEditor;
begin
  frmEditor := TfrmEditor.Create(Self);
  try
    frmEditor.Text := (Sender as TMHLButtonedEdit).Text;
    if frmEditor.ShowModal = mrOk then
      (Sender as TMHLButtonedEdit).Text := frmEditor.Text;
  finally
    frmEditor.Free;
  end;
end;

procedure TfrmMain.PresetFieldKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
    acApplyPreset.Execute;
end;

procedure TfrmMain.ShowGenreEditor(Sender: TObject);
var
  frmGenres: TfrmGenreTree;
  Genres: TBookGenres;
  Names, Conditions: TArray<string>;
  I: Integer;
begin
  Assert(Assigned(FCollection));
  frmGenres := TfrmGenreTree.Create(Application);
  try
    FillGenresTree(frmGenres.tvGenresTree, FCollection.GetGenreIterator(gmAll));
    if frmGenres.ShowModal = mrOk then
    begin
      frmGenres.GetSelectedGenres(Genres);

      SetLength(Names, Length(Genres));
      SetLength(Conditions, Length(Genres));
      for I := 0 to High(Genres) do
      begin
        Names[I] := Genres[I].GenreAlias;
        Conditions[I] := Format('(g.GenreCode = "%s")', [Genres[I].GenreCode]);
      end;
      edFGenre.Text := TArrayUtils.Join(Names, ' / ');
      edFGenre.Hint := TArrayUtils.Join(Conditions, ' OR ');
    end;
  finally
    frmGenres.Free;
  end;
end;

procedure TfrmMain.edFGenreKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = Chr(8) then
  begin
    edFGenre.Text := '';
    edFGenre.Hint := '';
  end;
  Key := Chr(0);
end;

procedure TfrmMain.ShowAboutExecute(Sender: TObject);
var
  frmAbout: TfrmAbout;
begin
  frmAbout := TfrmAbout.Create(Application);
  try
    frmAbout.ShowModal;
  finally
    frmAbout.Free;
  end;
end;

procedure TfrmMain.miActiveCollectionClick(Sender: TObject);
var
  i: Integer;
begin
  i := (Sender as TMenuItem).Tag;
  (Sender as TMenuItem).Checked := True;
  Settings.ActiveCollection := i;
  InitCollection;
end;

procedure TfrmMain.ShowBookInfo(Sender: TObject);
var
  Tree: TBookTree;
  Data: PBookRecord;
  frmBookDetails: TfrmBookDetails;

  bookStream: TStream;
  ReviewEditable: Boolean;
  BookCollection: IBookCollection;
  AuthorNames: TArray<string>; I: Integer;

  URL: string;

  strReview, strAnnotation: string;
  Saved, Stored, Changed: TBookRecord;
  PersonalOnly, RetrySave: Boolean;
  Outcome: TReaderPersonalWriteResult;
  DraftPath, DraftText, Namespace: string;
  DraftHandle: THandle; DraftStream: THandleStream; DraftBytes: TBytes;
  GroupNode: PVirtualNode; GroupData: PBookRecord; Modal: Integer;
begin
  Assert(Assigned(FCollection));
  GetActiveTree(Tree);
  Assert(Assigned(Tree));

  Data := Tree.GetNodeData(Tree.FocusedNode);
  if not Assigned(Data) or (Data^.nodeType <> ntBookInfo) then
    Exit;

  Saved := Data^; PersonalOnly := (Tree = tvBooksF) or (Saved.BookKey.BookID <= 0);
  BookCollection := nil;
  try BookCollection := FSystemData.GetCollection(Saved.BookKey.DatabaseID); except end;
  FFormBusy := True;
  try
    ReviewEditable := (Saved.BookKey.BookID <= 0) or
      (Saved.BookKey.DatabaseID = FCollection.CollectionID);

    frmBookDetails := TfrmBookDetails.Create(Application);
    try
      // сейчас мы грузим только fb2 или fbd, т к больше ничего разбирать не умеем
      if (bpIsLocal in Data^.BookProps) and CatalogBookAvailable(Data^, False) then
      begin
        try
          bookStream := Data^.GetBookDescriptorStream(False);
          try
            frmBookDetails.FillBookInfo(Data^, bookStream)
          finally
            FreeAndNil(bookStream);
          end;
        except
          // Скорее всего произошла ошибка при чтении файла (не найден, а должен был быть)
          // или при парсинге книги (загрузили какую-то ерунду).
          on e: Exception do
          begin
            if not (e is ENotSupportedException) then
              MHLShowError(e.Message);
            frmBookDetails.FillBookInfo(Data^, nil);
          end;
        end;
      end
      else
        frmBookDetails.FillBookInfo(Data^, nil);

      frmBookDetails.mmReview.ReadOnly := not ReviewEditable;
      SetLength(AuthorNames, Length(Data^.Authors));
      for I := 0 to High(AuthorNames) do AuthorNames[I] := Data^.Authors[I].GetFullName;
      if Assigned(BookCollection) then
        frmBookDetails.AuthorInformation.Configure(Saved.CollectionRoot,
          BookCollection.GetProperty(PROP_AUTHOR_INFO_FOLDER), AuthorNames,
          procedure(Folder: string)
          begin if Assigned(BookCollection) then BookCollection.SetProperty(PROP_AUTHOR_INFO_FOLDER, Folder); end);

      URL := '';
      if Assigned(BookCollection) and not isPrivateCollection(BookCollection.CollectionCode) then
      begin
        URL := BookCollection.GetViewURL(Data^.LibID);

        frmBookDetails.AllowOnlineReview(URL);
      end;

      if PersonalOnly then
      begin
        // Read the proved system snapshot or the already displayed saved A;
        // never load a review from the reused positive catalogue key B.
        if ReaderTryGetPersonalBook(FSystemData, BookCollection, Saved, Stored) then
        begin frmBookDetails.Review := Stored.Review; frmBookDetails.Annotation := Stored.Annotation; end
        else begin frmBookDetails.Review := Saved.Review; frmBookDetails.Annotation := Saved.Annotation; end;
      end
      else if bpHasReview in Saved.BookProps then
      begin
        // Ordinary list rows may omit memo text. Load it only from a proved
        // current snapshot, otherwise keep the saved personal/cached A.
        Stored := Default(TBookRecord);
        try
          if Assigned(BookCollection) then BookCollection.GetBookRecord(Saved.BookKey, Stored, True);
          Namespace := ''; if Assigned(BookCollection) then
            Namespace := VarToStr(BookCollection.GetProperty(PROP_SOURCE_LIBRARY));
          if Stored.BookKey.IsSameAs(Saved.BookKey) and
            ReaderBookMatchesExpectedIdentity(Saved.LibID, ReaderBookPhysicalIdentity(Saved), Stored, Namespace) then
            frmBookDetails.Review := Stored.Review
          else if ReaderTryGetPersonalBook(FSystemData, BookCollection, Saved, Stored) then
            frmBookDetails.Review := Stored.Review
          else frmBookDetails.Review := Saved.Review;
        except on E: Exception do frmBookDetails.Review := Saved.Review; end;
      end
      else if IsOnline and ReviewEditable and Settings.AutoLoadReview then
        DownloadReview(frmBookDetails, URL);

      Namespace := ''; if Assigned(BookCollection) then
        try Namespace := VarToStr(BookCollection.GetProperty(PROP_SOURCE_LIBRARY)); except end;
      RetrySave := False;
      repeat
        Modal := frmBookDetails.ShowModal;
        if RetrySave and (Modal = mrCancel) then
          if MHLShowWarning('Отзыв пока не сохранён. Закрыть редактор и отказаться от изменений?', mbYesNo) = mrYes then Exit
          else Continue;
        if not frmBookDetails.ReviewChanged then Exit;
        strReview := frmBookDetails.Review; strAnnotation := frmBookDetails.Annotation;
        Changed := Saved; Changed.Review := strReview; Changed.Annotation := strAnnotation;
        Outcome := rpwRejected;
        if ReviewEditable and not frmBookDetails.mmReview.ReadOnly then
          Outcome := TryStoreReaderBookPersonal(BookCollection, FSystemData, Changed,
            [bpfReview,bpfAnnotation], PersonalOnly);
        if Outcome <> rpwRejected then
        begin
          if Outcome = rpwCatalog then
            UpdateNodes(Saved.BookKey,
              procedure(BookData: PBookRecord)
              begin
                if Assigned(BookData) and ReaderBookMatchesExpectedIdentity(Saved.LibID,
                  ReaderBookPhysicalIdentity(Saved), BookData^, Namespace) then
                begin
                  BookData^.Review := strReview; BookData^.Annotation := strAnnotation;
                  if strReview <> '' then Include(BookData^.BookProps,bpHasReview) else Exclude(BookData^.BookProps,bpHasReview);
                end;
              end)
          else
          begin
            GroupNode := tvBooksF.GetFirst;
            while Assigned(GroupNode) do
            begin
              GroupData := tvBooksF.GetNodeData(GroupNode);
              if Assigned(GroupData) and GroupData^.BookKey.IsSameAs(Saved.BookKey) and
                ReaderBookMatchesExpectedIdentity(Saved.LibID, ReaderBookPhysicalIdentity(Saved), GroupData^, Namespace) then
              begin
                GroupData^.Review := strReview; GroupData^.Annotation := strAnnotation;
                if strReview <> '' then Include(GroupData^.BookProps,bpHasReview) else Exclude(GroupData^.BookProps,bpHasReview);
                tvBooksF.InvalidateNode(GroupNode);
              end;
              GroupNode := tvBooksF.GetNext(GroupNode);
            end;
            StatusMessage := 'Отзыв сохранён в личной карточке. Каталог книги не обновлён.';
          end;
          Exit;
        end;
        // Publish a fresh, durable draft without replacing an existing file.
        DraftHandle := INVALID_HANDLE_VALUE; DraftPath := '';
        try
          DraftPath := TPath.Combine(Settings.DataDir, 'ReviewDrafts'); ForceDirectories(DraftPath);
          DraftPath := TPath.Combine(DraftPath, TGUID.NewGuid.ToString + '.txt');
          DraftText := 'Книга: ' + Saved.Title + sLineBreak + 'LibID: ' + Saved.LibID + sLineBreak +
            'Коллекция/номер: ' + IntToStr(Saved.BookKey.DatabaseID) + '/' + IntToStr(Saved.BookKey.BookID) +
            sLineBreak + sLineBreak + 'Отзыв:' + sLineBreak + strReview + sLineBreak + sLineBreak +
            'Аннотация:' + sLineBreak + strAnnotation;
          DraftHandle := CreateFile(PChar(DraftPath), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
          if DraftHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
          DraftStream := THandleStream.Create(DraftHandle);
          try
            DraftBytes := TEncoding.UTF8.GetBytes(DraftText);
            if Length(DraftBytes) > 0 then DraftStream.WriteBuffer(DraftBytes[0], Length(DraftBytes));
            if not FlushFileBuffers(DraftHandle) then RaiseLastOSError;
          finally DraftStream.Free; end;
          CloseHandle(DraftHandle); DraftHandle := INVALID_HANDLE_VALUE;
          MHLShowInfo('Карточка книги недоступна для записи. Исходные данные не затронуты. ' +
            'Ваш текст сохранён в файле:' + sLineBreak + DraftPath);
          Exit;
        except
          on E: Exception do
          begin
            if DraftHandle <> INVALID_HANDLE_VALUE then
            begin CloseHandle(DraftHandle); DraftHandle := INVALID_HANDLE_VALUE; SysUtils.DeleteFile(DraftPath); end;
            MHLShowInfo('Не удалось сохранить отзыв и черновик. Текст остался в редакторе.' + sLineBreak + E.Message);
            RetrySave := True;
          end;
        end;
      until False;
    finally FreeAndNil(frmBookDetails); end;
  finally
    FFormBusy := False;
  end;
end;

procedure TfrmMain.QuitAppExecute(Sender: TObject);
begin
  Close;
end;

procedure TfrmMain.pmiCheckAllClick(Sender: TObject);
begin
  Selection(True);
end;

procedure TfrmMain.pmAuthorPopup(Sender: TObject);
begin
  UpdateFavoriteControls;
  FFavoriteContextMenu.Visible := ActiveView = AuthorsView;
  FFavoriteContextMenu.Enabled := FFavoriteToggleMenu.Enabled;
  FFavoriteContextMenu.Caption := FFavoriteToggleMenu.Caption;
  miAddToSearch.Visible := not (ActiveView in [GenresView, PublisherSeriesView]);
end;

procedure TfrmMain.pmiDeselectAllClick(Sender: TObject);
begin
  Selection(False);
end;

procedure TfrmMain.pmiSelectAllClick(Sender: TObject);
var
  Tree: TBookTree;
  Node: PVirtualNode;
begin
  GetActiveTree(Tree);
  Tree.BeginUpdate;
  try
    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Tree.Selected[Node] := not Tree.IsEffectivelyFiltered[Node];
      Node := Tree.GetNext(Node);
    end;
  finally Tree.EndUpdate; end;
end;

procedure TfrmMain.pmMarkSelectedClick(Sender: TObject);
var
  Node: PVirtualNode;
  Tree: TBookTree;
begin
  GetActiveTree(Tree);
  Tree.BeginUpdate;
  try
    Node := Tree.GetFirstSelected;
    while Assigned(Node) do
    begin
      Node.CheckState := csCheckedNormal;
      Node := Tree.GetNextSelected(Node);
    end;
  finally
    Tree.EndUpdate;
  end;
end;

procedure TfrmMain.GoSiteExecute(Sender: TObject);
begin
  SimpleShellExecute(Handle, PROGRAM_HOMEPAGE);
end;

procedure TfrmMain.miGoToAuthorClick(Sender: TObject);
var
  Tree: TBookTree;
  Node: PVirtualNode;
  Data: PBookRecord;
  BookKey: TBookKey;
  FullAuthorName: string;
begin
  Assert(Assigned(FCollection));
  GetActiveTree(Tree);

  Node := Tree.FocusedNode;
  Assert(Assigned(Node));

  Data := Tree.GetNodeData(Node);

  if not Assigned(Data) then
    Exit;

  if (Data^.nodeType <> ntBookInfo) then
  begin
    if not Tree.HasChildren[Node] then
      Exit;
    repeat
      Node := Tree.GetFirstChild(Node);
      Data := Tree.GetNodeData(Node);
    until (Data^.nodeType = ntBookInfo);
  end;

  Assert(Length(Data^.Authors) > 0);
  FullAuthorName := Data^.Authors[0].GetFullName;
  BookKey := Data^.BookKey;

  LocateAuthorAndBook(FullAuthorName, BookKey);
end;

procedure TfrmMain.ShowCollectionStatisticsExecute(Sender: TObject);
var
  frmStat: TfrmStat;
begin
  Assert(Assigned(FCollection));
  frmStat := TfrmStat.Create(Application);
  try
    frmStat.LoadCollectionInfo(FCollection);
    frmStat.ShowModal;
  finally
    frmStat.Free;
  end;
end;

procedure TfrmMain.SyncFilesExecute(Sender: TObject);
begin
  Assert(Assigned(FCollection));
  UpdatePositions;

  if isOnlineCollection(FCollection.CollectionCode) then
    unit_Utils.SyncOnLineFiles(FCollection.CollectionID)
  else
  begin
    unit_Utils.SyncFolders(FCollection.CollectionID);
    // Пока это нужно, т к рабочий поток не сообщает основному об изменении свойств книги
    InitCollection;
  end;
end;

procedure TfrmMain.UpdateOnlineCollectionExecute(Sender: TObject);
var
  ActiveCollectionID: Integer;
begin
  Assert(Assigned(FCollection));
  if CheckLibUpdates(False) then
  begin
    UpdatePositions;

    ActiveCollectionID := FCollection.CollectionID;
    StartLibUpdate;
    Settings.ActiveCollection := ActiveCollectionID;
    InitCollection;
  end;
end;

procedure TfrmMain.UpdateCollectionFromFileExecute(Sender: TObject);
var
  ActiveCollectionID: Integer;
  Succeeded, CommittedChanges: Boolean;
begin
  Assert(Assigned(FCollection));
  if Assigned(FOPDSForm) then FOPDSForm.StopServer;
  UpdatePositions;

  ActiveCollectionID := FCollection.CollectionID;
  Succeeded := unit_Utils.ManualCollectionUpdate(ActiveCollectionID, Settings.SystemFileName[sfUpdateLog], CommittedChanges);
  if CommittedChanges then NotifyFavoriteCatalogChanged(TArray<Integer>.Create(ActiveCollectionID));
  if Succeeded or CommittedChanges then
  begin
    Settings.ActiveCollection := ActiveCollectionID;
    InitCollection;
  end;
end;

procedure TfrmMain.UpdateCollectionFromFileUpdate(Sender: TObject);
var
  Action: TAction;
begin
  Assert(Sender is TAction);

  Action := Sender as TAction;
  Action.Enabled := Assigned(FCollection);
end;

procedure TfrmMain.mi_dwnl_LocateAuthorClick(Sender: TObject);
var
  Data: PDownloadData;
begin
  Data := tvDownloadList.GetNodeData(tvDownloadList.FocusedNode);
  if Assigned(Data) then
  begin
    LocateAuthorAndBook(Data.Author, Data^.BookKey);
  end;
end;

procedure TfrmMain.N27Click(Sender: TObject);
begin
  DeleteFile(Settings.SystemFileName[sfColumnsStore]);
  SetColumns;
  SetHeaderPopUp;
end;

procedure TfrmMain.CompactDataBaseExecute(Sender: TObject);
begin
  if Assigned(FOPDSForm) then FOPDSForm.StopServer;
  Assert(Assigned(FCollection));
  FCollection.CompactDatabase;
end;

procedure TfrmMain.Conver2FBDExecute(Sender: TObject);
var
  Tree: TBookTree;
  Node: PVirtualNode;
  Data: PBookRecord;
  frmConvert: TfrmConvertToFBD;
begin
  if (ActiveView = DownloadView) then
  begin
    MHLShowWarning(rstrNotFromDownloadsError);
    Exit;
  end;

  GetActiveTree(Tree);
  Node := Tree.GetFirstSelected;
  Data := Tree.GetNodeData(Node);
  if not Assigned(Data) or (Data^.nodeType <> ntBookInfo) then
    Exit;

  if (AnsiLowerCase(Data^.FileExt) = FB2_EXTENSION) then
  begin
    MHLShowWarning(Format(rstrNotForExtension, [Data^.FileExt]));
    Exit;
  end;

  frmConvert := TfrmConvertToFBD.Create(Application);
  try
    frmConvert.OnGetBook := OnGetBookHandler;
    frmConvert.OnReadBook := OnReadBookHandler;
    frmConvert.OnSelectBook := OnSelectBookHandler;
    frmConvert.OnChangeBook2Zip := OnChangeBook2ZipHandler;

    frmConvert.ShowModal;
  finally
    frmConvert.Free;
  end;
end;

procedure TfrmMain.N33Click(Sender: TObject);
begin
  Close;
end;

procedure TfrmMain.ClearReadFolderExecute(Sender: TObject);
var
  dirPath: string;
begin
  if Assigned(FOPDSForm) then FOPDSForm.StopServer;
  dirPath := Settings.ReadPath;
  if DirectoryExists(dirPath) then
    ClearReadFolder(dirPath,Settings.ReadDir<>'');
  ClearBookCache;
  BookCacheActionUpdate(nil);
end;

procedure TfrmMain.BookCacheActionUpdate(Sender: TObject);
begin
  if (Sender<>nil) and (GetTickCount64-FCacheMenuUpdated<1000) then Exit;
  FCacheMenuUpdated:=GetTickCount64; ScheduleBookCacheMaintenance;
  acToolsClearReadFolder.Caption:='Очистить кэш — '+BookCacheSizeText(BookCacheUsage);
end;

procedure TfrmMain.Export2HTMLExecute(Sender: TObject);
var
  Tree: TBookTree;
begin
  GetActiveTree(Tree);
  SimpleShellExecute(Handle, Export2HTML((Sender as TAction).Tag, Settings.TempPath, Tree));
end;

procedure TfrmMain.ExportUserDataExecute(Sender: TObject);
var
  FileName: string;
  Data: TUserData;
begin
  Assert(Assigned(FCollection));
  if not unit_Helpers.GetFileName(fnSaveUserData, FileName) then
    Exit;

  Data := TUserData.Create;
  try
    FCollection.ExportUserData(Data);
    Data.FavoriteAuthors:=FavoriteStore.Entries;
    Data.Save(FileName);
  finally
    Data.Free;
  end;
end;

procedure TfrmMain.SelectColumnsExecute(Sender: TObject);
var
  Tree: TBookTree;
  PopupPosition: TPoint;
begin
  if FFormBusy or (ActiveView = DownloadView) then Exit;
  GetActiveTree(Tree);
  if not Assigned(Tree) then Exit;
  SetHeaderPopUp;
  PopupPosition := Tree.ClientToScreen(Point(0, Tree.Header.Height));
  pmHeaders.Popup(PopupPosition.X, PopupPosition.Y);
end;

procedure TfrmMain.SelectColumnsUpdate(Sender: TObject);
begin
  acViewSelectColumns.Enabled := not FFormBusy and (ActiveView <> DownloadView);
end;

procedure TfrmMain.SetBookListTotals(Tree: TBookTree; VisibleCount, TotalCount: Integer);
var Text: string; TotalLabel: TLabel; Button: TButton; Filters: TBookColumnFilters;
begin
  Filters := TBookColumnFilters.ForTree(Tree);
  UpdateBookFilterIndicators(Tree);
  Tree.Invalidate;
  TotalLabel := nil;
  case Tree.Tag of
    PAGE_AUTHORS: TotalLabel := lblBooksTotalA;
    PAGE_SERIES: TotalLabel := lblBooksTotalS;
    PAGE_GENRES: TotalLabel := lblBooksTotalG;
    PAGE_SEARCH: TotalLabel := lblTotalBooksFL;
    PAGE_FAVORITES: TotalLabel := lblBooksTotalF;
    PAGE_PUBLISHER_SERIES: TotalLabel := FPublisher.Total;
  end;
  if Assigned(TotalLabel) then
  begin
    Button := FColumnReset[Tree.Tag];
    if not Assigned(Button) then
    begin
      Button := TButton.Create(Self); FColumnReset[Tree.Tag] := Button;
      Button.Parent := TotalLabel.Parent; Button.Caption := 'Сбросить фильтры столбцов';
      Button.Width := MulDiv(176,Tree.CurrentPPI,96); Button.Height := MulDiv(24,Tree.CurrentPPI,96);
      Button.Left := Max(0,TotalLabel.Left-Button.Width-8); Button.Align := alRight;
      Button.Margins.Right := 8; Button.AlignWithMargins := True; Button.OnClick := ResetColumnFiltersClick;
    end;
    Button.Visible := Filters.Count > 0;
  end;

  if TBookColumnFilters.ForTree(Tree).Count > 0 then
    Text := Format('(%d из %d · фильтр)', [VisibleCount, TotalCount])
  else Text := Format('(%d)', [TotalCount]);
  case Tree.Tag of
    PAGE_AUTHORS: lblBooksTotalA.Caption := Text;
    PAGE_SERIES: lblBooksTotalS.Caption := Text;
    PAGE_GENRES: lblBooksTotalG.Caption := Text;
    PAGE_SEARCH: lblTotalBooksFL.Caption := Text;
    PAGE_FAVORITES: lblBooksTotalF.Caption := Text;
    PAGE_PUBLISHER_SERIES: FPublisher.Total.Caption := Text;
  end;
end;

procedure TfrmMain.ResetColumnFiltersClick(Sender: TObject);
var Tree: TBookTree;
begin
  GetActiveTree(Tree);
  TBookColumnFilters.ForTree(Tree).Clear;
  ApplyBookColumnFilters(Tree);
end;

procedure TfrmMain.ApplyBookColumnFilters(Tree: TBookTree);
var Node: PVirtualNode; Book: PBookRecord; Total, VisibleCount: Integer; SavedCursor: TCursor;
begin
  if FBookListLoading then Exit;
  FBookListLoading:=True; FBookListCancelled:=False; FBookListLastPump:=0;
  Inc(FBookInfoUpdateCount); SavedCursor:=Screen.Cursor; Screen.Cursor:=crDefault;
  FBookListCancel.Visible:=True; FBookListCancel.BringToFront;
  ShowStatusProgress:=True; StatusProgress:=0;
  try
    FFirstFoundBook:=nil; FLastFoundBook:=nil;
    try
      if FBookListCancelled then Abort;
      VisibleCount:=TBookColumnFilters.ForTree(Tree).Apply(True,
        function: Boolean begin Result:=PollBookListCancel; end);
      Total:=TBookColumnFilters.ForTree(Tree).Total;
    except
      on E: EAbort do
      begin
        if not FBookListCancelled then raise;
        // The filter evaluator leaves the previous display intact on cancel.
        // Restore its conditions as well, including case-sensitive matching.
        TBookColumnFilters.ForTree(Tree).RestoreApplied;
        VisibleCount:=TBookColumnFilters.ForTree(Tree).Apply;
        Total:=TBookColumnFilters.ForTree(Tree).Total;
      end;
    end;
    SetBookListTotals(Tree,VisibleCount,Total);
  finally
    FBookListCancel.Visible:=False; ShowStatusProgress:=False;
    Screen.Cursor:=SavedCursor; FBookListLoading:=False; Dec(FBookInfoUpdateCount);
  end;
  RefreshBookInfo(Tree);
  if FBookListCancelled then StatusMessage:='Фильтрация отменена; сохранён предыдущий результат';
end;

procedure TfrmMain.ShowBookColumnFilters(Sender: TObject);
var Tree: TBookTree;
begin
  if FFormBusy or (ActiveView = DownloadView) then Exit;
  GetActiveTree(Tree);
  if (Sender is TMenuItem) and (TMenuItem(Sender).Tag = 1) then
    TBookColumnFilters.ForTree(Tree).Clear
  else if not EditBookColumnFilters(Tree) then Exit;
  ApplyBookColumnFilters(Tree);
end;

procedure TfrmMain.HeaderPopupItemClick(Sender: TObject);
var
  i, J: Integer;
  Tree: TBookTree;
  Tag: Integer;
  Column: TVirtualTreeColumn;

  S: string;
  MinWidth, MaxWidth: Integer;
  Options: TVTColumnOptions;
  Alignment: TAlignment;
  Keys, Kept: TArray<TBookSortKey>; Key: TBookSortKey;

begin
  GetActiveTree(Tree);

  Tag := (Sender as TMenuItem).Tag;

  if (Sender as TMenuItem).Checked then
  begin
    for i := 0 to Tree.Header.Columns.Count - 1 do
      if Tree.Header.Columns[i].Tag = Tag then
      begin
        Keys := Tree.SortKeys; Kept := nil;
        for Key in Keys do if Key.Tag <> Tag then
        begin SetLength(Kept,Length(Kept)+1); Kept[High(Kept)] := Key; end;
        Tree.SortKeys := Kept;
        if Length(Keys)>0 then Tree.Header.SortColumn := NoColumn;
        Tree.Header.Columns.Delete(i);
        if Length(Kept)>0 then
          for J := 0 to Tree.Header.Columns.Count-1 do
            if Tree.Header.Columns[J].Tag = Kept[0].Tag then
            begin Tree.Header.SortColumn := J; Tree.Header.SortDirection := Kept[0].Direction; end;
        FSortSettings[Tree.Tag].Column := Tree.Header.SortColumn;
        FSortSettings[Tree.Tag].Direction := Tree.Header.SortDirection;
        (Sender as TMenuItem).Checked := False;
        Break;
      end;
  end
  else
  begin
    Column := TVirtualTreeColumn.Create(Tree.Header.Columns);

    GetDefaultColumnProperties(Settings.TreeModes[Tree.Tag], Tag, S, MinWidth, MaxWidth, Alignment, Options);
    Column.Tag := Tag;
    Column.Text := S;
    Column.MinWidth := MinWidth;
    Column.MaxWidth := MaxWidth;
    Column.Alignment := Alignment;
    Column.Options := Options;
    (Sender as TMenuItem).Checked := True;
  end;

  SaveColumns;
end;

function TfrmMain.OnHelpHandler(Command: Word; Data: NativeInt; var CallHelp: Boolean): Boolean;
begin
  ShowHelpTopic(Integer(Data));

  CallHelp := False;
  Result := True;
end;

procedure TfrmMain.ShowCollectionSettingsExecute(Sender: TObject);
var
  frmBases: TfrmBases;
begin
  Assert(Assigned(FCollection));
  frmBases := TfrmBases.Create(Application);
  try
    frmBases.SetCollection(FSystemData, FCollection);
    if frmBases.ShowModal = mrOk then
    begin
      Assert(Settings.ActiveCollection = FCollection.CollectionID);
      // Refresh the collection cache (so that each book picks up the altered root path):
      FCollection := FSystemData.GetCollection(Settings.ActiveCollection, True);

      InitCollection;
    end;
  finally
    frmBases.Free;
  end;
end;

procedure TfrmMain.MarkAsReadedExecute(Sender: TObject);
begin
  Assert(Assigned(FCollection));

  ProcessNodes(
    procedure (Tree: TBookTree; Node: PVirtualNode)
    var
      Data: PBookRecord; Changed: TBookRecord;
      NewProgress: Integer;
    begin
      Data := Tree.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType = ntBookInfo) then
      begin
        // Переключатель по признаку «прочитано полностью»: книга с любым
        // промежуточным прогрессом становится прочитанной (100%), уже прочитанная —
        // непрочитанной (0%). Таким образом, текущий прогресс чтения не теряется.
        NewProgress := IfThen(Data^.Progress = 100, 0, 100);
        if Tree = tvBooksF then
        begin
          Changed := Data^; Changed.Progress := NewProgress;
          if TryStoreReaderBookPersonal(FSystemData.GetCollection(Data^.BookKey.DatabaseID), FSystemData,
            Changed, [bpfProgress]) <> rpwRejected then
          begin Data^.Progress := NewProgress; Tree.InvalidateNode(Node); end
          else MHLShowInfo('Не удалось подтвердить личную карточку книги. Прогресс не изменён.');
          Exit;
        end;

        FCollection.SetProgress(Data^.BookKey, NewProgress);
        UpdateNodes(
          Data^.BookKey,
          procedure(BookData: PBookRecord)
          begin
            Assert(Assigned(BookData));
            BookData^.Progress := NewProgress;
          end
        );
      end;
    end
  );
end;

procedure TfrmMain.UpdateGenresExecute(Sender: TObject);
var
  AFileName: string;
begin
  Assert(Assigned(FCollection));
  if isFB2Collection(FCollection.CollectionCode) then
    FCollection.ReloadGenres(Settings.SystemFileName[sfGenresFB2])
  else if unit_Helpers.GetFileName(fnGenreList, AFileName) then
    FCollection.ReloadGenres(AFileName);
  InitCollection;
end;

procedure TfrmMain.RepairDataBaseExecute(Sender: TObject);
var
  CheckResult: string;
begin
  Assert(Assigned(FCollection));
  CheckResult := FCollection.CheckDatabase;
  if SameText(CheckResult, 'ok') then
    MHLShowInfo(rstrDatabaseCheckOk)
  else
    MHLShowError(Format(rstrDatabaseCheckFailed, [CheckResult]));
end;

procedure TfrmMain.ChangeSettingsExecute(Sender: TObject);
var
  frmSettings: TfrmSettings;
begin
  if Assigned(FOPDSForm) then FOPDSForm.StopServer;
  SaveMainFormSettings;

  frmSettings := TfrmSettings.Create(Application);
  try
    frmSettings.LoadSetting;
    if (Sender is TComponent) and (TComponent(Sender).Name = 'miExternalToolsSetup') then
      frmSettings.tvSections.Selected := frmSettings.tvSections.Items[5];
    frmSettings.ShowModal;

    Settings.SaveSettings;

  finally
    frmSettings.Free;
  end;
  ReadINIData;
  CreateScriptMenu;
end;

procedure TfrmMain.SetHeaderPopUp;
var
  Tree: TBookTree;
  i: Integer;
begin
  if ActiveView = DownloadView then
    Exit;

  GetActiveTree(Tree);

  for i := 0 to pmHeaders.Items.Count - 1 do
  begin
    pmHeaders.Items[i].Checked := False;
  end;

  for i := 0 to Tree.Header.Columns.Count - 1 do
  begin
    case Tree.Header.Columns[i].Tag of
      COL_AUTHOR:
        pmHeaders.Items[0].Checked := True;
      COL_TITLE:
        pmHeaders.Items[1].Checked := True;
      COL_SERIES:
        pmHeaders.Items[2].Checked := True;
      COL_NO:
        pmHeaders.Items[3].Checked := True;
      COL_GENRE:
        pmHeaders.Items[4].Checked := True;
      COL_SIZE:
        pmHeaders.Items[5].Checked := True;
      COL_RATE:
        pmHeaders.Items[6].Checked := True;
      COL_DATE:
        pmHeaders.Items[7].Checked := True;
      COL_TYPE:
        pmHeaders.Items[8].Checked := True;
      COL_COLLECTION:
        pmHeaders.Items[9].Checked := True;
      COL_LANG:
        pmHeaders.Items[10].Checked := True;
      COL_LIBRATE:
        pmHeaders.Items[11].Checked := True;
      COL_LIBID:
        pmHeaders.Items[12].Checked := True;
    end;
  end;
  for i := 0 to pmHeaders.Items.Count-1 do
    if pmHeaders.Items[i].Tag in [COL_PUBLISHER_SERIES, COL_PUBLISHER,
      COL_TRANSLATORS, COL_CITY, COL_PUBYEAR, COL_ISBN] then
      for var J := 0 to Tree.Header.Columns.Count-1 do
        if Tree.Header.Columns[J].Tag = pmHeaders.Items[i].Tag then pmHeaders.Items[i].Checked := True;
  pmHeaders.Items[9].Visible := True;
end;

procedure TfrmMain.pgControlChange(Sender: TObject);
var
  ToolBuutonVisible: Boolean;
begin
  UpdateActions;

  FLastFoundBook := nil;
  FFirstFoundBook := nil;

  EnsureActiveBookViewLoaded;

  ToolBuutonVisible := (ActiveView <> DownloadView);

  BtnFav_add.Enabled := ToolBuutonVisible;
  tbSelectAll.Enabled := ToolBuutonVisible;
  tbCollapse.Enabled := ToolBuutonVisible;
  tbtnRead.Enabled := ToolBuutonVisible;

  tbSendToDevice.Enabled := ToolBuutonVisible;
  btnSwitchTreeMode.Enabled := not (ActiveView in [SeriesView, PublisherSeriesView, DownloadView]);
  miGoToAuthor.Visible := ActiveView in [SeriesView, PublisherSeriesView, GenresView, SearchView, FavoritesView];

  case ActiveView of
    FavoritesView:
      begin
        miDelFavorites.Visible := True;
        miAddFavorites.Visible := False;
        BtnFav_add.Hint := rstrRemoveFromGroup;
        BtnFav_add.DropdownMenu := nil;
        BtnFav_add.ImageIndex := 16;
        pmiGroups.Visible := False;
        miAddToGroup.Visible := False;
        miAdd2Favorites.Visible := False;
        miRemoveFromGroup.Visible := True;
      end;
    DownloadView:
      begin
        tbtnDownloadList_Add.ImageIndex := 23;
        tbtnDownloadList_Add.Hint := rstrRemoveFromDownloadList;
        btnSwitchTreeMode.Enabled := False;
        Exit;
      end;
  else
    begin
      miDelFavorites.Visible := False;
      miAddFavorites.Visible := True;
      BtnFav_add.Hint := rstrAddToFavorites;
      BtnFav_add.DropdownMenu := pmGroups;
      BtnFav_add.ImageIndex := 15;
      pmiGroups.Visible := True;
      miAddToGroup.Visible := True;
      miAdd2Favorites.Visible := True;
      miRemoveFromGroup.Visible := False;
    end;

  end;

  tbtnDownloadList_Add.ImageIndex := 2;
  tbtnDownloadList_Add.Hint := rstrAddToDownloads;


  SetHeaderPopUp;

  // The tab being shown was filled while another one was active, so its panel
  // has never been filled for the book it has focused.
  RefreshActiveBookInfo;


  Settings.ActivePage := Ord(ActiveView);
end;


procedure TfrmMain.ShowHelpExecute(Sender: TObject);
begin
  ShowHelpTopic(1);
end;

procedure TfrmMain.ImportNonFB2Execute(Sender: TObject);
var
  frmAddBooks: TfrmAddnonfb2;
begin
  Assert(Assigned(FCollection));
  frmAddBooks := TfrmAddnonfb2.Create(Application);
  try
    frmAddBooks.Collection := FCollection;
    frmAddBooks.ShowModal;
    CheckFavoriteCollection;
    InitCollection;
  finally
    frmAddBooks.Free;
  end;
end;

procedure TfrmMain.ImportNonFB2Update(Sender: TObject);
var
  Action: TAction;
begin
  Assert(Sender is TAction);

  Action := Sender as TAction;
  Action.Visible := IsPrivate and IsNonFB2;
  Action.Enabled := Action.Visible;
end;

procedure TfrmMain.OnChangeLocalStatus(var Message: TLocalStatusChangedMessage);
var Collection: IBookCollection; Current, Personal: TBookRecord; Namespace: string;
begin
  Assert(Assigned(Message.Params));
  try
    // A posted completion can outlive a catalog replacement. Refresh from
    // current, proven records instead of applying the old key-only Boolean.
    Collection := nil; Current := Default(TBookRecord); Personal := Default(TBookRecord); Namespace := '';
    try
      Collection := FSystemData.GetCollection(Message.Params^.BookKey.DatabaseID);
      Collection.GetBookRecord(Message.Params^.BookKey, Current, False);
      Namespace := VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
    except Current := Default(TBookRecord); end;
    try FSystemData.GetBookRecord(Message.Params^.BookKey, Personal);
    except Personal := Default(TBookRecord); end;
    UpdateNodes(Message.Params^.BookKey,
      procedure(BookData: PBookRecord)
      var IsLocal: Boolean;
      begin
        if not Assigned(BookData) then Exit;
        if Current.BookKey.IsSameAs(BookData^.BookKey) and
          ReaderBookMatchesExpectedIdentity(BookData^.LibID, ReaderBookPhysicalIdentity(BookData^), Current, Namespace) then
          IsLocal := bpIsLocal in Current.BookProps
        else if Personal.BookKey.IsSameAs(BookData^.BookKey) and
          ReaderBookMatchesExpectedIdentity(BookData^.LibID, ReaderBookPhysicalIdentity(BookData^), Personal, Namespace) then
          IsLocal := bpIsLocal in Personal.BookProps
        else Exit;
        if IsLocal then Include(BookData^.BookProps, bpIsLocal)
        else Exclude(BookData^.BookProps, bpIsLocal);
      end);
  finally Dispose(Message.Params); end;
  Message.Result := 0;
end;

procedure TfrmMain.SetBookLocalStatus(const BookKey: TBookKey; IsLocal: Boolean);
begin
  UpdateNodes(
    BookKey,
    procedure(BookData: PBookRecord)
    begin
      Assert(Assigned(BookData));
      if IsLocal then
        Include(BookData^.BookProps, bpIsLocal)
      else
        Exclude(BookData^.BookProps, bpIsLocal);
    end
  );
end;

procedure TfrmMain.ImportUserDataExecute(Sender: TObject);
var
  FileName: string;
  Data: TUserData;
  SavedCursor: TCursor;
begin
  if not GetFileName(fnOpenUserData, FileName) then
    Exit;


  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    Data := TUserData.Create;
    try
      if SameText(ExtractFileExt(FileName), '.mhlud') then
      begin
        Screen.Cursor := SavedCursor;
        if not ShowLegacyUserDataImportPreview(FileName, Data, FSystemData, Self) then Exit;
        Screen.Cursor := crHourGlass;
      end
      else
        Data.Load(FileName);
      OnImportUserDataHandler(Data);
    finally
      Data.Free;
    end;
  finally
    Screen.Cursor := SavedCursor;
  end;
end;



procedure TfrmMain.OnImportUserDataHandler(const UserDataSource: TUserData);
var
  SavedCursor: TCursor;
begin
  Assert(Assigned(FCollection));
  SavedCursor := Screen.Cursor;
  Screen.Cursor := crHourGlass;
  try
    FCollection.ImportUserData(
      UserDataSource,
      procedure(const BookKey: TBookKey; extra: TBookExtra)
      begin
        // На всех страницах (кроме "Группы") необходимо обновить список книг,
        // т к могли поменяться пользовательские данные
        UpdateNodes(
          BookKey,
          procedure(BookData: PBookRecord)
          begin
            Assert(Assigned(BookData));
            if extra.Rating <> 0 then
              BookData^.Rate := extra.Rating;
            if extra.Progress <> 0 then
              BookData^.Progress := extra.Progress;
            if extra.Review <> '' then
              Include(BookData^.BookProps, bpHasReview);
          end
        );
      end
    );

    CreateGroupsMenu;

    if Length(UserDataSource.FavoriteAuthors)>0 then
    begin
      StopFavoriteRefresh(True);
      FavoriteStore.ImportFavorites(UserDataSource.FavoriteAuthors);
      PublishFavoriteFilterKeys;
      FOnlyNewFavoriteBooks:=False;
      Include(FStaleSelectors,AuthorsView);
      Exclude(FLoadedBookViews,AuthorsView);
      CheckFavoriteCollection;
      tvAuthors.Invalidate;
      UpdateFavoriteControls;
    end;

    // Обновим список групп. Побочным эффектом будет перечитывание списка книг на странице "Группы"
    FillGroupsList(tvGroups, FSystemData.GetGroupIterator, FLastGroupID);
  finally
    Screen.Cursor := SavedCursor;
  end;
end;

procedure TfrmMain.Export2INPXExecute(Sender: TObject);
var
  FileName: string;
begin
  Assert(Assigned(FCollection));
  if not GetFileName(fnSaveINPX, FileName) then
    Exit;

  unit_Export.Export2INPX(FCollection.CollectionID, FileName);
end;

procedure TfrmMain.cbLangSelectAChange(Sender: TObject);
var
  filterValue: TFilterValue;
begin
  if not ((Sender as TComboBox).Tag in [Ord(AuthorsView), Ord(SeriesView),
    Ord(GenresView), Ord(FavoritesView), Ord(PublisherSeriesView)]) then Exit;
  FViewLanguageSelected[TView((Sender as TComboBox).Tag)] := True;
  case (Sender as TComboBox).Tag of
    0:begin
        FillCurrentAuthorBooks; // авторы
       end;


    1: begin
         FilterValue := SeriesBookFilter;
         FillBooksTree(tvBooksS, cbLangSelectS,
        function: IBookIterator begin Result := FCollection.GetBookIterator(bmBySeries, False, @FilterValue); end, False, False, @FLastSeriesBookID); // серии
       end;
    2: begin
         FillCurrentGenreBooks; // жанры
       end;
    4: FillBooksTree(tvBooksF, cbLangSelectF,
        function: IBookIterator begin Result := FSystemData.GetBookIterator(FLastGroupID); end, True, True, @FLastGroupBookID);  // избранное
    PAGE_PUBLISHER_SERIES:
      PublisherSeriesChange(FPublisher.SeriesTree, FPublisher.SeriesTree.GetFirstSelected);
  end;
end;

procedure TfrmMain.cbPresetNameSelect(Sender: TObject);
var
  preset: TSearchPreset;
  Value: string;
  PresetIndex: Integer;
begin
  PresetIndex := SearchPresetIndex(cbPresetName.Text);
  if (PresetIndex < 0) or not Assigned(FPresets) then Exit;
  DoClearFilter(True);
  cbPresetName.ItemIndex := PresetIndex;
  preset := FPresets.GetPreset(cbPresetName.Items[PresetIndex]);
  FSearchMode.LoadPreset(preset);

  if preset.TryGetValue(SF_AUTHORS, Value) then edFFullName.Text := Value;
  if preset.TryGetValue(SF_FAVORITE_AUTHORS, Value) then
    FSearchFavoriteCheck.Checked := StrToBoolDef(Value, False);
  if preset.TryGetValue(SF_TITLE, Value) then edFTitle.Text := Value;
  if preset.TryGetValue(SF_SERIES, Value) then edFSeries.Text := Value;
  if preset.TryGetValue(SF_PUBLISHER, Value) then FPublisherSearchEdit.Text := Value;
  if preset.TryGetValue(SF_TRANSLATORS,Value) then FTranslatorSearchEdit.Text:=Value;
  if preset.TryGetValue(SF_CITY,Value) then FCitySearchEdit.Text:=Value;
  if preset.TryGetValue(SF_PUBYEAR,Value) then FPubYearSearchEdit.Text:=Value;
  if preset.TryGetValue(SF_ISBN,Value) then FISBNSearchEdit.Text:=Value;
  if preset.TryGetValue(SF_WITH_NOTES,Value) then FNotesOnlySearchCheck.Checked:=StrToBoolDef(Value,False);
  if preset.TryGetValue(SF_GENRE_TITLE, Value) then edFGenre.Text := Value;
  if preset.TryGetValue(SF_GENRE_CODES, Value) then edFGenre.Hint := Value;
  if preset.TryGetValue(SF_ANNOTATION, Value) then edFAnnotation.Text := Value;

  if preset.TryGetValue(SF_FILE, Value) then edFFile.Text := Value;
  if preset.TryGetValue(SF_FOLDER, Value) then edFFolder.Text := Value;
  if preset.TryGetValue(SF_EXTENSION, Value) then edFExt.Text := Value;

  if preset.TryGetValue(SF_DOWNLOADED, Value) then
    cbDownloaded.ItemIndex := EnsureRange(StrToIntDef(Value, 0), 0, cbDownloaded.Items.Count - 1);
  if preset.TryGetValue(SF_KEYWORDS, Value) then edFKeyWords.Text := Value;
  if preset.TryGetValue(SF_DELETED, Value) then
    SetHideDeletedMode(StrToBoolDef(Value, False), False);

  if preset.TryGetValue(SF_DATE, Value) then
  begin
    cbDate.ItemIndex := EnsureRange(StrToIntDef(Value, -1), -1, cbDate.Items.Count - 1);
    if cbDate.ItemIndex = -1 then
     if preset.TryGetValue(SF_DATE_STR, Value) then cbDate.Text := Value;
  end;

  if preset.TryGetValue(SF_LIBRATE, Value) then
  begin
    cbLibRate.ItemIndex := EnsureRange(StrToIntDef(Value, -1), -1, cbLibRate.Items.Count - 1);
    if cbLibRate.ItemIndex = -1 then
     if preset.TryGetValue(SF_LIBRATE_STR, Value) then cbLibRate.Text := Value;
  end;

  if preset.TryGetValue(SF_LANG, Value) then
    cbLang.ItemIndex := EnsureRange(StrToIntDef(Value, -1), -1, cbLang.Items.Count - 1);
  if preset.TryGetValue(SF_READED, Value) then cbReaded.Checked := StrToBoolDef(Value, False);

end;

procedure TfrmMain.btnStartDownloadClick(Sender: TObject);
begin
  if tvDownloadList.GetFirst = nil then
    Exit;

  btnPauseDownload.Enabled := True;
  btnStartDownload.Enabled := False;

  // Предыдущий менеджер уже остановлен (кнопка "Пауза" или пустая очередь),
  // но сам объект оставался живым. Освобождаем его перед запуском нового.
  if Assigned(FDMThread) then
  begin
    FDMThread.TerminateNow;
    FDMThread.WaitFor;
    FreeAndNil(FDMThread);
  end;

  FDMThread := TDownloadManagerThread.Create(Self);
  // Start after construction: the RTL also processes suspension there.
  FDMThread.Start;
end;

procedure TfrmMain.btnPauseDownloadClick(Sender: TObject);
begin
  btnPauseDownload.Enabled := False;
  btnStartDownload.Enabled := True;
  if Assigned(FDMThread) then
    FDMThread.Stop;
end;

procedure TfrmMain.BtnSaveClick(Sender: TObject);
begin
  try SaveDownloadsList;
  except
    on E: Exception do MHLShowError('Не удалось сохранить очередь загрузок. Предыдущий файл сохранён.' +
      sLineBreak + E.Message);
  end;
end;

procedure TfrmMain.btnDeleteDownloadClick(Sender: TObject);
var
  Data: PDownloadData;
  i: Integer;
  List: TSelectionList;
begin
  GetSelections(tvDownloadList, List);
  for i := 0 to tvDownloadList.SelectedCount - 1 do
  begin
    Data := tvDownloadList.GetNodeData(List[i]);
    if Data.State <> dsRun then
    begin
      if List[i] = FDownloadNode then
        FDownloadNode := nil;
      tvDownloadList.DeleteNode(List[i]);
    end;
  end;
  UpdateDownloadCount;
end;

// Реализация для потока загрузок. Вызывается исключительно из главного потока.

procedure TfrmMain.UpdateDownloadCount;
begin
  lblDownloadCount.Caption := Format('(%d)', [tvDownloadList.ChildCount[nil]]);
end;

// Следующая книга очереди: двигаемся от текущего узла, а достигнув конца -
// возвращаемся к началу и пропускаем ошибочные. Если ошибочными оказались
// все, очередь начинается заново - ошибки загружаются повторно.
function TfrmMain.SelectNextDownload(out Item: TDownloadItem): Boolean;
var
  Data: PDownloadData;
  ErrorCount: Integer;
begin
  Result := False;
  Item := Default(TDownloadItem);

  if Assigned(FDownloadNode) then
    FDownloadNode := tvDownloadList.GetNext(FDownloadNode);

  if not Assigned(FDownloadNode) then
  begin
    ErrorCount := 0;
    FDownloadNode := tvDownloadList.GetFirst;
    Data := tvDownloadList.GetNodeData(FDownloadNode);
    while Assigned(Data) and Assigned(FDownloadNode) and (Data^.State = dsError) do
    begin
      FDownloadNode := tvDownloadList.GetNext(FDownloadNode);
      Data := tvDownloadList.GetNodeData(FDownloadNode);
      Inc(ErrorCount);
    end;

    if (ErrorCount > 0) and not Assigned(FDownloadNode) then
      FDownloadNode := tvDownloadList.GetFirst;
  end;

  while Assigned(FDownloadNode) do
  begin
    Data := tvDownloadList.GetNodeData(FDownloadNode);
    if not Assigned(Data) then
      Break;

    if Data^.State <> dsOk then
    begin
      Data^.State := dsRun;
      tvDownloadList.RepaintNode(FDownloadNode);

      Item.BookKey := Data^.BookKey;
      Item.Author := Data^.Author;
      Item.Title := Data^.Title;
      Item.Expected.BookKey := Data^.BookKey;
      Item.Expected.HasExpectedIdentity := True;
      if Data^.HasExpectedIdentity then
      begin
        Item.Expected.ExpectedLibID := Data^.ExpectedLibID;
        Item.Expected.ExpectedPhysicalIdentity := Data^.ExpectedPhysicalIdentity;
      end
      else
      begin
        // Old persisted queues know only their original whole-file path.
        // No library or archive member is guessed from an old positive key.
        Item.Expected.ExpectedLibID := '';
        try
          if Data^.FileName <> '' then
            Item.Expected.ExpectedPhysicalIdentity := TPath.GetFullPath(Data^.FileName).Replace('/', '\');
        except Item.Expected.ExpectedPhysicalIdentity := ''; end;
      end;
      Exit(True);
    end;

    FDownloadNode := tvDownloadList.GetNext(FDownloadNode);
  end;
end;

procedure TfrmMain.CompleteCurrentDownload(Success: Boolean);
var
  Data: PDownloadData;
  Node: PVirtualNode;
begin
  if not Assigned(FDownloadNode) then
    Exit;

  Data := tvDownloadList.GetNodeData(FDownloadNode);
  if not Assigned(Data) then
    Exit;

  if Success then
  begin
    Data^.State := dsOk;

    // Узел мог исчезнуть из дерева, пока книга загружалась (например, вместе с
    // удаленной коллекцией), поэтому сначала убеждаемся, что он еще на месте.
    Node := tvDownloadList.GetFirst;
    while Assigned(Node) do
    begin
      if Node = FDownloadNode then
      begin
        tvDownloadList.DeleteNode(FDownloadNode);
        Break;
      end;
      Node := tvDownloadList.GetNext(Node);
    end;

    FDownloadNode := nil;
  end
  else
  begin
    Data^.State := dsError;
    tvDownloadList.RepaintNode(FDownloadNode);
  end;

  UpdateDownloadCount;
end;

procedure TfrmMain.CancelCurrentDownload;
var
  Data: PDownloadData;
begin
  if not Assigned(FDownloadNode) then
    Exit;

  Data := tvDownloadList.GetNodeData(FDownloadNode);
  if not Assigned(Data) then
    Exit;

  Data^.State := dsError;
  tvDownloadList.RepaintNode(FDownloadNode);
end;

function TfrmMain.IsMainFormVisible: Boolean;
begin
  Result := Visible;
end;

procedure TfrmMain.ShowDownloadInfo(const Author, Title: string);
begin
  lblDnldAuthor.Caption := Author;
  lblDnldTitle.Caption := Title;
  pbDownloadProgress.Visible := True;
end;

procedure TfrmMain.ShowDownloadState(const State: string);
begin
  lblDownloadState.Caption := State;
end;

procedure TfrmMain.ShowDownloadProgress(Position: Integer);
begin
  pbDownloadProgress.Position := Position;
end;

procedure TfrmMain.ResetDownloadState;
begin
  pbDownloadProgress.Position := 0;
  pbDownloadProgress.Visible := False;
  lblDownloadState.Caption := rstrDownloadDone;
  lblDnldAuthor.Caption := '';
  lblDnldTitle.Caption := '';
end;

procedure TfrmMain.SetTrayHint(const Hint: string);
begin
  TrayIcon.Hint := Hint;
end;

procedure TfrmMain.SetDownloadRunning(Running: Boolean);
begin
  btnPauseDownload.Enabled := Running;
  btnStartDownload.Enabled := not Running;
end;

procedure TfrmMain.SetQueueControlsEnabled(Enabled: Boolean);
begin
  BtnFirstRecord.Enabled := Enabled;
  BtnDwnldUp.Enabled := Enabled;
  BtnDwnldDown.Enabled := Enabled;
  BtnLastRecord.Enabled := Enabled;
  BtnSave.Enabled := Enabled and FDownloadsReady and not FDownloadsLoadFailed;
  mi_dwnl_Delete.Enabled := Enabled;
end;

function TfrmMain.AskIgnoreDownloadErrors: Integer;
begin
  Result := Application.MessageBox(PWideChar(rstrIgnoreDownloadErrors), '', MB_YESNOCANCEL);
end;

procedure TfrmMain.DeleteSearchPreset(Sender: TObject);
var
  presetName: string;
  PresetIndex: Integer;
  ExistingPreset, CopiedPreset: TSearchPreset;
  Candidate, Previous: TSearchPresets;
  Field: TPair<string, string>;
begin
  presetName := Trim(cbPresetName.Text);
  PresetIndex := SearchPresetIndex(presetName);
  if (PresetIndex < 0) or not Assigned(FPresets) then
    Exit;
  presetName := cbPresetName.Items[PresetIndex];

  Candidate := TSearchPresets.Create;
  try
    for ExistingPreset in FPresets do
      if ExistingPreset.DisplayName <> presetName then
      begin
        CopiedPreset := Candidate.GetPreset(ExistingPreset.DisplayName);
        for Field in ExistingPreset do
          CopiedPreset.AddOrSetValue(Field.Key, Field.Value);
      end;
    try
      Candidate.Save(Settings.SystemFileName[sfPresets]);
    except
      on E: Exception do
        raise EInOutError.Create('Не удалось удалить пресет. Пресет сохранён. ' + E.Message);
    end;

    Previous := FPresets;
    FPresets := Candidate;
    Candidate := nil;
    Previous.Free;
    cbPresetName.Items.Delete(PresetIndex);
    cbPresetName.ItemIndex := -1;
    cbPresetName.Text := '';
  finally
    Candidate.Free;
  end;
end;

function TfrmMain.GetBookNode(const Tree: TBookTree; const BookKey: TBookKey): PVirtualNode;
var
  Data: PBookRecord;
  Node: PVirtualNode;
begin
  Assert(Assigned(Tree));

  Result := nil;

  Node := Tree.GetFirst;
  while Assigned(Node) do
  begin
    Data := Tree.GetNodeData(Node);
    Assert(Assigned(Data));
    if (Data^.nodeType = ntBookInfo) and (Data^.BookKey.IsSameAs(BookKey)) then
    begin
      Result := Node;
      Exit;
    end;
    Node := Tree.GetNext(Node);
  end;
end;

procedure TfrmMain.ProcessNodes(ProcessProc: TNodeProcessProc);
var
  Tree: TBookTree;
  FNode: PVirtualNode;
  Node: PVirtualNode;
begin
  GetActiveTree(Tree);
  Assert(Assigned(Tree));

  FNode := Tree.FocusedNode;

  Node := Tree.GetFirstChecked;
  while Assigned(Node) do
  begin
    if Node = FNode then
      FNode := nil;
    if not Tree.IsEffectivelyFiltered[Node] then ProcessProc(Tree, Node);
    Node := Tree.GetNextChecked(Node);
  end;

  if Assigned(FNode) and not Tree.IsEffectivelyFiltered[FNode] then
    ProcessProc(Tree, FNode);
end;

procedure TfrmMain.UpdateNodes(const BookKey: TBookKey; UpdateProc: TNodeUpdateProc);
type
  TTreeArray = array of TBookTree;
var
  BookTrees: TTreeArray;
  Tree: TBookTree;
  Node: PVirtualNode;
  Data: PBookRecord;
begin
  BookTrees := TTreeArray.Create(tvBooksA, tvBooksS, tvBooksG, tvBooksSR, tvBooksF, FPublisher.Books );
  for Tree in BookTrees do
  begin
    Node := GetBookNode(Tree, BookKey);
    if Assigned(Node) then
    begin
      Data := Tree.GetNodeData(Node);
      Assert(Assigned(Data));
      if Assigned(Data) then
      begin
        UpdateProc(Data);
        Tree.RepaintNode(Node);
      end;
    end;
  end;
end;

function TfrmMain.IsSelectedBookNode(Node: PVirtualNode; Data: PBookRecord): Boolean;
begin
  if Assigned(Node) and (vsFiltered in Node.States) then Exit(False);
  if Settings.SelectedIsChecked then
     Result :=
        Assigned(Node) and Assigned(Data) and
       (Data^.nodeType = ntBookInfo) and
       ((Node^.CheckState = csCheckedNormal) or (vsSelected in Node.States))
  else
    Result :=
      Assigned(Node) and Assigned(Data) and
     (Data^.nodeType = ntBookInfo) and ((Node^.CheckState = csCheckedNormal));
end;

procedure TfrmMain.OnGetBookHandler(var BookRecord: TBookRecord);
var
  Tree: TBookTree;
  Node: PVirtualNode;
  Data: PBookRecord;
  BookCollection: IBookCollection;
begin
  GetActiveTree(Tree);
  Node := Tree.GetFirstSelected;
  Data := Tree.GetNodeData(Node);

  Assert(Assigned(Data) and (Data^.nodeType = ntBookInfo));
  Assert(Assigned(FCollection));

  if (Data^.BookKey.DatabaseID <> FCollection.CollectionID) then
    BookCollection := FSystemData.GetCollection(Data^.BookKey.DatabaseID)
  else
    BookCollection := FCollection;

  BookCollection.GetBookRecord(Data^.BookKey, BookRecord, True);
end;

procedure TfrmMain.OnUpdateBookHandler;
var
  BookCollection: IBookCollection;
begin
  Assert(BookRecord.nodeType = ntBookInfo);

  Assert(Assigned(FCollection));
  if (BookRecord.BookKey.DatabaseID <> FCollection.CollectionID) then
    BookCollection := FSystemData.GetCollection(BookRecord.BookKey.DatabaseID)
  else
    BookCollection := FCollection;

  BookCollection.BeginBulkOperation;
  try
    BookCollection.UpdateBook(BookRecord);
    BookCollection.EndBulkOperation(True);
  except
    BookCollection.EndBulkOperation(False);
  end;

end;

// A raw file just became a zip archive (FBD + raw)
procedure TfrmMain.OnChangeBook2ZipHandler;
var
  NewFileName: string;
  BookCollection: IBookCollection;
begin
  Assert(Assigned(FCollection));
  if (BookRecord.BookKey.DatabaseID <> FCollection.CollectionID) then
    BookCollection := FSystemData.GetCollection(BookRecord.BookKey.DatabaseID)
  else
    BookCollection := FCollection;

  Assert(BookRecord.nodeType = ntBookInfo);

  NewFileName := BookRecord.FileName + ZIP_EXTENSION;
  BookCollection.SetFileName(BookRecord.BookKey, NewFileName);
  UpdateNodes(
    BookRecord.BookKey,
    procedure(BookData: PBookRecord)
    begin
      Assert(Assigned(BookData));
      BookData^.FileName := NewFileName;
    end
  );
end;

function TfrmMain.AuthorBookFilter: TFilterValue;
begin
  Result.ValueInt := FLastAuthorID;
end;

function TfrmMain.SeriesBookFilter: TFilterValue;
begin
  Result.ValueInt := FLastSeriesID;
end;

function TfrmMain.GenreBookFilter: TFilterValue;
begin
  Assert(Assigned(FCollection));
  if FLastGenreIsTopLevelContainer or
    isFB2Collection(FCollection.CollectionCode) or
    (not Settings.ShowSubGenreBooks) then
    Result.ValueString := FLastGenreCode
  else
    Result.ValueString := FLastGenreCode + IfThen(FLastGenreIsContainer, '.', '');
end;

procedure TfrmMain.FillCurrentGenreBooks;
var
  FilterValue: TFilterValue;
  Mode: TBookIteratorMode;
begin
  btnShowGenreBooks.Visible := FLastGenreIsTopLevelContainer;

  if not Assigned(FCollection) or (FLastGenreCode = '') or
    (FLastGenreIsTopLevelContainer and not FRootGenreBooksRequested) then
  begin
    lblBooksTotalG.Caption := '(0)';
    ipnlGenres.Clear;
    tvBooksG.Clear;
    Exit;
  end;

  FilterValue := GenreBookFilter;
  if FLastGenreIsTopLevelContainer then
    Mode := bmByGenreRecursive
  else
    Mode := bmByGenre;

  FillBooksTree(tvBooksG, cbLangSelectG,
        function: IBookIterator begin Result := FCollection.GetBookIterator(Mode, False, @FilterValue); end, True, True, @FLastGenreBookID);
end;

end.
