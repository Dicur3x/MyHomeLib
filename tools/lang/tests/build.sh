#!/bin/bash
export MSYS2_ARG_CONV_EXCL="*"
export MSYS_NO_PATHCONV=1
cd "D:/DelphiProjects/MyHomeLib" || exit 1

BDS="C:/Program Files (x86)/Embarcadero/Studio/37.0"
CRALL="C:/Users/Public/Documents/Embarcadero/Studio/37.0/CatalogRepository"
CRUSER="D:/WinDocuments/Embarcadero/Studio/37.0/CatalogRepository"
OUT="${LANGTEST_OUT:-$TEMP/langtest}"
mkdir -p "$OUT/dcu"

DIRS="Program/Units Program/Forms Program/Forms/Editors Program/DataModules
Program/DAO Program/DAO/SQLite Program/DAO/SQLite/Lib Program/ImportImpl
Program/DwnldImpl Program/UtilsImpl Program/Wizards Program/Wizards/Base
Program/Wizards/NewCollection Components Components/MHLComponents
Components/MHLComponents/Out/Units"

LIBS="$CRUSER/VirtualTreeview_by_JamSoftware-13/8.3/source
$CRUSER/Abbrevia-13/2025.11/source
$CRUSER/SynEdit-13/2025.03/source
$CRUSER/SynEdit-13/2025.03/source/Highlighters
$CRUSER/JEDICodeLibraryJCL-13/2025.10/lib/d37/win64
$CRUSER/JEDICodeLibraryJCL-13/2025.10/source/include
$CRUSER/JEDIVisualComponentLibraryJVCL-13/2025.10/lib/D37/win64
$CRUSER/JEDIVisualComponentLibraryJVCL-13/2025.10/common
$CRUSER/OmniThreadLibrary-13/3.07.11
$CRUSER/OmniThreadLibrary-13/3.07.11/src
$CRALL/BonusKSVC/8.0.2/Lib/RX13/Win64
D:/DelphiProjects/Libraries/FastMM5
$BDS/Imports
C:/Users/Public/Documents/Embarcadero/Studio/37.0/Dcp/Win64"

UNITS="$BDS/lib/Win64/release"
for d in $DIRS $LIBS; do UNITS="$UNITS;$d"; done

NS="Vcl;Vcl.Imaging;Vcl.Touch;Vcl.Samples;Vcl.Shell;System;Xml;Data;Datasnap;Web;Soap;Winapi;Bde;Xml.Win;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win"

"$BDS/bin/dcc64.exe" -B -E"$OUT" -N0"$OUT/dcu" -U"$UNITS" -NS"$NS" -R"Program" \
  tools/lang/tests/LangTest.dpr 2>&1 | grep -Ev "^(Embarcadero|Copyright)|H2443" | tail -8
