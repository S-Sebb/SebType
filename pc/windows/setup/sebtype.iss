; SebType's Windows installer (#73): one SebType-setup-<version>.exe that installs, upgrades and
; uninstalls everything SebType needs on Windows, in the Picnic look (Decisions #2). Built by
; .github/workflows/windows-setup.yml:
;   ISCC /DIn=<folder of the workflow's artifacts> [/DBuild=<n>] pc/windows/setup/sebtype.iss
; It installs SebType's text service and server (windows/, #190) with librime, Rime's shared data and
; Mozc (sebtype-mozc.dll, which the server runs, #233). The steps themselves are setup.ps1's: -Machine (elevated) removes the Weasel and Mozc
; that SebType installed before #190, -User (as the person who runs Setup) sets up their account. Why each step
; exists: ../README.md.

; The version is SebType's one version, the phone's too (VERSION, #420).
#define VersionFile FileOpen(SourcePath + "\..\..\..\VERSION")
#define Version Trim(FileRead(VersionFile))
#expr FileClose(VersionFile)
#ifndef Build
  #define Build "0"
#endif
#ifndef In
  #error /DIn=<folder with the artifacts of windows-setup.yml> is required
#endif
#define Pictures In + "\setup-pictures"
#define Repo SourcePath + "\..\..\.."

#define Service In + "\sebtype-service"
#if !FileExists(Service + "\sebtype-server.exe") || !FileExists(Service + "\x86\sebtype.dll")
  #error SebType's text service (windows/build.ps1) is missing from /DIn
#endif
#define Rime In + "\sebtype-rime"
#if !FileExists(Rime + "\rime.dll")
  #error SebType's librime (pc/windows/rime/build.ps1) is missing from /DIn
#endif
#if !FileExists(In + "\mozc\sebtype-mozc.dll")
  #error Mozc (pc/windows/mozc/build.ps1) is missing from /DIn\mozc
#endif

; Python's embeddable package, for the Configurator's sync (#180): python.ps1 puts it in In\python.
#define PythonDir In + "\python"
#if !FileExists(PythonDir + "\python.exe")
  #error No Python's embeddable package in In\python: run python.ps1 -Dir <In>\python first
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
; Windows loads text services registered for the whole PC only, so SebType installs as admin.
PrivilegesRequired=admin
; Apps keep the text service loaded; PrepareToInstall moves it aside instead of asking to close them.
CloseApplications=no
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
en.WelcomeLabel2=SebType types Chinese, Japanese and English on this PC, just like on your phone.%n%nIt sets up Chinese (Rime with SebType's dictionary), Japanese (SebType's Mozc) and the SebType Configurator, and makes Win+Space the one key that switches language.%n%nAlready have SebType? This updates it and keeps every word it has learned.
zh.WelcomeLabel2=SebType 让这台电脑像你的手机一样输入中文、日本語和英文。%n%n它会装好中文（Rime 和 SebType 的词库）、日本語（SebType 的 Mozc）和 SebType 设置，并让 Win+Space 成为切换语言的唯一按键。%n%n已经装过 SebType？这次会更新它，并保留它学会的每一个词。
ja.WelcomeLabel2=SebType で、この PC でもスマホと同じように中国語・日本語・英語を入力できます。%n%n中国語（Rime と SebType の辞書）、日本語（SebType の Mozc）と SebType 設定をインストールし、言語の切り替えを Win+Space ひとつにします。%n%nSebType をもうお使いですか？アップデートしても、覚えた言葉はそのまま残ります。
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
en.Chinese=中文 Chinese (Rime with SebType's dictionary)
zh.Chinese=中文（Rime 和 SebType 的词库）
ja.Chinese=中文 中国語（Rime と SebType の辞書）
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
en.Kept=SebType couldn't send the words it learned on this PC to your sync server, so it kept them in %1.%n%nThey come back when you set up SebType with that language again.
zh.Kept=SebType 没能把它在这台电脑上学会的词发到你的同步服务器，所以把它们留在了 %1。%n%n下次装 SebType 时选上这个语言，它们就会回来。
ja.Kept=この PC で SebType が覚えた言葉を同期サーバーに送れなかったので、%1 に残しました。%n%nもう一度その言語で SebType をセットアップすると戻ります。
en.SyncTitle=Account sync
zh.SyncTitle=账号同步
ja.SyncTitle=アカウント同期
en.SyncDesc=Optional. You can also set this up later in SebType Configurator.
zh.SyncDesc=可选。也可以稍后在 SebType 设置里开启。
ja.SyncDesc=任意です。あとから SebType 設定で有効にすることもできます。
en.SyncSub=Sync your learned words and dictionaries across devices with your own sync server. Leave all fields blank to skip.
zh.SyncSub=通过你自己的同步服务器，在多台设备间同步学到的词和自定义词库。全部留空即可跳过。
ja.SyncSub=自分の同期サーバーを使って、学習した単語やユーザー辞書を端末間で同期できます。すべて空欄のまま［次へ］でスキップできます。
en.SyncServer=Server address (sync.example.com):
zh.SyncServer=服务器地址（sync.example.com）：
ja.SyncServer=サーバーアドレス（sync.example.com）：
en.SyncUser=Username:
zh.SyncUser=用户名：
ja.SyncUser=ユーザー名：
en.SyncPassword=Password:
zh.SyncPassword=密码：
ja.SyncPassword=パスワード：
en.SyncIncomplete=Fill in server, username, and password, or leave all three blank to skip.
zh.SyncIncomplete=请填全服务器地址、用户名和密码，或全部留空以跳过。
ja.SyncIncomplete=サーバーアドレス・ユーザー名・パスワードをすべて入力するか、すべて空欄にしてスキップしてください。
en.SyncInvalidServer=Server address must be an https:// address.
zh.SyncInvalidServer=服务器地址必须是 https:// 网址。
ja.SyncInvalidServer=サーバーアドレスは https:// のアドレスにしてください。
en.SyncSaveFailed=Could not save your sync login. Check your details or clear the fields to skip.
zh.SyncSaveFailed=无法保存同步账号。请检查填写的内容，或清空后跳过。
ja.SyncSaveFailed=同期アカウントを保存できませんでした。入力内容を確認するか、空欄にしてスキップしてください。

[Tasks]
Name: "en"; Description: "{cm:English}"; GroupDescription: "{cm:Languages}"
Name: "zh"; Description: "{cm:Chinese}"; GroupDescription: "{cm:Languages}"
Name: "ja"; Description: "{cm:Japanese}"; GroupDescription: "{cm:Languages}"
Name: "desktopicon"; Description: "{cm:Desktop}"; GroupDescription: "{cm:Shortcuts}"; Flags: unchecked

[Files]
Source: "setup.ps1"; DestDir: "{app}"; Flags: ignoreversion
; The Configurator's update (#422): the person's side and the admin side, run from here, where only admins write.
Source: "update-user.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "start-setup.ps1"; DestDir: "{app}"; Flags: ignoreversion
; The text service (64-bit, and 32-bit for 32-bit apps), its server, librime with Rime's shared data, and
; Mozc. An app that has the text service loaded keeps it until it closes.
Source: "{#Service}\sebtype-server.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Service}\sebtype.dll"; DestDir: "{app}"; Flags: ignoreversion regserver
Source: "{#Service}\x86\sebtype.dll"; DestDir: "{app}\x86"; Flags: ignoreversion regserver 32bit
Source: "{#Rime}\rime.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Rime}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs
Source: "{#In}\mozc\sebtype-mozc.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Repo}\pc\linux\mozc-keymap.tsv"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#In}\rime-data\rime-data.zip"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#In}\sebtype-configurator\sebtype-configurator.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PythonDir}\*"; DestDir: "{app}\python"; Flags: ignoreversion recursesubdirs
Source: "{#Pictures}\sebtype.ico"; DestDir: "{app}"; Flags: ignoreversion
; The uninstaller's look: it runs from {app}, without Setup's own files.
Source: "{#Pictures}\cloth.png"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Pictures}\small-1.png"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Pictures}\small-2.png"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Repo}\art\fonts\Jersey10-Regular.ttf"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Repo}\art\fonts\Nunito-Bold.ttf"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Repo}\art\fonts\OFL-Jersey10.txt"; DestDir: "{app}\look"; Flags: ignoreversion
Source: "{#Repo}\art\fonts\OFL-Nunito.txt"; DestDir: "{app}\look"; Flags: ignoreversion
; Setup's own, unpacked when needed.
Source: "{#Repo}\art\fonts\Jersey10-Regular.ttf"; Flags: dontcopy
Source: "{#Repo}\art\fonts\Nunito-Bold.ttf"; Flags: dontcopy
Source: "{#Pictures}\finish-1.png"; Flags: dontcopy
Source: "{#Pictures}\finish-2.png"; Flags: dontcopy

[Icons]
; The update's toast (#422) shows under this shortcut's AppUserModelID (windows.rs, AUMID).
Name: "{autoprograms}\{cm:Configurator}"; Filename: "{app}\sebtype-configurator.exe"; IconFilename: "{app}\sebtype.ico"; AppUserModelID: "SebType.Configurator"
Name: "{autodesktop}\{cm:Configurator}"; Filename: "{app}\sebtype-configurator.exe"; IconFilename: "{app}\sebtype.ico"; Tasks: desktopicon

[Registry]
; The server starts at logon, as each user; the text service also starts it when it isn't running.
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "SebType"; ValueData: """{app}\sebtype-server.exe"""; Flags: uninsdeletevalue

; A click on the update's toast (#422) opens sebtype-configurator:update: the Configurator's About page.
Root: HKLM; Subkey: "Software\Classes\sebtype-configurator"; ValueType: string; ValueData: "URL:SebType Configurator"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\sebtype-configurator"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKLM; Subkey: "Software\Classes\sebtype-configurator\shell\open\command"; ValueType: string; ValueData: """{app}\sebtype-configurator.exe"" --update"

[Run]
Filename: "{app}\sebtype-configurator.exe"; Description: "{cm:OpenConfigurator}"; Flags: nowait postinstall skipifsilent

; What SebType installed before #233 for Mozc's own server (its C++ runtime too), left by PrepareToInstall
; where it was still loaded.
[InstallDelete]
Type: files; Name: "{app}\mozc_server.exe*"
Type: files; Name: "{app}\msvcp140*.dll*"
Type: files; Name: "{app}\vcruntime140*.dll*"

[UninstallDelete]
; the update's checked copies of Setup (#422, start-setup.ps1)
Type: filesandordirs; Name: "{app}\updates"
Type: files; Name: "{app}\setup.log"
Type: files; Name: "{app}\sebtype.dll.*.old"
Type: files; Name: "{app}\x86\sebtype.dll.*.old"
Type: files; Name: "{app}\sebtype-server.exe.*.old"
Type: files; Name: "{app}\rime.dll.*.old"
Type: files; Name: "{app}\sebtype-mozc.dll.*.old"
Type: files; Name: "{app}\mozc_server.exe.*.old"
Type: files; Name: "{app}\msvcp140*.dll.*.old"
Type: files; Name: "{app}\vcruntime140*.dll.*.old"

[Code]
const
  Ink = $222F4A;    // Picnic's ink #4A2F22 and key berry #C2506A, as TColor ($BBGGRR)
  Berry = $6A50C2;
  FR_PRIVATE = $10;

var
  FailCode: Integer;
  SyncPage: TInputQueryWizardPage;

function AddFontResourceEx(Name: String; Flags: Cardinal; Reserved: Cardinal): Integer;
  external 'AddFontResourceExW@gdi32.dll stdcall';
function RemoveFontResourceEx(Name: String; Flags: Cardinal; Reserved: Cardinal): Integer;
  external 'RemoveFontResourceExW@gdi32.dll stdcall';
function MoveFileEx(Existing: String; New: String; Flags: Cardinal): Boolean;
  external 'MoveFileExW@kernel32.dll stdcall';

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

// A silent Setup or uninstall shows no message: /VERYSILENT without /SUPPRESSMSGBOXES still shows a
// SuppressibleMsgBox, which nobody can click when Setup runs in session 0, so Setup would never exit (#311).
function Silent: Boolean;
begin
  if IsUninstaller then
    Result := UninstallSilent
  else
    Result := WizardSilent;
end;

procedure Tell(Text: String; Typ: TMsgBoxType);
begin
  Log(Text);
  if not Silent then
    MsgBox(Text, Typ, MB_OK);
end;

// /NOUSERSTEPS: the Configurator's update (#422, update-user.ps1) runs Setup elevated, so the original
// user may be the administrator who approved UAC; it runs the person's steps itself, as them.
function NoUserSteps: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/NOUSERSTEPS') = 0 then
      Result := True;
end;

// Runs a setup.ps1 step; on failure says so (logged only in a silent run) and makes Setup's exit code 1.
procedure Step(Name, Arguments, LogFile: String; AsOriginalUser: Boolean);
var
  Code: Integer;
  Ok: Boolean;
begin
  if AsOriginalUser then
    Ok := ExecAsOriginalUser('powershell.exe', PowerShell(Arguments), '', SW_HIDE, ewWaitUntilTerminated, Code)
  else
    Ok := Exec('powershell.exe', PowerShell(Arguments), '', SW_HIDE, ewWaitUntilTerminated, Code);
  // 2: done, but learned words the sync couldn't send were kept rather than deleted (setup.ps1, #271).
  if Ok and (Code = 2) then
    Tell(FmtMessage(CustomMessage('Kept'), ['%LOCALAPPDATA%\SebType\unsynced']), mbInformation)
  else if not Ok or (Code <> 0) then
  begin
    Log(Format('setup.ps1 %s failed: %d', [Arguments, Code]));
    FailCode := 1;
    Tell(FmtMessage(CustomMessage('Failed'), [Name, IntToStr(Code), LogFile]), mbError);
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
  SyncPage := CreateInputQueryPage(wpInstalling, CustomMessage('SyncTitle'), CustomMessage('SyncDesc'), CustomMessage('SyncSub'));
  SyncPage.Add(CustomMessage('SyncServer'), False);
  SyncPage.Add(CustomMessage('SyncUser'), False);
  SyncPage.Add(CustomMessage('SyncPassword'), True);
  Body(SyncPage.SubCaptionLabel);
  Body(SyncPage.PromptLabels[0]);
  Body(SyncPage.PromptLabels[1]);
  Body(SyncPage.PromptLabels[2]);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = SyncPage.ID) and (Silent or NoUserSteps or (FailCode <> 0));
end;

// Resolves the invoking desktop user's %LOCALAPPDATA% so a cross-account UAC elevation writes the
// short-lived credential handoff inside that user's own private profile directory (readable only by
// that user, Administrators and SYSTEM). Falls back to {localappdata} when the same account elevated.
function OriginalLocalAppData: String;
var
  OutFile: String;
  QuotedOut: String;
  Cmd: String;
  Code: Integer;
  Lines: TArrayOfString;
  Sid: String;
  ProfileDir: String;
begin
  Result := ExpandConstant('{localappdata}');
  OutFile := ExpandConstant('{tmp}\orig-sid.txt');
  QuotedOut := OutFile;
  StringChangeEx(QuotedOut, '''', '''''', True);
  DeleteFile(OutFile);
  Cmd := '-NoProfile -NonInteractive -Command "' +
    '$sid = (Get-CimInstance Win32_Process -Filter (''Name=''''explorer.exe'''' AND SessionId='' + (Get-Process -Id $PID).SessionId) | ' +
    'Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwnerSid).Sid; ' +
    'if ($sid) { [IO.File]::WriteAllText(''' + QuotedOut + ''', $sid, [Text.Encoding]::ASCII) }"';
  if Exec('powershell.exe', Cmd, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) and
     LoadStringsFromFile(OutFile, Lines) and (GetArrayLength(Lines) > 0) then
  begin
    Sid := Trim(Lines[0]);
    if (Sid <> '') and
       RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + Sid, 'ProfileImagePath', ProfileDir) and
       (ProfileDir <> '') and DirExists(ProfileDir + '\AppData\Local') then
      Result := ProfileDir + '\AppData\Local';
  end;
  DeleteFile(OutFile);
end;

// Saves the sync login as the invoking user via a short-lived file (never on the command line or in logs).
function SaveSyncLogin(Server, User, Password: String): Boolean;
var
  CredFile: String;
  Lines: TArrayOfString;
  Code: Integer;
  Ok: Boolean;
begin
  Result := False;
  CredFile := OriginalLocalAppData + '\SebType\sync-login.tmp';
  ForceDirectories(ExtractFileDir(CredFile));
  SetArrayLength(Lines, 3);
  Lines[0] := Server;
  Lines[1] := User;
  Lines[2] := Password;
  Ok := False;
  try
    if not SaveStringsToUTF8FileWithoutBOM(CredFile, Lines, False) then
    begin
      Tell(CustomMessage('SyncSaveFailed'), mbError);
      Exit;
    end;
    Ok := ExecAsOriginalUser(ExpandConstant('{app}\sebtype-configurator.exe'),
      '--sync-login-file "' + CredFile + '"', '', SW_HIDE, ewWaitUntilTerminated, Code);
  finally
    DeleteFile(CredFile);
  end;
  if Ok and (Code = 0) then
    Result := True
  else if Ok and (Code = 2) then
    Tell(CustomMessage('SyncInvalidServer'), mbError)
  else
    Tell(CustomMessage('SyncSaveFailed'), mbError);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  S, U, P: String;
begin
  Result := True;
  if (CurPageID = wpSelectTasks) and (Chosen = '') then
  begin
    Tell(CustomMessage('NoLanguage'), mbInformation);
    Result := False;
  end
  else if CurPageID = SyncPage.ID then
  begin
    S := Trim(SyncPage.Values[0]);
    U := Trim(SyncPage.Values[1]);
    P := SyncPage.Values[2];
    if (S = '') and (U = '') and (P = '') then
      Exit;
    if (S = '') or (U = '') or (P = '') then
    begin
      Tell(CustomMessage('SyncIncomplete'), mbInformation);
      Result := False;
      Exit;
    end;
    if SaveSyncLogin(S, U, P) then
      SyncPage.Values[2] := ''
    else
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

// The servers stop so their files can be replaced: SebType's saves the learned words first, for the
// person running Setup (the uninstaller runs as them, and can't run anything as the original user);
// other users' stop as they are (Rime writes learned words as they come).
procedure StopServers(AsOriginalUser: Boolean);
var
  Code: Integer;
begin
  // With /NOUSERSTEPS the person's own server has saved and quit already (update-user.ps1).
  if FileExists(ExpandConstant('{app}\sebtype-server.exe')) and not (AsOriginalUser and NoUserSteps) then
    if AsOriginalUser then
      ExecAsOriginalUser(ExpandConstant('{app}\sebtype-server.exe'), '/quit', '', SW_HIDE, ewWaitUntilTerminated, Code)
    else
      Exec(ExpandConstant('{app}\sebtype-server.exe'), '/quit', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec('taskkill.exe', '/f /im sebtype-server.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Log('taskkill sebtype-server.exe: ' + IntToStr(Code));  // 0 stopped, 128 none running
  // Mozc's own server, from SebType before #233: SebType's /quit above had it save the learned words.
  Exec('taskkill.exe', '/f /im mozc_server.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Log('taskkill mozc_server.exe: ' + IntToStr(Code));
end;
// A loaded file can't be replaced but can be renamed: the new one goes in its place, apps load it when they
// next start, and the next Setup deletes the old one. Servers count too: a running app's text service starts
// its server again at its next key. Not deleted at the next restart: a rename pending in its folder makes
// the next Setup ask for a restart first.
procedure MoveAside(Path: String);
var
  Old: String;
  N: Integer;
begin
  if not FileExists(Path) then
    Exit;
  N := 0;
  repeat
    N := N + 1;
    Old := Path + '.' + IntToStr(N) + '.old';
  until not FileExists(Old) or DeleteFile(Old);
  if not RenameFile(Path, Old) then
    Log('could not move aside ' + Path);
end;
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopServers(True);
  MoveAside(ExpandConstant('{app}\sebtype.dll'));
  MoveAside(ExpandConstant('{app}\x86\sebtype.dll'));
  MoveAside(ExpandConstant('{app}\sebtype-server.exe'));
  MoveAside(ExpandConstant('{app}\rime.dll'));
  MoveAside(ExpandConstant('{app}\sebtype-mozc.dll'));
  // Mozc's own server and its C++ runtime, from SebType before #233 ([InstallDelete] deletes them)
  MoveAside(ExpandConstant('{app}\mozc_server.exe'));
  MoveAside(ExpandConstant('{app}\msvcp140.dll'));
  MoveAside(ExpandConstant('{app}\msvcp140_1.dll'));
  MoveAside(ExpandConstant('{app}\msvcp140_2.dll'));
  MoveAside(ExpandConstant('{app}\vcruntime140.dll'));
  MoveAside(ExpandConstant('{app}\vcruntime140_1.dll'));
  Result := '';
end;
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then
    Exit;
  WizardForm.StatusLabel.Caption := CustomMessage('Engines');
  StopServers(True);  // one an app started again from the old files since PrepareToInstall
  // How the account is before SebType, saved before the machine step changes it.
  if not NoUserSteps then
    Step('-User -Save', '-User -Save', '%LOCALAPPDATA%\SebType\setup.log', True);
  Step('-Machine', '-Machine -Languages ' + Chosen + ' -Log "' + ExpandConstant('{app}\setup.log') + '"',
    ExpandConstant('{app}\setup.log'), False);
  // The account of the person who started Setup, not the administrator's it may run as.
  if NoUserSteps then
    Exit;
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

// What apps still have loaded (the text service, until they close) goes to %TEMP%, as a rename on the same
// drive can: no restart, and nothing pending in the folder to stop a new Setup.
procedure MoveOut(Dir: String);
var
  F: TFindRec;
  N: Integer;
begin
  N := 0;
  if FindFirst(Dir + '\*', F) then
    try
      repeat
        if (F.Attributes and FILE_ATTRIBUTE_DIRECTORY = 0) and (Pos('unins', F.Name) <> 1) and
           not DeleteFile(Dir + '\' + F.Name) then
        begin
          N := N + 1;
          if not RenameFile(Dir + '\' + F.Name, ExpandConstant('{%TEMP}\SebType-') +
              GetDateTimeString('yyyymmddhhnnss', #0, #0) + '-' + IntToStr(N) + '-' + F.Name) then
            Log('could not move out ' + Dir + '\' + F.Name);
        end;
      until not FindNext(F);
    finally
      FindClose(F);
    end;
end;

// The text service an app has loaded can't be deleted, which the uninstaller would report as not removed: it
// moves out to %TEMP% where the app keeps it, and an unloaded copy takes its place for the uninstaller to
// unregister and delete. Where no app has it, the moved one is deleted at once.
procedure MoveOutLoaded(Path, Tag: String);
var
  Old: String;
begin
  Old := ExpandConstant('{%TEMP}\SebType-') + GetDateTimeString('yyyymmddhhnnss', #0, #0) + '-' + Tag + ExtractFileName(Path);
  if FileExists(Path) and RenameFile(Path, Old) then begin
    if not FileCopy(Old, Path, False) then
      Log('could not copy back ' + Path);
    DeleteFile(Old);
  end;
end;

// The uninstaller runs elevated as the person removing SebType, whose account it puts back. The servers
// stop first: a running one writes its folder again, so the account is put back only once they are gone.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then begin
    StopServers(False);
    DeleteFile(ExpandConstant('{app}\uninstalling'));
    MoveOut(ExpandConstant('{app}\x86'));
    MoveOut(ExpandConstant('{app}'));
    // The uninstaller tried to remove {app} before this step, while those files were still in it.
    RemoveDir(ExpandConstant('{app}\x86'));
    RemoveDir(ExpandConstant('{app}'));
  end;
  if CurUninstallStep <> usUninstall then
    Exit;
  UninstallProgressForm.StatusLabel.Caption := CustomMessage('Undoing');
  // Apps' text services start no server from here on (an app did while the account was put back, and the
  // server and Mozc's were running when their files were deleted).
  SaveStringToFile(ExpandConstant('{app}\uninstalling'), '', False);
  StopServers(False);
  UninstallProgressForm.ProgressBar.Position := UninstallProgressForm.ProgressBar.Max div 3;
  Step('-Machine -Undo', '-Machine -Undo -Log "' + ExpandConstant('{app}\setup.log') + '"', ExpandConstant('{app}\setup.log'), False);
  UninstallProgressForm.ProgressBar.Position := UninstallProgressForm.ProgressBar.Max * 2 div 3;
  Step('-User -Undo', '-User -Undo', '%LOCALAPPDATA%\SebType\setup.log', False);
  StopServers(False);
  MoveOutLoaded(ExpandConstant('{app}\sebtype.dll'), '');
  MoveOutLoaded(ExpandConstant('{app}\x86\sebtype.dll'), 'x86-');
end;

procedure DeinitializeUninstall;
begin
  UnloadFonts;
end;
