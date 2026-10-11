#!/bin/bash
set -euo pipefail
# unit_MHLArchiveHelpers/unit_MHLExternalTools, so the search path is shorter than the lang
export MSYS2_ARG_CONV_EXCL="*"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../../.."

BDS="${BDS:-C:/Program Files (x86)/Embarcadero/Studio/37.0}"
OUT="${METABIBTEST_OUT:-$TEMP/metabibtest}"
mkdir -p "$OUT/dcu"

DIRS="Program/Units Components/MHLComponents"

NS="System;Winapi;Xml;Data;System.Win;Xml.Win;Data.Win"

UNITS="$BDS/lib/Win64/release"
for d in $DIRS; do UNITS="$UNITS;$d"; done

"$BDS/bin/dcc64.exe" -B -E"$OUT" -N0"$OUT/dcu" -U"$UNITS" -NS"$NS" \
  tools/metabib/tests/MetabibTest.dpr 2>&1 | grep -Ev "^(Embarcadero|Copyright)|H2443" | tail -8
