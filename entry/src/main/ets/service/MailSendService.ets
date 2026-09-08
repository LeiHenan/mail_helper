import { LocalMailRepository } from '../data/LocalMailRepository';
import { DraftMessage, EmailAccount } from '../model/MailModels';
import { AccountServerSettings, AuthenticationMethod } from '../model/MailServerModels';
import { OAuthResolvedCredential, OAuthService } from './OAuthService';
import { SmtpClient } from './SmtpClient';

export class MailSendService {
  private repository: LocalMailRepository;
  private oauthService: OAuthService = new OAuthService();

  constructor(repository: LocalMailRepository) {
    this.repository = repository;
  }

  async send(draft: DraftMessage): Promise<void> {
    const account: EmailAccount | undefined = (await this.repository.listAccounts())
      .find((item: EmailAccount) => item.id === draft.accountId);
    if (!account) {
      throw new Error('请选择发件账户');
    }
    const settings: AccountServerSettings | undefined =
      await this.repository.getAccountServerSettings(account.id);
    if (!settings || settings.outgoing.host.length === 0) {
      throw new Error('缺少 SMTP 发件服务器配置');
    }
    let credential: string = await this.repository.readAccountCredential(account.id);
    if (credential.length === 0) {
      throw new Error('没有可用的邮箱授权凭据，请重新添加账户');
    }
    if (settings.outgoing.authentication === AuthenticationMethod.OAUTH2) {
      const resolved: OAuthResolvedCredential = await this.oauthService.resolveAccessToken(
        account.provider, credential);
      credential = resolved.accessToken;
      if (resolved.wasRefreshed) {
        await this.repository.updateAccountCredential(account.id, resolved.serializedCredential);
      }
    }
    const client: SmtpClient = new SmtpClient();
    try {
      await client.send(settings.outgoing, account, credential, draft);
      await this.repository.recordSent(draft);
    } finally {
      await client.close();
    }
  }
}
