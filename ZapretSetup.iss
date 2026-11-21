; ============================================================
;  Zapret GUI — скрипт установщика для Inno Setup
;  Скачать Inno Setup (бесплатно): https://jrsoftware.org/isdl.php
;  Открой этот файл в Inno Setup -> Build -> Compile
; ============================================================

#define MyAppName "Zapret GUI BETA"
#ifndef MyAppVersion
  #define MyAppVersion "1.10.4"
#endif
#define MyAppExeName "ZapretGUI.exe"

[Setup]
AppId={{E1B6E6D4-9B7A-4B7D-9C3E-5A0F2E7C1001}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=Zapret GUI
DefaultDirName={autopf}\Zapret
DefaultGroupName=Zapret
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=Output
OutputBaseFilename=ZapretSetup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
SetupIconFile=zapret-discord-youtube-1.10.4\assets\zapret.ico
DisableWelcomePage=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на &рабочем столе"; GroupDescription: "Дополнительно:"

[Files]
; Готовый exe (его собирает GitHub Actions через ps2exe)
Source: "ZapretGUI.exe"; DestDir: "{app}"; Flags: ignoreversion
; Вся папка zapret со стратегиями, bin, lists и т.д.
Source: "zapret-discord-youtube-1.10.4\*"; DestDir: "{app}\zapret-discord-youtube-1.10.4"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Zapret"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Zapret"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить Zapret"; Flags: nowait postinstall skipifsilent shellexec

[UninstallDelete]
; файлы, которые программа создаёт сама во время работы (оценки, настройки и т.п.)
Type: filesandordirs; Name: "{app}\zapret-discord-youtube-1.10.4"

[UninstallRun]
; при удалении программы закрываем её и убираем службу автозапуска zapret из системы
Filename: "{cmd}"; Parameters: "/c taskkill /IM ZapretGUI.exe /F >nul 2>&1"; Flags: runhidden; RunOnceId: "CloseZapretGUI"
Filename: "{cmd}"; Parameters: "/c sc stop zapret >nul 2>&1 & sc delete zapret >nul 2>&1 & sc stop WinDivert >nul 2>&1 & sc delete WinDivert >nul 2>&1 & taskkill /IM winws.exe /F >nul 2>&1"; Flags: runhidden; RunOnceId: "RemoveZapretService"
