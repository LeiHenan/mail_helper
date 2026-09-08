# 邮箱助手架构

## 目标

第一阶段提供可演示、可继续扩展的 HarmonyOS NEXT 原生客户端。第二阶段接入同步服务，实现真实邮件、可靠通知和多设备状态一致性。

## 数据流

```text
ArkUI 页面
   │
   ▼
MailRepository
   ├── MockMailRepository（当前）
   └── BackendMailRepository（下一阶段）
              │ HTTPS
              ▼
        邮件同步服务
        ├── IMAP/SMTP: QQ、163、自定义邮箱
        ├── Gmail API
        ├── Microsoft Graph
        └── Push Kit
```

## 为什么需要同步服务

移动端应用进入后台后，系统不会保证 IMAP TCP 长连接持续存活。仅依赖客户端轮询会导致通知延迟、耗电增加，并容易触发邮箱服务器连接限制。同步服务可以持续维护 IMAP IDLE 或云邮箱订阅，并把新邮件事件转换为 Push Kit 通知。

## 客户端模块

### 页面层

- `Index`：统一收件箱、账户筛选和同步入口。
- `MailDetail`：正文、附件入口、已读和星标。
- `Compose`：新建、回复、转发和账户选择。
- `Accounts`：多账户管理和同步开关。
- `AddAccount`：授权码或 OAuth 方式添加邮箱。

### 数据层

`MailRepository` 是页面唯一依赖的数据接口。真实实现需要处理分页、缓存、冲突合并和网络重试。

推荐本地表：

- `accounts`：不包含任何原始密码或 Token。
- `folders`：远端文件夹 ID、UIDVALIDITY、同步游标。
- `messages`：信封信息、正文缓存状态、已读和星标状态。
- `attachments`：元数据和沙箱文件路径。
- `outbox`：待发送、发送中、失败和重试次数。

### 安全层

账户表只保存 `credentialRef`。引用指向 HUKS 管理的加密材料，或服务端颁发的短期会话。删除账户时需要同步删除凭证和本地缓存。

## 同步策略

1. 前台启动时拉取增量游标之后的新变更。
2. Push 到达后只把它当作“有变化”的信号，再从服务端拉取增量数据。
3. 写操作先进入本地 outbox，联网后按顺序提交。
4. 服务端以邮箱提供商的 message/thread ID 去重。
5. 网络失败使用指数退避，并限制 IMAP 并发连接数。

## 后端最小接口

```text
POST   /v1/auth/oauth/start
POST   /v1/auth/oauth/exchange
POST   /v1/accounts/imap
GET    /v1/accounts
DELETE /v1/accounts/{id}
GET    /v1/messages?accountId=&folder=&cursor=
GET    /v1/messages/{id}
PATCH  /v1/messages/{id}
POST   /v1/messages/send
POST   /v1/push/devices
POST   /v1/sync/{accountId}
```

所有接口都应使用 HTTPS。OAuth 回调必须校验 `state`，服务端保存 Refresh Token 时应使用独立的密钥管理服务加密。

## 后续实现顺序

1. HUKS 凭证保险库与关系型数据库缓存。
2. 后端仓库、分页和离线 outbox。
3. QQ/163 IMAP/SMTP 同步 Worker。
4. Gmail 与 Microsoft OAuth/订阅。
5. Push Kit、HTML 邮件安全渲染和真实附件管理。

