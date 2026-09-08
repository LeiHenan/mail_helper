import { EmailProviderType } from '../model/MailModels';
import oauthClients from './oauth-clients.json';

interface OAuthClientEntry {
  clientId: string;
  clientSecret: string;
}

interface OAuthClientsFile {
  gmail: OAuthClientEntry;
  outlook: OAuthClientEntry;
}

export class OAuthClientConfig {
  clientId: string;
  clientSecret: string;

  constructor(clientId: string, clientSecret: string = '') {
    this.clientId = clientId;
    this.clientSecret = clientSecret;
  }
}

const CLIENTS: OAuthClientsFile = oauthClients as OAuthClientsFile;

const GMAIL_CLIENT: OAuthClientConfig = new OAuthClientConfig(
  CLIENTS.gmail.clientId,
  CLIENTS.gmail.clientSecret
);

// Outlook 公共客户端使用 PKCE，不配置 Client Secret。
const OUTLOOK_CLIENT: OAuthClientConfig = new OAuthClientConfig(
  CLIENTS.outlook.clientId,
  CLIENTS.outlook.clientSecret
);

export function oauthClientConfig(provider: EmailProviderType): OAuthClientConfig {
  if (provider === EmailProviderType.GMAIL) {
    return GMAIL_CLIENT;
  }
  if (provider === EmailProviderType.OUTLOOK) {
    return OUTLOOK_CLIENT;
  }
  return new OAuthClientConfig('');
}
