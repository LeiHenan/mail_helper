import { LocalMailRepository } from '../data/LocalMailRepository';
import { EmailAccount, EmailProviderType, MailFolder, MailMessage } from '../model/MailModels';
import { AccountServerSettings, AuthenticationMethod, PendingMailOperation,
  PendingOperationType } from '../model/MailServerModels';
import { ImapClient, ImapMessagePage, ImapMessageRecord } from './ImapClient';
import { describeError } from './ErrorFormatter';
import { OAuthResolvedCredential, OAuthService } from './OAuthService';

export class AccountSyncResult {
  accountId: string;
  accountName: string;
  receivedCount: number;
  errorMessage: string;
  hasMoreHistory: boolean;
  fetchedCount: number;

  constructor(accountId: string, accountName: string, receivedCount: number = 0, errorMessage: string = '',
    hasMoreHistory: boolean = false, fetchedCount: number = 0) {
    this.accountId = accountId;
    this.accountName = accountName;
    this.receivedCount = receivedCount;
    this.errorMessage = errorMessage;
    this.hasMoreHistory = hasMoreHistory;
    this.fetchedCount = fetchedCount;
  }
}

export class MailAccountSyncService {
  private repository: LocalMailRepository;
  private oauthService: OAuthService = new OAuthService();

  constructor(repository: LocalMailRepository) {
    this.repository = repository;
  }

  async pushPendingOperations(account: EmailAccount): Promise<AccountSyncResult> {
    if (!account.syncEnabled) {
      return new AccountSyncResult(account.id, account.displayName, 0, '账户同步已暂停');
    }
    const settings: AccountServerSettings | undefined =
      await this.repository.getAccountServerSettings(account.id);
    if (!settings || settings.incoming.host.length === 0) {
      return new AccountSyncResult(account.id, account.displayName, 0, '缺少 IMAP 服务器配置');
    }
    let credential: string;
    try {
      credential = await this.resolveCredential(account, settings);
    } catch (error) {
      return new AccountSyncResult(account.id, account.displayName, 0, describeError(error));
    }
    if (credential.length === 0) {
      return new AccountSyncResult(account.id, account.displayName, 0, '没有可用的邮箱授权凭据');
    }
    const client: ImapClient = new ImapClient();
    try {
      const username: string = settings.incoming.username.length > 0 ? settings.incoming.username : account.email;
      await client.connect(settings.incoming, username, credential);
      const operationError: string = await this.executePendingOperations(client, account.id);
      return new AccountSyncResult(account.id, account.displayName, 0, operationError);
    } catch (error) {
      return new AccountSyncResult(account.id, account.displayName, 0, describeError(error));
    } finally {
      await client.close();
    }
  }

  async synchronize(account: EmailAccount): Promise<AccountSyncResult> {
    if (!account.syncEnabled) {
      return new AccountSyncResult(account.id, account.displayName, 0, '账户同步已暂停');
    }
    const settings: AccountServerSettings | undefined =
      await this.repository.getAccountServerSettings(account.id);
    if (!settings || settings.incoming.host.length === 0) {
      return new AccountSyncResult(account.id, account.displayName, 0, '缺少 IMAP 服务器配置');
    }
    let credential: string;
    try {
      credential = await this.resolveCredential(account, settings);
    } catch (error) {
      return new AccountSyncResult(account.id, account.displayName, 0, describeError(error));
    }
    if (credential.length === 0) {
      return new AccountSyncResult(account.id, account.displayName, 0, '没有可用的邮箱授权凭据');
    }
    const client: ImapClient = new ImapClient();
    try {
      const username: string = settings.incoming.username.length > 0 ? settings.incoming.username : account.email;
      await client.connect(settings.incoming, username, credential);
      await this.executePendingOperations(client, account.id);
      const folders: MailFolder[] = [MailFolder.INBOX, MailFolder.SPAM, MailFolder.TRASH];
      const refreshCoremailDates: boolean = account.provider === EmailProviderType.NETEASE_163 &&
        (await this.repository.getSetting(`coremail_date_parser_v3_${account.id}`, 'false')) !== 'true';
      let insertedCount: number = 0;
      for (let folderIndex: number = 0; folderIndex < folders.length; folderIndex++) {
        const folder: MailFolder = folders[folderIndex];
        let page: ImapMessagePage;
        try {
          const initialized: boolean =
            (await this.repository.getSetting(this.stateKey('initialized', account.id, folder), 'false')) === 'true';
          const savedLastUid: number = Number.parseInt(
            await this.repository.getSetting(this.stateKey('last_uid', account.id, folder), '0'), 10);
          const savedUidValidity: string =
            await this.repository.getSetting(this.stateKey('uidvalidity', account.id, folder), '');
          if (!initialized || refreshCoremailDates) {
            page = await client.fetchInitial(folder, 30, 200);
          } else {
            page = await client.fetchIncremental(folder, Number.isNaN(savedLastUid) ? 0 : savedLastUid);
            if (savedUidValidity.length > 0 && page.uidValidity.length > 0 &&
              savedUidValidity !== page.uidValidity) {
              page = await client.fetchInitial(folder, 30, 200);
              await this.repository.setSetting(this.stateKey('history_complete', account.id, folder), 'false');
            } else if (!Number.isNaN(savedLastUid)) {
              page.highestUid = Math.max(savedLastUid, page.highestUid);
            }
          }
          insertedCount += await this.storeRecords(account, folder, page.records);
          await this.saveSyncState(account.id, folder, page, initialized &&
            (savedUidValidity.length === 0 || savedUidValidity === page.uidValidity));
        } catch (error) {
          if (folder === MailFolder.INBOX) throw new Error(describeError(error));
          await this.repository.setSetting(`last_folder_error_${account.id}_${folder}`, describeError(error));
          continue;
        }
        await this.repository.setSetting(`last_folder_error_${account.id}_${folder}`, '');
      }
      if (refreshCoremailDates) {
        await this.repository.setSetting(`coremail_date_parser_v3_${account.id}`, 'true');
      }
      await this.repository.setSetting(`last_sync_${account.id}`, `${Date.now()}`);
      return new AccountSyncResult(account.id, account.displayName, insertedCount);
    } catch (error) {
      return new AccountSyncResult(account.id, account.displayName, 0, describeError(error));
    } finally {
      await client.close();
    }
  }

  async loadOlder(account: EmailAccount, folder: MailFolder, limit: number = 50): Promise<AccountSyncResult> {
    if (!account.syncEnabled) {
      return new AccountSyncResult(account.id, account.displayName, 0, '账户同步已暂停');
    }
    if (!this.isSynchronizedFolder(folder)) {
      return new AccountSyncResult(account.id, account.displayName, 0, '此文件夹暂不支持加载历史邮件');
    }
    const historyComplete: boolean =
      (await this.repository.getSetting(this.stateKey('history_complete', account.id, folder), 'false')) === 'true';
    if (historyComplete) {
      return new AccountSyncResult(account.id, account.displayName);
    }
    const settings: AccountServerSettings | undefined =
      await this.repository.getAccountServerSettings(account.id);
    if (!settings || settings.incoming.host.length === 0) {
      return new AccountSyncResult(account.id, account.displayName, 0, '缺少 IMAP 服务器配置');
    }
    let credential: string;
    try {
      credential = await this.resolveCredential(account, settings);
    } catch (error) {
      return new AccountSyncResult(account.id, account.displayName, 0, describeError(error));
    }
    if (credential.length === 0) {
      return new AccountSyncResult(account.id, account.displayName, 0, '没有可用的邮箱授权凭据');
    }
    const initialized: boolean =
      (await this.repository.getSetting(this.stateKey('initialized', account.id, folder), 'false')) === 'true';
    if (!initialized) {
      return new AccountSyncResult(account.id, account.displayName, 0, '请先同步当前邮箱文件夹');
    }
    const oldestUidValue: number = Number.parseInt(
      await this.repository.getSetting(this.stateKey('oldest_uid', account.id, folder), '0'), 10);
    const oldestUid: number = Number.isNaN(oldestUidValue) ? 0 : oldestUidValue;
    const savedUidValidity: string =
      await this.repository.getSetting(this.stateKey('uidvalidity', account.id, folder), '');
    const client: ImapClient = new ImapClient();
    try {
      const username: string = settings.incoming.username.length > 0 ? settings.incoming.username : account.email;
      await client.connect(settings.incoming, username, credential);
      const page: ImapMessagePage = await client.fetchOlder(folder, oldestUid, limit);
      if (savedUidValidity.length > 0 && page.uidValidity.length > 0 &&
        savedUidValidity !== page.uidValidity) {
        return new AccountSyncResult(account.id, account.displayName, 0, '邮箱文件夹已重建，请先同步');
      }
      const insertedCount: number = await this.storeRecords(account, folder, page.records);
      if (page.lowestUid > 0) {
        await this.repository.setSetting(this.stateKey('oldest_uid', account.id, folder), `${page.lowestUid}`);
      }
      await this.repository.setSetting(this.stateKey('history_complete', account.id, folder),
        page.hasMore && page.records.length > 0 ? 'false' : 'true');
      return new AccountSyncResult(account.id, account.displayName, insertedCount, '',
        page.hasMore, page.records.length);
    } catch (error) {
      return new AccountSyncResult(account.id, account.displayName, 0, describeError(error));
    } finally {
      await client.close();
    }
  }

  private async saveSyncState(accountId: string, folder: MailFolder, page: ImapMessagePage,
    wasIncremental: boolean): Promise<void> {
    await this.repository.setSetting(this.stateKey('initialized', accountId, folder), 'true');
    await this.repository.setSetting(this.stateKey('last_uid', accountId, folder), `${page.highestUid}`);
    await this.repository.setSetting(this.stateKey('uidvalidity', accountId, folder), page.uidValidity);
    if (!wasIncremental) {
      await this.repository.setSetting(this.stateKey('oldest_uid', accountId, folder), `${page.lowestUid}`);
      await this.repository.setSetting(this.stateKey('history_complete', accountId, folder),
        page.hasMore ? 'false' : 'true');
    }
  }

  private async resolveCredential(account: EmailAccount, settings: AccountServerSettings): Promise<string> {
    const storedCredential: string = await this.repository.readAccountCredential(account.id);
    if (storedCredential.length === 0 ||
      settings.incoming.authentication !== AuthenticationMethod.OAUTH2) {
      return storedCredential;
    }
    const resolved: OAuthResolvedCredential = await this.oauthService.resolveAccessToken(
      account.provider, storedCredential);
    if (resolved.wasRefreshed) {
      await this.repository.updateAccountCredential(account.id, resolved.serializedCredential);
    }
    return resolved.accessToken;
  }

  private async storeRecords(account: EmailAccount, folder: MailFolder,
    records: ImapMessageRecord[]): Promise<number> {
    const messages: MailMessage[] = [];
    const sortOrders: number[] = [];
    for (let index: number = 0; index < records.length; index++) {
      const record: ImapMessageRecord = records[index];
      const body: string = record.body;
      const preview: string = body.replace(/\s+/g, ' ').substring(0, 180);
      const messageId: string = folder === MailFolder.INBOX ? `imap_${account.id}_${record.uid}` :
        `imap_${account.id}_${folder}_${record.uid}`;
      messages.push(new MailMessage(messageId, account.id, folder,
        record.sender, record.recipients, record.subject, preview, body,
        this.displayTime(record.receivedAt), record.isRead, record.isStarred, record.hasAttachments,
        record.htmlBody));
      sortOrders.push(record.receivedAt);
    }
    return this.repository.upsertRemoteMessages(messages, sortOrders);
  }

  private stateKey(name: string, accountId: string, folder: MailFolder): string {
    const version: string = name === 'history_complete' ? 'v3' : 'v2';
    return `sync_${name}_${version}_${accountId}_${folder}`;
  }

  private isSynchronizedFolder(folder: MailFolder): boolean {
    return folder === MailFolder.INBOX || folder === MailFolder.SPAM || folder === MailFolder.TRASH;
  }

  private async executePendingOperations(client: ImapClient, accountId: string): Promise<string> {
    const operations: PendingMailOperation[] = await this.repository.listPendingOperations(accountId);
    let firstError: string = '';
    for (let operationIndex: number = 0; operationIndex < operations.length; operationIndex++) {
      const operation: PendingMailOperation = operations[operationIndex];
      if (operation.type === PendingOperationType.SEND) {
        continue;
      }
      try {
        await client.execute(operation);
        await this.repository.acknowledgePendingOperation(operation.id);
      } catch (error) {
        await this.repository.recordPendingOperationFailure(operation.id);
        if (firstError.length === 0) {
          firstError = describeError(error);
        }
      }
    }
    return firstError;
  }

  private displayTime(timestamp: number): string {
    const date: Date = new Date(timestamp);
    const now: Date = new Date();
    const hour: string = `${date.getHours()}`.padStart(2, '0');
    const minute: string = `${date.getMinutes()}`.padStart(2, '0');
    if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() &&
      date.getDate() === now.getDate()) {
      return `${hour}:${minute}`;
    }
    return `${date.getMonth() + 1}月${date.getDate()}日 ${hour}:${minute}`;
  }
}
