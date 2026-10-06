unit unit_UpdateAuthenticity;

interface

uses System.SysUtils;

function UpdateSHA3(const FileName: string): string;
procedure VerifySumatraSignature(const FileName: string);

implementation

uses System.Classes, Winapi.Windows;

// SHA3-256, FIPS 202: 1088-bit rate, 512-bit capacity, domain suffix 06.
function UpdateSHA3(const FileName: string): string;
const
  RC: array[0..23] of UInt64 = ($0000000000000001,$0000000000008082,$800000000000808A,
    $8000000080008000,$000000000000808B,$0000000080000001,$8000000080008081,
    $8000000000008009,$000000000000008A,$0000000000000088,$0000000080008009,
    $000000008000000A,$000000008000808B,$800000000000008B,$8000000000008089,
    $8000000000008003,$8000000000008002,$8000000000000080,$000000000000800A,
    $800000008000000A,$8000000080008081,$8000000000008080,$0000000080000001,
    $8000000080008008);
  Rot: array[0..24] of Integer = (0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,
    41,45,15,21,8,18,2,61,56,14);
var A, B: array[0..24] of UInt64; C, D: array[0..4] of UInt64;
  Buffer: array[0..135] of Byte; Stream: TFileStream;
  Count, I: Integer;
  function Rotate(Value: UInt64; Bits: Integer): UInt64;
  begin
    if Bits = 0 then Result := Value else Result := (Value shl Bits) or (Value shr (64 - Bits));
  end;
  procedure Absorb;
  var J, X, Y, Round: Integer;
  begin
    for J := 0 to 135 do A[J div 8] := A[J div 8] xor (UInt64(Buffer[J]) shl ((J mod 8) * 8));
    for Round := 0 to 23 do
    begin
      for X := 0 to 4 do C[X] := A[X] xor A[X+5] xor A[X+10] xor A[X+15] xor A[X+20];
      for X := 0 to 4 do D[X] := C[(X+4) mod 5] xor Rotate(C[(X+1) mod 5],1);
      for Y := 0 to 4 do for X := 0 to 4 do A[X+5*Y] := A[X+5*Y] xor D[X];
      for Y := 0 to 4 do for X := 0 to 4 do B[Y+5*((2*X+3*Y) mod 5)] := Rotate(A[X+5*Y],Rot[X+5*Y]);
      for Y := 0 to 4 do for X := 0 to 4 do
        A[X+5*Y] := B[X+5*Y] xor ((not B[(X+1) mod 5+5*Y]) and B[(X+2) mod 5+5*Y]);
      A[0] := A[0] xor RC[Round];
    end;
  end;
begin
  FillChar(A, SizeOf(A), 0); Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    repeat
      FillChar(Buffer, SizeOf(Buffer), 0); Count := Stream.Read(Buffer, SizeOf(Buffer));
      if Count = SizeOf(Buffer) then Absorb;
    until Count < SizeOf(Buffer);
    Buffer[Count] := $06; Buffer[135] := Buffer[135] or $80; Absorb;
    Result := '';
    for I := 0 to 31 do Result := Result + LowerCase(IntToHex(Byte(A[I div 8] shr ((I mod 8)*8)), 2));
  finally Stream.Free; end;
end;

type
  TTrustFile = record
    Size: DWORD; FileName: PWideChar; Handle: THandle; KnownSubject: Pointer;
  end;
  TTrustData = record
    Size: DWORD; Policy, SIP: Pointer; UI, Revocation, Choice: DWORD; FileInfo: Pointer;
    Action: DWORD; State: THandle; URL: PWideChar; Flags, Context: DWORD; SignatureSettings: Pointer;
  end;

function WinVerifyTrust(Window: HWND; var Action: TGUID; Data: Pointer): Longint; stdcall; external 'wintrust.dll';
function CryptQueryObject(ObjectType: DWORD; Obj: Pointer; Content, Format, Flags: DWORD;
  Encoding, ContentType, FormatType: PDWORD; Store, Msg, Context: Pointer): BOOL; stdcall; external 'crypt32.dll';
function CryptMsgGetParam(Msg: THandle; ParamType, Index: DWORD; Data: Pointer; var Size: DWORD): BOOL; stdcall; external 'crypt32.dll';
function CertFindCertificateInStore(Store: THandle; Encoding, Flags, FindType: DWORD;
  FindParam, Previous: Pointer): Pointer; stdcall; external 'crypt32.dll';
function CertGetNameString(Cert: Pointer; NameType, Flags: DWORD; Param: Pointer;
  Name: PWideChar; Size: DWORD): DWORD; stdcall; external 'crypt32.dll' name 'CertGetNameStringW';
function CertFreeCertificateContext(Cert: Pointer): BOOL; stdcall; external 'crypt32.dll';
function CertCloseStore(Store: THandle; Flags: DWORD): BOOL; stdcall; external 'crypt32.dll';
function CryptMsgClose(Msg: THandle): BOOL; stdcall; external 'crypt32.dll';

procedure VerifySumatraSignature(const FileName: string);
const ActionGUID: TGUID = '{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}';
var FileInfo: TTrustFile; Data: TTrustData; Action: TGUID; Store, Msg: THandle;
  SignerInfo: TBytes; Size: DWORD; Cert: Pointer; Name: string;
begin
  FileInfo := Default(TTrustFile); FileInfo.Size := SizeOf(FileInfo); FileInfo.FileName := PChar(FileName);
  Data := Default(TTrustData); Data.Size := SizeOf(Data); Data.UI := 2;
  Data.Choice := 1; Data.FileInfo := @FileInfo; Data.Action := 1; Data.Flags := $1000 or $10;
  Action := ActionGUID;
  try
    if WinVerifyTrust(HWND(-1), Action, @Data) <> 0 then
      raise Exception.Create('Не удалось подтвердить цифровую подпись SumatraPDF. Обновление не будет установлено.');
  finally Data.Action := 2; WinVerifyTrust(HWND(-1), Action, @Data); end;
  Store := 0; Msg := 0; Cert := nil;
  try
    if not CryptQueryObject(1, PChar(FileName), $400, 2, 0, nil, nil, nil, @Store, @Msg, nil) then RaiseLastOSError;
    Size := 0;
    if not CryptMsgGetParam(Msg, 7, 0, nil, Size) or (Size > 65536) then RaiseLastOSError;
    SetLength(SignerInfo, Size);
    if not CryptMsgGetParam(Msg, 7, 0, @SignerInfo[0], Size) then RaiseLastOSError;
    Cert := CertFindCertificateInStore(Store, $10001, 0, $B0000, @SignerInfo[0], nil);
    if Cert = nil then RaiseLastOSError;
    Size := CertGetNameString(Cert, 4, 0, nil, nil, 0); SetLength(Name, Size);
    if Size > 1 then
    begin CertGetNameString(Cert, 4, 0, nil, PChar(Name), Size); SetLength(Name, Size-1); end;
    if Name <> 'Krzysztof Kowalczyk' then
      raise Exception.Create('Издатель SumatraPDF не совпадает с официальным автором.');
  finally
    if Cert <> nil then CertFreeCertificateContext(Cert);
    if Msg <> 0 then CryptMsgClose(Msg);
    if Store <> 0 then CertCloseStore(Store, 0);
  end;
end;

end.
