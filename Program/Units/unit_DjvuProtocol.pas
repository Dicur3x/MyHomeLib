unit unit_DjvuProtocol;

interface

const
  DJVU_PROTOCOL = $48444A31;
  DJVU_BUFFER_BYTES = 64 * 1024 * 1024;
  DJVU_OPEN = 1;
  DJVU_RENDER = 2;
  DJVU_CLOSE = 3;

type
  TDjvuRequest = packed record
    Magic, Command, Index, Length: Integer;
  end;
  TDjvuResponse = packed record
    Magic, Status, Width, Height, Count, Length: Integer;
  end;

implementation
end.
