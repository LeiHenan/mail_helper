import { EmailProviderType } from '../model/MailModels';
import { EmailProviderConfig, findProvider } from '../model/ProviderConfig';
import { AccountServerSettings, MailServerSettings } from '../model/MailServerModels';

export class DiscoveryResult {
  settings?: AccountServerSettings;
  errorMessage: string;

  constructor(settings: AccountServerSettings | undefined, errorMessage: string = '') {
    this.settings = settings;
    this.errorMessage = errorMessage;
  }

  isSuccess(): boolean {
    return this.settings !== undefined;
  }
}

export class MailServerDiscovery {
  discover(email: string, preferredProvider?: EmailProviderType): DiscoveryResult {
    const normalized: string = email.trim().toLowerCase();
    const separator: number = normalized.lastIndexOf('@');
    if (separator <= 0 || separator === normalized.length - 1) {
      return new DiscoveryResult(undefined, '邮箱地址格式不正确');
    }

    const providerType: EmailProviderType = preferredProvider ?? this.providerForDomain(
      normalized.substring(separator + 1));
    const provider: EmailProviderConfig = findProvider(providerType);
    if (!provider.incoming || !provider.outgoing) {
      return new DiscoveryResult(undefined, '需要手动填写 IMAP/SMTP 服务器');
    }

    const incoming: MailServerSettings = this.withUsername(provider.incoming, normalized);
    const outgoing: MailServerSettings = this.withUsername(provider.outgoing, normalized);
    return new DiscoveryResult(new AccountServerSettings(provider.type, normalized, incoming, outgoing));
  }

  validate(settings: AccountServerSettings): string[] {
    const errors: string[] = [];
    this.validateEndpoint(settings.incoming, '收件服务器', errors);
    this.validateEndpoint(settings.outgoing, '发件服务器', errors);
    if (!settings.email.includes('@')) {
      errors.push('邮箱地址格式不正确');
    }
    return errors;
  }

  private providerForDomain(domain: string): EmailProviderType {
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

  private withUsername(source: MailServerSettings, username: string): MailServerSettings {
    return new MailServerSettings(source.protocol, source.host, source.port, source.security,
      source.authentication, username);
  }

  private validateEndpoint(settings: MailServerSettings, label: string, errors: string[]): void {
    if (settings.host.trim().length === 0 || !settings.host.includes('.')) {
      errors.push(`${label}地址不正确`);
    }
    if (settings.port < 1 || settings.port > 65535) {
      errors.push(`${label}端口范围应为 1-65535`);
    }
    if (settings.username.trim().length === 0) {
      errors.push(`${label}用户名不能为空`);
    }
  }
}
