import { EmailProviderType } from '../model/MailModels';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const RAWFILE_NAME: string = 'oauth-clients.json';

interface OAuthClientEntry {
  clientId?: string;
  clientSecret?: string;
}

interface OAuthClientsFile {
  gmail?: OAuthClientEntry;
  outlook?: OAuthClientEntry;
}

export class OAuthClientConfig {
  clientId: string;
  clientSecret: string;

  constructor(clientId: string = '', clientSecret: string = '') {
    this.clientId = clientId;
    this.clientSecret = clientSecret;
  }

  isConfigured(): boolean {
    return this.clientId.trim().length > 0;
  }
}

let gmailClient: OAuthClientConfig = new OAuthClientConfig();
// Outlook 公共客户端使用 PKCE，不配置 Client Secret。
let outlookClient: OAuthClientConfig = new OAuthClientConfig();
let loaded: boolean = false;

// 从 rawfile/oauth-clients.json 读取 OAuth 客户端配置。
// 文件缺失或格式错误时保持空配置，OAuth 登录入口会引导用户完成配置而不是崩溃。
export function initializeOAuthClientConfigs(context: common.Context): void {
  if (loaded) {
    return;
  }
  loaded = true;
  try {
    const content: Uint8Array = context.resourceManager.getRawFileContentSync(RAWFILE_NAME);
    const text: string = new util.TextDecoder('utf-8').decode(content);
    const parsed: OAuthClientsFile = JSON.parse(text) as OAuthClientsFile;
    gmailClient = new OAuthClientConfig(parsed.gmail?.clientId ?? '', parsed.gmail?.clientSecret ?? '');
    outlookClient = new OAuthClientConfig(parsed.outlook?.clientId ?? '', parsed.outlook?.clientSecret ?? '');
  } catch (_error) {
    gmailClient = new OAuthClientConfig();
    outlookClient = new OAuthClientConfig();
  }
}

export function oauthClientConfig(provider: EmailProviderType): OAuthClientConfig {
  if (provider === EmailProviderType.GMAIL) {
    return gmailClient;
  }
  if (provider === EmailProviderType.OUTLOOK) {
    return outlookClient;
  }
  return new OAuthClientConfig();
}

export function isOAuthProviderConfigured(provider: EmailProviderType): boolean {
  return oauthClientConfig(provider).isConfigured();
}
