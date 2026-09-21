# Thunderbird Android 到 HarmonyOS 邮箱助手的实现映射

## 参考边界

- 参考项目：`thunderbird/thunderbird-android`
- 许可证：Apache License 2.0
- 当前工程仅参考功能划分和架构原则，没有复制 Android/Kotlin/Compose 源码。
- UI 使用 ArkTS + ArkUI 原生实现，以 Thunderbird Android 的信息架构、主题和交互为视觉基准。
- 保留本项目名称与品牌资产，不直接使用 Thunderbird 名称、Logo 或商标素材。

## 架构映射

| Thunderbird Android | HarmonyOS 邮箱助手 |
| --- | --- |
| `feature:account:*` | `model/ProviderConfig.ets`、`service/MailServerDiscovery.ets` |
| `feature:autodiscovery:*` | `MailServerDiscovery` |
| `mail:protocols:imap/smtp` | 后续 `backend/imap`、`backend/smtp` 原生实现 |
| `backend:api` | `service/MailBackendContract.ets` |
| Offline-first local store | `data/LocalMailRepository.ets`、ArkData RDB |
| Offline-first operation queue | `pending_operations`、`SyncCoordinator`、`PendingMailOperation` |
| `feature:mail:*` | 现有收件箱、详情、写信页面和 Repository 接口 |
| `feature:notification:*` | 后续 HarmonyOS Notification Kit 实现 |
| Android WorkManager / push | 后续 HarmonyOS 后台任务 + Push Kit |

## 当前已完成

- 多账户领域模型与 QQ、163、Gmail、Outlook、通用 IMAP/SMTP 配置。
- 邮箱地址服务商识别和服务器参数自动发现。
- 原生 TCP/TLS 服务器连通性探测。
- IMAP/SMTP/JMAP/Graph 可替换后端边界。
- 文件夹、远程邮件摘要、离线操作和同步状态模型。
- 离线操作队列及账户同步状态机。
- 添加账户流程接入服务器验证和连接测试。
- 对齐 Thunderbird Light Theme 的核心色板、扁平列表和表面层级。
- 主界面实现账户/文件夹抽屉、统一收件箱、星标、草稿、已发送、归档、垃圾邮件和垃圾箱。
- 邮件列表实现未读/已读状态、账户指示器、头像选择、长按多选、批量已读、归档和删除。
- 邮件阅读器实现星标、归档、删除、已读切换、引用内容、附件、回复/回复全部/转发。
- 写信页实现账户切换、收件人、抄送/密送、主题、正文、附件占位和发送流程。
- 添加账户流程改为邮箱地址优先的自动发现，并保留手动 IMAP/SMTP 编辑入口。
- 使用 ArkData RDB 建立本地账户、邮件和待同步操作数据库，应用重启后状态仍可恢复。
- 星标、已读、归档、删除、已发送邮件、草稿和账户同步开关已切换到持久化数据源。
- 首次启动自动创建数据库结构，后续启动不再重复覆盖用户状态。
- 数据库升级到版本 2，新增 To/Cc/Bcc 地址表，并保留版本 1 数据迁移逻辑。
- 草稿使用稳定 ID 覆盖保存，可从草稿箱继续编辑，发送后自动移除原草稿。
- `SyncCoordinator` 已改为读取 ArkData 持久化操作队列；远端确认后删除，失败时保留并累计重试次数。

## 推荐迭代顺序

1. 实现 IMAP TCP/TLS 会话、命令解析、文件夹同步、UID/UIDVALIDITY 和增量拉取。
2. 实现 SMTP AUTH、MIME 组装、附件上传与发件箱重试。
3. 接入 Gmail 和 Microsoft OAuth 2.0 PKCE，配置独立客户端标识。
4. 用 HUKS 加密 OAuth Token 和邮箱授权码。
5. 补充离线操作合并、指数退避、不可重试错误识别与冲突处理。
6. 接入后台任务、网络约束、IMAP IDLE/服务端推送及系统通知。
7. 完成服务端搜索、移动、垃圾邮件和会话视图。
8. 增加证书异常处理、日志脱敏、协议测试和端到端测试。
