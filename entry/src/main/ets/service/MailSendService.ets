import { LocalMailRepository } from '../data/LocalMailRepository';
import { DraftMessage, EmailAccount, SendStatus } from '../model/MailModels';
import { AccountServerSettings, AuthenticationMethod, PendingMailOperation,
  PendingOperationType } from '../model/MailServerModels';
import { describeError } from './ErrorFormatter';
import { OAuthResolvedCredential, OAuthService } from './OAuthService';
import { SmtpClient } from './SmtpClient';

const MAX_SEND_ATTEMPTS: number = 8;
const MAX_BACKOFF_MINUTES: number = 60;

const inFlightAccounts: Set<string> = new Set<string>();

class SendContext {
  account: EmailAccount;
  settings: AccountServerSettings;
  credential: string;

  constructor(account: EmailAccount, settings: AccountServerSettings, credential: string) {
    this.account = account;
    this.settings = settings;
    this.credential = credential;
  }
}

export class SendDeliveryResult {
  delivered: number;
  failed: number;
  firstError: string;

  constructor(delivered: number = 0, failed: number = 0, firstError: string = '') {
    this.delivered = delivered;
    this.failed = failed;
    this.firstError = firstError;
  }
}

export class MailSendService {
  private repository: LocalMailRepository;
  private oauthService: OAuthService = new OAuthService();

  constructor(repository: LocalMailRepository) {
    this.repository = repository;
  }

  async deliverPendingSends(accountId: string): Promise<SendDeliveryResult> {
    const result: SendDeliveryResult = new SendDeliveryResult();
    if (inFlightAccounts.has(accountId)) {
      return result;
    }
    inFlightAccounts.add(accountId);
    try {
      const now: number = Date.now();
      const operations: PendingMailOperation[] = (await this.repository.listPendingOperations(accountId))
        .filter((operation: PendingMailOperation) => operation.type === PendingOperationType.SEND &&
          (operation.nextRetryAt === 0 || operation.nextRetryAt <= now));
      if (operations.length === 0) {
        return result;
      }
      let context: SendContext;
      try {
        context = await this.resolveContext(accountId);
      } catch (error) {
        result.firstError = describeError(error);
        return result;
      }
      for (let index: number = 0; index < operations.length; index++) {
        const operation: PendingMailOperation = operations[index];
        const draft: DraftMessage | undefined =
          await this.repository.getSendableMessage(operation.messageId);
        if (!draft) {
          await this.repository.acknowledgePendingOperation(operation.id);
          continue;
        }
        try {
          await this.deliver(context, draft);
          await this.repository.markMessageSendStatus(operation.messageId, SendStatus.SENT);
          await this.repository.acknowledgePendingOperation(operation.id);
          result.delivered++;
        } catch (error) {
          result.failed++;
          if (result.firstError.length === 0) {
            result.firstError = describeError(error);
          }
          await this.recordDeliveryFailure(operation);
        }
      }
    } catch (error) {
      result.firstError = describeError(error);
    } finally {
      inFlightAccounts.delete(accountId);
    }
    return result;
  }

  private async recordDeliveryFailure(operation: PendingMailOperation): Promise<void> {
    const attempts: number = operation.retryCount + 1;
    if (attempts >= MAX_SEND_ATTEMPTS) {
      await this.repository.markMessageSendStatus(operation.messageId, SendStatus.FAILED);
      await this.repository.acknowledgePendingOperation(operation.id);
      return;
    }
    const delayMinutes: number = Math.min(Math.pow(2, attempts - 1), MAX_BACKOFF_MINUTES);
    await this.repository.reschedulePendingOperation(operation.id, attempts,
      Date.now() + delayMinutes * 60000);
  }

  private async deliver(context: SendContext, draft: DraftMessage): Promise<void> {
    const client: SmtpClient = new SmtpClient();
    try {
      await client.send(context.settings.outgoing, context.account, context.credential, draft);
    } finally {
      await client.close();
    }
  }

  private async resolveContext(accountId: string): Promise<SendContext> {
    const account: EmailAccount | undefined = (await this.repository.listAccounts())
      .find((item: EmailAccount) => item.id === accountId);
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
    return new SendContext(account, settings, credential);
  }
}
