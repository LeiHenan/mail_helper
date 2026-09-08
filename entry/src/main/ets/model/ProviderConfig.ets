import { AuthType, EmailProviderType } from './MailModels';
import { AuthenticationMethod, ConnectionSecurity, MailProtocol, MailServerSettings } from './MailServerModels';

export class EmailProviderConfig {
  type: EmailProviderType;
  name: string;
  shortName: string;
  color: string;
  authType: AuthType;
  incoming?: MailServerSettings;
  outgoing?: MailServerSettings;
  oauthIssuer: string;
  helpText: string;

  constructor(type: EmailProviderType, name: string, shortName: string, color: string,
    authType: AuthType, incoming: MailServerSettings | undefined,
    outgoing: MailServerSettings | undefined, oauthIssuer: string = '', helpText: string = '') {
    this.type = type;
    this.name = name;
    this.shortName = shortName;
    this.color = color;
    this.authType = authType;
    this.incoming = incoming;
    this.outgoing = outgoing;
    this.oauthIssuer = oauthIssuer;
    this.helpText = helpText;
  }
}

export const EMAIL_PROVIDERS: EmailProviderConfig[] = [
  new EmailProviderConfig(
    EmailProviderType.QQ, 'QQ 邮箱', 'QQ', '#2878FF', AuthType.AUTHORIZATION_CODE,
    new MailServerSettings(MailProtocol.IMAP, 'imap.qq.com', 993, ConnectionSecurity.TLS,
      AuthenticationMethod.PASSWORD),
    new MailServerSettings(MailProtocol.SMTP, 'smtp.qq.com', 465, ConnectionSecurity.TLS,
      AuthenticationMethod.PASSWORD),
    '', '请在 QQ 邮箱设置中开启 IMAP/SMTP，并使用生成的授权码。'
  ),
  new EmailProviderConfig(
    EmailProviderType.NETEASE_163, '网易 163 邮箱', '163', '#D63B32', AuthType.AUTHORIZATION_CODE,
    new MailServerSettings(MailProtocol.IMAP, 'imap.163.com', 993, ConnectionSecurity.TLS,
      AuthenticationMethod.PASSWORD),
    new MailServerSettings(MailProtocol.SMTP, 'smtp.163.com', 465, ConnectionSecurity.TLS,
      AuthenticationMethod.PASSWORD),
    '', '请在 163 邮箱设置中开启 IMAP/SMTP，并使用客户端授权密码。'
  ),
  new EmailProviderConfig(
    EmailProviderType.GMAIL, 'Gmail', 'G', '#EA4335', AuthType.OAUTH_PKCE,
    new MailServerSettings(MailProtocol.IMAP, 'imap.gmail.com', 993, ConnectionSecurity.TLS,
      AuthenticationMethod.OAUTH2),
    new MailServerSettings(MailProtocol.SMTP, 'smtp.gmail.com', 587, ConnectionSecurity.STARTTLS,
      AuthenticationMethod.OAUTH2),
    'https://accounts.google.com', 'Gmail 使用 OAuth 2.0 登录，客户端不会接触邮箱密码。'
  ),
  new EmailProviderConfig(
    EmailProviderType.OUTLOOK, 'Outlook', 'O', '#0078D4', AuthType.OAUTH_PKCE,
    new MailServerSettings(MailProtocol.IMAP, 'outlook.office365.com', 993, ConnectionSecurity.TLS,
      AuthenticationMethod.OAUTH2),
    new MailServerSettings(MailProtocol.SMTP, 'smtp.office365.com', 587, ConnectionSecurity.STARTTLS,
      AuthenticationMethod.OAUTH2),
    'https://login.microsoftonline.com/common', 'Outlook 使用 Microsoft OAuth 2.0，可通过 IMAP/SMTP 或 Graph API 同步。'
  ),
  new EmailProviderConfig(
    EmailProviderType.CUSTOM, '其他邮箱', 'IMAP', '#7259D9', AuthType.AUTHORIZATION_CODE,
    undefined, undefined, '', '使用邮箱服务商提供的 IMAP/SMTP 地址、端口和授权码连接。'
  )
];

export function findProvider(type: EmailProviderType): EmailProviderConfig {
  for (let index: number = 0; index < EMAIL_PROVIDERS.length; index++) {
    if (EMAIL_PROVIDERS[index].type === type) {
      return EMAIL_PROVIDERS[index];
    }
  }
  return EMAIL_PROVIDERS[0];
}
