unit unit_PDFProtocol;

interface

const
  PDF_PROTOCOL = $48504431;
  PDF_BUFFER_BYTES = 64 * 1024 * 1024;
  PDF_OPEN = 1;
  PDF_RENDER = 2;
  PDF_CLOSE = 3;

type
  TPDFRequest = packed record
    // Length: UTF-8 filename byte count for OPEN; max image edge for RENDER
    // (0 keeps the original 4000px limit); no payload follows RENDER.
    Magic, Command, Index, Length: Integer;
  end;
  TPDFResponse = packed record
    Magic, Status, Width, Height, Count, Length: Integer;
  end;

implementation
end.
