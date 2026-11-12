; SebType's Windows installer (#73): one SebType-setup-<version>.exe that installs, upgrades and
; uninstalls everything SebType needs on Windows, in the Picnic look (Decisions #2). Built by
; .github/workflows/windows-setup.yml:
;   ISCC /DIn=<folder of the workflow's artifacts> [/DBuild=<n>] pc/windows/setup/sebtype.iss
; The steps themselves are setup.ps1's: -Machine (elevated) installs SebType's Weasel and Mozc,
; -User (as the person who runs Setup) sets up their account. Why each step exists: ../README.md.

#ifndef Version
  #define Version "0.1.0"
#endif
#ifndef Build
  #define Build "0"
#endif
#ifndef In
  #error /DIn=<folder with the artifacts of windows-setup.yml> is required
#endif
#define Pictures In + "\setup-pictures"
#define Repo SourcePath + "\..\..\.."

; The engines' files, by name: their names say their versions, which setup.ps1 compares.
#define Handle FindFirst(In + "\sebtype-weasel\sebtype-weasel-*-installer.exe", 0)
#if !Handle
  #error SebType's Weasel installer is missing from /DIn
#endif
#define WeaselExe FindGetFileName(Handle)
#expr FindClose(Handle)
#define Handle FindFirst(In + "\sebtype-mozc\SebType-Mozc-*.msi", 0)
#if !Handle
  #error SebType's Mozc MSI is missing from /DIn
#endif
#define MozcMsi FindGetFileName(Handle)
#expr FindClose(Handle)

; Python's embeddable package, for the Configurator's sync (#180): python.ps1 fetches and checks it now.
#define PythonDir SourcePath + "\out\python"
#if Exec("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File """ + SourcePath + "\python.ps1"" -Dir """ + PythonDir + """", SourcePath, 1, 0) != 0
  #error python.ps1 failed: Python's embeddable package for sync is missing
#endif

[Setup]
AppId={{5C1E7A52-3D8B-4F7E-9E0B-7B3B5A1C7354}
AppName=SebType
AppVersion={#Version}.{#Build}
AppVerName=SebType {#Version}
AppPublisher=Seb
AppPublisherURL=https://github.com/S-Sebb/SebType
DefaultDirName={autopf}\SebType
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableWelcomePage=no
; Windows loads text services registered for the whole PC only, so Weasel and Mozc install as admin.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=out
OutputBaseFilename=SebType-setup-{#Version}
SetupIconFile={#Pictures}\sebtype.ico
UninstallDisplayIcon={app}\sebtype.ico
UninstallDisplayName=SebType
SolidCompression=yes
; Windows' language, switchable before anything else shows; English where it isn't one of these.
ShowLanguageDialog=yes
LanguageDetectionMethod=uilanguage
; Picnic (#73, look B): the checkered cloth behind every page, the cream card with the pig.
WizardStyle=modern hidebevels
WizardBackColor=#FBE9D6
WizardBackImageFile={#Pictures}\cloth.png
WizardImageFile={#Pictures}\welcome-1.png,{#Pictures}\welcome-2.png
WizardSmallImageFile={#Pictures}\small-1.png,{#Pictures}\small-2.png

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "zh"; MessagesFile: "ChineseSimplified.isl"
Name: "ja"; MessagesFile: "compiler:Languages\Japanese.isl"

[Messages]
en.WelcomeLabel1=Hi! Let's set up SebType
zh.WelcomeLabel1=你好！来装 SebType 吧
ja.WelcomeLabel1=こんにちは！SebType をはじめよう
en.WelcomeLabel2=SebType types Chinese, Japanese and English on this PC, just like on your phone.%n%nIt sets up Chinese (Weasel with SebType's dictionary), Japanese (SebType's Mozc) and the SebType Configurator, and makes Win+Space the one key that switches language.%n%nAlready have SebType? This updates it and keeps every word it has learned.
zh.WelcomeLabel2=SebType 让这台电脑像你的手机一样输入中文、日本語和英文。%n%n它会装好中文（小狼毫和 SebType 的词库）、日本語（SebType 的 Mozc）和 SebType 设置，并让 Win+Space 成为切换语言的唯一按键。%n%n已经装过 SebType？这次会更新它，并保留它学会的每一个词。
ja.WelcomeLabel2=SebType で、この PC でもスマホと同じように中国語・日本語・英語を入力できます。%n%n中国語（小狼毫と SebType の辞書）、日本語（SebType の Mozc）と SebType 設定をインストールし、言語の切り替えを Win+Space ひとつにします。%n%nSebType をもうお使いですか？アップデートしても、覚えた言葉はそのまま残ります。
en.WizardSelectTasks=Your languages
zh.WizardSelectTasks=你的语言
ja.WizardSelectTasks=使う言語
en.SelectTasksDesc=Pick what you'd like.
zh.SelectTasksDesc=选你想要的。
ja.SelectTasksDesc=使いたいものを選んでください。
en.SelectTasksLabel2=SebType sets these up for you. Click Install when you're ready.
zh.SelectTasksLabel2=SebType 会为你装好这些。准备好了就点“安装”。
ja.SelectTasksLabel2=選んだものを SebType がセットアップします。準備ができたら［インストール］をクリックしてください。
en.WizardInstalling=Setting up SebType
zh.WizardInstalling=正在安装 SebType
ja.WizardInstalling=SebType をセットアップしています
en.InstallingLabel=This takes about a minute. The words SebType has learned stay.
zh.InstallingLabel=大约需要一分钟。SebType 学会的词都会保留。
ja.InstallingLabel=1 分ほどかかります。SebType が覚えた言葉はそのまま残ります。
en.FinishedHeadingLabel=SebType is ready!
zh.FinishedHeadingLabel=SebType 装好啦！
ja.FinishedHeadingLabel=SebType の準備ができました！
en.FinishedLabel=Press Win+Space to switch EN → 中 → あ.%nIn Chinese or Japanese, tap Shift for quick English.%n%nCtrl+Shift+F switches 简 ⇄ 繁, and Alt+` switches あ ⇄ ア.
zh.FinishedLabel=按 Win+Space 切换 EN → 中 → あ。%n在中文或日本語里，轻按一下 Shift 临时输入英文。%n%nCtrl+Shift+F 切换简 ⇄ 繁，Alt+` 切换 あ ⇄ ア。
ja.FinishedLabel=Win+Space で EN → 中 → あ を切り替えます。%n中国語や日本語では、Shift を軽く押すと一時的に英語で入力できます。%n%nCtrl+Shift+F で簡体 ⇄ 繁体、Alt+` で あ ⇄ ア を切り替えます。
ClickFinish=
en.ConfirmUninstall=Remove SebType from this PC?%n%nThe words SebType has learned on this PC are deleted with it.
zh.ConfirmUninstall=要从这台电脑上移除 SebType 吗？%n%nSebType 在这台电脑上学会的词也会一起删除。
ja.ConfirmUninstall=この PC から SebType を削除しますか？%n%nこの PC で SebType が覚えた言葉も削除されます。
en.UninstalledAll=SebType was removed. Your keyboard is back to how it was before.
zh.UninstalledAll=SebType 已移除，键盘已恢复原样。
ja.UninstalledAll=SebType を削除しました。キーボードは元どおりです。
en.WizardUninstalling=Removing SebType
zh.WizardUninstalling=正在移除 SebType
ja.WizardUninstalling=SebType を削除しています
en.UninstallStatusLabel=Bye for now! Removing SebType from this PC.
zh.UninstallStatusLabel=下次见！正在从这台电脑上移除 SebType。
ja.UninstallStatusLabel=またね！この PC から SebType を削除しています。

[CustomMessages]
en.Languages=Languages (Win+Space switches between them)
zh.Languages=语言（用 Win+Space 切换）
ja.Languages=言語（Win+Space で切り替え）
en.English=English (the US keyboard)
zh.English=English（美式键盘）
ja.English=English（US キーボード）
en.Chinese=中文 Chinese (小狼毫 Weasel with SebType's dictionary)
zh.Chinese=中文（小狼毫和 SebType 的词库）
ja.Chinese=中文 中国語（小狼毫と SebType の辞書）
en.Japanese=日本語 Japanese (SebType's Mozc)
zh.Japanese=日本語（SebType 的 Mozc）
ja.Japanese=日本語（SebType の Mozc）
en.Shortcuts=Shortcuts
zh.Shortcuts=快捷方式
ja.Shortcuts=ショートカット
en.Desktop=SebType Configurator on the desktop
zh.Desktop=在桌面上放 SebType 设置
ja.Desktop=デスクトップに SebType 設定
en.Configurator=SebType Configurator
zh.Configurator=SebType 设置
ja.Configurator=SebType 設定
en.OpenConfigurator=Open SebType Configurator
zh.OpenConfigurator=打开 SebType 设置
ja.OpenConfigurator=SebType 設定を開く
en.NoLanguage=Pick at least one language.
zh.NoLanguage=请至少选一种语言。
ja.NoLanguage=言語を 1 つ以上選んでください。
en.Engines=Installing the input methods...
zh.Engines=正在安装输入法…
ja.Engines=入力方式をインストールしています…
en.Account=Setting up your keyboard...
zh.Account=正在设置你的键盘…
ja.Account=キーボードを設定しています…
en.Undoing=Putting your old keyboards back...
zh.Undoing=正在恢复你原来的键盘…
ja.Undoing=元のキーボードに戻しています…
en.Failed=Something went wrong while setting up SebType (step "%1", code %2).%n%nThe details are in %3. Running Setup again usually fixes it.
zh.Failed=安装 SebType 时出了点问题（步骤“%1”，代码 %2）。%n%n详情见 %3。再运行一次安装程序通常就好了。
ja.Failed=SebType のセットアップ中に問題が起きました（手順「%1」、コード %2）。%n%n詳しくは %3 を見てください。もう一度セットアップを実行すると、たいてい直ります。

[Tasks]
Name: "en"; Description: "{cm:English}"; GroupDescription: "{cm:Languages}"
Name: "zh"; Description: "{cm:Chinese}"; GroupDescription: "{cm:Languages}"
Name: "ja"; Description: "{cm:Japanese}"; GroupDescription: "{cm:Languages}"
Name: "desktopicon"; Description: "{cm:Desktop}"; GroupDescription: "{cm:Shortcuts}"; Flags: unchecked

[Files]
Source: "setup.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Repo}\pc\linux\mozc-keymap.tsv"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#In}\rime-data\rime-data.zip"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#In}\sebtype-configurator\sebtype-configurator.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PythonDir}\*"; DestDir: "{app}\python"; Flags: ignoreversion recursesubdirs
Source: "{#Pictures}\sebtype.ico"; DestDir: "{app}"; Flags: ignoreversion
; The uninstaller's look: it runs from {app}, without Setup's own files.
Source: "{#Pictures}\cloth.png"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Pictures}\small-1.png"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Pictures}\small-2.png"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Repo}\sebtype\fonts\Jersey10-Regular.ttf"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Repo}\sebtype\fonts\Nunito-Bold.ttf"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Repo}\sebtype\fonts\OFL-Jersey10.txt"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Repo}\sebtype\fonts\OFL-Nunito.txt"; DestDir: "{app}\look"; Flags: ignoreversion
; Setup's own, unpacked when needed.
Source: "{#Repo}\sebtype\fonts\Jersey10-Regular.ttf"; Flags: dontcopy
Source: "{#Repo}\sebtype\fonts\Nunito-Bold.ttf"; Flags: dontcopy
Source: "{#Pictures}\finish-1.png"; Flags: dontcopy
Source: "{#Pictures}\finish-2.png"; Flags: dontcopy
Source: "{#In}\sebtype-weasel\{#WeaselExe}"; Flags: dontcopy
Source: "{#In}\sebtype-mozc\{#MozcMsi}"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\{cm:Configurator}"; Filename: "{app}\sebtype-configurator.exe"; IconFilename: "{app}\sebtype.ico"
Name: "{autodesktop}\{cm:Configurator}"; Filename: "{app}\sebtype-configurator.exe"; IconFilename: "{app}\sebtype.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\sebtype-configurator.exe"; Description: "{cm:OpenConfigurator}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\setup.log"

[Code]
const
  Ink = $222F4A;    // Picnic's ink #4A2F22 and key berry #C2506A, as TColor ($BBGGRR)
  Berry = $6A50C2;
  FR_PRIVATE = $10;

var
  FailCode: Integer;

function AddFontResourceEx(Name: String; Flags: Cardinal; Reserved: Cardinal): Integer;
  external 'AddFontResourceExW@gdi32.dll stdcall';
function RemoveFontResourceEx(Name: String; Flags: Cardinal; Reserved: Cardinal): Integer;
  external 'RemoveFontResourceExW@gdi32.dll stdcall';

// SebType's languages Setup sets up, as setup.ps1 -Languages takes them.
function Chosen: String;
begin
  Result := '';
  if WizardIsTaskSelected('en') then Result := Result + ',en';
  if WizardIsTaskSelected('zh') then Result := Result + ',zh';
  if WizardIsTaskSelected('ja') then Result := Result + ',ja';
  Delete(Result, 1, 1);
end;

function PowerShell(Arguments: String): String;
begin
  Result := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\setup.ps1') + '" ' + Arguments;
end;

// Runs a setup.ps1 step; on failure says so (not in a silent run) and makes Setup's exit code 1.
procedure Step(Name, Arguments, LogFile: String; AsOriginalUser: Boolean);
var
  Code: Integer;
  Ok: Boolean;
begin
  if AsOriginalUser then
    Ok := ExecAsOriginalUser('powershell.exe', PowerShell(Arguments), '', SW_HIDE, ewWaitUntilTerminated, Code)
  else
    Ok := Exec('powershell.exe', PowerShell(Arguments), '', SW_HIDE, ewWaitUntilTerminated, Code);
  if not Ok or (Code <> 0) then
  begin
    Log(Format('setup.ps1 %s failed: %d', [Arguments, Code]));
    FailCode := 1;
    SuppressibleMsgBox(FmtMessage(CustomMessage('Failed'), [Name, IntToStr(Code), LogFile]), mbError, MB_OK, IDOK);
  end;
end;

procedure Restyle(C: TNewStaticText; FontName: String; Size: Integer; Colour: TColor);
begin
  C.StyleElements := C.StyleElements - [seFont];
  if FontName <> '' then
    C.Font.Name := FontName;
  if Size > 0 then
    C.Font.Size := Size;
  C.Font.Color := Colour;
end;

// Headings in the app's fonts: Jersey 10 for English. It has no Chinese or Japanese letters, so those
// get their own system font, bold, in the same berry.
procedure Heading(C: TNewStaticText; Size: Integer);
begin
  if ActiveLanguage = 'en' then
    Restyle(C, 'Jersey 10', Size, Berry)
  else
  begin
    if ActiveLanguage = 'zh' then
      Restyle(C, 'Microsoft YaHei UI', Size * 2 div 3, Berry)
    else
      Restyle(C, 'Yu Gothic UI', Size * 2 div 3, Berry);
    C.Font.Style := [fsBold];
  end;
end;

// Body text in Nunito where it is English only (Nunito has no CJK letters), else the dialog font.
procedure Body(C: TNewStaticText);
begin
  if ActiveLanguage = 'en' then
    Restyle(C, 'Nunito', 0, Ink)
  else
    Restyle(C, '', 0, Ink);
end;

// The app's fonts, loaded from {tmp} for this process only. A loaded font file can't be deleted, so they
// are let go before Setup or the uninstaller removes {tmp}, and never loaded from {app}.
procedure LoadFonts;
begin
  AddFontResourceEx(ExpandConstant('{tmp}\Jersey10-Regular.ttf'), FR_PRIVATE, 0);
  AddFontResourceEx(ExpandConstant('{tmp}\Nunito-Bold.ttf'), FR_PRIVATE, 0);
end;

procedure UnloadFonts;
begin
  RemoveFontResourceEx(ExpandConstant('{tmp}\Jersey10-Regular.ttf'), FR_PRIVATE, 0);
  RemoveFontResourceEx(ExpandConstant('{tmp}\Nunito-Bold.ttf'), FR_PRIVATE, 0);
end;

function Scale: String;
begin
  if ScaleX(100) >= 150 then Result := '2' else Result := '1';
end;

procedure InitializeWizard;
begin
  ExtractTemporaryFile('Jersey10-Regular.ttf');
  ExtractTemporaryFile('Nunito-Bold.ttf');
  LoadFonts;
  Heading(WizardForm.WelcomeLabel1, 24);
  Heading(WizardForm.FinishedHeadingLabel, 24);
  Heading(WizardForm.PageNameLabel, 16);
  WizardForm.WelcomeLabel1.Height := ScaleY(40);
  WizardForm.FinishedHeadingLabel.Height := ScaleY(40);
  WizardForm.WelcomeLabel2.Top := WizardForm.WelcomeLabel1.Top + ScaleY(44);
  WizardForm.FinishedLabel.Top := WizardForm.FinishedHeadingLabel.Top + ScaleY(44);
  WizardForm.PageNameLabel.Top := WizardForm.PageNameLabel.Top - ScaleY(6);
  WizardForm.PageNameLabel.Height := WizardForm.PageNameLabel.Height + ScaleY(8);
  Body(WizardForm.WelcomeLabel2);
  Body(WizardForm.PageDescriptionLabel);
  Body(WizardForm.SelectTasksLabel);
  Body(WizardForm.FilenameLabel);
  Restyle(WizardForm.FinishedLabel, '', 0, Ink);
  Restyle(WizardForm.StatusLabel, '', 0, Ink);
  ExtractTemporaryFile('finish-' + Scale + '.png');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectTasks) and (Chosen = '') then
  begin
    MsgBox(CustomMessage('NoLanguage'), mbInformation, MB_OK);
    Result := False;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpSelectTasks then
    WizardForm.NextButton.Caption := SetupMessage(msgButtonInstall);
  // The finish page's card shows the tray keys.
  if CurPageID = wpFinished then
    WizardForm.WizardBitmapImage2.PngImage.LoadFromFile(ExpandConstant('{tmp}\finish-' + Scale + '.png'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Weasel, Mozc: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  WizardForm.StatusLabel.Caption := CustomMessage('Engines');
  // How the account is before SebType, saved before the engines' installers touch it.
  Step('-User -Save', '-User -Save', '%LOCALAPPDATA%\SebType\setup.log', True);
  if WizardIsTaskSelected('zh') then
  begin
    ExtractTemporaryFile('{#WeaselExe}');
    Weasel := ' -Weasel "' + ExpandConstant('{tmp}\{#WeaselExe}') + '"';
  end;
  if WizardIsTaskSelected('ja') then
  begin
    ExtractTemporaryFile('{#MozcMsi}');
    Mozc := ' -Mozc "' + ExpandConstant('{tmp}\{#MozcMsi}') + '"';
  end;
  Step('-Machine', '-Machine -Languages ' + Chosen + Weasel + Mozc + ' -Log "' + ExpandConstant('{app}\setup.log') + '"',
    ExpandConstant('{app}\setup.log'), False);
  // The account of the person who started Setup, not the administrator's it may run as.
  WizardForm.StatusLabel.Caption := CustomMessage('Account');
  Step('-User', '-User -Languages ' + Chosen, '%LOCALAPPDATA%\SebType\setup.log', True);
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := FailCode;
end;

procedure DeinitializeSetup;
begin
  UnloadFonts;
end;

procedure InitializeUninstallProgressForm;
var
  Look: String;
  Cloth: TBitmapImage;
begin
  Look := ExpandConstant('{app}\look');
  UninstallProgressForm.WizardSmallBitmapImage.PngImage.LoadFromFile(Look + '\small-' + Scale + '.png');
  Cloth := TBitmapImage.Create(UninstallProgressForm);
  Cloth.PngImage.LoadFromFile(Look + '\cloth.png');
  WizardSetBackImage([Cloth.PngImage], True, True, 255);
  FileCopy(Look + '\Jersey10-Regular.ttf', ExpandConstant('{tmp}\Jersey10-Regular.ttf'), False);
  FileCopy(Look + '\Nunito-Bold.ttf', ExpandConstant('{tmp}\Nunito-Bold.ttf'), False);
  LoadFonts;
  Heading(UninstallProgressForm.PageNameLabel, 16);
  UninstallProgressForm.PageNameLabel.Top := UninstallProgressForm.PageNameLabel.Top - ScaleY(6);
  UninstallProgressForm.PageNameLabel.Height := UninstallProgressForm.PageNameLabel.Height + ScaleY(8);
  Body(UninstallProgressForm.PageDescriptionLabel);
  Restyle(UninstallProgressForm.StatusLabel, '', 0, Ink);
end;

// The uninstaller runs elevated as the person removing SebType, whose account it puts back. The engines
// go first: removing Mozc adds an empty Japanese to the account's languages, and a running Weasel or
// Mozc writes its folder again, so the account is put back only once they are gone.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usUninstall then
    Exit;
  UninstallProgressForm.StatusLabel.Caption := CustomMessage('Undoing');
  UninstallProgressForm.ProgressBar.Position := UninstallProgressForm.ProgressBar.Max div 3;
  Step('-Machine -Undo', '-Machine -Undo -Log "' + ExpandConstant('{app}\setup.log') + '"', ExpandConstant('{app}\setup.log'), False);
  UninstallProgressForm.ProgressBar.Position := UninstallProgressForm.ProgressBar.Max * 2 div 3;
  Step('-User -Undo', '-User -Undo', '%LOCALAPPDATA%\SebType\setup.log', False);
end;

procedure DeinitializeUninstall;
begin
  UnloadFonts;
end;
