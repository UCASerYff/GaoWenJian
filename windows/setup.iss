#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildDirectory
  #error BuildDirectory is required
#endif
#ifndef ReleaseDirectory
  #error ReleaseDirectory is required
#endif
#ifndef AppIcon
  #error AppIcon is required
#endif

[Setup]
AppId={{B06256C0-5B37-44AB-941B-7B8E00C7ED63}
AppName=搞文件
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
AppPublisher=GaoSeries
DefaultDirName={localappdata}\Programs\GaoSeries\GaoWenJian
DefaultGroupName=搞文件
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
DisableProgramGroupPage=yes
UninstallDisplayName=搞文件
UninstallDisplayIcon={app}\GaoWenJian.exe
CreateUninstallRegKey=not IsolatedInstall
UsedUserAreasWarning=no
CloseApplications=yes
RestartApplications=no
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
SetupIconFile={#AppIcon}
OutputDir={#ReleaseDirectory}
OutputBaseFilename=GaoWenJian-Windows-{#AppVersion}-x64-Setup

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#BuildDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\搞文件"; Filename: "{app}\GaoWenJian.exe"; WorkingDir: "{app}"; Check: not IsolatedInstall

[Code]
function IsolatedInstall: Boolean;
begin
  Result := ExpandConstant('{param:GAOISOLATED|0}') = '1';
end;
