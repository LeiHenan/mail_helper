import { LocalMailRepository } from '../data/LocalMailRepository';
import { EmailAccount, EmailProviderType, MailAttachmentPayload, MailFolder, MailMessage } from '../model/MailModels';
import { AccountServerSettings, AuthenticationMethod, PendingMailOperation,
  PendingOperationType } from '../model/MailServerModels';
import { ImapClient, ImapMessagePage, ImapMessageRecord } from './ImapClient';
import { describeError } from './ErrorFormatter';
import { MailSendService, SendDeliveryResult } from './MailSendService';
import { OAuthResolvedCredential, OAuthService } from './OAuthService';

export class AccountSyncResult {
  accountId: string;
  accountName: string;
  receivedCount: number;
  errorMessage: string;
  hasMoreHistory: boolean;
  fetchedCount: number;
  // true 表示本次调用因为同账户已有同步在跑而被跳过（不是失败，errorMessage 保持为空）。
  skipped: boolean;

  constructor(accountId: string, accountName: string, receivedCount: number = 0, errorMessage: string = '',
    hasMoreHistory: boolean = false, fetchedCount: number = 0, skipped: boolean = false) {
    this.accountId = accountId;
    this.accountName = accountName;
    this.receivedCount = receivedCount;
    this.errorMessage = errorMessage;
    this.hasMoreHistory = hasMoreHistory;
    this.fetchedCount = fetchedCount;
    this.skipped = skipped;
  }
}

// 按 accountId 的账户级单飞表：前台的定时/下拉同步、账户详情页的“立即同步”和后台 WorkScheduler
// 都可能同时触发同一账户的服务器操作，重复执行会争抢同一个 IMAP 连接状态与同步游标。
// 放在模块级是因为各页面/扩展各自 new 了 MailAccountSyncService 实例。
// 覆盖范围是“每一个会新开 IMAP 会话的账户级操作”：synchronize、pushPendingOperations、loadOlder。
// 只保护 synchronize 时，星标/已读回推和加载历史会另开一条并发 IMAP 会话，导致 pending 队列被
// 重复执行（同一账户的连接被抢、命令超时）、retry_count 无谓堆积，投递草稿也可能被并发投两次。
const inFlightSyncs: Map<string, Promise<AccountSyncResult>> = new Map<string, Promise<AccountSyncResult>>();

export class MailAccountSyncService {
  private repository: LocalMailRepository;
  private oauthService: OAuthService = new OAuthService();
  private sendService: MailSendService;

  constructor(repository: LocalMailRepository) {
    this.repository = repository;
    this.sendService = new MailSendService(repository);
  }

  // 账户级单飞：同账户已有服务器操作在跑时直接返回 skipped=true（errorMessage 为空，UI 不当失败处理）。
  // 被跳过的工作不需要补偿性重跑：synchronize 自己会执行 pending 队列，本地已落库的星标/已读/移动
  // 等操作留在队列里等下一轮；history 由 skippedHasMoreHistory 让调用方继续保留“加载更早邮件”的能力。
  private async runAccountExclusive(account: EmailAccount, work: () => Promise<AccountSyncResult>,
    skippedHasMoreHistory: boolean = false): Promise<AccountSyncResult> {
    if (inFlightSyncs.has(account.id)) {
      return new AccountSyncResult(account.id, account.displayName, 0, '', skippedHasMoreHistory, 0, true);
    }
    // 注册与检查之间不能有 await：work() 虽会立即开始执行，但到它第一次 await 之前都同步运行，
    // 因此“检查 + 注册”对同一账户的其它调用是原子的。
    const run: Promise<AccountSyncResult> = work();
    inFlightSyncs.set(account.id, run);
    try {
      return await run;
    } finally {
      inFlightSyncs.delete(account.id);
    }
  }

  async pushPendingOperations(account: EmailAccount): Promise<AccountSyncResult> {
    return this.runAccountExclusive(account,
      (): Promise<AccountSyncResult> => this.runPushPendingOperations(account));
  }

  private async runPushPendingOperations(account: EmailAccount): Promise<AccountSyncResult> {
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

  // 同一账户的同步单飞（与 pushPendingOperations/loadOlder 共用同一张表）：已有服务器操作在跑时
  // 本次直接跳过（skipped=true，errorMessage 为空，不会被 UI 当成失败），避免两个 IMAP 会话争抢
  // 同一账户的游标/文件夹状态。shouldCancel 由后台任务传入（onWorkStop 置位），用于在文件夹边界中断同步。
  async synchronize(account: EmailAccount, shouldCancel?: () => boolean): Promise<AccountSyncResult> {
    return this.runAccountExclusive(account,
      (): Promise<AccountSyncResult> => this.runSynchronize(account, shouldCancel));
  }

  private async runSynchronize(account: EmailAccount,
    shouldCancel?: () => boolean): Promise<AccountSyncResult> {
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
        // 取消（后台任务被系统停止）时在文件夹边界中断：不写同步状态，游标停在原处，
        // 下轮同步重取该文件夹，不会漏邮件。
        if (this.isCancelled(shouldCancel)) {
          break;
        }
        const folder: MailFolder = folders[folderIndex];
        try {
          const initialized: boolean =
            (await this.repository.getSetting(this.stateKey('initialized', account.id, folder), 'false')) === 'true';
          const savedLastUid: number = Number.parseInt(
            await this.repository.getSetting(this.stateKey('last_uid', account.id, folder), '0'), 10);
          const savedUidValidity: string =
            await this.repository.getSetting(this.stateKey('uidvalidity', account.id, folder), '');
          const incremental: boolean = initialized && !refreshCoremailDates;
          let page: ImapMessagePage = incremental ?
            await client.fetchIncremental(folder, Number.isNaN(savedLastUid) ? 0 : savedLastUid) :
            await client.fetchInitial(folder, 30, 200);
          const uidValidityChanged: boolean = incremental && savedUidValidity.length > 0 &&
            page.uidValidity.length > 0 && savedUidValidity !== page.uidValidity;
          if (uidValidityChanged) {
            // UIDVALIDITY 变了：旧 UID 全部失效，先整目录清库（走仓库写入串行器）再走初始同步。
            // 否则同主键行 imap_<accountId>_<uid> 会被新邮件覆盖，没被覆盖的旧行成为幽灵邮件。
            const purged: number = await this.repository.purgeFolderMessages(account.id, folder);
            await this.repository.setSetting(this.stateKey('history_complete', account.id, folder), 'false');
            await this.repository.setSetting(`last_folder_uidvalidity_reset_${account.id}_${folder}`,
              `${purged}`);
            page = await client.fetchInitial(folder, 30, 200);
          }
          insertedCount += await this.storeRecords(account, folder, page.records);
          await this.reportSkippedUids(account.id, folder, page);
          const wasIncremental: boolean = initialized &&
            (savedUidValidity.length === 0 || savedUidValidity === page.uidValidity);
          await this.saveSyncState(account.id, folder, page,
            this.advanceCursor(page, savedLastUid, wasIncremental), wasIncremental);
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

  // 加载更早邮件也要过账户级单飞：它同样会新开 IMAP 会话并写 sync_* 状态（oldest_uid/history_complete），
  // 与正在跑的同步并发会让游标互相覆盖、重复拉取同一批历史邮件。
  // 被跳过时 hasMoreHistory 传 true：历史并没有读完，只是这次没跑，调用方要保留“还能继续加载”的状态。
  async loadOlder(account: EmailAccount, folder: MailFolder, limit: number = 50): Promise<AccountSyncResult> {
    return this.runAccountExclusive(account,
      (): Promise<AccountSyncResult> => this.runLoadOlder(account, folder, limit), true);
  }

  private async runLoadOlder(account: EmailAccount, folder: MailFolder,
    limit: number = 50): Promise<AccountSyncResult> {
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
      await this.reportSkippedUids(account.id, folder, page);
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

  // last_uid 以“实际入库的最大 UID”为准，而不是 SEARCH 结果的最大值：解析失败的邮件不会入库，
  // 游标若越过它们，这些邮件再也不会被重取（增量同步下等于永久丢新邮件）。
  // monotonic 为 true（增量且 UIDVALIDITY 未变）时游标只前进，不因单批全失败而倒退。
  private advanceCursor(page: ImapMessagePage, savedLastUid: number, monotonic: boolean): number {
    const previous: number = Number.isNaN(savedLastUid) ? 0 : savedLastUid;
    const highestStored: number = this.highestUid(page.records);
    let cursor: number = 0;
    if (highestStored > 0) {
      cursor = highestStored;
    } else if (page.records.length > 0 || page.skippedUids.length > 0) {
      // 本批全部读取/解析失败：游标停在原处，下次同步重试这些 UID。
      cursor = previous;
    } else {
      // 本轮没有需要拉取的邮件（窗口期内无新邮件）：沿用服务器给出的 UID 边界。
      cursor = page.highestUid;
    }
    return monotonic ? Math.max(previous, cursor) : cursor;
  }

  private highestUid(records: ImapMessageRecord[]): number {
    let highest: number = 0;
    for (let index: number = 0; index < records.length; index++) {
      const uid: number = Number.parseInt(records[index].uid, 10);
      if (!Number.isNaN(uid) && uid > highest) {
        highest = uid;
      }
    }
    return highest;
  }

  // 被跳过的邮件只跳过、不阻塞文件夹同步，这里留下可诊断记录。
  // 游标以实际入库的最大 UID 为准：若失败的是本批最新的几封，游标会停在它们之前，下轮自动重试；
  // 若失败邮件之下还有成功入库的更大 UID，则不再自动重取，只保留这里的记录。
  private async reportSkippedUids(accountId: string, folder: MailFolder,
    page: ImapMessagePage): Promise<void> {
    const sample: string = page.skippedUids.slice(0, 10).join(', ');
    await this.repository.setSetting(`last_folder_skipped_${accountId}_${folder}`,
      page.skippedUids.length === 0 ? '' :
        `${page.skippedUids.length} 封邮件读取失败，UID: ${sample}`);
  }

  private async saveSyncState(accountId: string, folder: MailFolder, page: ImapMessagePage,
    lastUid: number, wasIncremental: boolean): Promise<void> {
    await this.repository.setSetting(this.stateKey('initialized', accountId, folder), 'true');
    await this.repository.setSetting(this.stateKey('last_uid', accountId, folder), `${lastUid}`);
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
    const attachments: MailAttachmentPayload[][] = [];
    for (let index: number = 0; index < records.length; index++) {
      const record: ImapMessageRecord = records[index];
      const body: string = record.body;
      const preview: string = body.replace(/\s+/g, ' ').substring(0, 180);
      const messageId: string = folder === MailFolder.INBOX ? `imap_${account.id}_${record.uid}` :
        `imap_${account.id}_${folder}_${record.uid}`;
      messages.push(new MailMessage(messageId, account.id, folder,
        record.sender, record.recipients, record.subject, preview, body,
        this.displayTime(record.receivedAt), record.isRead, record.isStarred, record.hasAttachments,
        record.htmlBody, record.rfcMessageId));
      sortOrders.push(record.receivedAt);
      attachments.push(record.attachments);
    }
    return this.repository.upsertRemoteMessages(messages, sortOrders, attachments);
  }

  private stateKey(name: string, accountId: string, folder: MailFolder): string {
    const version: string = name === 'history_complete' ? 'v3' : 'v2';
    return `sync_${name}_${version}_${accountId}_${folder}`;
  }

  private isSynchronizedFolder(folder: MailFolder): boolean {
    return folder === MailFolder.INBOX || folder === MailFolder.SPAM || folder === MailFolder.TRASH;
  }

  private isCancelled(shouldCancel?: () => boolean): boolean {
    return shouldCancel !== undefined && shouldCancel();
  }

  private async executePendingOperations(client: ImapClient, accountId: string): Promise<string> {
    const delivery: SendDeliveryResult = await this.sendService.deliverPendingSends(accountId);
    let firstError: string = delivery.firstError;
    const operations: PendingMailOperation[] = await this.repository.listPendingOperations(accountId);
    for (let operationIndex: number = 0; operationIndex < operations.length; operationIndex++) {
      const operation: PendingMailOperation = operations[operationIndex];
      if (operation.type === PendingOperationType.SEND) {
        continue;
      }
      if (!client.isRemoteMessage(operation.messageId)) {
        // 种子/本地发送的邮件在服务器上没有 UID，状态变更只保留在本地
        await this.repository.acknowledgePendingOperation(operation.id);
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
