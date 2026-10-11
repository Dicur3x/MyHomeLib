(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors             Nick Rymanov     nrymanov@gmail.com
  * Created             20.08.2008
  * Description
  *
  * $Id: unit_NCWParams.pas 1104 2012-01-27 04:43:24Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_NCWParams;

interface

uses unit_globals;

type
  TNCWOperation = (
    otNew,
    otExisting,
    otInpx,
    otInpxDownload,
    otMetabib
  );

  TNCWCollectionType = (
    ltUser,             // тип книг задаёт FileTypes
    ltUserFB,
    ltUserAny,
    ltExternalLocalFB,
    ltExternalOnlineFB,
    ltExternalLocalAny,
    ltExternalOnlineAny
  );

  TNCWFileTypes = (
    ftFB2,
    ftAny
  );

  PNCWParams = ^TNCWParams;
  TNCWParams = record
    Operation: TNCWOperation;
    CollectionType: TNCWCollectionType;
    FileTypes: TNCWFileTypes;
    DefaultGenres: Boolean;
    GenreFile: string;

    DisplayName: string;
    CollectionFile: string;
    CollectionRoot: string;

    INPXFile: string;

    AutoImport: boolean;

    INPXUrl: string;

    CollectionCode: COLLECTION_TYPE;

    CollectionID: Integer;
  end;

implementation

end.

