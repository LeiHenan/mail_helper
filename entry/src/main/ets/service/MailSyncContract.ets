import { EmailProviderType } from '../model/MailModels';

export class OAuthStartRequest {
  provider: EmailProviderType;
  redirectUri: string;
  codeChallenge: string;

  constructor(provider: EmailProviderType, redirectUri: string, codeChallenge: string) {
    this.provider = provider;
    this.redirectUri = redirectUri;
    this.codeChallenge = codeChallenge;
  }
}

export class PushRegistration {
  deviceToken: string;
  accountIds: string[];

  constructor(deviceToken: string, accountIds: string[]) {
    this.deviceToken = deviceToken;
    this.accountIds = accountIds;
  }
}

// Contract implemented by the future synchronization backend. It maintains
// IMAP IDLE/Gmail/Graph subscriptions and converts new-mail events to Push Kit.
export interface MailSyncService {
  startOAuth(request: OAuthStartRequest): Promise<string>;
  exchangeOAuthCode(provider: EmailProviderType, code: string, verifier: string): Promise<string>;
  registerPush(registration: PushRegistration): Promise<void>;
  triggerSync(accountId: string): Promise<void>;
}

