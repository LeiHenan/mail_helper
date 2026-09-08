import { AuthType, EmailProviderType } from "@bundle:com.mailhelper.app/entry/ets/model/MailModels";
export class ServerEndpoint {
    host: string;
    port: number;
    tls: boolean;
    constructor(host: string, port: number, tls: boolean = true) {
        this.host = host;
        this.port = port;
        this.tls = tls;
    }
}
export class EmailProviderConfig {
    type: EmailProviderType;
    name: string;
    shortName: string;
    color: string;
    authType: AuthType;
    imap?: ServerEndpoint;
    smtp?: ServerEndpoint;
    oauthIssuer: string;
    helpText: string;
    constructor(type: EmailProviderType, name: string, shortName: string, color: string, authType: AuthType, imap: ServerEndpoint | undefined, smtp: ServerEndpoint | undefined, oauthIssuer: string = '', helpText: string = '') {
        this.type = type;
        this.name = name;
        this.shortName = shortName;
        this.color = color;
        this.authType = authType;
        this.imap = imap;
        this.smtp = smtp;
        this.oauthIssuer = oauthIssuer;
        this.helpText = helpText;
    }
}
export const EMAIL_PROVIDERS: EmailProviderConfig[] = [
    new EmailProviderConfig(EmailProviderType.QQ, 'QQ 邮箱', 'QQ', '#2878FF', AuthType.AUTHORIZATION_CODE, new ServerEndpoint('imap.qq.com', 993), new ServerEndpoint('smtp.qq.com', 465), '', '请在 QQ 邮箱设置中开启 IMAP/SMTP，并使用生成的授权码。'),
    new EmailProviderConfig(EmailProviderType.NETEASE_163, '网易 163 邮箱', '163', '#D63B32', AuthType.AUTHORIZATION_CODE, new ServerEndpoint('imap.163.com', 993), new ServerEndpoint('smtp.163.com', 465), '', '请在 163 邮箱设置中开启 IMAP/SMTP，并使用客户端授权密码。'),
    new EmailProviderConfig(EmailProviderType.GMAIL, 'Gmail', 'G', '#EA4335', AuthType.OAUTH_PKCE, undefined, undefined, 'https://accounts.google.com', 'Gmail 使用 OAuth 2.0 登录，客户端不会接触邮箱密码。'),
    new EmailProviderConfig(EmailProviderType.OUTLOOK, 'Outlook', 'O', '#0078D4', AuthType.OAUTH_PKCE, undefined, undefined, 'https://login.microsoftonline.com/common', 'Outlook 使用 Microsoft OAuth 2.0 和 Graph API。')
];
export function findProvider(type: EmailProviderType): EmailProviderConfig {
    for (let index: number = 0; index < EMAIL_PROVIDERS.length; index++) {
        if (EMAIL_PROVIDERS[index].type === type) {
            return EMAIL_PROVIDERS[index];
        }
    }
    return EMAIL_PROVIDERS[0];
}
