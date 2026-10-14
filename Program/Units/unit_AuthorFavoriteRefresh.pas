unit unit_AuthorFavoriteRefresh;

interface

uses
  Winapi.Windows, Winapi.Messages, System.Classes, System.SysUtils, System.SyncObjs, unit_AuthorFavorites;

const
  WM_AUTHOR_FAVORITES_READY = WM_APP + 481;
  WM_AUTHOR_FAVORITES_PROGRESS = WM_APP + 482;
  WM_AUTHOR_FAVORITES_LAYOUT = WM_APP + 483;

type
  // Owns no UI or live collection object. Completion messages identify both
  // the worker and its generation; the UI retains ownership until completion.
  TAuthorFavoriteRefreshThread = class(TThread)
  private
    FWindow: HWND;
    FGeneration: Cardinal;
    FProfileFile: string;
    FCollection: TAuthorFavoriteCollection;
    FSucceeded: Boolean;
    FErrorMessage: string;
    FAuthorsDone, FAuthorsTotal, FBooksRead: Integer;
    FLastProgress: UInt64;
  protected
    procedure Execute; override;
  public
    constructor Create(Window: HWND; Generation: Cardinal; const ProfileFile: string;
      const Collection: TAuthorFavoriteCollection);
    property Generation: Cardinal read FGeneration;
    property Collection: TAuthorFavoriteCollection read FCollection;
    property Succeeded: Boolean read FSucceeded;
    property ErrorMessage: string read FErrorMessage;
    function AuthorsDone: Integer;
    function AuthorsTotal: Integer;
    function BooksRead: Integer;
  end;

implementation

constructor TAuthorFavoriteRefreshThread.Create(Window: HWND; Generation: Cardinal;
  const ProfileFile: string; const Collection: TAuthorFavoriteCollection);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWindow := Window;
  FGeneration := Generation;
  FProfileFile := ProfileFile;
  FCollection := Collection;
end;

function TAuthorFavoriteRefreshThread.AuthorsDone: Integer;
begin Result := TInterlocked.CompareExchange(FAuthorsDone, 0, 0); end;
function TAuthorFavoriteRefreshThread.AuthorsTotal: Integer;
begin Result := TInterlocked.CompareExchange(FAuthorsTotal, 0, 0); end;
function TAuthorFavoriteRefreshThread.BooksRead: Integer;
begin Result := TInterlocked.CompareExchange(FBooksRead, 0, 0); end;

procedure TAuthorFavoriteRefreshThread.Execute;
var Store: TAuthorFavorites;
begin
  Store := nil;
  try
    try
      if Terminated then Exit;
      Store := TAuthorFavorites.Create(FProfileFile);
      Store.RefreshCollection(FCollection,
        function: Boolean begin Result := Terminated; end,
        procedure(Done, Total, Books: Integer)
        begin
          TInterlocked.Exchange(FAuthorsDone, Done);
          TInterlocked.Exchange(FAuthorsTotal, Total);
          TInterlocked.Exchange(FBooksRead, Books);
          if GetTickCount64 - FLastProgress >= 100 then
          begin
            FLastProgress := GetTickCount64;
            PostMessage(FWindow, WM_AUTHOR_FAVORITES_PROGRESS, WPARAM(NativeUInt(Self)), LPARAM(FGeneration));
          end;
        end);
      FSucceeded := not Terminated;
    except
      on E: EAuthorFavoritesCanceled do FErrorMessage := '';
      on E: Exception do FErrorMessage := E.Message;
    end;
  finally
    Store.Free;
    PostMessage(FWindow, WM_AUTHOR_FAVORITES_READY, WPARAM(NativeUInt(Self)), LPARAM(FGeneration));
  end;
end;

end.
