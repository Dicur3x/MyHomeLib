unit unit_ImportOldUserData;

interface

uses unit_UserData;

procedure LoadOldUserData(const FileName: string; var UserDataSource: TUserData);

implementation

uses unit_LegacyUserDataPreview;

procedure LoadOldUserData(const FileName: string; var UserDataSource: TUserData);
var Preview: TLegacyUserDataPreview;
begin
  Preview := TLegacyUserDataPreview.Create(FileName);
  try
    // Noninteractive compatibility callers retain the historical second-group
    // convention. The interactive preview requires an explicit mapping.
    Preview.UseHistoricalDefaults;
    Preview.AppendTo(UserDataSource);
  finally Preview.Free; end;
end;

end.
