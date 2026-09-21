import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { AuthType, EmailAccount, EmailProviderType } from '../model/MailModels';
import { EMAIL_PROVIDERS, EmailProviderConfig, findProvider } from '../model/ProviderConfig';
import { AccountServerSettings, AuthenticationMethod, ConnectionSecurity, MailProtocol,
  MailServerSettings } from '../model/MailServerModels';
import { DiscoveryResult, MailServerDiscovery } from '../service/MailServerDiscovery';
import { MailServerProbe, ProbeResult } from '../service/MailServerProbe';
import { MailNotificationService } from '../service/MailNotificationService';
import { describeError } from '../service/ErrorFormatter';
import { OAuthCredential, OAuthService } from '../service/OAuthService';
import { isOAuthProviderConfigured } from '../config/OAuthClientConfig';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { showToast } from '../common/Toast';

const DOMAIN: number = 0x0003;

// Gmail 支持两条登录路径：应用专用密码（无需注册 OAuth 应用）与 OAuth 2.0 PKCE。
enum GmailLoginMode {
  APP_PASSWORD = 'app_password',
  OAUTH = 'oauth'
}

@Entry
@Component
struct AddAccount {
  private repository: LocalMailRepository = LocalMailRepository.shared();
  private discovery: MailServerDiscovery = new MailServerDiscovery();
  private serverProbe: MailServerProbe = new MailServerProbe();
  private oauthService: OAuthService = new OAuthService();
  private notificationService: MailNotificationService = new MailNotificationService();
  @State private step: number = 0;
  @State private selectedProvider: EmailProviderType = EmailProviderType.CUSTOM;
  @State private manualSetup: boolean = false;
  @State private displayName: string = '';
  @State private email: string = '';
  @State private secret: string = '';
  @State private incomingHost: string = '';
  @State private incomingPort: string = '993';
  @State private outgoingHost: string = '';
  @State private outgoingPort: string = '465';
  @State private connectionStatus: string = '';
  @State private isConnecting: boolean = false;
  @State private gmailLoginMode: GmailLoginMode = GmailLoginMode.APP_PASSWORD;
  private awaitingOAuthReturn: boolean = false;
  private oauthPageHidden: boolean = false;
  private deferredToast: string = '';
  // 连接成功后已发起一次返回：防止用户再按返回键把向导的上一层页面也弹掉。
  private leaving: boolean = false;

  private inferProvider(): EmailProviderType {
    const domain: string = this.email.trim().toLowerCase().split('@')[1] ?? '';
    if (domain === 'qq.com' || domain === 'foxmail.com') {
      return EmailProviderType.QQ;
    }
    if (domain === '163.com' || domain === '126.com' || domain === 'yeah.net') {
      return EmailProviderType.NETEASE_163;
    }
    if (domain === 'gmail.com' || domain === 'googlemail.com') {
      return EmailProviderType.GMAIL;
    }
    if (domain === 'outlook.com' || domain === 'hotmail.com' || domain === 'live.com') {
      return EmailProviderType.OUTLOOK;
    }
    return EmailProviderType.CUSTOM;
  }

  private securityForPort(protocol: MailProtocol, port: number): ConnectionSecurity {
    if (protocol === MailProtocol.IMAP) {
      return port === 993 ? ConnectionSecurity.TLS : ConnectionSecurity.STARTTLS;
    }
    return port === 465 ? ConnectionSecurity.TLS : ConnectionSecurity.STARTTLS;
  }

  private securityLabel(protocol: MailProtocol, port: number): string {
    return this.securityForPort(protocol, port) === ConnectionSecurity.TLS ? 'SSL/TLS' : 'STARTTLS';
  }

  private incomingEndpointText(): string {
    return `${this.incomingHost}:${this.incomingPort} · ` +
      this.securityLabel(MailProtocol.IMAP, Number.parseInt(this.incomingPort));
  }

  private outgoingEndpointText(): string {
    return `${this.outgoingHost}:${this.outgoingPort} · ` +
      this.securityLabel(MailProtocol.SMTP, Number.parseInt(this.outgoingPort));
  }

  // OAuth 已配置时默认走 OAuth，未配置时默认走应用专用密码；用户可在第 2 步手动切换。
  private defaultGmailLoginMode(): GmailLoginMode {
    return isOAuthProviderConfigured(EmailProviderType.GMAIL) ?
      GmailLoginMode.OAUTH : GmailLoginMode.APP_PASSWORD;
  }

  // 只有 Gmail 提供密码登录：Outlook 已关闭基本认证，只保留 OAuth。
  private usesAppPassword(): boolean {
    return this.selectedProvider === EmailProviderType.GMAIL &&
      this.gmailLoginMode === GmailLoginMode.APP_PASSWORD;
  }

  private usesOAuth(): boolean {
    return findProvider(this.selectedProvider).authType === AuthType.OAUTH_PKCE && !this.usesAppPassword();
  }

  private connectionFailure(label: string, settings: MailServerSettings, detail: string): string {
    const reason: string = detail.trim().length > 0 ? detail.trim() : '未知连接错误';
    return `${label} ${settings.host}:${settings.port} 连接失败：${reason}`;
  }

  private async continueSetup(): Promise<void> {
    if (this.email.trim().length === 0 || !this.email.includes('@')) {
      showToast('请输入有效的邮箱地址');
      return;
    }
    if (this.selectedProvider === EmailProviderType.CUSTOM) {
      this.selectedProvider = this.inferProvider() === EmailProviderType.CUSTOM ?
        EmailProviderType.CUSTOM : this.inferProvider();
    }
    const provider: EmailProviderConfig = findProvider(this.selectedProvider);
    this.incomingHost = provider.incoming?.host ?? `imap.${this.email.split('@')[1]}`;
    this.incomingPort = `${provider.incoming?.port ?? 993}`;
    this.outgoingHost = provider.outgoing?.host ?? `smtp.${this.email.split('@')[1]}`;
    this.outgoingPort = `${provider.outgoing?.port ?? 465}`;
    this.connectionStatus = this.selectedProvider === EmailProviderType.CUSTOM ?
      '未找到可信的自动配置，请检查服务器设置' : '已找到推荐的服务器配置';
    this.manualSetup = this.selectedProvider === EmailProviderType.CUSTOM;
    this.step = 2;
  }

  private goBack(): void {
    if (this.isConnecting || this.leaving) {
      return;
    }
    if (this.step > 0) {
      this.step -= 1;
      return;
    }
    this.leaving = true;
    this.getUIContext().getRouter().back();
  }

  // 系统返回键走向导回退：多步表单里一次返回只退一步，连接中 / 已发起返回时吃掉事件。
  onBackPress(): boolean {
    if (this.isConnecting) {
      return true;
    }
    this.goBack();
    return true;
  }

  aboutToAppear(): void {
    this.gmailLoginMode = this.defaultGmailLoginMode();
  }

  onPageShow(): void {
    this.reportOAuthReturn();
  }

  onPageHide(): void {
    if (this.awaitingOAuthReturn) {
      this.oauthPageHidden = true;
    }
  }

  // OAuth 配置缺失只影响 OAuth 模式：Gmail 走应用专用密码时按钮不受影响。
  private oauthSetupMissing(): boolean {
    return this.usesOAuth() && !isOAuthProviderConfigured(this.selectedProvider);
  }

  // OAuth 授权在系统浏览器里进行，等待期间的提示用户在浏览器中看不到。
  // 页面重新可见时补一次反馈，最终结果仍由 connect() 统一给出。
  private reportOAuthReturn(): void {
    if (!this.oauthPageHidden) {
      return;
    }
    this.oauthPageHidden = false;
    if (this.awaitingOAuthReturn) {
      this.connectionStatus = '已返回邮箱助手，正在等待授权结果…';
      showToast('已返回邮箱助手，正在等待授权结果…');
      return;
    }
    const deferred: string = this.deferredToast;
    this.deferredToast = '';
    if (deferred.length > 0) {
      showToast(deferred);
    }
  }

  private deliverToast(message: string): void {
    if (this.oauthPageHidden) {
      this.deferredToast = message;
      return;
    }
    showToast(message);
  }

  // 已授权时不再打扰用户；未授权时先说明用途再拉起系统授权弹窗。
  // 权限申请失败不影响账户添加结果，只记日志。
  private async requestNotificationPermission(): Promise<void> {
    try {
      if (await this.notificationService.isNotificationEnabled()) {
        return;
      }
      this.deliverToast('开启通知权限，收到新邮件时及时提醒你');
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.notificationService.requestPermission(context);
    } catch (error) {
      if (error instanceof Error) {
        hilog.warn(DOMAIN, 'AddAccount', '申请通知权限失败：%{public}s', error.message);
      }
    }
  }

  // 应用专用密码复用发现到的端点，只把认证方式换成密码，让同步/发件全链路走 LOGIN。
  private passwordSettings(source: MailServerSettings): MailServerSettings {
    return new MailServerSettings(source.protocol, source.host, source.port, source.security,
      AuthenticationMethod.PASSWORD, this.email.trim());
  }

  private resolveServerSettings(): AccountServerSettings | undefined {
    if (!this.manualSetup && this.selectedProvider !== EmailProviderType.CUSTOM) {
      const discovered: DiscoveryResult = this.discovery.discover(this.email, this.selectedProvider);
      if (!discovered.settings) {
        this.connectionStatus = discovered.errorMessage;
        return discovered.settings;
      }
      if (!this.usesAppPassword()) {
        return discovered.settings;
      }
      return new AccountServerSettings(discovered.settings.provider, discovered.settings.email,
        this.passwordSettings(discovered.settings.incoming),
        this.passwordSettings(discovered.settings.outgoing));
    }
    const incomingPort: number = Number.parseInt(this.incomingPort);
    const outgoingPort: number = Number.parseInt(this.outgoingPort);
    const authentication: AuthenticationMethod = this.usesOAuth() ?
      AuthenticationMethod.OAUTH2 : AuthenticationMethod.PASSWORD;
    const incoming: MailServerSettings = new MailServerSettings(MailProtocol.IMAP,
      this.incomingHost.trim(), incomingPort, this.securityForPort(MailProtocol.IMAP, incomingPort),
      authentication,
      this.email.trim());
    const outgoing: MailServerSettings = new MailServerSettings(MailProtocol.SMTP,
      this.outgoingHost.trim(), outgoingPort, this.securityForPort(MailProtocol.SMTP, outgoingPort),
      authentication,
      this.email.trim());
    return new AccountServerSettings(this.selectedProvider, this.email.trim(), incoming, outgoing);
  }

  private async connect(): Promise<void> {
    const provider: EmailProviderConfig = findProvider(this.selectedProvider);
    if (provider.authType === AuthType.AUTHORIZATION_CODE && this.secret.length === 0) {
      showToast('请输入邮箱授权码');
      return;
    }
    if (this.usesAppPassword() && this.secret.length === 0) {
      showToast('请输入应用专用密码');
      return;
    }
    this.isConnecting = true;
    try {
      const existingAccounts: EmailAccount[] = await this.repository.listAccounts();
      if (existingAccounts.some((account: EmailAccount) =>
        account.email.toLowerCase() === this.email.trim().toLowerCase())) {
        this.connectionStatus = '这个邮箱账户已经存在';
        showToast(this.connectionStatus);
        return;
      }
      const settings: AccountServerSettings | undefined = this.resolveServerSettings();
      if (!settings) {
        return;
      }
      const validationErrors: string[] = this.discovery.validate(settings);
      if (validationErrors.length > 0) {
        this.connectionStatus = validationErrors[0];
        showToast(validationErrors[0]);
        return;
      }
      let storedCredential: string = this.secret;
      let loginCredential: string = this.secret;
      if (this.usesOAuth()) {
        if (!isOAuthProviderConfigured(provider.type)) {
          this.connectionStatus = `${provider.name} 尚未配置 OAuth Client ID，请先完成 OAuth 配置`;
          showToast(this.connectionStatus);
          return;
        }
        this.connectionStatus = `正在打开 ${provider.name} 安全登录页面…`;
        const context: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.awaitingOAuthReturn = true;
        this.oauthPageHidden = false;
        this.deferredToast = '';
        try {
          storedCredential = await this.oauthService.authorize(context, provider.type, this.email.trim());
        } finally {
          this.awaitingOAuthReturn = false;
        }
        const oauthCredential: OAuthCredential = JSON.parse(storedCredential) as OAuthCredential;
        loginCredential = oauthCredential.accessToken;
      }
      this.connectionStatus = `正在连接收件服务器 ${settings.incoming.host}:${settings.incoming.port}…`;
      const loginResult: ProbeResult = await this.serverProbe.validateImapLogin(
        settings.incoming, settings.incoming.username, loginCredential);
      if (!loginResult.reachable) {
        this.connectionStatus = this.connectionFailure('收件服务器', settings.incoming, loginResult.detail);
        this.deliverToast(this.connectionStatus);
        return;
      }
      this.connectionStatus = `正在检查发件服务器 ${settings.outgoing.host}:${settings.outgoing.port}…`;
      const outgoingResult: ProbeResult = await this.serverProbe.probe(settings.outgoing);
      if (!outgoingResult.reachable) {
        this.connectionStatus = this.connectionFailure('发件服务器', settings.outgoing, outgoingResult.detail);
        this.deliverToast(this.connectionStatus);
        return;
      }
      const name: string = this.displayName.trim().length > 0 ? this.displayName : provider.name;
      await this.repository.addAccount(new EmailAccount(`account_${Date.now()}`, this.email.trim(), name,
        provider.type, provider.color), storedCredential, settings);
      this.connectionStatus = '账户创建成功';
      showToast('邮箱账户已添加');
      // 场景化申请：账户刚添加成功，此时申请通知权限并说明用途（用于新邮件提醒）。
      await this.requestNotificationPermission();
      this.leaving = true;
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.connectionStatus = `账户创建失败：${describeError(error)}`;
      this.deliverToast(this.connectionStatus);
    } finally {
      this.isConnecting = false;
      this.awaitingOAuthReturn = false;
    }
  }

  @Builder
  private outlinedInput(label: string, value: string, placeholder: string,
    change: (value: string) => void, password: boolean = false) {
    Column({ space: 6 }) {
      Text(label).width('100%').fontSize(12).fontColor($r('app.color.onSurfaceVariant'))
      TextInput({ placeholder: placeholder, text: value })
        .width('100%').height(52).fontSize(15).backgroundColor($r('app.color.surfaceLowest'))
        .border({ width: 1, color: $r('app.color.outlineVariant') })
        .borderRadius(ThunderbirdTheme.controlRadius)
        .type(password ? InputType.Password : InputType.Normal).onChange(change)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private serverRow(title: string, host: string, port: string, incoming: boolean) {
    Column({ space: 8 }) {
      Text(title).width('100%').fontSize(14).fontWeight(FontWeight.Bold).fontColor($r('app.color.onSurface'))
      Row({ space: 10 }) {
        TextInput({ placeholder: '服务器地址', text: host })
          .layoutWeight(1).height(50).fontSize(14).backgroundColor($r('app.color.surfaceLowest'))
          .border({ width: 1, color: $r('app.color.outlineVariant') })
          .borderRadius(ThunderbirdTheme.controlRadius)
          .onChange((value: string) => {
            if (incoming) this.incomingHost = value; else this.outgoingHost = value;
          })
        TextInput({ placeholder: '端口', text: port })
          .width(82).height(50).fontSize(14).type(InputType.Number).backgroundColor($r('app.color.surfaceLowest'))
          .border({ width: 1, color: $r('app.color.outlineVariant') })
          .borderRadius(ThunderbirdTheme.controlRadius)
          .onChange((value: string) => {
            if (incoming) this.incomingPort = value; else this.outgoingPort = value;
          })
      }.width('100%')
      Text(incoming ?
        (this.securityForPort(MailProtocol.IMAP, Number.parseInt(this.incomingPort)) === ConnectionSecurity.TLS ?
          'IMAP · SSL/TLS' : 'IMAP · STARTTLS') :
        (this.securityForPort(MailProtocol.SMTP, Number.parseInt(this.outgoingPort)) === ConnectionSecurity.TLS ?
          'SMTP · SSL/TLS' : 'SMTP · STARTTLS'))
        .width('100%').fontSize(12).fontColor($r('app.color.onSurfaceVariant'))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private providerRow(provider: EmailProviderConfig) {
    Row({ space: 14 }) {
      Stack() {
        Circle().width(42).height(42).fill($r('app.color.surfaceLow'))
        Image(provider.type === EmailProviderType.CUSTOM ? $r('app.media.ic_settings') :
          $r('app.media.ic_mail')).width(21).height(21).objectFit(ImageFit.Contain).fillColor(provider.color)
      }
      Column({ space: 3 }) {
        Text(provider.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.onSurface'))
        if (provider.type === EmailProviderType.CUSTOM) {
          Text('手动配置 IMAP/SMTP').fontSize(12).fontColor($r('app.color.onSurfaceVariant'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Image($r('app.media.ic_chevron_right')).width(19).height(19).objectFit(ImageFit.Contain)
        .fillColor($r('app.color.outline'))
    }
    .width('100%').constraintSize({ minHeight: provider.type === EmailProviderType.CUSTOM ? 68 : 62 })
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .backgroundColor($r('app.color.surfaceLowest'))
    .border({ width: 1, color: $r('app.color.cardBorder') })
    .borderRadius(ThunderbirdTheme.cardRadius)
    .onClick(() => {
      this.selectedProvider = provider.type;
      this.manualSetup = provider.type === EmailProviderType.CUSTOM;
      this.email = '';
      this.connectionStatus = '';
      // 切换服务商后登录方式回到默认值，避免带着上一个服务商的选择进入第 2 步。
      this.gmailLoginMode = this.defaultGmailLoginMode();
      this.step = 1;
    })
  }

  @Builder
  private providerStep() {
    Scroll() {
      Column({ space: 8 }) {
        Text('添加账户').width('100%').fontSize(26).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface')).textAlign(TextAlign.Center)
        Text('选择邮箱服务商以继续登录').width('100%').fontSize(13)
          .fontColor($r('app.color.onSurfaceVariant')).textAlign(TextAlign.Center)
          .margin({ bottom: 8 })
        ForEach(EMAIL_PROVIDERS, (provider: EmailProviderConfig) => {
          this.providerRow(provider)
        }, (provider: EmailProviderConfig) => provider.type)
      }
      .width('100%').padding({ left: 16, right: 16, top: 20, bottom: 28 })
      .alignItems(HorizontalAlign.Center)
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
  }

  @Builder
  private emailStep() {
    Column({ space: 14 }) {
      Stack() {
        Circle().width(68).height(68).fill($r('app.color.primaryContainer'))
        Image(this.selectedProvider === EmailProviderType.CUSTOM ? $r('app.media.ic_settings') :
          $r('app.media.ic_mail')).width(32).height(32).objectFit(ImageFit.Contain)
          .fillColor(findProvider(this.selectedProvider).color)
      }
      Text(`登录 ${findProvider(this.selectedProvider).name}`).fontSize(24).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.onSurface'))
      Text(this.selectedProvider === EmailProviderType.CUSTOM ?
        '输入邮箱地址，我们会查找服务器设置，也可以继续手动配置。' :
        '输入邮箱地址以继续安全登录。')
        .fontSize(14).lineHeight(21).fontColor($r('app.color.onSurfaceVariant')).textAlign(TextAlign.Center)
        .margin({ bottom: 14 })
      TextInput({ placeholder: '邮箱地址', text: this.email })
        .width('100%').height(54).fontSize(16).type(InputType.Email)
        .backgroundColor($r('app.color.surfaceLowest'))
        .border({ width: 1, color: $r('app.color.outlineVariant') })
        .borderRadius(ThunderbirdTheme.controlRadius)
        .onChange((value: string) => this.email = value)
      Button('继续').width('100%').height(50).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.onPrimary')).backgroundColor($r('app.color.primary'))
        .borderRadius(ThunderbirdTheme.controlRadius)
        .onClick(() => this.continueSetup())
      Text(findProvider(this.selectedProvider).helpText)
        .fontSize(12).lineHeight(19).fontColor($r('app.color.onSurfaceVariant')).textAlign(TextAlign.Center)
    }
    .layoutWeight(1).width('100%')
    .padding({ left: 32, right: 32, top: 36, bottom: 36 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.surfaceLowest'))
  }

  @Builder
  private oauthSetupCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Image($r('app.media.ic_warning')).width(20).height(20).objectFit(ImageFit.Contain)
          .fillColor($r('app.color.warning'))
        Text('需要先配置 OAuth Client ID').layoutWeight(1).fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface'))
      }.width('100%')
      Text('邮箱助手不内置第三方客户端密钥，需要填写你自己申请的客户端 ID 才能登录。')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
      Text('配置文件  entry/src/main/resources/rawfile/oauth-clients.json')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.primary'))
      Text(this.selectedProvider === EmailProviderType.GMAIL ?
        '把 Google Cloud“桌面应用”类型的 Client ID 填到 gmail.clientId，clientSecret 留空。' :
        '把 Microsoft Entra 注册的“应用程序(客户端) ID”填到 outlook.clientId，clientSecret 留空。')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
      Text('保存文件后重新安装应用即可使用 OAuth 登录，完整步骤见 docs/oauth-setup.md')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
    }
    .width('100%').padding(14)
    .backgroundColor($r('app.color.surfaceLow'))
    .border({ width: 1, color: $r('app.color.cardBorder') })
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
  }

  // Gmail 登录方式选择：两段式胶囊选择器，样式与页面卡片一致。
  @Builder
  private gmailLoginModeOption(mode: GmailLoginMode, title: string, subtitle: string) {
    Column({ space: 2 }) {
      Text(title).fontSize(14).fontWeight(FontWeight.Bold)
        .fontColor(this.gmailLoginMode === mode ? $r('app.color.onPrimary') : $r('app.color.onSurface'))
      Text(subtitle).fontSize(11).maxLines(1)
        .fontColor(this.gmailLoginMode === mode ?
          $r('app.color.onPrimary') : $r('app.color.onSurfaceVariant'))
    }
    .layoutWeight(1).padding({ top: 8, bottom: 8 })
    .backgroundColor(this.gmailLoginMode === mode ? $r('app.color.primary') : Color.Transparent)
    .borderRadius(ThunderbirdTheme.controlRadius - 2)
    .onClick(() => {
      this.gmailLoginMode = mode;
      // 密码与 OAuth 令牌不能混用，切换方式时清空已输入的凭证。
      this.secret = '';
    })
  }

  @Builder
  private gmailLoginModeSelector() {
    Row({ space: 4 }) {
      this.gmailLoginModeOption(GmailLoginMode.APP_PASSWORD, '应用专用密码', '无需配置，推荐')
      this.gmailLoginModeOption(GmailLoginMode.OAUTH, 'OAuth 登录', '需配置 Client ID')
    }
    .width('100%').padding(4)
    .backgroundColor($r('app.color.surfaceLow'))
    .border({ width: 1, color: $r('app.color.cardBorder') })
    .borderRadius(ThunderbirdTheme.controlRadius)
  }

  @Builder
  private appPasswordCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Image($r('app.media.ic_lock')).width(20).height(20).objectFit(ImageFit.Contain)
          .fillColor($r('app.color.primary'))
        Text('使用 Google 应用专用密码登录').layoutWeight(1).fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface'))
      }.width('100%')
      Text('1. 打开 Google 账号 →「安全性」，开启两步验证。')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
      Text('2. 在两步验证页面底部选择「应用专用密码」，输入名称（例如 邮箱助手）后生成。')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
      Text('3. 复制生成的 16 位密码填到下面，它只用于本应用登录 IMAP/SMTP，可随时在 Google 账号中删除。')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
      Text('4. 还需在 Gmail「设置 → 转发和 POP/IMAP」中启用 IMAP，否则连接收件服务器会失败。')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
      Text('这种方式无需注册 OAuth 应用，用账号密码也无法登录，必须使用这里生成的密码。')
        .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
      Row() {
        Text('查看分步指南').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.primary'))
      }
      .width('100%').height(ThunderbirdTheme.touchTarget).alignItems(VerticalAlign.Center)
      .onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/GmailGuide' }).catch(() => {}))
    }
    .width('100%').padding(14)
    .backgroundColor($r('app.color.surfaceLow'))
    .border({ width: 1, color: $r('app.color.cardBorder') })
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private configurationStep() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.manualSetup ? '服务器设置' : '发现的配置')
          .width('100%').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.onSurface'))
        Text(this.email).width('100%').fontSize(14).fontColor($r('app.color.onSurfaceVariant'))

        if (this.selectedProvider === EmailProviderType.GMAIL) {
          this.gmailLoginModeSelector()
        }

        Row({ space: 10 }) {
          Image(this.selectedProvider === EmailProviderType.CUSTOM ? $r('app.media.ic_warning') :
            $r('app.media.ic_check_circle'))
            .width(22).height(22).objectFit(ImageFit.Contain)
            .fillColor(this.selectedProvider === EmailProviderType.CUSTOM ?
              $r('app.color.warning') : $r('app.color.primary'))
          Text(this.connectionStatus).layoutWeight(1).fontSize(13).lineHeight(19)
            .fontColor($r('app.color.onSurfaceVariant'))
        }
        .width('100%').padding(14).backgroundColor($r('app.color.surfaceContainer')).borderRadius(8)

        this.outlinedInput('显示名称', this.displayName, '你的名字', (value: string) => this.displayName = value)
        if (this.usesAppPassword()) {
          this.appPasswordCard()
          this.outlinedInput('应用专用密码', this.secret, '输入 16 位应用专用密码',
            (value: string) => this.secret = value, true)
        } else if (findProvider(this.selectedProvider).authType === AuthType.OAUTH_PKCE) {
          if (isOAuthProviderConfigured(this.selectedProvider)) {
            Text(this.selectedProvider === EmailProviderType.GMAIL ?
              '将通过 Google 安全登录，应用不会读取或保存 Gmail 登录密码。' :
              '将通过 Microsoft 安全登录，应用不会读取或保存 Outlook 登录密码。')
              .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
          } else {
            this.oauthSetupCard()
          }
        } else {
          this.outlinedInput('密码或授权码', this.secret, '输入邮箱授权码',
            (value: string) => this.secret = value, true)
        }

        if (this.manualSetup) {
          this.serverRow('收件服务器', this.incomingHost, this.incomingPort, true)
          Divider().color($r('app.color.outlineVariant'))
          this.serverRow('发件服务器', this.outgoingHost, this.outgoingPort, false)
        } else {
          Column({ space: 8 }) {
            Text(`收件服务器  ${this.incomingEndpointText()}`)
              .width('100%').fontSize(13).fontColor($r('app.color.onSurface'))
            Text(`发件服务器  ${this.outgoingEndpointText()}`)
              .width('100%').fontSize(13).fontColor($r('app.color.onSurface'))
            Button('编辑配置').height(44).fontSize(13).fontColor($r('app.color.primary'))
              .backgroundColor(Color.Transparent).onClick(() => this.manualSetup = true)
          }.width('100%').padding(14).backgroundColor($r('app.color.surfaceLow')).borderRadius(8)
        }

        Button(this.isConnecting ? '正在验证…' : (this.usesOAuth() ? '使用 OAuth 登录' : '连接'))
          .width('100%').height(50).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(this.oauthSetupMissing() ? $r('app.color.outline') : $r('app.color.onPrimary'))
          .backgroundColor(this.oauthSetupMissing() ? $r('app.color.surfaceHigh') : $r('app.color.primary'))
          .borderRadius(ThunderbirdTheme.controlRadius)
          .enabled(!this.isConnecting && !this.oauthSetupMissing())
          .onClick(() => this.connect())
      }
      .width('100%').padding({ left: 16, right: 16, top: 20, bottom: 28 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surfaceLowest'))
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
  }

  build() {
    Column() {
      Row() {
        Button() {
          Image($r('app.media.ic_back')).width(23).height(23).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.onSurface'))
        }
          .width(48).height(48).backgroundColor(Color.Transparent)
          .enabled(!this.isConnecting && !this.leaving)
          .onClick(() => this.goBack())
        Text(this.step === 0 ? '邮箱助手' : (this.step === 1 ? '登录账户' : '配置账户'))
          .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.onSurface'))
        Row() {}.width(48)
      }
      .width('100%').height(56).padding({ left: 4, right: 4 })
      .backgroundColor(this.step === 0 ? $r('app.color.surface') : $r('app.color.surfaceLowest'))
      if (this.step === 0) {
        this.providerStep()
      } else if (this.step === 1) {
        this.emailStep()
      } else {
        this.configurationStep()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.step === 0 ? $r('app.color.surface') : $r('app.color.surfaceLowest'))
  }
}
