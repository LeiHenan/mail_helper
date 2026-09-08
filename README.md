# 邮箱助手

面向 HarmonyOS NEXT 的原生多账户邮箱客户端 MVP，使用 ArkTS、ArkUI 和 Stage 模型。

当前版本已经包含：

- 统一收件箱和账户筛选
- 邮件详情、已读、星标
- 写邮件、回复、转发
- 多邮箱账户管理
- QQ、163、Gmail、Outlook 提供商配置
- IMAP/SMTP 授权码与 OAuth PKCE 的数据边界
- 邮件同步服务和 Push Kit 注册契约
- 可替换的 `MailRepository`，当前默认使用内存模拟数据

## 打开和运行

1. 使用 DevEco Studio 6.0 或更新版本打开本目录。
2. 确认 DevEco Studio 已安装 HarmonyOS 6.0.2 / API 22 SDK 和 Phone 模拟器。
3. 为 `com.mailhelper.app` 配置自动签名。
4. 选择 `entry` 模块并运行到 HarmonyOS NEXT 模拟器或真机。

命令行验证：

```bash
DEVECO_SDK_HOME="$HOME/Library/Huawei/Sdk" \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode=debug \
  assembleHap
```

## 项目结构

```text
entry/src/main/ets
├── data/          MailRepository 与模拟实现
├── entryability/  应用入口
├── model/         账户、邮件、服务商配置
├── pages/         收件箱、详情、写信、账户页面
├── security/      凭证保险库边界
└── service/       OAuth、同步与 Push 注册契约
```

## OAuth 客户端配置

Gmail 和 Outlook 的 OAuth 客户端参数统一维护在本地配置文件：

`entry/src/main/ets/config/oauth-clients.json`

首次配置时复制 `oauth-clients.example.json` 为 `oauth-clients.json`，再填写对应参数。实际配置文件已加入 `.gitignore`，避免 Client ID 和 Secret 被误提交到代码仓库。

配置格式：

```json
{
  "gmail": {
    "clientId": "Google OAuth Client ID",
    "clientSecret": "Google OAuth Client Secret"
  },
  "outlook": {
    "clientId": "Microsoft OAuth Client ID",
    "clientSecret": ""
  }
}
```

Outlook 使用带 PKCE 的公共客户端登录，不应配置 Client Secret。客户端配置最终会进入 HAP，不能作为真正的密钥保管方案；生产环境如必须使用机密客户端 Secret，应把令牌交换放到受控服务端完成。

## 接入真实邮箱

客户端不应该长时间维持 IMAP IDLE 连接。生产环境推荐由同步服务负责：

- QQ/163：IMAP IDLE 收件、SMTP 发件；使用用户生成的授权码。
- Gmail：OAuth 2.0 PKCE，优先 Gmail API。
- Outlook：OAuth 2.0 PKCE，优先 Microsoft Graph。
- 新邮件：同步服务收到事件后，通过 Push Kit 通知鸿蒙客户端。

将 `MockMailRepository` 替换成后端仓库实现后，页面层不需要改变。

## 安全说明

`MemoryCredentialVault` 只是让 UI 原型可运行的开发实现，应用重启后不会保留凭证。上线前必须替换为 HUKS 实现，并遵守以下规则：

- 授权码、Refresh Token 不写入日志、Preferences 或关系型数据库明文字段。
- OAuth 使用授权码模式和 PKCE，不在客户端内置可滥用的密钥。
- HTML 邮件通过白名单过滤后再渲染，默认阻止脚本和远程追踪图片。
- 附件下载前校验大小、MIME 类型和文件名。

更完整的模块设计见 [docs/architecture.md](docs/architecture.md)。
