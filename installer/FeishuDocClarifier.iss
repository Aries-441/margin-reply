; 飞书文档评论机器人 Windows 安装包
; 构建：在仓库根目录运行 powershell -ExecutionPolicy Bypass -File .\build-installer.ps1
; 产物：installer\Output\FeishuDocClarifier-Setup-<版本>.exe

#define MyAppName "飞书文档评论机器人"
#define MyAppNameEn "Feishu Doc Clarifier"
#define MyAppPublisher "Feishu Doc Clarifier"
#define MyAppURL "https://open.feishu.cn/app"
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#define MyAppId "{{8E2F6A31-6C4B-4D7E-9C1A-2F5B7D9E4A63}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={localappdata}\FeishuDocClarifier
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
MinVersion=10.0
OutputDir=Output
OutputBaseFilename=FeishuDocClarifier-Setup-{#MyAppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={sys}\WindowsPowerShell\v1.0\powershell.exe
; 不默认写安装日志：静默安装的参数（含密钥）会出现在日志的命令行里。
; 需要排查时手动加 /LOG="路径"。

[Languages]
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"

[Tasks]
; 不用 checkedonce：升级时 Inno 会把它自动取消勾选，导致升级后自启任务被删。
; 默认勾选 + UsePreviousTasks（默认开启）会沿用上一次安装的选择。
Name: "autostart"; Description: "登录 Windows 后自动启动机器人（推荐）"; GroupDescription: "启动选项："

[Files]
; build\app 由 build-installer.ps1 生成：项目文件 + 内置 Python runtime。
Source: "build\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Dirs]
Name: "{app}\logs"

[Icons]
Name: "{group}\启动机器人"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\run.ps1"""; WorkingDir: "{app}"; Comment: "立即启动飞书文档评论机器人"
Name: "{group}\查看机器人日志"; Filename: "{win}\explorer.exe"; Parameters: """{app}\logs"""; Comment: "打开日志目录，bot.log 和 runner.log 都在这里"
Name: "{group}\飞书应用配置指南"; Filename: "{sys}\notepad.exe"; Parameters: """{app}\docs\feishu-setup.md"""; Comment: "首次使用前在飞书开放平台完成配置"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
; 未勾选登录自启时，从完成页直接后台启动机器人。
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\run.ps1"""; Description: "立即启动机器人"; Flags: nowait postinstall skipifsilent runhidden; Check: NotAutoStart

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall-task.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "StopBotAndTask"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\__pycache__"
Type: filesandordirs; Name: "{app}\runtime"
Type: files; Name: "{app}\.env"
Type: files; Name: "{app}\.seen_events.json"
Type: files; Name: "{app}\.stop-runner"

[Code]
var
  SetupInfoPage: TWizardPage;
  CredPage: TInputQueryWizardPage;
  BackendPage: TWizardPage;
  DeepSeekPage: TInputQueryWizardPage;
  CliPage: TInputQueryWizardPage;
  RadioDeepSeek: TNewRadioButton;
  RadioClaude: TNewRadioButton;
  RadioCodex: TNewRadioButton;
  RadioCustom: TNewRadioButton;
  OpenConsoleButton: TNewButton;
  LastBackend: Integer;
  Prefilled: Boolean;
  OriginalBackend: String;
  ExistingTrustMode: String;
  ExistingAllowedUsers: String;

procedure OpenFeishuConsole(Sender: TObject);
var
  ErrorCode: Integer;
begin
  ShellExec('open', 'https://open.feishu.cn/app', '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
end;

function ReadEnvValue(const Name: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Prefix, Line: String;
begin
  Result := '';
  if not LoadStringsFromFile(ExpandConstant('{app}\.env'), Lines) then
    Exit;
  Prefix := Name + '=';
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    Line := Lines[I];
    if Copy(Line, 1, Length(Prefix)) = Prefix then
    begin
      Result := Copy(Line, Length(Prefix) + 1, Length(Line));
      Exit;
    end;
  end;
end;

function CurrentBackendIndex: Integer;
begin
  if RadioClaude.Checked then
    Result := 1
  else if RadioCodex.Checked then
    Result := 2
  else if RadioCustom.Checked then
    Result := 3
  else
    Result := 0;
end;

procedure PrefillFromExisting;
var
  ExistingBackend, ExistingCommand, ParamValue: String;
begin
  if Prefilled then
    Exit;
  Prefilled := True;

  // 先读旧配置做默认值，再让命令行参数覆盖（供静默部署使用）。
  CredPage.Values[0] := Trim(ReadEnvValue('FEISHU_COMMENT_BOT_APP_ID'));
  CredPage.Values[1] := Trim(ReadEnvValue('FEISHU_COMMENT_BOT_APP_SECRET'));
  OriginalBackend := Trim(ReadEnvValue('FEISHU_COMMENT_BOT_AGENT_BACKEND'));
  ExistingBackend := Lowercase(OriginalBackend);
  if ExistingBackend = 'claude' then
    RadioClaude.Checked := True
  else if ExistingBackend = 'codex' then
    RadioCodex.Checked := True
  else if (ExistingBackend <> '') and (ExistingBackend <> 'deepseek') then
  begin
    // .env 里是自定义命令（README 允许任意命令），原样保留，别改成 deepseek。
    RadioCustom.Caption := '保留 .env 中的自定义后端（' + OriginalBackend + '）';
    RadioCustom.Visible := True;
    RadioCustom.Checked := True;
  end;

  ExistingCommand := Trim(ReadEnvValue('FEISHU_COMMENT_BOT_AGENT_COMMAND'));
  if ExistingCommand <> '' then
    CliPage.Values[0] := ExistingCommand
  else if RadioCodex.Checked then
    CliPage.Values[0] := 'codex';

  DeepSeekPage.Values[0] := ReadEnvValue('FEISHU_COMMENT_BOT_DEEPSEEK_API_KEY');
  if ReadEnvValue('FEISHU_COMMENT_BOT_DEEPSEEK_MODEL') <> '' then
    DeepSeekPage.Values[1] := ReadEnvValue('FEISHU_COMMENT_BOT_DEEPSEEK_MODEL');

  // 信任策略原样保留：升级不能把 allowlist 改回 owner。
  ExistingTrustMode := Trim(ReadEnvValue('FEISHU_COMMENT_BOT_TRUST_MODE'));
  ExistingAllowedUsers := Trim(ReadEnvValue('FEISHU_COMMENT_BOT_ALLOWED_USERS'));

  // 命令行参数：/APPID= /APPSECRET= /BACKEND=deepseek|claude|codex /CLICOMMAND= /DEEPSEEKKEY= /DEEPSEEKMODEL=
  ParamValue := Trim(ExpandConstant('{param:APPID|}'));
  if ParamValue <> '' then
    CredPage.Values[0] := ParamValue;
  ParamValue := Trim(ExpandConstant('{param:APPSECRET|}'));
  if ParamValue <> '' then
    CredPage.Values[1] := ParamValue;

  ParamValue := Lowercase(Trim(ExpandConstant('{param:BACKEND|}')));
  if ParamValue = 'claude' then
  begin
    RadioClaude.Checked := True;
    // 静默安装不会经过「选择后端」页，这里补上命令默认值。
    if Trim(ExpandConstant('{param:CLICOMMAND|}')) = '' then
      CliPage.Values[0] := 'claude';
  end
  else if ParamValue = 'codex' then
  begin
    RadioCodex.Checked := True;
    if Trim(ExpandConstant('{param:CLICOMMAND|}')) = '' then
      CliPage.Values[0] := 'codex';
  end
  else if ParamValue = 'deepseek' then
    RadioDeepSeek.Checked := True
  else if ParamValue <> '' then
  begin
    // /BACKEND=任意命令：按自定义后端原样写回。
    OriginalBackend := Trim(ExpandConstant('{param:BACKEND|}'));
    RadioCustom.Caption := '保留 .env 中的自定义后端（' + OriginalBackend + '）';
    RadioCustom.Visible := True;
    RadioCustom.Checked := True;
  end;

  ParamValue := Trim(ExpandConstant('{param:CLICOMMAND|}'));
  if ParamValue <> '' then
    CliPage.Values[0] := ParamValue;
  ParamValue := Trim(ExpandConstant('{param:DEEPSEEKKEY|}'));
  if ParamValue <> '' then
    DeepSeekPage.Values[0] := ParamValue;
  ParamValue := Trim(ExpandConstant('{param:DEEPSEEKMODEL|}'));
  if ParamValue <> '' then
    DeepSeekPage.Values[1] := ParamValue;
  ParamValue := Lowercase(Trim(ExpandConstant('{param:TRUSTMODE|}')));
  if ParamValue <> '' then
    ExistingTrustMode := ParamValue;
  ParamValue := Trim(ExpandConstant('{param:ALLOWEDUSERS|}'));
  if ParamValue <> '' then
    ExistingAllowedUsers := ParamValue;

  LastBackend := CurrentBackendIndex;
end;

procedure InitializeWizard;
var
  Memo: TNewMemo;
begin
  // 放在选择安装目录之后，这样预填时可以安全读取 {app}\.env。
  SetupInfoPage := CreateCustomPage(wpSelectDir,
    '准备工作：创建飞书应用',
    '机器人需要一个飞书企业自建应用的 App ID 和 App Secret。');

  Memo := TNewMemo.Create(SetupInfoPage);
  Memo.Parent := SetupInfoPage.Surface;
  Memo.SetBounds(0, 0, SetupInfoPage.SurfaceWidth, SetupInfoPage.SurfaceHeight - ScaleY(44));
  Memo.ReadOnly := True;
  Memo.ScrollBars := ssVertical;
  Memo.Font.Name := 'Microsoft YaHei UI';
  Memo.Font.Size := 10;
  Memo.Text :=
    '安装前请先在飞书开放平台创建企业自建应用（约 5 分钟）：' + #13#10 + #13#10 +
    '1. 打开 open.feishu.cn/app，创建「企业自建应用」。' + #13#10 +
    '2. 在「添加应用能力」中启用「机器人」。' + #13#10 +
    '3. 在「事件与回调」中添加事件 drive.notice.comment_add_v1，' + #13#10 +
    '   事件订阅和回调配置都选择「长连接」。' + #13#10 +
    '4. 在「权限管理」中批量导入 docs/feishu-setup.md 列出的 10 项权限。' + #13#10 +
    '5. 在「版本管理与发布」中创建版本并发布（部分企业需要管理员审批）。' + #13#10 +
    '6. 在「凭证与基础信息」中复制 App ID 和 App Secret。' + #13#10 + #13#10 +
    '提示：App Secret 只保存在本机的 .env 文件中，不会上传到任何地方。' + #13#10 +
    '安装完成后，开始菜单里会提供完整的配置指南和日志入口。' + #13#10 + #13#10 +
    '安全：默认只回答文档所有者的 @，其他人的 @ 会被忽略；' + #13#10 +
    '机器人没有提示词注入防护，请只把机器人加进可信的文档。' + #13#10 + #13#10 +
    '已经创建过应用？直接点「下一步」填写凭证即可。';

  OpenConsoleButton := TNewButton.Create(SetupInfoPage);
  OpenConsoleButton.Parent := SetupInfoPage.Surface;
  OpenConsoleButton.SetBounds(0, SetupInfoPage.SurfaceHeight - ScaleY(32), ScaleX(190), ScaleY(28));
  OpenConsoleButton.Caption := '打开飞书开放平台';
  OpenConsoleButton.OnClick := @OpenFeishuConsole;

  CredPage := CreateInputQueryPage(SetupInfoPage.ID,
    '填写飞书应用凭证',
    '在飞书开放平台 → 你的应用 →「凭证与基础信息」中获取这两项。',
    'App Secret 只写入本机安装目录下的 .env 文件。');
  CredPage.Add('App ID（通常以 cli_ 开头）：', False);
  CredPage.Add('App Secret：', True);

  BackendPage := CreateCustomPage(CredPage.ID,
    '选择回答后端',
    '机器人收到 @ 后会调用这个后端生成回答。之后可以修改 .env 更换。');

  RadioDeepSeek := TNewRadioButton.Create(BackendPage);
  RadioDeepSeek.Parent := BackendPage.Surface;
  RadioDeepSeek.SetBounds(0, ScaleY(8), BackendPage.SurfaceWidth, ScaleY(22));
  RadioDeepSeek.Caption := 'DeepSeek API（推荐，开箱即用，按量计费）';
  RadioDeepSeek.Checked := True;

  RadioClaude := TNewRadioButton.Create(BackendPage);
  RadioClaude.Parent := BackendPage.Surface;
  RadioClaude.SetBounds(0, ScaleY(44), BackendPage.SurfaceWidth, ScaleY(22));
  RadioClaude.Caption := '本机 Claude Code CLI（需已安装并登录 claude）';

  RadioCodex := TNewRadioButton.Create(BackendPage);
  RadioCodex.Parent := BackendPage.Surface;
  RadioCodex.SetBounds(0, ScaleY(80), BackendPage.SurfaceWidth, ScaleY(22));
  RadioCodex.Caption := '本机 Codex CLI（需已安装并登录 codex）';

  // 只有升级时 .env 里已经是其它自定义命令才显示，用来原样保留。
  RadioCustom := TNewRadioButton.Create(BackendPage);
  RadioCustom.Parent := BackendPage.Surface;
  RadioCustom.SetBounds(0, ScaleY(116), BackendPage.SurfaceWidth, ScaleY(22));
  RadioCustom.Caption := '保留 .env 中的自定义后端';
  RadioCustom.Visible := False;

  DeepSeekPage := CreateInputQueryPage(BackendPage.ID,
    'DeepSeek 配置',
    'API Key 可在 platform.deepseek.com 的「API keys」页面创建。',
    'Key 只写入本机 .env。');
  DeepSeekPage.Add('DeepSeek API Key：', True);
  DeepSeekPage.Add('模型名：', False);
  DeepSeekPage.Values[1] := 'deepseek-chat';

  CliPage := CreateInputQueryPage(BackendPage.ID,
    '本机 CLI 配置',
    '机器人会执行该命令，并把问题通过 -p 参数传入。',
    '命令可以是命令名，也可以是可执行文件的绝对路径。只支持 .exe：' +
    '.cmd/.bat 会让正文里的特殊字符被命令行重新解析，出于安全原因不执行。');
  CliPage.Add('CLI 命令：', False);
  CliPage.Values[0] := 'claude';

  LastBackend := CurrentBackendIndex;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  // 目录页通过后 {app} 才可用；首次进入配置页时预填旧配置。
  if CurPageID = SetupInfoPage.ID then
    PrefillFromExisting;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = DeepSeekPage.ID then
    Result := not RadioDeepSeek.Checked
  else if PageID = CliPage.ID then
    Result := RadioDeepSeek.Checked;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  BackendIndex: Integer;
begin
  Result := True;

  // 静默安装无人可回答弹窗：缺参数时直接放行，把校验留给首次启动。
  if WizardSilent then
    Exit;

  if CurPageID = CredPage.ID then
  begin
    CredPage.Values[0] := Trim(CredPage.Values[0]);
    CredPage.Values[1] := Trim(CredPage.Values[1]);
    if CredPage.Values[0] = '' then
    begin
      MsgBox('请填写飞书 App ID。', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if CredPage.Values[1] = '' then
    begin
      MsgBox('请填写飞书 App Secret。', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if Pos('cli_', CredPage.Values[0]) <> 1 then
    begin
      if MsgBox('飞书 App ID 通常以 cli_ 开头。仍然继续吗？', mbConfirmation, MB_YESNO) = IDNO then
      begin
        Result := False;
        Exit;
      end;
    end;
  end;

  if CurPageID = BackendPage.ID then
  begin
    BackendIndex := CurrentBackendIndex;
    if BackendIndex <> LastBackend then
    begin
      if BackendIndex = 1 then
        CliPage.Values[0] := 'claude'
      else if BackendIndex = 2 then
        CliPage.Values[0] := 'codex';
      // 自定义后端保留原来的命令，不覆盖。
      LastBackend := BackendIndex;
    end;
  end;

  if CurPageID = DeepSeekPage.ID then
  begin
    DeepSeekPage.Values[0] := Trim(DeepSeekPage.Values[0]);
    DeepSeekPage.Values[1] := Trim(DeepSeekPage.Values[1]);
    if DeepSeekPage.Values[0] = '' then
    begin
      MsgBox('请填写 DeepSeek API Key，或返回上一步改用本机 CLI。', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if DeepSeekPage.Values[1] = '' then
      DeepSeekPage.Values[1] := 'deepseek-chat';
  end;

  if CurPageID = CliPage.ID then
  begin
    CliPage.Values[0] := Trim(CliPage.Values[0]);
    if CliPage.Values[0] = '' then
    begin
      MsgBox('请填写 CLI 命令，例如 claude 或 codex。', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

procedure BuildEnvLines(var Lines: TArrayOfString);
var
  Backend, Command, ApiKey, Model, TrustMode, AllowedUsers: String;
begin
  if RadioDeepSeek.Checked then
    Backend := 'deepseek'
  else if RadioClaude.Checked then
    Backend := 'claude'
  else if RadioCustom.Checked then
    Backend := OriginalBackend
  else
    Backend := 'codex';

  // 两个后端的配置都保留：切换后端时只需改 FEISHU_COMMENT_BOT_AGENT_BACKEND。
  Command := Trim(CliPage.Values[0]);
  ApiKey := Trim(DeepSeekPage.Values[0]);
  Model := Trim(DeepSeekPage.Values[1]);
  if Model = '' then
    Model := 'deepseek-chat';

  TrustMode := Lowercase(Trim(ExistingTrustMode));
  if TrustMode = '' then
    TrustMode := 'owner';
  AllowedUsers := Trim(ExistingAllowedUsers);

  SetArrayLength(Lines, 16);
  Lines[0] := '# 由安装程序生成。修改后重启机器人生效。';
  Lines[1] := '# 环境变量优先于本文件；不要把本文件提交到版本库。';
  Lines[2] := '';
  Lines[3] := 'FEISHU_COMMENT_BOT_APP_ID=' + Trim(CredPage.Values[0]);
  Lines[4] := 'FEISHU_COMMENT_BOT_APP_SECRET=' + Trim(CredPage.Values[1]);
  Lines[5] := '';
  Lines[6] := 'FEISHU_COMMENT_BOT_AGENT_BACKEND=' + Backend;
  Lines[7] := 'FEISHU_COMMENT_BOT_AGENT_COMMAND=' + Command;
  Lines[8] := '';
  Lines[9] := 'FEISHU_COMMENT_BOT_DEEPSEEK_API_KEY=' + ApiKey;
  Lines[10] := 'FEISHU_COMMENT_BOT_DEEPSEEK_MODEL=' + Model;
  Lines[11] := '';
  Lines[12] := '# owner=只回答文档所有者（默认）；allowlist=只回答白名单；any=任何人';
  Lines[13] := 'FEISHU_COMMENT_BOT_TRUST_MODE=' + TrustMode;
  Lines[14] := 'FEISHU_COMMENT_BOT_ALLOWED_USERS=' + AllowedUsers;
  Lines[15] := '';
end;

function SaveEnvFile: Boolean;
var
  Lines: TArrayOfString;
begin
  BuildEnvLines(Lines);
  Result := SaveStringsToUTF8FileWithoutBOM(
    ExpandConstant('{app}\.env'), Lines, False);
end;

function RunAppScript(const ScriptName, ExtraParams: String; var ErrorCode: Integer): Boolean;
var
  PowerShell, Params: String;
begin
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\' + ScriptName) + '"';
  if ExtraParams <> '' then
    Params := Params + ' ' + ExtraParams;
  Result := Exec(PowerShell, Params, ExpandConstant('{app}'), SW_HIDE,
    ewWaitUntilTerminated, ErrorCode);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ErrorCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    // 升级安装前先停掉旧任务和旧机器人，避免文件被占用。
    if FileExists(ExpandConstant('{app}\uninstall-task.ps1')) then
      RunAppScript('uninstall-task.ps1', '-StopOnly', ErrorCode);
  end;

  if CurStep = ssPostInstall then
  begin
    if not SaveEnvFile then
      MsgBox('无法写入 .env 配置文件，请检查安装目录权限。' + #13#10 +
        ExpandConstant('{app}\.env'), mbError, MB_OK);

    if WizardIsTaskSelected('autostart') then
    begin
      if (not RunAppScript('install-task.ps1', '', ErrorCode)) or (ErrorCode <> 0) then
        MsgBox('安装已完成，但注册登录自启任务失败。' + #13#10 +
          '可以手动运行：' + ExpandConstant('{app}\install-task.ps1') + #13#10 +
          '或从开始菜单启动机器人。', mbError, MB_OK);
    end
    else
    begin
      // 用户取消登录自启时，清掉旧版本可能留下的计划任务。
      if FileExists(ExpandConstant('{app}\uninstall-task.ps1')) then
        RunAppScript('uninstall-task.ps1', '', ErrorCode);
    end;
  end;
end;

function NotAutoStart: Boolean;
begin
  Result := not WizardIsTaskSelected('autostart');
end;
