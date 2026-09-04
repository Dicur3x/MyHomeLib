-------------------------------------------------------------------------------
--
-- MyHomeLib
--
-- Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
--
-- Author(s)           eg
--                     Nick Rymanov    nrymanov@gmail.com
-- Created             04.09.2010
-- Description
--
-- $Id: CreateCollectionDB_SQLite.sql 1064 2011-09-02 11:33:04Z eg_ $
--
-- History
--
-- Notes
--   При изменении схемы базы данных необходимо изменить значение константы TBookCollection_SQLite.DATABASE_VERSION
-------------------------------------------------------------------------------

PRAGMA page_size = 16384;
PRAGMA journal_mode = OFF;
--@@

DROP TABLE IF EXISTS Series;
--@@

DROP TABLE IF EXISTS Authors;
--@@

DROP TABLE IF EXISTS Books;
--@@

DROP TABLE IF EXISTS Genre_List;
--@@

DROP TABLE IF EXISTS Author_List;
--@@

CREATE TABLE Series (
  SeriesID          INTEGER     NOT NULL                           PRIMARY KEY AUTOINCREMENT,
  SeriesTitle       VARCHAR(80) NOT NULL COLLATE MHL_SYSTEM_NOCASE UNIQUE,
  SearchSeriesTitle VARCHAR(80)          COLLATE NOCASE
);
--@@

CREATE INDEX IXSeries_Title ON Series (SeriesTitle);
--@@

CREATE INDEX IXSeries_SearchSeriesTitle ON Series (SearchSeriesTitle);
--@@

CREATE TRIGGER TRSeries_AI AFTER INSERT ON Series WHEN MHL_TRIGGERS_ON()
  BEGIN
    UPDATE Series
    SET SearchSeriesTitle = MHL_UPPER(NEW.SeriesTitle)
    WHERE SeriesID = NEW.SeriesID;
  END;
--@@

CREATE TRIGGER TRSeries_AU AFTER UPDATE ON Series WHEN MHL_TRIGGERS_ON()
  BEGIN
    UPDATE Series
    SET SearchSeriesTitle = MHL_UPPER(NEW.SeriesTitle)
    WHERE SeriesID = NEW.SeriesID;
  END;
--@@

CREATE TABLE Authors (
  AuthorID   INTEGER      NOT NULL                           PRIMARY KEY AUTOINCREMENT,
  LastName   VARCHAR(128) NOT NULL COLLATE MHL_SYSTEM_NOCASE,
  FirstName  VARCHAR(128)          COLLATE MHL_SYSTEM_NOCASE,
  MiddleName VARCHAR(128)          COLLATE MHL_SYSTEM_NOCASE,
  SearchName VARCHAR(512)          COLLATE NOCASE
);
--@@

CREATE INDEX IXAuthors_FullName ON Authors (LastName, FirstName, MiddleName);
--@@

CREATE INDEX IXAuthors_SearchName ON Authors (SearchName);
--@@

CREATE TRIGGER TRAuthors_AI AFTER INSERT ON Authors WHEN MHL_TRIGGERS_ON()
  BEGIN
    UPDATE Authors
    SET SearchName = MHL_FULLNAME(NEW.LastName, NEW.FirstName, NEW.MiddleName, 1)
    WHERE AuthorID = NEW.AuthorID ;
  END;
--@@

CREATE TRIGGER TRAuthors_AU AFTER UPDATE ON Authors WHEN MHL_TRIGGERS_ON()
  BEGIN
    UPDATE Authors
    SET SearchName = MHL_FULLNAME(NEW.LastName, NEW.FirstName, NEW.MiddleName, 1)
    WHERE AuthorID = NEW.AuthorID ;
  END;
--@@

CREATE TABLE Books (
  BookID           INTEGER       NOT NULL                           PRIMARY KEY AUTOINCREMENT,
  LibID            VARCHAR(2048) NOT NULL COLLATE MHL_SYSTEM_NOCASE,
  Title            VARCHAR(150)  NOT NULL COLLATE MHL_SYSTEM_NOCASE,
  SeriesID         INTEGER,
  SeqNumber        INTEGER,
  UpdateDate       VARCHAR(23)   NOT NULL,
  LibRate          INTEGER       NOT NULL                           DEFAULT 0,
  Lang             VARCHAR(2)            COLLATE MHL_SYSTEM_NOCASE,
  Folder           VARCHAR(200)          COLLATE MHL_SYSTEM_NOCASE,
  FileName         VARCHAR(170)  NOT NULL COLLATE MHL_SYSTEM_NOCASE,
  InsideNo         INTEGER       NOT NULL,
  Ext              VARCHAR(10)           COLLATE MHL_SYSTEM_NOCASE,
  BookSize         INTEGER,
  IsLocal          INTEGER       NOT NULL                           DEFAULT 0,
  IsDeleted        INTEGER       NOT NULL                           DEFAULT 0,
  KeyWords         VARCHAR(255)          COLLATE MHL_SYSTEM_NOCASE,
  Rate             INTEGER       NOT NULL                           DEFAULT 0,
  Progress         INTEGER       NOT NULL                           DEFAULT 0,
  Annotation       VARCHAR(4096)         COLLATE MHL_SYSTEM_NOCASE,
  Review           BLOB,
  SearchTitle      VARCHAR(150)          COLLATE NOCASE,
  SearchLang       VARCHAR(2)            COLLATE NOCASE,
  SearchFolder     VARCHAR(200)          COLLATE NOCASE,
  SearchFileName   VARCHAR(170)          COLLATE NOCASE,
  SearchExt        VARCHAR(10)           COLLATE NOCASE,
  SearchKeyWords   VARCHAR(255)          COLLATE NOCASE,
  SearchAnnotation VARCHAR(4096)         COLLATE NOCASE,
  Translators      VARCHAR(300)          COLLATE MHL_SYSTEM_NOCASE,
  Publisher        VARCHAR(200)          COLLATE MHL_SYSTEM_NOCASE,
  City             VARCHAR(100)          COLLATE MHL_SYSTEM_NOCASE,
  PubYear          INTEGER,
  ISBN             VARCHAR(50)
);
--@@

CREATE INDEX IXBooks_SeriesID_SeqNumber ON Books (SeriesID, SeqNumber);
--@@

CREATE INDEX IXBooks_SeriesID_IsDeleted_IsLocal ON Books (SeriesID, IsDeleted, IsLocal);
--@@

CREATE INDEX IXBooks_Title ON Books (Title);
--@@

CREATE INDEX IXBooks_FileName ON Books (FileName);
--@@

CREATE INDEX IXBooks_Folder ON Books (Folder);
--@@

CREATE INDEX IXBooks_IsDeleted ON Books (IsDeleted);
--@@

CREATE INDEX IXBooks_UpdateDate ON Books (UpdateDate);
--@@

CREATE INDEX IXBooks_IsLocal ON Books (IsLocal);
--@@

CREATE INDEX IXBooks_LibID ON Books (LibID);
--@@

CREATE INDEX IXBooks_KeyWords ON Books (KeyWords);
--@@

CREATE INDEX IXBooks_BookID_IsDeleted_IsLocal ON Books (BookID, IsDeleted, IsLocal);
--@@

CREATE INDEX IXBooks_SearchTitle ON Books (SearchTitle);
--@@

CREATE INDEX IXBooks_SearchLang ON Books (SearchLang);
--@@

CREATE INDEX IXBooks_SearchFolder ON Books (SearchFolder);
--@@

CREATE INDEX IXBooks_SearchFileName ON Books (SearchFileName);
--@@

CREATE INDEX IXBooks_SearchExt ON Books (SearchExt);
--@@

CREATE INDEX IXBooks_SearchKeyWords ON Books (SearchKeyWords);
--@@

CREATE INDEX IXBooks_SearchAnnotation ON Books (SearchAnnotation);
--@@

-- A book may belong to several series. Books.SeriesID/SeqNumber remains the
-- primary-series mirror for compatibility with older MyHomeLib builds.
CREATE TABLE Series_List (
  BookID      INTEGER NOT NULL,
  SeriesID    INTEGER NOT NULL,
  SeqNumber   INTEGER,
  IsPrimary   INTEGER NOT NULL DEFAULT 0,
  OrdNum      INTEGER NOT NULL DEFAULT 0,

  CONSTRAINT "PKSeriesList" PRIMARY KEY (BookID, SeriesID)
);
--@@

CREATE INDEX IXSeriesList_SeriesID_BookID ON Series_List (SeriesID, BookID);
--@@

CREATE TRIGGER TRBooks_AI AFTER INSERT ON Books WHEN MHL_TRIGGERS_ON()
  BEGIN
    UPDATE Books
    SET
      SearchTitle      = MHL_UPPER(NEW.Title),
      SearchLang       = MHL_UPPER(NEW.Lang),
      SearchFolder     = MHL_UPPER(NEW.Folder),
      SearchFileName   = MHL_UPPER(NEW.FileName),
      SearchExt        = MHL_UPPER(NEW.Ext),
      SearchKeyWords   = MHL_UPPER(NEW.KeyWords),
      SearchAnnotation = MHL_UPPER(NEW.Annotation)
    WHERE
      BookID = NEW.BookID;
  END;
--@@

CREATE TRIGGER TRBooks_AU AFTER UPDATE OF Title, Lang, Folder, FileName, Ext, KeyWords, Annotation ON Books WHEN MHL_TRIGGERS_ON()
  BEGIN
    UPDATE Books
    SET
      SearchTitle      = MHL_UPPER(NEW.Title),
      SearchLang       = MHL_UPPER(NEW.Lang),
      SearchFolder     = MHL_UPPER(NEW.Folder),
      SearchFileName   = MHL_UPPER(NEW.FileName),
      SearchExt        = MHL_UPPER(NEW.Ext),
      SearchKeyWords   = MHL_UPPER(NEW.KeyWords),
      SearchAnnotation = MHL_UPPER(NEW.Annotation)
    WHERE
      BookID = NEW.BookID;
  END;
--@@

CREATE TRIGGER TRBooks_AI_Series AFTER INSERT ON Books
  WHEN MHL_TRIGGERS_ON() AND NEW.SeriesID IS NOT NULL
  BEGIN
    INSERT OR REPLACE INTO Series_List
      (BookID, SeriesID, SeqNumber, IsPrimary, OrdNum)
      VALUES (NEW.BookID, NEW.SeriesID, NEW.SeqNumber, 1, 0);
  END;
--@@

CREATE TRIGGER TRBooks_AU_Series AFTER UPDATE OF SeriesID, SeqNumber ON Books
  WHEN MHL_TRIGGERS_ON()
  BEGIN
    UPDATE Series_List SET IsPrimary = 0 WHERE BookID = NEW.BookID;
    DELETE FROM Series_List
      WHERE BookID = NEW.BookID
        AND SeriesID = OLD.SeriesID
        AND OLD.SeriesID IS NOT NULL
        AND (NEW.SeriesID IS NULL OR OLD.SeriesID <> NEW.SeriesID);
    INSERT OR REPLACE INTO Series_List
      (BookID, SeriesID, SeqNumber, IsPrimary, OrdNum)
      SELECT NEW.BookID, NEW.SeriesID, NEW.SeqNumber, 1, 0
      WHERE NEW.SeriesID IS NOT NULL;
    DELETE FROM Series
      WHERE SeriesID = OLD.SeriesID
        AND NOT EXISTS (
          SELECT 1 FROM Series_List sl WHERE sl.SeriesID = OLD.SeriesID
        );
  END;
--@@

-- CREATE TRIGGER TRBooks_BD BEFORE DELETE ON Books
--  BEGIN
--    DELETE FROM Genre_List WHERE BookID = OLD.BookID;
--    DELETE FROM Author_List WHERE BookID = OLD.BookID;
--    DELETE FROM Series WHERE SeriesID IN (SELECT b.SeriesID FROM Books b WHERE  b.SeriesID = OLD.SeriesID GROUP BY b.SeriesID HAVING COUNT(b.SeriesID) <= 1);
--    DELETE FROM Authors WHERE NOT AuthorID in (SELECT DISTINCT al.AuthorID FROM Author_List al);
--  END;
--@@

CREATE TRIGGER TRBooks_BD BEFORE DELETE ON Books
  BEGIN
    DELETE FROM Genre_List WHERE BookID = OLD.BookID;
--	  DELETE FROM Authors WHERE AuthorID in (SELECT DISTINCT AuthorID FROM Author_List WHERE BookID = OLD.BookID);
    DELETE FROM Author_List WHERE BookID = OLD.BookID;
    DELETE FROM Series
      WHERE SeriesID IN (
        SELECT SeriesID FROM Series_List WHERE BookID = OLD.BookID
      )
      AND NOT EXISTS (
        SELECT 1 FROM Series_List sl
          WHERE sl.SeriesID = Series.SeriesID AND sl.BookID <> OLD.BookID
      );
    DELETE FROM Series_List WHERE BookID = OLD.BookID;
  END;

--@@

CREATE TABLE Genre_List (
  GenreCode VARCHAR(20) NOT NULL COLLATE NOCASE,
  BookID    INTEGER     NOT NULL,

  CONSTRAINT "PKGenreList" PRIMARY KEY (BookID, GenreCode)
);
--@@

CREATE INDEX IXGenreList_GenreCode_BookID ON Genre_List (GenreCode, BookID);
--@@

CREATE TABLE Author_List (
  AuthorID INTEGER NOT NULL,
  BookID   INTEGER NOT NULL,

  CONSTRAINT "PKAuthorList" PRIMARY KEY (BookID, AuthorID)
);
--@@

CREATE INDEX IXAuthorList_AuthorID_BookID ON Author_List (AuthorID, BookID);
--@@
