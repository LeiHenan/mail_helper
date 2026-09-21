# 邮箱助手

面向 HarmonyOS NEXT 的原生多账户邮箱客户端，使用 ArkTS、ArkUI 和 Stage 模型。

当前版本已经包含：

- 统一收件箱：常驻搜索栏、全部/未读/星标/附件筛选、日期分组、下拉刷新、滑动归档与删除（5 秒内可撤销）
- 邮件详情：清洗后的 HTML / 纯文本正文、附件打开、已读与星标
- 写邮件、回复、转发、草稿、附件选择
- 多邮箱账户管理：QQ、163、Gmail、Outlook 自动配置，支持授权码与 OAuth 2.0 PKCE；Gmail 支持应用专用密码或 OAuth 登录
- 真实收发链路：IMAP 增量同步、SMTP 发送，附件落盘到应用沙箱
- 本地持久化：ArkData RDB（`mail_helper.db`，当前版本 8），`LocalMailRepository` 是唯一数据源
- 凭证安全：HUKS AES-256-CBC 加密后存入 Preferences
- 浅色/深色主题，设置中可选跟随系统、浅色或深色
- 前台 IMAP IDLE 近实时收信（30 秒轮询兜底）+ WorkScheduler 每 30 分钟后台同步与新邮件通知

## 打开和运行

环境要求：DevEco Studio 6.0 或更新版本（自带 HarmonyOS 6.0.2 / API 22 SDK）。

**先确认项目路径只含 ASCII 字符。** hvigor 不支持中文路径，`邮箱` 这类目录名会直接导致构建失败。

**命令行构建**，默认 debug，也可以传 `release`：

```bash
./build-hap.sh          # 等价于 ./build-hap.sh debug
./build-hap.sh release
```

`build-hap.sh` 会设置 `DEVECO_SDK_HOME`（DevEco 自带 SDK）和 `JAVA_HOME`（DevEco 自带 JBR），再执行 `hvigorw assembleHap`，产物为 `entry/build/default/outputs/default/entry-default-unsigned.hap`。

**运行到模拟器**：在 DevEco Studio 中打开本目录，选择 `entry` 模块直接运行。

**运行到真机**：`build-profile.json5` 的 `signingConfigs` 为空，构建产物是未签名 HAP，无法直接安装。在 DevEco Studio 中打开「File → Project Structure → Signing Configs」，勾选 **Automatically generate signature**，按提示登录华为开发者账号，等待自动签名完成后即可运行到真机。

## 项目结构

```text
entry/src/main/ets
├── common/        列表行与数据源、Toast、可复用列表组件
├── config/        OAuth 客户端配置读取与示例配置
├── data/          MailRepository、LocalMailRepository、附件落盘、待推送队列边界
├── entryability/  应用入口（外观恢复、隐私窗口、后台任务注册）
├── model/         账户、邮件、服务器与提供商配置
├── pages/         收件箱、详情、写信、账户列表、账户详情、添加账户、设置详情、Gmail 设置指南
├── security/      HUKS 凭证保险库
├── service/       OAuth、IMAP/SMTP、MIME、同步与通知
├── theme/         尺寸与圆角常量
└── workscheduler/ 后台同步 Worker

entry/src/main/resources
├── base/element/color.json   浅色配色
├── dark/element/color.json   深色配色
└── rawfile/                  本地配置（oauth-clients.json，已 gitignore）
```

## OAuth 客户端配置

Gmail 和 Outlook 的 OAuth 客户端参数统一维护在本地配置文件：

`entry/src/main/resources/rawfile/oauth-clients.json`

首次配置时复制 `entry/src/main/ets/config/oauth-clients.example.json` 为该文件，再填写对应参数。实际配置文件已加入 `.gitignore`，避免 Client ID 被误提交到代码仓库。应用在启动时读取该文件（`EntryAbility` 与后台同步 Worker 各初始化一次）。文件缺失或格式错误时应用仍可正常编译运行：添加账户页会显示配置引导卡片，并禁用 OAuth 登录按钮。

配置格式：

```json
{
  "gmail": {
    "clientId": "Google OAuth Client ID（桌面应用类型）",
    "clientSecret": ""
  },
  "outlook": {
    "clientId": "Microsoft OAuth Client ID（移动和桌面平台）",
    "clientSecret": ""
  }
}
```

Gmail（桌面应用类型）和 Outlook（公共客户端）都使用带 PKCE 的授权码流程，不需要也不应配置 Client Secret。详细的注册步骤见 [docs/oauth-setup.md](docs/oauth-setup.md)。客户端配置最终会进入 HAP，不能作为真正的密钥保管方案。

Gmail 也可以完全不配置这个文件：在添加账户向导第 2 步顶部把登录方式切到「应用专用密码」，用 Google 账号生成的应用专用密码登录即可。Outlook 只有 OAuth 一种方式（Microsoft 已关闭基本认证）。

## 收发与同步

客户端不依赖服务端，直接在设备上连接邮箱：

- 收件：IMAP over TLS（默认 993）或 STARTTLS。首轮同步取最近 30 天最多 200 封，之后用 `UID SEARCH UID <last_uid>:*` 增量拉取；批量读取用 `UID FETCH`（每批 20 封，一次往返取回 HEADER 与正文），UIDVALIDITY 变化时回退到初始同步。
- 发件：SMTP（TLS 或 STARTTLS）。发送先写入本地 `pending_operations` 队列（outbox），联网后由 `MailSendService` 按时间顺序投递，失败按 1/2/4…60 分钟退避重试，最多 8 次，最终失败写入邮件的 `send_status`。
- 附件：从 MIME 解析后写入应用沙箱 `filesDir/attachments/<messageId>/`，数据库只保存元数据与文件 URI，打开时通过 `fileUri` 授予临时读权限。
- 通知：前台 IMAP IDLE 事件触发即时同步（30 秒轮询兜底），后台由 WorkScheduler 每 30 分钟同步一次并发布本地通知。

`MailRepository` 是页面唯一依赖的数据接口，`LocalMailRepository` 是其唯一实现。

## 安全说明

账户凭据由 `HuksCredentialVault` 保管：HUKS 中生成并持有 AES-256 密钥，授权码和 OAuth 令牌用 AES-256-CBC（PKCS7）加密后才写入 Preferences，数据库里只保存 `credential_ref` 引用。密钥缺失时会自动重建，重建后需要重新添加账户。此外遵守以下规则：

- 授权码、Refresh Token 不写入日志，也不以明文出现在 Preferences 或关系型数据库中。
- OAuth 使用授权码模式和 PKCE，不在客户端内置可滥用的密钥。
- HTML 正文渲染前先清洗：剔除脚本、iframe/object/embed/form、内联事件属性和 `javascript:` 链接。
- 附件在解析时限制单个 15 MB、单封合计 30 MB，落盘前清洗文件名，并统一写入应用沙箱。

## 已知限制

- **未签名构建**：`signingConfigs` 为空，只能产出未签名 HAP；真机安装前需要先在 DevEco Studio 里完成自动签名（见「打开和运行」）。
- **IMAP IDLE 只在前台保持**：前台靠 IDLE 近实时收信（30 秒轮询兜底），页面隐藏/锁屏后断开，后台靠 WorkScheduler 每 30 分钟同步，新邮件到达有延迟。
- **关键词搜索只作用于已加载窗口**：未读/附件/星标筛选已下推到 SQL 并参与分页，但搜索框的关键词仍只在已加载的窗口里过滤。
- **列表时间不带年份**：更早的邮件在列表里显示 `M月D日`（今天 `HH:mm`、昨天显示「昨天」），跨年的同月日邮件在列表上无法区分（详情页带年份）。
- **部分文件夹不双向同步**：只有收件箱、垃圾邮件和垃圾箱参与同步，已发送、草稿、归档保持本地状态。
- **深色模式细节**：多色 SVG 图标用 `fillColor` 覆盖，个别图标在深色下对比度可能不理想。
- **MIME 解析在主线程**：批量解析每 4 封让出一次主线程，尚未迁移到 TaskPool，超大邮件同步时仍可能造成轻微卡顿。
- **发送失败状态未呈现**：最终失败会写入 `send_status`，但界面还没有失败标记和重发入口。

更完整的模块设计见 [docs/architecture.md](docs/architecture.md)。
