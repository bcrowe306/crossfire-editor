; The Windows installer (Inno Setup 6): the release's files into Program Files, a Start menu entry,
; an uninstaller. CI's windows-installer job compiles it from the archive with every platform's
; prebuilt player:
;
;   iscc /DSourceDir=<release folder> /DAppVersion=<version> /DOutputDir=<folder> tools\windows\crossfire-editor.iss
;
; Installed in Program Files the editor can't write beside itself, so it runs "installed"
; (bundle.odin): settings and build folders in its data folder, the demo copied to Documents.

#ifndef SourceDir
  #error Pass /DSourceDir=<the release folder>
#endif
#ifndef AppVersion
  #define AppVersion "dev"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
AppId={{6C6F7D52-3C7E-4B1E-9F64-63726F737366}
AppName=Crossfire Editor
AppVersion={#AppVersion}
AppPublisher=bcrowe306
AppPublisherURL=https://github.com/bcrowe306/crossfire-editor
DefaultDirName={autopf}\Crossfire Editor
DefaultGroupName=Crossfire Editor
UninstallDisplayIcon={app}\crossfire-editor.exe
OutputDir={#OutputDir}
OutputBaseFilename=crossfire-editor-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\assets\icons\crossfire.ico
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
PrivilegesRequiredOverridesAllowed=dialog

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Crossfire Editor"; Filename: "{app}\crossfire-editor.exe"
Name: "{group}\Uninstall Crossfire Editor"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Crossfire Editor"; Filename: "{app}\crossfire-editor.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Run]
Filename: "{app}\crossfire-editor.exe"; Description: "{cm:LaunchProgram,Crossfire Editor}"; Flags: nowait postinstall skipifsilent
