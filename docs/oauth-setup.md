# Gmail / Outlook OAuth 配置指南

邮箱助手不内置任何第三方 OAuth 凭据：Gmail 和 Outlook 登录用的客户端 ID 由你自己在 Google Cloud 或 Microsoft Entra 申请，然后填进本地配置文件。本页说明申请步骤、需要的权限，以及配置文件的填写方式。

## Gmail 的两种登录方式

| | 方式一：应用专用密码 | 方式二：OAuth 2.0（本页其余章节） |
| --- | --- | --- |
| 需要注册应用 | 不需要 | 需要在 Google Cloud 注册 OAuth 客户端 |
| 需要开启的条件 | Google 账号已开启两步验证 | 无（但同意屏幕处于测试状态时需把账号加入测试用户） |
| 客户端保存的内容 | 加密保存 16 位应用专用密码 | 加密保存访问令牌与刷新令牌 |
| 适用场景 | 个人自用、想立刻用起来 | 多用户分发、需要随登录状态自动续期 |

Outlook 只提供 OAuth：Microsoft 已基本关闭基本认证，密码方式无法登录。**Gmail 两种方式都可用**，在添加账户向导第 2 步（「配置账户」页面）顶部的选择器里切换：OAuth 已配置好时默认选中 OAuth，未配置时默认选中应用专用密码。

### 方式一：应用专用密码（推荐个人使用，无需注册）

1. 打开 [Google 账号](https://myaccount.google.com/) →「安全性」，开启**两步验证**（应用专用密码必须先开启两步验证才能生成）。
2. 仍在「安全性」页面，进入「两步验证」，在页面底部选择「**应用专用密码**」；输入一个名称（例如 `邮箱助手`）后点击「创建」。
3. 复制弹出的 **16 位密码**（形如 `abcd efgh ijkl mnop`，空格可以连在一起输入）。弹窗关闭后无法再次查看，可以重新生成一个。
4. 在 Gmail 网页端「设置 → 转发和 POP/IMAP」中确认已**启用 IMAP**，否则连接收件服务器会失败（这一步与 OAuth 方式的要求相同）。
5. 打开邮箱助手 → 账户与设置 → 添加账户 → 选择 **Gmail** → 输入邮箱地址 → 继续 → 在顶部选择「**应用专用密码**」→ 把 16 位密码填进输入框 → 点击「连接」。

应用专用密码的使用范围：它只用于本应用登录 IMAP/SMTP，不能用于登录网页版 Gmail。若密码泄露或不再使用，在 Google 账号的「应用专用密码」列表里删除它即可立即失效，不影响账号主密码。注意它不会像 OAuth 令牌那样自动刷新——在 Google 账号里删除或停用后，需要在应用里删除账户并重新添加。

下面的内容只适用于 **OAuth 方式**。

## 客户端实际使用的协议参数

下面的值都来自 `entry/src/main/ets/service/OAuthService.ets` 的 `configuration()`，申请应用时请以它们为准。

| 项目 | Gmail | Outlook |
| --- | --- | --- |
| 授权端点 | `https://accounts.google.com/o/oauth2/v2/auth` | `https://login.microsoftonline.com/common/oauth2/v2.0/authorize` |
| 令牌端点 | `https://oauth2.googleapis.com/token` | `https://login.microsoftonline.com/common/oauth2/v2.0/token` |
| 授权范围 scope | `openid email https://mail.google.com/` | `offline_access openid email https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send` |
| 回环重定向地址 | `http://127.0.0.1:<随机端口>/oauth/callback` | `http://localhost:<随机端口>/oauth/callback` |
| 收件服务器 | `imap.gmail.com:993` (SSL/TLS) | `outlook.office365.com:993` (SSL/TLS) |
| 发件服务器 | `smtp.gmail.com:587` (STARTTLS) | `smtp.office365.com:587` (STARTTLS) |
| Client Secret | 不需要，留空 | 不需要，留空 |

登录流程是标准的授权码 + PKCE（`code_challenge_method=S256`）：

1. 应用在本机随机端口起一个临时 HTTP 服务，生成 `code_verifier`、`code_challenge` 和 `state`，然后用系统浏览器打开授权页面（Gmail 额外带 `access_type=offline`、`prompt=consent`，Outlook 额外带 `response_mode=query`）。
2. 授权完成后浏览器被重定向到上面的回环地址，应用校验 `state` 并用授权码换取访问令牌和刷新令牌。
3. 回调页会跳转 `mailhelper://oauth/complete` 把应用拉回前台，随后应用用访问令牌登录 IMAP/SMTP 验证服务器设置。

因为回环端口是启动时随机分配的，注册应用时不需要（也做不到）写死端口。

## Google Cloud 配置步骤

1. 打开 [Google Cloud Console](https://console.cloud.google.com/)，新建（或选择）一个项目。
2. 在「API 和服务 → 库」中启用 [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com)。当前版本的邮件收发走 IMAP/SMTP，不直接调用 Gmail API，启用它是为后续切换到 Gmail API 同步留出余地，也让项目与 `https://mail.google.com/` 这个受限范围对应起来。
3. 配置 OAuth 同意屏幕（「API 和服务 → OAuth 同意屏幕」）：
   - User Type 选 **External**（外部）。
   - 必填项只有应用名称和用户支持邮箱，其余可留空。
   - 保存后项目处于 **测试（Testing）** 发布状态。测试状态下，**只有被添加为测试用户的 Google 账号才能完成授权**，请在「测试用户」里加入你要登录的 Gmail 地址（最多 100 个）。若要给任意用户使用，需要提交验证并发布，`https://mail.google.com/` 属于受限范围，审核会要求说明用途。
4. 创建凭据：「API 和服务 → 凭据 → 创建凭据 → OAuth 客户端 ID」。
   - 应用类型选 **桌面应用（Desktop app）**。
   - 桌面应用类型不需要 Client Secret，Google 允许它使用任意回环端口（`127.0.0.1` 或 `localhost`），因此无需预先登记重定向 URI。
5. 复制生成的 **Client ID**（形如 `xxxxxxxx.apps.googleusercontent.com`），填入配置文件的 `gmail.clientId`。Client Secret 留空。

> 如果 Gmail 账号设置里关闭了 IMAP，请在 Gmail 网页端「设置 → 转发和 POP/IMAP」中启用 IMAP，否则授权成功后连接收件服务器会失败。

## Microsoft Entra 配置步骤

1. 打开 [Azure 门户](https://portal.azure.com/) 或 [Entra 管理中心](https://entra.microsoft.com/)，进入「Microsoft Entra ID → 应用注册 → 新注册」。
2. 名称随意，**受支持的账户类型**按需要选择：
   - 只登录企业/学校账号：选「仅此组织目录中的账户」。
   - 需要登录 `outlook.com`、`hotmail.com`、`live.com` 个人账号：必须选包含「个人 Microsoft 帐户」的选项。
3. 注册完成后记下 **应用程序(客户端) ID**，稍后填入 `outlook.clientId`。
4. 「身份验证 → 添加平台 → **移动和桌面应用程序**」，勾选自定义重定向 URI，添加：
   - `http://localhost/oauth/callback`（与代码里的回调路径完全一致）
   - `http://localhost`（不带路径的回调也能匹配）

   Microsoft 对本机回环地址（`localhost`、`127.0.0.1`）的**端口不做匹配**，所以随机端口不需要额外注册，但路径要一致。不要选「Web」平台，那会要求 Client Secret。
5. 同一页面下方的「高级设置」里把 **允许公共客户端流（Allow public client flows）** 设为 **是**。公共客户端 + PKCE 是桌面/移动应用的推荐做法，不需要客户端密码。
6. 「API 权限 → 添加权限」中按代码里的 scope 配置：
   - `offline_access`、`openid`、`email`：OpenID Connect 的保留范围，分别用于获取刷新令牌、身份标识和邮箱声明。它们由客户端在授权请求里直接带上，不需要在门户里手动添加。
   - `IMAP.AccessAsUser.All`、`SMTP.Send`：在「我的组织使用的 API」中找到 **Office 365 Exchange Online**，添加其**委托的权限**中的这两项。这是代码实际收发邮件所需的权限。

   > 代码使用的是 Outlook IMAP/SMTP 的范围，**不是** Microsoft Graph 的 `Mail.ReadWrite` / `Mail.Send`。如果你希望之后改用 Graph API 同步，需要另外添加 Graph 的 `Mail.ReadWrite`、`Mail.Send`。
   >
   > 企业/学校账号上这两个 Exchange Online 权限通常需要管理员同意；个人 Microsoft 账号由用户在授权页直接同意即可。授权页会按请求的 scope 动态展示同意内容。
7. 复制「应用程序(客户端) ID」（形如 `11111111-2222-3333-4444-555555555555`），填入配置文件的 `outlook.clientId`。客户端密码不需要创建。

## 填写配置文件

把上面拿到的 Client ID 填进：

`entry/src/main/resources/rawfile/oauth-clients.json`

首次配置时可以复制模板 `entry/src/main/ets/config/oauth-clients.example.json` 后改名，完整格式如下（`clientSecret` 保持空字符串）：

```json
{
  "gmail": {
    "clientId": "xxxxxxxx.apps.googleusercontent.com",
    "clientSecret": ""
  },
  "outlook": {
    "clientId": "11111111-2222-3333-4444-555555555555",
    "clientSecret": ""
  }
}
```

关于这个文件：

- 该文件已写入 `.gitignore`，不会提交到代码仓库。
- 但打包后 Client ID 会随资源进入 HAP，可以被解包看到。客户端 ID 对公共客户端（桌面/移动应用）来说本来就是公开信息，**不是密钥**；不要使用 Web 应用类型的客户端密钥，也不要把真正的机密放进这个文件。
- 文件缺失、内容为空或缺字段时，应用照常编译运行，只是 Gmail/Outlook 的 OAuth 入口不可用：添加账户向导的第 2 步（「配置账户」页面）会显示「需要先配置 OAuth Client ID」提示卡片，并禁用「使用 OAuth 登录」按钮。此时 Gmail 仍可选择顶部的「应用专用密码」正常登录；Outlook 只有 OAuth，因此无法登录。
- 修改配置文件后需要重新编译安装应用才会生效；应用在启动时（`EntryAbility.onCreate`）读取一次该文件。

## 验证

1. 用 DevEco Studio 重新编译安装 `entry` 模块。
2. 打开应用 → 账户与设置 → 添加账户 → 选择 Gmail 或 Outlook → 输入邮箱地址 → 继续。
3. 第 2 步（「配置账户」页面）顶部确认已选中「OAuth 登录」，页面不再出现「需要先配置 OAuth Client ID」卡片，点击「使用 OAuth 登录」。
4. 系统浏览器打开授权页面，同意后浏览器会短暂访问 `127.0.0.1` / `localhost` 的回调页，然后自动跳回应用。
5. 应用继续验证收件/发件服务器，成功后提示「邮箱账户已添加」并返回账户列表。
6. 返回应用时若授权尚未返回结果，页面会提示「已返回邮箱助手，正在等待授权结果…」，此时不要重复点击登录按钮，等待回调完成即可。

## 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| 提示「应用尚未配置 OAuth Client ID」 | `oauth-clients.json` 缺失、为空或对应 provider 的 `clientId` 是空串；按上文填好后重新安装。 |
| Google 提示「此应用未经验证 / 访问被阻止」 | 同意屏幕仍是测试状态且当前账号不在测试用户列表；把它加为测试用户，或提交验证后发布应用。 |
| Google 提示 `invalid_client` 或 `client_secret is missing` | 客户端类型不是「桌面应用」，或错误地配置了 Client Secret；桌面应用类型不需要 Secret。 |
| Microsoft 报 `AADSTS50011: redirect URI mismatch` | 平台类型不是「移动和桌面应用程序」，或重定向 URI 的路径与 `/oauth/callback` 不一致；端口差异不会导致该错误。 |
| Microsoft 报 `AADSTS7000218: client_assertion 或 client_secret required` | 「允许公共客户端流」没有设为「是」。 |
| 提示「OAuth 登录等待超时，请重新尝试」 | 5 分钟内没有收到回调。常见原因是浏览器没有真正访问回环地址（被代理/清理工具拦截），或授权时切换到了其他设备完成。回到页面后重新点击登录即可重试。 |
| 提示收件服务器连接失败 | 授权本身成功了，是 IMAP 登录被拒：Gmail 需确认已启用 IMAP，企业账号需确认管理员未禁用 Exchange Online 的 IMAP/SMTP。 |
| 应用专用密码提示「邮箱地址或授权码验证失败」 | 填的不是账号主密码：必须用 Google 账号「应用专用密码」页面生成的 16 位密码（需先开启两步验证）；同时确认 Gmail 已启用 IMAP。 |
| 已用应用专用密码添加的 Gmail，想改用 OAuth | 账户按添加时保存的认证方式工作，需要删除该账户后重新添加，并在第 2 步顶部选择「OAuth 登录」。 |
