import { common } from '@kit.AbilityKit';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { AuthType, EmailAccount, EmailProviderType } from '../model/MailModels';
import { EMAIL_PROVIDERS, EmailProviderConfig, findProvider } from '../model/ProviderConfig';
import { AccountServerSettings, AuthenticationMethod, ConnectionSecurity, MailProtocol,
  MailServerSettings } from '../model/MailServerModels';
import { DiscoveryResult, MailServerDiscovery } from '../service/MailServerDiscovery';
import { MailServerProbe, ProbeResult } from '../service/MailServerProbe';
import { describeError } from '../service/ErrorFormatter';
import { OAuthCredential, OAuthService } from '../service/OAuthService';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';

@Entry
@Component
struct AddAccount {
  private repository: LocalMailRepository = LocalMailRepository.shared();
  private discovery: MailServerDiscovery = new MailServerDiscovery();
  private serverProbe: MailServerProbe = new MailServerProbe();
  private oauthService: OAuthService = new OAuthService();
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

  private connectionFailure(label: string, settings: MailServerSettings, detail: string): string {
    const reason: string = detail.trim().length > 0 ? detail.trim() : '未知连接错误';
    return `${label} ${settings.host}:${settings.port} 连接失败：${reason}`;
  }

  private async continueSetup(): Promise<void> {
    if (this.email.trim().length === 0 || !this.email.includes('@')) {
      this.showToast('请输入有效的邮箱地址');
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
    if (this.step > 0) {
      this.step -= 1;
      return;
    }
    this.getUIContext().getRouter().back();
  }

  private resolveServerSettings(): AccountServerSettings | undefined {
    if (!this.manualSetup && this.selectedProvider !== EmailProviderType.CUSTOM) {
      const discovered: DiscoveryResult = this.discovery.discover(this.email, this.selectedProvider);
      if (!discovered.settings) {
        this.connectionStatus = discovered.errorMessage;
      }
      return discovered.settings;
    }
    const incomingPort: number = Number.parseInt(this.incomingPort);
    const outgoingPort: number = Number.parseInt(this.outgoingPort);
    const authentication: AuthenticationMethod = findProvider(this.selectedProvider).authType ===
      AuthType.OAUTH_PKCE ? AuthenticationMethod.OAUTH2 : AuthenticationMethod.PASSWORD;
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
      this.showToast('请输入邮箱授权码');
      return;
    }
    this.isConnecting = true;
    try {
      const existingAccounts: EmailAccount[] = await this.repository.listAccounts();
      if (existingAccounts.some((account: EmailAccount) =>
        account.email.toLowerCase() === this.email.trim().toLowerCase())) {
        this.connectionStatus = '这个邮箱账户已经存在';
        this.showToast(this.connectionStatus);
        return;
      }
      const settings: AccountServerSettings | undefined = this.resolveServerSettings();
      if (!settings) {
        return;
      }
      const validationErrors: string[] = this.discovery.validate(settings);
      if (validationErrors.length > 0) {
        this.connectionStatus = validationErrors[0];
        this.showToast(validationErrors[0]);
        return;
      }
      let storedCredential: string = this.secret;
      let loginCredential: string = this.secret;
      if (provider.authType === AuthType.OAUTH_PKCE) {
        this.connectionStatus = `正在打开 ${provider.name} 安全登录页面…`;
        const context: common.UIAbilityContext =
          this.getUIContext().getHostContext() as common.UIAbilityContext;
        storedCredential = await this.oauthService.authorize(context, provider.type, this.email.trim());
        const oauthCredential: OAuthCredential = JSON.parse(storedCredential) as OAuthCredential;
        loginCredential = oauthCredential.accessToken;
      }
      this.connectionStatus = `正在连接收件服务器 ${settings.incoming.host}:${settings.incoming.port}…`;
      const loginResult: ProbeResult = await this.serverProbe.validateImapLogin(
        settings.incoming, settings.incoming.username, loginCredential);
      if (!loginResult.reachable) {
        this.connectionStatus = this.connectionFailure('收件服务器', settings.incoming, loginResult.detail);
        this.showToast(this.connectionStatus);
        return;
      }
      this.connectionStatus = `正在检查发件服务器 ${settings.outgoing.host}:${settings.outgoing.port}…`;
      const outgoingResult: ProbeResult = await this.serverProbe.probe(settings.outgoing);
      if (!outgoingResult.reachable) {
        this.connectionStatus = this.connectionFailure('发件服务器', settings.outgoing, outgoingResult.detail);
        this.showToast(this.connectionStatus);
        return;
      }
      const name: string = this.displayName.trim().length > 0 ? this.displayName : provider.name;
      await this.repository.addAccount(new EmailAccount(`account_${Date.now()}`, this.email.trim(), name,
        provider.type, provider.color), storedCredential, settings);
      this.connectionStatus = '账户创建成功';
      this.showToast('邮箱账户已添加');
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.connectionStatus = `账户创建失败：${describeError(error)}`;
      this.showToast(this.connectionStatus);
    } finally {
      this.isConnecting = false;
    }
  }

  private showToast(_message: string): void {
  }

  @Builder
  private outlinedInput(label: string, value: string, placeholder: string,
    change: (value: string) => void, password: boolean = false) {
    Column({ space: 6 }) {
      Text(label).width('100%').fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
      TextInput({ placeholder: placeholder, text: value })
        .width('100%').height(52).fontSize(15).backgroundColor(ThunderbirdTheme.surfaceLowest)
        .border({ width: 1, color: ThunderbirdTheme.outlineVariant })
        .borderRadius(ThunderbirdTheme.controlRadius)
        .type(password ? InputType.Password : InputType.Normal).onChange(change)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private serverRow(title: string, host: string, port: string, incoming: boolean) {
    Column({ space: 8 }) {
      Text(title).width('100%').fontSize(14).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface)
      Row({ space: 10 }) {
        TextInput({ placeholder: '服务器地址', text: host })
          .layoutWeight(1).height(50).fontSize(14).backgroundColor(ThunderbirdTheme.surfaceLowest)
          .border({ width: 1, color: ThunderbirdTheme.outlineVariant })
          .borderRadius(ThunderbirdTheme.controlRadius)
          .onChange((value: string) => {
            if (incoming) this.incomingHost = value; else this.outgoingHost = value;
          })
        TextInput({ placeholder: '端口', text: port })
          .width(82).height(50).fontSize(14).type(InputType.Number).backgroundColor(ThunderbirdTheme.surfaceLowest)
          .border({ width: 1, color: ThunderbirdTheme.outlineVariant })
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
        .width('100%').fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private providerRow(provider: EmailProviderConfig) {
    Row({ space: 14 }) {
      Stack() {
        Circle().width(42).height(42).fill(ThunderbirdTheme.surfaceLow)
        Image(provider.type === EmailProviderType.CUSTOM ? $r('app.media.ic_settings') :
          $r('app.media.ic_mail')).width(21).height(21).objectFit(ImageFit.Contain).fillColor(provider.color)
      }
      Column({ space: 3 }) {
        Text(provider.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(ThunderbirdTheme.onSurface)
        if (provider.type === EmailProviderType.CUSTOM) {
          Text('手动配置 IMAP/SMTP').fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Image($r('app.media.ic_chevron_right')).width(19).height(19).objectFit(ImageFit.Contain)
        .fillColor(ThunderbirdTheme.outline)
    }
    .width('100%').constraintSize({ minHeight: provider.type === EmailProviderType.CUSTOM ? 68 : 62 })
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .backgroundColor(ThunderbirdTheme.surfaceLowest)
    .border({ width: 1, color: ThunderbirdTheme.cardBorder })
    .borderRadius(ThunderbirdTheme.cardRadius)
    .onClick(() => {
      this.selectedProvider = provider.type;
      this.manualSetup = provider.type === EmailProviderType.CUSTOM;
      this.email = '';
      this.connectionStatus = '';
      this.step = 1;
    })
  }

  @Builder
  private providerStep() {
    Scroll() {
      Column({ space: 8 }) {
        Text('添加账户').width('100%').fontSize(26).fontWeight(FontWeight.Bold)
          .fontColor(ThunderbirdTheme.onSurface).textAlign(TextAlign.Center)
        Text('选择邮箱服务商以继续登录').width('100%').fontSize(13)
          .fontColor(ThunderbirdTheme.onSurfaceVariant).textAlign(TextAlign.Center)
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
        Circle().width(68).height(68).fill(ThunderbirdTheme.primaryContainer)
        Image(this.selectedProvider === EmailProviderType.CUSTOM ? $r('app.media.ic_settings') :
          $r('app.media.ic_mail')).width(32).height(32).objectFit(ImageFit.Contain)
          .fillColor(findProvider(this.selectedProvider).color)
      }
      Text(`登录 ${findProvider(this.selectedProvider).name}`).fontSize(24).fontWeight(FontWeight.Bold)
        .fontColor(ThunderbirdTheme.onSurface)
      Text(this.selectedProvider === EmailProviderType.CUSTOM ?
        '输入邮箱地址，我们会查找服务器设置，也可以继续手动配置。' :
        '输入邮箱地址以继续安全登录。')
        .fontSize(14).lineHeight(21).fontColor(ThunderbirdTheme.onSurfaceVariant).textAlign(TextAlign.Center)
        .margin({ bottom: 14 })
      TextInput({ placeholder: '邮箱地址', text: this.email })
        .width('100%').height(54).fontSize(16).type(InputType.Email)
        .backgroundColor(ThunderbirdTheme.surfaceLowest)
        .border({ width: 1, color: ThunderbirdTheme.outlineVariant })
        .borderRadius(ThunderbirdTheme.controlRadius)
        .onChange((value: string) => this.email = value)
      Button('继续').width('100%').height(50).fontSize(15).fontWeight(FontWeight.Bold)
        .fontColor(ThunderbirdTheme.onPrimary).backgroundColor(ThunderbirdTheme.primary)
        .borderRadius(ThunderbirdTheme.controlRadius)
        .onClick(() => this.continueSetup())
      Text(findProvider(this.selectedProvider).helpText)
        .fontSize(12).lineHeight(19).fontColor(ThunderbirdTheme.onSurfaceVariant).textAlign(TextAlign.Center)
    }
    .layoutWeight(1).width('100%')
    .padding({ left: 32, right: 32, top: 36, bottom: 36 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(ThunderbirdTheme.surfaceLowest)
  }

  @Builder
  private configurationStep() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.manualSetup ? '服务器设置' : '发现的配置')
          .width('100%').fontSize(22).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface)
        Text(this.email).width('100%').fontSize(14).fontColor(ThunderbirdTheme.onSurfaceVariant)

        Row({ space: 10 }) {
          Image(this.selectedProvider === EmailProviderType.CUSTOM ? $r('app.media.ic_warning') :
            $r('app.media.ic_check_circle'))
            .width(22).height(22).objectFit(ImageFit.Contain)
          Text(this.connectionStatus).layoutWeight(1).fontSize(13).lineHeight(19)
            .fontColor(ThunderbirdTheme.onSurfaceVariant)
        }
        .width('100%').padding(14).backgroundColor(ThunderbirdTheme.surfaceContainer).borderRadius(8)

        this.outlinedInput('显示名称', this.displayName, '你的名字', (value: string) => this.displayName = value)
        if (findProvider(this.selectedProvider).authType === AuthType.OAUTH_PKCE) {
          Text(this.selectedProvider === EmailProviderType.GMAIL ?
            '将通过 Google 安全登录，应用不会读取或保存 Gmail 登录密码。' :
            '将通过 Microsoft 安全登录，应用不会读取或保存 Outlook 登录密码。')
            .width('100%').fontSize(12).lineHeight(18).fontColor(ThunderbirdTheme.onSurfaceVariant)
        } else {
          this.outlinedInput('密码或授权码', this.secret, '输入邮箱授权码',
            (value: string) => this.secret = value, true)
        }

        if (this.manualSetup) {
          this.serverRow('收件服务器', this.incomingHost, this.incomingPort, true)
          Divider().color(ThunderbirdTheme.outlineVariant)
          this.serverRow('发件服务器', this.outgoingHost, this.outgoingPort, false)
        } else {
          Column({ space: 8 }) {
            Text(`收件服务器  ${this.incomingHost}:${this.incomingPort}`)
              .width('100%').fontSize(13).fontColor(ThunderbirdTheme.onSurface)
            Text(`发件服务器  ${this.outgoingHost}:${this.outgoingPort}`)
              .width('100%').fontSize(13).fontColor(ThunderbirdTheme.onSurface)
            Button('编辑配置').height(44).fontSize(13).fontColor(ThunderbirdTheme.primary)
              .backgroundColor(Color.Transparent).onClick(() => this.manualSetup = true)
          }.width('100%').padding(14).backgroundColor(ThunderbirdTheme.surfaceLow).borderRadius(8)
        }

        Button(this.isConnecting ? '正在验证…' :
          (findProvider(this.selectedProvider).authType === AuthType.OAUTH_PKCE ? '使用 OAuth 登录' : '连接'))
          .width('100%').height(50).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(ThunderbirdTheme.onPrimary).backgroundColor(ThunderbirdTheme.primary)
          .borderRadius(ThunderbirdTheme.controlRadius)
          .enabled(!this.isConnecting).onClick(() => this.connect())
      }
      .width('100%').padding({ left: 16, right: 16, top: 20, bottom: 28 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(ThunderbirdTheme.surfaceLowest)
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
  }

  build() {
    Column() {
      Row() {
        Button() {
          Image($r('app.media.ic_back')).width(23).height(23).objectFit(ImageFit.Contain)
        }
          .width(48).height(48).backgroundColor(Color.Transparent).onClick(() => this.goBack())
        Text(this.step === 0 ? '邮箱助手' : (this.step === 1 ? '登录账户' : '配置账户'))
          .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface)
        Row() {}.width(48)
      }
      .width('100%').height(56).padding({ left: 4, right: 4 })
      .backgroundColor(this.step === 0 ? ThunderbirdTheme.surface : ThunderbirdTheme.surfaceLowest)
      if (this.step === 0) {
        this.providerStep()
      } else if (this.step === 1) {
        this.emailStep()
      } else {
        this.configurationStep()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.step === 0 ? ThunderbirdTheme.surface : ThunderbirdTheme.surfaceLowest)
  }
}
