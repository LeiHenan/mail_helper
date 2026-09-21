# 邮箱助手架构

## 现状

当前版本是一个自包含的 HarmonyOS NEXT 客户端：不依赖自有服务端，直接在设备上通过 IMAP 收信、SMTP 发信，本地用 ArkData RDB 持久化，附件落在应用沙箱里。页面只依赖 `MailRepository` 接口，不知道下面连的是数据库还是网络。

`service/MailBackendContract.ets`、`service/MailSyncContract.ets` 和 `service/SyncCoordinator.ets` 保留了「把协议下沉到服务端」的接口形状，但当前没有任何调用方，属于未启用的占位。

## 数据流

```text
ArkUI 页面（pages/）
   │  只依赖接口
   ▼
MailRepository（data/MailRepository.ets）
   │
   ▼
LocalMailRepository（data/LocalMailRepository.ets，唯一实现）
   ├── ArkData RDB：mail_helper.db（S2 安全等级）
   ├── HuksCredentialVault：凭据密文
   └── AttachmentFileStore：filesDir/attachments/<messageId>/

MailAccountSyncService ──► ImapClient ──► ProtocolSocket（TLS / TCP+STARTTLS）
MailSendService ────────► SmtpClient  ──► ProtocolSocket
```

页面刷新路径：`Index` 从 RDB 按键集（keyset）分页读摘要（每页 50 条，游标是上一页末行的 `sort_order`/`id`），同时按 60 秒周期调用 `MailAccountSyncService.synchronize()`，每同步完一个账户只刷新计数并把窗口头部的新邮件合并进来（不整窗替换、不动游标）；切文件夹 / 换账户 / 改筛选 / 下拉刷新才整窗替换，发布时同一封邮件的行 key 不变，`LazyForEach` 会复用已有组件。翻页加载更早的邮件走末尾追加路径，只对新增区间发通知。

## 客户端模块

### 页面层（pages/）

- `Index`：文件夹与账户切换、常驻搜索栏、筛选 chip（全部/未读/星标/附件）、日期分组列表、下拉刷新、滑动归档/删除、批量选择、抽屉侧边栏。
- `MailDetail`：正文（HTML 走 RichText）、附件打开、已读与星标、回复/转发入口。
- `Compose`：新建、回复、转发、草稿、附件选择。
- `Accounts`：账户列表、同步开关、最近同步时间、进入设置。
- `AccountDetail`：服务器设置查看与修改、探测结果。
- `AddAccount`：邮箱地址自动发现、手动配置、授权码、应用专用密码（Gmail）或 OAuth 登录。
- `SettingsDetail`：邮件列表、滑动手势、通知、同步、隐私与安全、外观、帮助等分节设置。
- `GmailGuide`：Gmail 应用专用密码的 4 步设置指南（两步验证、生成密码、启用 IMAP、回到应用添加账户），前两步可直接拉起 Google 对应网页；入口在添加账户的「应用专用密码」说明卡与设置的帮助分节。

### 公共组件（common/）

- `MailListRow`：列表行的联合类型（日期表头 / 邮件），并负责把邮件序列拍平成带表头的行序列，按 epoch 毫秒（`MailMessage.receivedAtMs`，来自 `messages.sort_order`）以本地零点为界分桶（今天/昨天/本周/更早），行内时间也由它格式化。
- `MailRowDataSource`：`IDataSource` 实现，供 `LazyForEach` 消费；支持全量替换、末尾追加、单条更新和批量移除，每种变更只发对应的精确通知（含表头清理），所以分组不会破坏按行复用与 `cachedCount` 懒加载。
- `components/MessageCard`：`@Reusable` 列表行组件，所有状态由参数驱动，`aboutToReuse` 里按新参数重新赋值；头像底色按发件人地址哈希取自资源色板。
- `components/UndoSnackbar`：底部浮层，滑动归档/删除后 5 秒内可撤销。
- `Toast.ets`：基于 `promptAction` 的全局提示。
- `MessageId.ets`：Message-ID 规范化、尖括号包装与按发件人域名生成新 ID。

### 服务层（service/）

- `ImapClient`：IMAP 命令与响应解析。初始同步取最近 30 天最多 200 封，增量同步用 `UID SEARCH UID <last_uid>:*`，历史回溯用 `fetchOlder`；批量读取用 `UID FETCH`（每批 20 封，一次往返取回 HEADER + 正文），批次失败或解析结果不全时退化为逐封读取；`LIST` 结果与文件夹映射在同一连接内缓存。批量解析是纯 CPU 工作，每处理 4 封让出一次主线程。
- `SmtpClient`：SMTP 投递，走 `MimeMessageBuilder` 组装报文。
- `MimeMessageBuilder`：写 `Message-ID`（按发件人域名生成），回复/转发带 `In-Reply-To` 与 `References`。
- `MimeBodyParser`：MIME 递归解析，输出纯文本、HTML 与附件载荷；HTML 在渲染前清洗（去脚本、iframe/object/embed/form、内联事件、`javascript:`）；附件限制单个 15 MB、单封合计 30 MB。
- `MimeHeaderDecoder`：RFC 2047 编码字解码，`LocalMailRepository` 读库时也用它处理发件人、主题等字段。
- `ProtocolSocket`：TLS/TCP 收发封装，流式 UTF-8 解码（不按分片截断多字节字符），监听 close/error 事件让挂起请求失败而不是等到超时，并带读空闲超时与缓冲区上限。
- `OAuthService`：授权码 + PKCE（S256），本地回环端口接收回调，令牌刷新后回写凭据。
- `MailAccountSyncService`：串联凭据解析、IMAP 连接、待推送操作执行、文件夹同步与 UID 游标持久化。
- `MailSendService`：outbox 投递与重试。
- `MailServerDiscovery` / `MailServerProbe`：按域名给出服务器配置建议，并在添加/编辑账户时实际连一次验证。
- `BackgroundSyncScheduler`：注册 WorkScheduler 周期性后台任务。
- `MailNotificationService`：本地通知与角标（`notificationManager`），不是 Push Kit。
- `ErrorFormatter`：把系统错误码转成可读文案。

### 数据层（data/）

`MailRepository` 是页面唯一依赖的数据接口，`LocalMailRepository` 是唯一实现（`MockMailRepository` 已删除）。数据库 `mail_helper.db` 当前版本 9：

| 表 | 内容 |
| --- | --- |
| `accounts` | 账户信息与 IMAP/SMTP 设置，只保存 `credential_ref` 引用 |
| `messages` | 邮件头、预览、正文、已读/星标、`rfc_message_id`/`in_reply_to`/`send_status`、排序用的 `sort_order` |
| `message_addresses` | to/cc/bcc 收件人，按 `(message_id, address_type, position)` 主键 |
| `message_attachments` | 附件元数据与沙箱文件 URI（`is_inline` 标记内联） |
| `pending_operations` | 待推送队列，含 `retry_count`、`next_retry_at` |
| `app_settings` | 键值设置与同步游标（`sync_*`、`last_sync_*`） |

版本迁移：v3 增加已读回执标记，v5 展开服务器设置列，v6 增加 `html_body`，v7 增加 `message_attachments.is_inline`，v8 增加 `messages.rfc_message_id`/`in_reply_to`/`send_status` 与 `pending_operations.next_retry_at`。

实现的几个要点：

- 列表查询只取摘要列（跳过 `plain_body`/`html_body`）并按 `sort_order DESC, id DESC` 键集分页，未读 / 附件 / 星标筛选下推到 `WHERE`（参与分页）；`accountId === 'all'` 表示跨账户。
- 多封邮件的写入放在一个事务里；存在性检查用一条 `IN` 查询替代逐条 `getMessage()`，入参超过 500 时分批。
- 侧边栏计数由 `folderCounts()` 一条聚合 SQL 得出，替代原先 7 次邮件查询。
- `getSettingsByPrefix()` 一次取回某前缀下的全部设置（如各账户的 `last_sync_`），前缀中的 `%`、`_` 按字面量转义。
- 删除分软硬两种：`deleteMessages()` 只改文件夹并入队远端删除，`purgeMessages()`/`emptyTrash()` 才真正删行并清理附件目录。
- 全部写入路径（含事务方法）经 `enqueueWrite` 串行器排队，事务嵌套并入外层事务（原子性由最外层负责），杜绝并发写库破坏事务；同步按账户单飞（`inFlightSyncs`），重复触发返回 `skipped` 结果。
- UID 游标以实际入库的最大 UID 为准；单封失败的邮件记入 `last_folder_skipped_*` 而不阻塞整账户；UIDVALIDITY 变化时先清空该文件夹的本地行、附件与相关待推送操作再全量重拉。

### 安全层（security/）

`HuksCredentialVault` 在 HUKS 中生成并持有 AES-256 密钥，凭据用 AES-256-CBC（PKCS7）+ 随机 IV 加密后写入 Preferences，数据库只保存 `credential_ref`。HUKS 会话按 init/update/finish 执行，密钥缺失（错误码 12000011）时自动重建后重试一次。`MemoryCredentialVault` 只在数据库初始化完成前作为占位。

### 入口与后台任务（entryability/、workscheduler/）

`EntryAbility` 在启动时初始化 OAuth 客户端配置与数据库、恢复外观设置（避免首帧跳变）、应用隐私窗口设置、注册后台同步任务，并在 `onConfigurationUpdate` 中同步状态栏内容色。`MailSyncWorkSchedulerExtensionAbility` 在后台任务触发时重新初始化数据库与 OAuth 配置，逐账户同步，然后按通知开关与免打扰时段决定是否发新邮件通知。

## 同步与 outbox

`pending_operations` 是一张持久化队列，本地变更先落库入队，远端确认后才删除，因此应用重启不会丢操作。队列里有两类操作，分别由不同服务消费：

- `SEND` 由 `MailSendService` 处理：按 `created_at` 顺序投递，`next_retry_at` 未到期的跳过；失败时退避 1/2/4…最多 60 分钟，重试 8 次后放弃，并把邮件的 `send_status` 置为 `failed`（成功为 `sent`，入队时为 `sending`）。同一账户的发送是串行的。
- 其余状态变更（已读、星标、移动、删除）由 `MailAccountSyncService` 在 IMAP 连接上执行；失败只累加 `retry_count`，下次同步继续。种子数据和本地发出的邮件在服务器上没有 UID，这类操作会直接出队。

同步游标按 `(账户, 文件夹)` 存在 `app_settings` 中：`last_uid`、`uidvalidity`、`initialized`、`oldest_uid`、`history_complete`。UIDVALIDITY 变化时回退到初始同步。当前只有收件箱、垃圾邮件和垃圾箱参与同步；已发送、草稿、归档只有本地状态。

## 附件

`MimeBodyParser` 解析出的附件载荷先交给 `AttachmentFileStore` 写入 `filesDir/attachments/<messageId>/`（文件名清洗、长度截断），再把 URI 和元数据写进 `message_attachments`。落盘放在数据库事务之外，避免长时间持有事务；事务失败时清理刚写入的文件。详情页打开附件时把路径转成 `fileUri`，通过 `FLAG_AUTH_READ_URI_PERMISSION` 交给系统应用打开。删除邮件、清空垃圾箱、删除账户都会连带清理附件目录，清理失败不影响数据库操作。

## 列表渲染

列表数据源把「日期表头」和「邮件」拍平成同一种行对象（`MailListRow`），由 `MailRowDataSource` 实现 `IDataSource`，`LazyForEach` 只按行 key 复用。好处是分组不会退化成分组容器内嵌 `ForEach` 的全量构建；星标/已读只让单行重新取值，归档/删除按倒序发删除通知并顺带移除因此空掉的分组表头。

日期分组依据 `sort_order` 里的 epoch 毫秒与本地零点比较（今天 / 昨天 / 近 7 天归入本周 / 更早），不再解析 `received_at` 展示串：`received_at` 是入库时算好的文案，只作历史字段保留。

## 深浅色

颜色全部资源化为 `$r('app.color.*')`，`resources/base/element/color.json` 与 `resources/dark/element/color.json` 是两套同名的 22 个语义色（surface/onSurface/primary/error/warning/success 等），由系统按当前配色自动选择，`ThunderbirdTheme` 因此只保留尺寸、圆角和字号常量。

外观设置存在 `app_settings.appearance_mode`：`system`/`light`/`dark` 三档，通过 `ApplicationContext.setColorMode()` 应用，`system` 对应「不设置」；`EntryAbility` 在冷启动时先恢复该设置再加载首帧，切换后资源会自动换色，只需额外同步状态栏内容色。

## 已知限制

- 没有 IMAP IDLE：前台 60 秒轮询、后台 WorkScheduler 30 分钟同步，新邮件有延迟。
- 未读/附件筛选只作用于当前已加载的窗口；星标走服务器侧查询。
- 日期分组依赖展示字符串，跨年等边界情况只能近似判断。
- 已发送、草稿、归档不做双向同步。
- MIME 解析在主线程（每 4 封让出一次），未迁移到 TaskPool。
- 发送最终失败只写 `send_status`，界面尚无失败标记与重发入口。
- 多色 SVG 图标用 `fillColor` 覆盖，深色模式下个别图标对比度不理想。

## 后续可选方向

1. 把 MIME 解析与批量同步移到 TaskPool，长同步期间进一步降低主线程占用。
2. 用 IMAP IDLE 或系统推送替代轮询，减少延迟与耗电。
3. 接入 `MailBackendContract` 形状的服务端，由服务端承担 IDLE/Gmail API/Graph 与推送，客户端只保留本地缓存与离线队列。
4. 补齐发送失败的重发入口，并让更多文件夹参与双向同步。
