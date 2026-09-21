import { Context } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import BuildProfile from 'BuildProfile';
import { CredentialVault, HuksCredentialVault, MemoryCredentialVault } from '../security/CredentialVault';
import { DraftMessage, EmailAccount, EmailProviderType, MailAddress, MailAttachment, MailAttachmentPayload,
  MailFolder, MailFolderCounts, MailMessage, SendStatus } from '../model/MailModels';
import { AccountServerSettings, AuthenticationMethod, ConnectionSecurity, MailProtocol, MailServerSettings,
  PendingMailOperation, PendingOperationType } from '../model/MailServerModels';
import { findProvider } from '../model/ProviderConfig';
import { MailRepository, MailSummaryQuery } from './MailRepository';
import { PendingOperationStore } from './PendingOperationStore';
import { AttachmentFileStore } from './AttachmentFileStore';
import { MimeHeaderDecoder } from '../service/MimeHeaderDecoder';
import { newMessageId } from '../common/MessageId';

const DATABASE_NAME: string = 'mail_helper.db';
const DATABASE_VERSION: number = 9;
// 演示数据只写一次：标记写进 app_settings 后，用户即使删光账户重启也不会再被写入示例账户 / 邮件。
const SEEDED_SETTING_KEY: string = 'seeded';
// 列表页只需要摘要列：跳过 plain_body/html_body 大字段，避免整表正文进入内存。
// sort_order 是 epoch 毫秒，列表的日期分组 / 行内时间 / 键集分页游标都依赖它，必须带上。
const SUMMARY_COLUMNS: string = `id, account_id, folder, sender_name, sender_address, recipient_name,
  recipient_address, subject, preview, received_at, is_read, is_starred, has_attachments,
  rfc_message_id, in_reply_to, sort_order`;
// SQLite 变量绑定上限约为 999，批量 IN 查询按 500 分批。
const BIND_BATCH_SIZE: number = 500;
// limit <= 0 表示不限制条数。
const NO_LIMIT: number = 0;
// sort_order 的时间语义下限（2000-01-01）：小于它的值一定不是 epoch 毫秒，
// 而是 8 及更早版本的示例数据用的自增序号，需要按迁移回填成时间戳。
const MIN_EPOCH_SORT_ORDER: number = 946684800000;

export class LocalMailRepository implements MailRepository, PendingOperationStore {
  private static instance: LocalMailRepository = new LocalMailRepository();
  private store?: relationalStore.RdbStore = undefined;
  private initialization?: Promise<void> = undefined;
  private vault: CredentialVault = new MemoryCredentialVault();
  private operationSequence: number = 0;
  // 仓库级写入串行器：所有写库公共路径都接到同一条 promise 链上排队，任何时刻只有一个写任务
  // （及其事务）在跑，避免同步事务与 UI 写入并发嵌套——内层 rollBack 会结束外层事务、外层 commit
  // 随之失败，整批邮件可能被静默丢弃。读路径（list/get/count/getSetting）不进串行器。
  private writeChain: Promise<void> = Promise.resolve();
  private serialSegmentActive: boolean = false;
  private transactionDepth: number = 0;
  private headerDecoder: MimeHeaderDecoder = new MimeHeaderDecoder();
  private attachmentFiles: AttachmentFileStore = new AttachmentFileStore('');

  private constructor() {
  }

  static shared(): LocalMailRepository {
    return LocalMailRepository.instance;
  }

  initialize(context: Context): Promise<void> {
    if (this.store) {
      return Promise.resolve();
    }
    if (!this.initialization) {
      this.initialization = this.openDatabase(context);
    }
    return this.initialization;
  }

  private async openDatabase(context: Context): Promise<void> {
    this.vault = new HuksCredentialVault(context);
    this.attachmentFiles = new AttachmentFileStore(context.filesDir);
    const config: relationalStore.StoreConfig = {
      name: DATABASE_NAME,
      securityLevel: relationalStore.SecurityLevel.S2
    };
    this.store = await relationalStore.getRdbStore(context, config);
    await this.enqueueWrite(async (): Promise<void> => {
      await this.createSchema();
      await this.seedDemoDataOnce();
      await this.recoverStuckSends();
    });
  }

  private requireStore(): relationalStore.RdbStore {
    if (!this.store) {
      throw new Error('邮件数据库尚未初始化');
    }
    return this.store;
  }

  private async createSchema(): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    const previousVersion: number = store.version;
    await store.executeSql(`CREATE TABLE IF NOT EXISTS accounts (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL,
      display_name TEXT NOT NULL,
      provider TEXT NOT NULL,
      color TEXT NOT NULL,
      credential_ref TEXT NOT NULL DEFAULT '',
      sync_enabled INTEGER NOT NULL DEFAULT 1,
      incoming_host TEXT NOT NULL DEFAULT '',
      incoming_port INTEGER NOT NULL DEFAULT 993,
      incoming_security TEXT NOT NULL DEFAULT 'tls',
      incoming_authentication TEXT NOT NULL DEFAULT 'password',
      incoming_username TEXT NOT NULL DEFAULT '',
      outgoing_host TEXT NOT NULL DEFAULT '',
      outgoing_port INTEGER NOT NULL DEFAULT 465,
      outgoing_security TEXT NOT NULL DEFAULT 'tls',
      outgoing_authentication TEXT NOT NULL DEFAULT 'password',
      outgoing_username TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL
    )`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      account_id TEXT NOT NULL,
      folder TEXT NOT NULL,
      sender_name TEXT NOT NULL,
      sender_address TEXT NOT NULL,
      recipient_name TEXT NOT NULL DEFAULT '',
      recipient_address TEXT NOT NULL DEFAULT '',
      subject TEXT NOT NULL DEFAULT '',
      preview TEXT NOT NULL DEFAULT '',
      plain_body TEXT NOT NULL DEFAULT '',
      html_body TEXT NOT NULL DEFAULT '',
      received_at TEXT NOT NULL DEFAULT '',
      is_read INTEGER NOT NULL DEFAULT 0,
      is_starred INTEGER NOT NULL DEFAULT 0,
      has_attachments INTEGER NOT NULL DEFAULT 0,
      request_read_receipt INTEGER NOT NULL DEFAULT 0,
      rfc_message_id TEXT NOT NULL DEFAULT '',
      in_reply_to TEXT NOT NULL DEFAULT '',
      send_status TEXT NOT NULL DEFAULT '',
      sort_order INTEGER NOT NULL,
      FOREIGN KEY(account_id) REFERENCES accounts(id) ON DELETE CASCADE
    )`);
    await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_messages_folder_account
      ON messages(folder, account_id, sort_order DESC)`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS message_addresses (
      message_id TEXT NOT NULL,
      address_type TEXT NOT NULL,
      position INTEGER NOT NULL,
      display_name TEXT NOT NULL DEFAULT '',
      address TEXT NOT NULL,
      PRIMARY KEY(message_id, address_type, position),
      FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
    )`);
    await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_message_addresses_message
      ON message_addresses(message_id, address_type, position)`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS message_attachments (
      id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL,
      uri TEXT NOT NULL,
      display_name TEXT NOT NULL,
      mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
      size INTEGER NOT NULL DEFAULT 0,
      is_inline INTEGER NOT NULL DEFAULT 0,
      position INTEGER NOT NULL,
      FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
    )`);
    await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_message_attachments_message
      ON message_attachments(message_id, position)`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS pending_operations (
      id TEXT PRIMARY KEY,
      account_id TEXT NOT NULL,
      message_id TEXT NOT NULL DEFAULT '',
      operation_type TEXT NOT NULL,
      payload TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      next_retry_at INTEGER NOT NULL DEFAULT 0
    )`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS app_settings (
      setting_key TEXT PRIMARY KEY,
      setting_value TEXT NOT NULL
    )`);
    if (previousVersion < 2) {
      await store.executeSql(`INSERT OR IGNORE INTO message_addresses
        (message_id, address_type, position, display_name, address)
        SELECT id, 'to', 0, recipient_name, recipient_address FROM messages
        WHERE recipient_address <> ''`);
    }
    if (previousVersion > 0 && previousVersion < 3) {
      await store.executeSql(
        'ALTER TABLE messages ADD COLUMN request_read_receipt INTEGER NOT NULL DEFAULT 0');
    }
    if (previousVersion > 0 && previousVersion < 5) {
      await store.executeSql("ALTER TABLE accounts ADD COLUMN incoming_host TEXT NOT NULL DEFAULT ''");
      await store.executeSql('ALTER TABLE accounts ADD COLUMN incoming_port INTEGER NOT NULL DEFAULT 993');
      await store.executeSql("ALTER TABLE accounts ADD COLUMN incoming_security TEXT NOT NULL DEFAULT 'tls'");
      await store.executeSql(
        "ALTER TABLE accounts ADD COLUMN incoming_authentication TEXT NOT NULL DEFAULT 'password'");
      await store.executeSql("ALTER TABLE accounts ADD COLUMN incoming_username TEXT NOT NULL DEFAULT ''");
      await store.executeSql("ALTER TABLE accounts ADD COLUMN outgoing_host TEXT NOT NULL DEFAULT ''");
      await store.executeSql('ALTER TABLE accounts ADD COLUMN outgoing_port INTEGER NOT NULL DEFAULT 465');
      await store.executeSql("ALTER TABLE accounts ADD COLUMN outgoing_security TEXT NOT NULL DEFAULT 'tls'");
      await store.executeSql(
        "ALTER TABLE accounts ADD COLUMN outgoing_authentication TEXT NOT NULL DEFAULT 'password'");
      await store.executeSql("ALTER TABLE accounts ADD COLUMN outgoing_username TEXT NOT NULL DEFAULT ''");
    }
    if (previousVersion > 0 && previousVersion < 6) {
      await store.executeSql("ALTER TABLE messages ADD COLUMN html_body TEXT NOT NULL DEFAULT ''");
    }
    if (previousVersion > 0 && previousVersion < 7) {
      await store.executeSql(
        'ALTER TABLE message_attachments ADD COLUMN is_inline INTEGER NOT NULL DEFAULT 0');
    }
    if (previousVersion > 0 && previousVersion < 8) {
      await store.executeSql("ALTER TABLE messages ADD COLUMN rfc_message_id TEXT NOT NULL DEFAULT ''");
      await store.executeSql("ALTER TABLE messages ADD COLUMN in_reply_to TEXT NOT NULL DEFAULT ''");
      await store.executeSql("ALTER TABLE messages ADD COLUMN send_status TEXT NOT NULL DEFAULT ''");
      await store.executeSql(
        'ALTER TABLE pending_operations ADD COLUMN next_retry_at INTEGER NOT NULL DEFAULT 0');
    }
    if (previousVersion > 0 && previousVersion < 9) {
      // 8 及更早版本的示例数据把自增序号当 sort_order，日期分组与行内时间按它算会落到 1970 年。
      // 只回填明显不是时间戳的行（真实邮件来自 IMAP，写的一直是 epoch 毫秒）。
      await store.executeSql(
        'UPDATE messages SET sort_order = ? WHERE sort_order > 0 AND sort_order < ?',
        [Date.now(), MIN_EPOCH_SORT_ORDER]);
    }
    store.version = DATABASE_VERSION;
  }

  // 演示数据只在 debug 构建、且从未写过演示数据、且账户表为空时才落库：
  // release 包不写演示数据；一次性标记（app_settings.seeded）保证用户删光账户后不会复活示例数据。
  // 这里直接写 app_settings 而不走 setSetting：本方法已在 enqueueWrite 串行段内，
  // 再入队会等自己所在的串行段结束，形成死锁。
  private async seedDemoDataOnce(): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    const seeded: relationalStore.ResultSet = await store.querySql(
      'SELECT setting_value FROM app_settings WHERE setting_key = ? LIMIT 1', [SEEDED_SETTING_KEY]);
    let alreadySeeded: boolean = false;
    try {
      alreadySeeded = seeded.goToFirstRow() &&
        seeded.getString(seeded.getColumnIndex('setting_value')) === 'true';
    } finally {
      seeded.close();
    }
    if (alreadySeeded) {
      return;
    }
    const result: relationalStore.ResultSet = await store.querySql('SELECT COUNT(*) AS total FROM accounts');
    let count: number = 0;
    try {
      if (result.goToFirstRow()) {
        count = result.getLong(result.getColumnIndex('total'));
      }
    } finally {
      result.close();
    }
    if (count > 0) {
      await this.markSeeded();
      return;
    }
    if (BuildProfile.DEBUG) {
      await this.writeDemoData();
    }
    await this.markSeeded();
  }

  private async markSeeded(): Promise<void> {
    await this.requireStore().executeSql(
      'INSERT OR REPLACE INTO app_settings (setting_key, setting_value) VALUES (?, ?)',
      [SEEDED_SETTING_KEY, 'true']);
  }

  private async writeDemoData(): Promise<void> {
    const qq: EmailAccount = new EmailAccount('account_qq', 'hello@qq.com', '工作邮箱',
      EmailProviderType.QQ, '#2878FF', '', 0);
    const gmail: EmailAccount = new EmailAccount('account_gmail', 'hello@gmail.com', '个人邮箱',
      EmailProviderType.GMAIL, '#94A3B8', '', 0, false);
    const netease: EmailAccount = new EmailAccount('account_163', 'work_account@163.com', '163 邮箱',
      EmailProviderType.NETEASE_163, '#24A6A1');
    const outlook: EmailAccount = new EmailAccount('account_outlook', 'business@outlook.com', 'Outlook',
      EmailProviderType.OUTLOOK, '#5367F8');
    const accounts: EmailAccount[] = [qq, netease, gmail, outlook];
    for (let index: number = 0; index < accounts.length; index++) {
      await this.insertAccount(accounts[index], index + 1);
    }

    const messages: MailMessage[] = [
      new MailMessage('mail_1', qq.id, MailFolder.INBOX,
        new MailAddress('HarmonyOS 团队', 'developer@harmonyos.com'), [new MailAddress('我', qq.email)],
        'NEXT 版本更新说明与开发指南',
        '您好，全新的 HarmonyOS NEXT 开发者预览版已经发布。本次更新带来了全新的原生 UI 框架。',
        '团队成员大家好，\n\n随着第四季度的深入，我们的核心产品线即将迎来关键里程碑。为了确保按时交付并保证质量，我计划在下周二下午召开一次全面的进度评审会议。\n\n本次会议的主要议题包括：\n1. 各模块当前开发进度与目标核对。\n2. 识别并解决可能存在的研发阻塞点。\n3. 根据最新市场反馈调整后续资源。\n\n请大家在会前仔细阅读附件中的季度报告草案和进度追踪表。\n\n祝好，\nHarmonyOS 团队',
        '09:41', false, true, true),
      new MailMessage('mail_2', netease.id, MailFolder.INBOX,
        new MailAddress('财务部 - 张伟', 'finance@company.com'), [new MailAddress('我', netease.email)],
        '2023年第四季度报销审批进度通知',
        '您的Q4季度差旅报销申请已通过最终审批，预计款项将在3个工作日内到账。',
        '您的Q4季度差旅报销申请已通过最终审批，预计款项将在3个工作日内打入您的工资卡账户，请注意查收。',
        '08:15', true, false, false),
      new MailMessage('mail_3', outlook.id, MailFolder.INBOX,
        new MailAddress('设计系统周报', 'design@example.com'), [new MailAddress('我', outlook.email)],
        '【第42期】全新组件库资产已上线',
        '本周我们完成了 24 个核心组件的视觉规范升级，并引入了全新的微动效体系。',
        '本周我们完成了 24 个核心组件的视觉规范升级。重点优化了深色模式下的对比度问题，并引入了全新的微动效体系。',
        '昨天 16:30', false, false, false),
      new MailMessage('mail_4', gmail.id, MailFolder.INBOX,
        new MailAddress('Mozilla 社区', 'community@mozilla.org'), [new MailAddress('我', gmail.email)],
        '欢迎加入开放互联网社区', '感谢你关注开放互联网。本期社区通讯包含隐私、安全和开源项目的最新动态。',
        '感谢你关注开放互联网。\n\n本期社区通讯包含隐私、安全和开源项目的最新动态，也欢迎参与社区活动。',
        '周一', true, true, false),
      new MailMessage('mail_5', qq.id, MailFolder.SENT,
        new MailAddress('我', qq.email), [new MailAddress('产品团队', 'product@example.com')],
        'Re: NEXT 版本发布计划', '已收到，发布前我会完成最终检查。',
        '已收到，发布前我会完成最终检查。', '周日', true, false, false),
      new MailMessage('mail_6', netease.id, MailFolder.DRAFTS,
        new MailAddress('我', netease.email), [new MailAddress('', 'finance@company.com')],
        '报销材料补充说明', '附件中的发票信息已经重新整理。',
        '附件中的发票信息已经重新整理。', '周六', true, false, true)
    ];
    // 种子邮件的 sort_order 必须是真实 epoch 毫秒：列表的日期分组、行内时间与分页游标都按它算，
    // 用自增序号会让全部示例邮件落到 1970 年。时间点与上面的展示串（今天 09:41 / 昨天 16:30 等）对应。
    const midnight: number = new Date(new Date().getFullYear(), new Date().getMonth(),
      new Date().getDate()).getTime();
    const hourMs: number = 60 * 60 * 1000;
    const seedTimes: number[] = [
      midnight + 9 * hourMs + 41 * 60 * 1000,
      midnight + 8 * hourMs + 15 * 60 * 1000,
      midnight - 24 * hourMs + 16 * hourMs + 30 * 60 * 1000,
      midnight - 2 * 24 * hourMs,
      midnight - 3 * 24 * hourMs,
      midnight - 4 * 24 * hourMs
    ];
    for (let index: number = 0; index < messages.length; index++) {
      await this.insertMessage(messages[index], seedTimes[index]);
    }
  }

  private async insertAccount(account: EmailAccount, createdAt: number = Date.now(),
    settings?: AccountServerSettings): Promise<void> {
    const providerSettings = findProvider(account.provider);
    const incoming: MailServerSettings = settings?.incoming ?? providerSettings.incoming ??
      new MailServerSettings(MailProtocol.IMAP, '', 993, ConnectionSecurity.TLS,
        AuthenticationMethod.PASSWORD, account.email);
    const outgoing: MailServerSettings = settings?.outgoing ?? providerSettings.outgoing ??
      new MailServerSettings(MailProtocol.SMTP, '', 465, ConnectionSecurity.TLS,
        AuthenticationMethod.PASSWORD, account.email);
    await this.requireStore().executeSql(
      `INSERT OR REPLACE INTO accounts
      (id, email, display_name, provider, color, credential_ref, sync_enabled,
       incoming_host, incoming_port, incoming_security, incoming_authentication, incoming_username,
       outgoing_host, outgoing_port, outgoing_security, outgoing_authentication, outgoing_username, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [account.id, account.email, account.displayName, account.provider, account.color,
        account.credentialRef, account.syncEnabled ? 1 : 0,
        incoming.host, incoming.port, incoming.security, incoming.authentication,
        incoming.username.length > 0 ? incoming.username : account.email,
        outgoing.host, outgoing.port, outgoing.security, outgoing.authentication,
        outgoing.username.length > 0 ? outgoing.username : account.email, createdAt]
    );
  }

  private async insertMessage(message: MailMessage, sortOrder: number = Date.now(),
    cc: MailAddress[] = [], bcc: MailAddress[] = [], attachments: MailAttachment[] = [],
    requestReadReceipt: boolean = false, sendStatus: SendStatus | '' = ''): Promise<void> {
    const recipient: MailAddress = message.recipients.length > 0 ? message.recipients[0] : new MailAddress('', '');
    await this.requireStore().executeSql(
      `INSERT OR REPLACE INTO messages
      (id, account_id, folder, sender_name, sender_address, recipient_name, recipient_address,
       subject, preview, plain_body, html_body, received_at, is_read, is_starred, has_attachments,
       request_read_receipt, rfc_message_id, in_reply_to, send_status, sort_order)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [message.id, message.accountId, message.folder, message.sender.name, message.sender.address,
        recipient.name, recipient.address, message.subject, message.preview, message.plainBody,
        message.htmlBody, message.receivedAt, message.isRead ? 1 : 0, message.isStarred ? 1 : 0,
        attachments.length > 0 || message.hasAttachments ? 1 : 0, requestReadReceipt ? 1 : 0,
        message.rfcMessageId, message.inReplyTo, sendStatus, sortOrder]
    );
    await this.replaceAddresses(message.id, message.recipients, cc, bcc);
    await this.replaceAttachments(message.id, attachments);
  }

  private async replaceAttachments(messageId: string, attachments: MailAttachment[]): Promise<void> {
    await this.requireStore().executeSql('DELETE FROM message_attachments WHERE message_id = ?', [messageId]);
    for (let index: number = 0; index < attachments.length; index++) {
      const attachment: MailAttachment = attachments[index];
      await this.requireStore().executeSql(
        `INSERT INTO message_attachments
        (id, message_id, uri, display_name, mime_type, size, is_inline, position)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        [attachment.id, messageId, attachment.uri, attachment.name, attachment.mimeType,
          attachment.size, attachment.inline ? 1 : 0, index]
      );
    }
  }

  private async storeAttachments(messageId: string,
    payloads: MailAttachmentPayload[]): Promise<MailAttachment[]> {
    const uris: string[] = await this.attachmentFiles.writeMessageAttachments(messageId, payloads);
    const attachments: MailAttachment[] = [];
    for (let index: number = 0; index < payloads.length; index++) {
      const payload: MailAttachmentPayload = payloads[index];
      attachments.push(new MailAttachment(`${messageId}_attachment_${index}`, uris[index] ?? '',
        payload.name, payload.mimeType, payload.size, payload.inline));
    }
    return attachments;
  }

  private async replaceAddresses(messageId: string, to: MailAddress[], cc: MailAddress[],
    bcc: MailAddress[]): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    await store.executeSql('DELETE FROM message_addresses WHERE message_id = ?', [messageId]);
    await this.insertAddresses(messageId, 'to', to);
    await this.insertAddresses(messageId, 'cc', cc);
    await this.insertAddresses(messageId, 'bcc', bcc);
  }

  private async insertAddresses(messageId: string, type: string, addresses: MailAddress[]): Promise<void> {
    for (let index: number = 0; index < addresses.length; index++) {
      if (addresses[index].address.trim().length === 0) {
        continue;
      }
      await this.requireStore().executeSql(
        `INSERT INTO message_addresses
        (message_id, address_type, position, display_name, address) VALUES (?, ?, ?, ?, ?)`,
        [messageId, type, index, addresses[index].name, addresses[index].address]
      );
    }
  }

  private parseAddresses(value: string): MailAddress[] {
    if (value.trim().length === 0) {
      return [];
    }
    return value.split(/[;,]/).map((address: string) => new MailAddress('', address.trim()))
      .filter((address: MailAddress) => address.address.length > 0);
  }

  private async addressText(messageId: string, type: string): Promise<string> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      `SELECT address FROM message_addresses WHERE message_id = ? AND address_type = ?
       ORDER BY position ASC`, [messageId, type]);
    const addresses: string[] = [];
    try {
      while (result.goToNextRow()) {
        addresses.push(result.getString(result.getColumnIndex('address')));
      }
    } finally {
      result.close();
    }
    return addresses.join(', ');
  }

  private mapMessage(result: relationalStore.ResultSet): MailMessage {
    const recipient: MailAddress = new MailAddress(
      this.headerDecoder.decode(result.getString(result.getColumnIndex('recipient_name'))),
      result.getString(result.getColumnIndex('recipient_address'))
    );
    return new MailMessage(
      result.getString(result.getColumnIndex('id')),
      result.getString(result.getColumnIndex('account_id')),
      result.getString(result.getColumnIndex('folder')) as MailFolder,
      new MailAddress(this.headerDecoder.decode(result.getString(result.getColumnIndex('sender_name'))),
        result.getString(result.getColumnIndex('sender_address'))),
      [recipient],
      this.headerDecoder.decode(result.getString(result.getColumnIndex('subject'))),
      result.getString(result.getColumnIndex('preview')),
      result.getString(result.getColumnIndex('plain_body')),
      result.getString(result.getColumnIndex('received_at')),
      result.getLong(result.getColumnIndex('is_read')) === 1,
      result.getLong(result.getColumnIndex('is_starred')) === 1,
      result.getLong(result.getColumnIndex('has_attachments')) === 1,
      result.getString(result.getColumnIndex('html_body')),
      result.getString(result.getColumnIndex('rfc_message_id')),
      result.getString(result.getColumnIndex('in_reply_to')),
      result.getLong(result.getColumnIndex('sort_order'))
    );
  }

  // 摘要行与整行共用 MailMessage，但正文字段固定为空串：列表页不读 plain_body/html_body。
  private mapMessageSummary(result: relationalStore.ResultSet): MailMessage {
    const recipient: MailAddress = new MailAddress(
      this.headerDecoder.decode(result.getString(result.getColumnIndex('recipient_name'))),
      result.getString(result.getColumnIndex('recipient_address'))
    );
    return new MailMessage(
      result.getString(result.getColumnIndex('id')),
      result.getString(result.getColumnIndex('account_id')),
      result.getString(result.getColumnIndex('folder')) as MailFolder,
      new MailAddress(this.headerDecoder.decode(result.getString(result.getColumnIndex('sender_name'))),
        result.getString(result.getColumnIndex('sender_address'))),
      [recipient],
      this.headerDecoder.decode(result.getString(result.getColumnIndex('subject'))),
      result.getString(result.getColumnIndex('preview')),
      '',
      result.getString(result.getColumnIndex('received_at')),
      result.getLong(result.getColumnIndex('is_read')) === 1,
      result.getLong(result.getColumnIndex('is_starred')) === 1,
      result.getLong(result.getColumnIndex('has_attachments')) === 1,
      '',
      result.getString(result.getColumnIndex('rfc_message_id')),
      result.getString(result.getColumnIndex('in_reply_to')),
      result.getLong(result.getColumnIndex('sort_order'))
    );
  }

  private async enqueueOperation(accountId: string, messageId: string, type: PendingOperationType,
    payload: string = ''): Promise<void> {
    this.operationSequence++;
    await this.requireStore().executeSql(
      `INSERT INTO pending_operations
      (id, account_id, message_id, operation_type, payload, created_at, retry_count)
      VALUES (?, ?, ?, ?, ?, ?, 0)`,
      [`operation_${Date.now()}_${this.operationSequence}`, accountId, messageId, type, payload, Date.now()]
    );
  }

  async listAccounts(): Promise<EmailAccount[]> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      `SELECT a.*,
       (SELECT COUNT(*) FROM messages m
        WHERE m.account_id = a.id AND m.folder = ? AND m.is_read = 0) AS unread_count
       FROM accounts a ORDER BY a.created_at ASC`, [MailFolder.INBOX]
    );
    const accounts: EmailAccount[] = [];
    try {
      while (result.goToNextRow()) {
        accounts.push(new EmailAccount(
          result.getString(result.getColumnIndex('id')),
          result.getString(result.getColumnIndex('email')),
          result.getString(result.getColumnIndex('display_name')),
          result.getString(result.getColumnIndex('provider')) as EmailProviderType,
          result.getString(result.getColumnIndex('color')),
          result.getString(result.getColumnIndex('credential_ref')),
          result.getLong(result.getColumnIndex('unread_count')),
          result.getLong(result.getColumnIndex('sync_enabled')) === 1
        ));
      }
    } finally {
      result.close();
    }
    return accounts;
  }

  // 兼容入口：内部走摘要查询，正文（plainBody/htmlBody）返回空串，列表页请改用分页摘要方法。
  async listMessages(accountId: string, folder: MailFolder): Promise<MailMessage[]> {
    return this.listMessageSummaries(
      new MailSummaryQuery(accountId, folder, false, false, false, NO_LIMIT));
  }

  // 列表摘要查询：键集（keyset）分页，排序键 (sort_order DESC, id DESC)。
  // 游标用上一页末行的排序键，而不是 offset——删除 / 归档 / 新邮件插入都不会让后续页漏邮件或重复。
  // 筛选（未读 / 附件）与账户 / 文件夹条件一起进 WHERE，因此翻页拿到的每一页都满足筛选条件。
  async listMessageSummaries(query: MailSummaryQuery): Promise<MailMessage[]> {
    const conditions: string[] = [];
    const args: relationalStore.ValueType[] = [];
    if (query.starredOnly) {
      // 星标是跨文件夹集合，与原 listStarredMessageSummaries 一致，不带 folder 条件。
      conditions.push('is_starred = 1');
    } else {
      conditions.push('folder = ?');
      args.push(query.folder);
    }
    if (query.accountId !== 'all') {
      conditions.push('account_id = ?');
      args.push(query.accountId);
    }
    if (query.unreadOnly) {
      conditions.push('is_read = 0');
    }
    if (query.attachmentOnly) {
      conditions.push('has_attachments = 1');
    }
    if (query.cursorActive) {
      conditions.push('(sort_order < ? OR (sort_order = ? AND id < ?))');
      args.push(query.cursorSortOrder);
      args.push(query.cursorSortOrder);
      args.push(query.cursorMessageId);
    }
    let sql: string = `SELECT ${SUMMARY_COLUMNS} FROM messages WHERE ${conditions.join(' AND ')}
      ORDER BY sort_order DESC, id DESC`;
    if (query.limit > 0) {
      sql += ' LIMIT ?';
      args.push(query.limit);
    }
    const result: relationalStore.ResultSet = await this.requireStore().querySql(sql, args);
    const messages: MailMessage[] = [];
    try {
      while (result.goToNextRow()) {
        messages.push(this.mapMessageSummary(result));
      }
    } finally {
      result.close();
    }
    return messages;
  }

  async listStarredMessages(accountId: string): Promise<MailMessage[]> {
    return this.listMessageSummaries(
      new MailSummaryQuery(accountId, MailFolder.INBOX, true, false, false, NO_LIMIT));
  }

  // 一次聚合出侧边栏需要的全部计数，替代原先 7 次 listMessages/listStarredMessages。
  async folderCounts(accountId: string): Promise<MailFolderCounts> {
    let sql: string = `SELECT
      COUNT(CASE WHEN folder = ? AND is_read = 0 THEN 1 END) AS inbox_unread,
      COUNT(CASE WHEN is_starred = 1 THEN 1 END) AS starred_total,
      COUNT(CASE WHEN folder = ? THEN 1 END) AS drafts_total,
      COUNT(CASE WHEN folder = ? THEN 1 END) AS sent_total,
      COUNT(CASE WHEN folder = ? THEN 1 END) AS archive_total,
      COUNT(CASE WHEN folder = ? THEN 1 END) AS spam_total,
      COUNT(CASE WHEN folder = ? THEN 1 END) AS trash_total
      FROM messages`;
    const args: relationalStore.ValueType[] = [MailFolder.INBOX, MailFolder.DRAFTS, MailFolder.SENT,
      MailFolder.ARCHIVE, MailFolder.SPAM, MailFolder.TRASH];
    if (accountId !== 'all') {
      sql += ' WHERE account_id = ?';
      args.push(accountId);
    }
    const result: relationalStore.ResultSet = await this.requireStore().querySql(sql, args);
    try {
      if (!result.goToFirstRow()) {
        return new MailFolderCounts();
      }
      return new MailFolderCounts(
        result.getLong(result.getColumnIndex('inbox_unread')),
        result.getLong(result.getColumnIndex('starred_total')),
        result.getLong(result.getColumnIndex('drafts_total')),
        result.getLong(result.getColumnIndex('sent_total')),
        result.getLong(result.getColumnIndex('archive_total')),
        result.getLong(result.getColumnIndex('spam_total')),
        result.getLong(result.getColumnIndex('trash_total'))
      );
    } finally {
      result.close();
    }
  }

  async getMessage(messageId: string): Promise<MailMessage | undefined> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      'SELECT * FROM messages WHERE id = ? LIMIT 1', [messageId]);
    let message: MailMessage | undefined = undefined;
    try {
      if (result.goToFirstRow()) {
        message = this.mapMessage(result);
      }
    } finally {
      result.close();
    }
    if (message) {
      const recipients: MailAddress[] = await this.listMessageAddresses(messageId, 'to');
      if (recipients.length > 0) {
        message.recipients = recipients;
      }
    }
    return message;
  }

  async listMessageAddresses(messageId: string, type: string): Promise<MailAddress[]> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      `SELECT display_name, address FROM message_addresses
       WHERE message_id = ? AND address_type = ? ORDER BY position ASC`, [messageId, type]);
    const addresses: MailAddress[] = [];
    try {
      while (result.goToNextRow()) {
        addresses.push(new MailAddress(
          this.headerDecoder.decode(result.getString(result.getColumnIndex('display_name'))),
          result.getString(result.getColumnIndex('address'))
        ));
      }
    } finally {
      result.close();
    }
    return addresses;
  }

  async getDraft(messageId: string): Promise<DraftMessage | undefined> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    if (!message || message.folder !== MailFolder.DRAFTS) {
      return undefined;
    }
    return this.draftFromMessage(message);
  }

  async getSendableMessage(messageId: string): Promise<DraftMessage | undefined> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    return message ? this.draftFromMessage(message) : undefined;
  }

  private async draftFromMessage(message: MailMessage): Promise<DraftMessage> {
    const to: string = await this.addressText(message.id, 'to');
    const cc: string = await this.addressText(message.id, 'cc');
    const bcc: string = await this.addressText(message.id, 'bcc');
    const attachments: MailAttachment[] = await this.listAttachments(message.id);
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      'SELECT request_read_receipt FROM messages WHERE id = ? LIMIT 1', [message.id]);
    let requestReadReceipt: boolean = false;
    try {
      if (result.goToFirstRow()) {
        requestReadReceipt = result.getLong(result.getColumnIndex('request_read_receipt')) === 1;
      }
    } finally {
      result.close();
    }
    return new DraftMessage(message.accountId, to, cc, message.subject, message.plainBody, bcc,
      message.id, attachments, requestReadReceipt, message.inReplyTo, message.rfcMessageId);
  }

  async listAttachments(messageId: string): Promise<MailAttachment[]> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      'SELECT * FROM message_attachments WHERE message_id = ? ORDER BY position ASC', [messageId]);
    const attachments: MailAttachment[] = [];
    try {
      while (result.goToNextRow()) {
        attachments.push(new MailAttachment(
          result.getString(result.getColumnIndex('id')),
          result.getString(result.getColumnIndex('uri')),
          result.getString(result.getColumnIndex('display_name')),
          result.getString(result.getColumnIndex('mime_type')),
          result.getLong(result.getColumnIndex('size')),
          result.getLong(result.getColumnIndex('is_inline')) === 1
        ));
      }
    } finally {
      result.close();
    }
    return attachments;
  }

  private placeholders(count: number): string {
    let clause: string = '?';
    for (let index: number = 1; index < count; index++) {
      clause += ', ?';
    }
    return clause;
  }

  private toBindArgs(values: string[]): relationalStore.ValueType[] {
    const args: relationalStore.ValueType[] = [];
    for (let index: number = 0; index < values.length; index++) {
      args.push(values[index]);
    }
    return args;
  }

  // 一次性查出现有 id，替代逐条 getMessage() 的存在性检查；超过 500 个入参时分批。
  private async findExistingMessageIds(messageIds: string[]): Promise<Set<string>> {
    const existing: Set<string> = new Set<string>();
    for (let start: number = 0; start < messageIds.length; start += BIND_BATCH_SIZE) {
      const chunk: string[] = messageIds.slice(start, start + BIND_BATCH_SIZE);
      const result: relationalStore.ResultSet = await this.requireStore().querySql(
        `SELECT id FROM messages WHERE id IN (${this.placeholders(chunk.length)})`, this.toBindArgs(chunk));
      try {
        while (result.goToNextRow()) {
          existing.add(result.getString(result.getColumnIndex('id')));
        }
      } finally {
        result.close();
      }
    }
    return existing;
  }

  // 写库公共路径的唯一入口：把 work 接到写入链尾部，前一个写任务结束后才轮到它。
  // 链自身吞掉错误，否则任一写任务失败都会卡死后续所有写任务。
  private enqueueWrite<T>(work: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.writeChain.then((): Promise<T> => this.runSerialSegment(work));
    this.writeChain = result.then((): void => {}, (): void => {});
    return result;
  }

  private async runSerialSegment<T>(work: () => Promise<T>): Promise<T> {
    this.serialSegmentActive = true;
    try {
      return await work();
    } finally {
      this.serialSegmentActive = false;
      // 串行段结束时不应残留未闭合事务，否则会污染后续事务的嵌套判定。
      this.transactionDepth = 0;
    }
  }

  // RdbStore 事务 API：同步的 beginTransaction()/commit()/rollBack()（异步变体是
  // beginTrans()/commit(txId)/rollback(txId)）。work 抛错时回滚并原样抛出。
  // 嵌套禁止：已处于事务中时直接并入外层事务，不再 begin/commit/rollback——否则内层 rollBack
  // 会结束外层事务，外层 commit 再失败就会静默丢掉整批写入。
  private async inTransaction(work: () => Promise<void>): Promise<void> {
    if (this.transactionDepth > 0) {
      await work();
      return;
    }
    if (!this.serialSegmentActive) {
      // 不在串行段内（异常调用路径）：先取写入锁，避免与正在执行的写任务并发开事务。
      await this.enqueueWrite((): Promise<void> => this.runTransaction(work));
      return;
    }
    await this.runTransaction(work);
  }

  private async runTransaction(work: () => Promise<void>): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    store.beginTransaction();
    this.transactionDepth++;
    try {
      await work();
      store.commit();
    } catch (error) {
      try {
        store.rollBack();
      } catch (_rollbackError) {
        // 回滚本身失败时不掩盖原始错误
      }
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('数据库事务执行失败');
    } finally {
      this.transactionDepth--;
      if (this.transactionDepth < 0) {
        this.transactionDepth = 0;
      }
    }
  }

  async upsertRemoteMessages(messages: MailMessage[], sortOrders: number[],
    attachmentPayloads: MailAttachmentPayload[][] = []): Promise<number> {
    return this.enqueueWrite((): Promise<number> =>
      this.upsertMessagesLocked(messages, sortOrders, attachmentPayloads));
  }

  private async upsertMessagesLocked(messages: MailMessage[], sortOrders: number[],
    attachmentPayloads: MailAttachmentPayload[][]): Promise<number> {
    if (messages.length === 0) {
      return 0;
    }
    const messageIds: string[] = messages.map((message: MailMessage): string => message.id);
    const existing: Set<string> = await this.findExistingMessageIds(messageIds);
    let insertedCount: number = 0;
    for (let index: number = 0; index < messages.length; index++) {
      if (!existing.has(messages[index].id)) {
        insertedCount++;
      }
    }
    // 已有完整附件行的邮件不再重写附件：重同步（loadOlder 重叠、服务器整表重刷）时的新解析可能
    // 因为正文被截断而缺附件，重写会连同沙箱文件一起毁掉先前完好的附件。正文/信封字段照旧更新。
    const preserved: Map<string, MailAttachment[]> = await this.preservedAttachments(messageIds);
    // 附件落盘是文件 IO，放在事务外，避免长时间持有数据库事务。
    const attachments: MailAttachment[][] = [];
    for (let index: number = 0; index < messages.length; index++) {
      const keep: MailAttachment[] | undefined = preserved.get(messages[index].id);
      if (keep !== undefined) {
        attachments.push(keep);
        continue;
      }
      attachments.push(await this.storeAttachments(messages[index].id,
        attachmentPayloads[index] ?? []));
    }
    try {
      await this.inTransaction(async (): Promise<void> => {
        for (let index: number = 0; index < messages.length; index++) {
          await this.insertMessage(messages[index], sortOrders[index] ?? Date.now(), [], [],
            attachments[index]);
        }
      });
    } catch (error) {
      await this.discardAttachmentFiles(messageIds
        .filter((messageId: string): boolean => !existing.has(messageId)));
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('批量写入邮件失败');
    }
    return insertedCount;
  }

  // 返回“附件行必须原样保留”的邮件 id → 附件行。判定：该邮件已有附件行，且每一行都带 uri
  // （说明上次已完整落盘）。全部行都缺 uri 的（上次没下全）不返回，允许本轮补写。
  private async preservedAttachments(messageIds: string[]): Promise<Map<string, MailAttachment[]>> {
    const rows: Map<string, MailAttachment[]> = new Map<string, MailAttachment[]>();
    const missingUri: Set<string> = new Set<string>();
    for (let start: number = 0; start < messageIds.length; start += BIND_BATCH_SIZE) {
      const chunk: string[] = messageIds.slice(start, start + BIND_BATCH_SIZE);
      const result: relationalStore.ResultSet = await this.requireStore().querySql(
        `SELECT id, message_id, uri, display_name, mime_type, size, is_inline
         FROM message_attachments WHERE message_id IN (${this.placeholders(chunk.length)})
         ORDER BY message_id, position ASC`, this.toBindArgs(chunk));
      try {
        while (result.goToNextRow()) {
          const messageId: string = result.getString(result.getColumnIndex('message_id'));
          const uri: string = result.getString(result.getColumnIndex('uri'));
          if (uri.length === 0) {
            missingUri.add(messageId);
          }
          const attachment: MailAttachment = new MailAttachment(
            result.getString(result.getColumnIndex('id')), uri,
            result.getString(result.getColumnIndex('display_name')),
            result.getString(result.getColumnIndex('mime_type')),
            result.getLong(result.getColumnIndex('size')),
            result.getLong(result.getColumnIndex('is_inline')) === 1);
          const current: MailAttachment[] | undefined = rows.get(messageId);
          if (current) {
            current.push(attachment);
          } else {
            rows.set(messageId, [attachment]);
          }
        }
      } finally {
        result.close();
      }
    }
    const preserved: Map<string, MailAttachment[]> = new Map<string, MailAttachment[]>();
    rows.forEach((list: MailAttachment[], messageId: string) => {
      if (!missingUri.has(messageId)) {
        preserved.set(messageId, list);
      }
    });
    return preserved;
  }

  // 尽力清理：删除失败不影响主流程（文件可能仍被其他记录引用或已被移除）。
  private async discardAttachmentFiles(messageIds: string[]): Promise<void> {
    if (messageIds.length === 0) {
      return;
    }
    try {
      await this.attachmentFiles.removeMessageAttachmentDirectories(messageIds);
    } catch (_error) {
      return;
    }
  }

  async addAccount(account: EmailAccount, secret: string, settings: AccountServerSettings): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      account.credentialRef = await this.vault.save(account.id, secret);
      await this.insertAccount(account, Date.now(), settings);
    });
  }

  async getAccountServerSettings(accountId: string): Promise<AccountServerSettings | undefined> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      'SELECT * FROM accounts WHERE id = ? LIMIT 1', [accountId]);
    try {
      if (!result.goToFirstRow()) {
        return undefined;
      }
      const provider = result.getString(result.getColumnIndex('provider')) as EmailProviderType;
      const email: string = result.getString(result.getColumnIndex('email'));
      const incoming: MailServerSettings = new MailServerSettings(MailProtocol.IMAP,
        result.getString(result.getColumnIndex('incoming_host')),
        result.getLong(result.getColumnIndex('incoming_port')),
        result.getString(result.getColumnIndex('incoming_security')) as ConnectionSecurity,
        result.getString(result.getColumnIndex('incoming_authentication')) as AuthenticationMethod,
        result.getString(result.getColumnIndex('incoming_username')));
      const outgoing: MailServerSettings = new MailServerSettings(MailProtocol.SMTP,
        result.getString(result.getColumnIndex('outgoing_host')),
        result.getLong(result.getColumnIndex('outgoing_port')),
        result.getString(result.getColumnIndex('outgoing_security')) as ConnectionSecurity,
        result.getString(result.getColumnIndex('outgoing_authentication')) as AuthenticationMethod,
        result.getString(result.getColumnIndex('outgoing_username')));
      return new AccountServerSettings(provider, email, incoming, outgoing);
    } finally {
      result.close();
    }
  }

  async readAccountCredential(accountId: string): Promise<string> {
    const account: EmailAccount | undefined = (await this.listAccounts())
      .find((item: EmailAccount) => item.id === accountId);
    if (!account || account.credentialRef.length === 0) {
      return '';
    }
    return this.vault.read(account.credentialRef);
  }

  async updateAccountCredential(accountId: string, secret: string): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      const reference: string = await this.vault.save(accountId, secret);
      await this.requireStore().executeSql('UPDATE accounts SET credential_ref = ? WHERE id = ?',
        [reference, accountId]);
    });
  }

  private async listMessageIds(query: string, args: relationalStore.ValueType[]): Promise<string[]> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(query, args);
    const ids: string[] = [];
    try {
      while (result.goToNextRow()) {
        ids.push(result.getString(result.getColumnIndex('id')));
      }
    } finally {
      result.close();
    }
    return ids;
  }

  async removeAccount(accountId: string): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      const accounts: EmailAccount[] = await this.listAccounts();
      const account: EmailAccount | undefined = accounts.find((item: EmailAccount) => item.id === accountId);
      if (account && account.credentialRef.length > 0) {
        await this.vault.remove(account.credentialRef);
      }
      // 先收集将删消息 id，再清理沙箱附件目录；文件清理失败不阻塞数据库删除。
      const messageIds: string[] = await this.listMessageIds(
        'SELECT id FROM messages WHERE account_id = ?', [accountId]);
      await this.discardAttachmentFiles(messageIds);
      await this.inTransaction(async (): Promise<void> => {
        const store: relationalStore.RdbStore = this.requireStore();
        await store.executeSql(
          `DELETE FROM message_addresses WHERE message_id IN
           (SELECT id FROM messages WHERE account_id = ?)`, [accountId]);
        await store.executeSql(
          `DELETE FROM message_attachments WHERE message_id IN
           (SELECT id FROM messages WHERE account_id = ?)`, [accountId]);
        await store.executeSql('DELETE FROM messages WHERE account_id = ?', [accountId]);
        await store.executeSql('DELETE FROM pending_operations WHERE account_id = ?', [accountId]);
        await store.executeSql('DELETE FROM accounts WHERE id = ?', [accountId]);
      });
    });
  }

  async setAccountSyncEnabled(accountId: string, enabled: boolean): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      await this.requireStore().executeSql('UPDATE accounts SET sync_enabled = ? WHERE id = ?',
        [enabled ? 1 : 0, accountId]);
    });
  }

  async getSetting(key: string, defaultValue: string): Promise<string> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      'SELECT setting_value FROM app_settings WHERE setting_key = ? LIMIT 1', [key]);
    try {
      return result.goToFirstRow() ? result.getString(result.getColumnIndex('setting_value')) : defaultValue;
    } finally {
      result.close();
    }
  }

  async setSetting(key: string, value: string): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      await this.requireStore().executeSql(
        'INSERT OR REPLACE INTO app_settings (setting_key, setting_value) VALUES (?, ?)', [key, value]);
    });
  }

  // 一次取回某前缀下的全部设置（如 'last_sync_' 对应各账户的最近同步时间）。
  // 前缀中的 % 和 _ 按字面量处理；前缀为空串时返回全部设置。
  async getSettingsByPrefix(prefix: string): Promise<Map<string, string>> {
    const settings: Map<string, string> = new Map<string, string>();
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      `SELECT setting_key, setting_value FROM app_settings WHERE setting_key LIKE ? ESCAPE '\\'`,
      [`${this.escapeLikePattern(prefix)}%`]);
    try {
      while (result.goToNextRow()) {
        settings.set(result.getString(result.getColumnIndex('setting_key')),
          result.getString(result.getColumnIndex('setting_value')));
      }
    } finally {
      result.close();
    }
    return settings;
  }

  private escapeLikePattern(prefix: string): string {
    let escaped: string = '';
    for (let index: number = 0; index < prefix.length; index++) {
      const character: string = prefix.charAt(index);
      if (character === '\\' || character === '%' || character === '_') {
        escaped += '\\';
      }
      escaped += character;
    }
    return escaped;
  }

  async markRead(messageId: string): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      const message: MailMessage | undefined = await this.getMessage(messageId);
      if (!message || message.isRead) {
        return;
      }
      await this.requireStore().executeSql('UPDATE messages SET is_read = 1 WHERE id = ?', [messageId]);
      await this.enqueueOperation(message.accountId, messageId, PendingOperationType.MARK_READ);
    });
  }

  async toggleRead(messageId: string): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      const message: MailMessage | undefined = await this.getMessage(messageId);
      await this.requireStore().executeSql(
        'UPDATE messages SET is_read = CASE is_read WHEN 1 THEN 0 ELSE 1 END WHERE id = ?', [messageId]);
      if (message) {
        await this.enqueueOperation(message.accountId, messageId,
          message.isRead ? PendingOperationType.MARK_UNREAD : PendingOperationType.MARK_READ);
      }
    });
  }

  async toggleStar(messageId: string): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      const message: MailMessage | undefined = await this.getMessage(messageId);
      await this.requireStore().executeSql(
        'UPDATE messages SET is_starred = CASE is_starred WHEN 1 THEN 0 ELSE 1 END WHERE id = ?',
        [messageId]);
      if (message) {
        await this.enqueueOperation(message.accountId, messageId,
          message.isStarred ? PendingOperationType.UNSTAR : PendingOperationType.STAR);
      }
    });
  }

  async moveMessages(messageIds: string[], folder: MailFolder): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      for (let index: number = 0; index < messageIds.length; index++) {
        const message: MailMessage | undefined = await this.getMessage(messageIds[index]);
        await this.requireStore().executeSql('UPDATE messages SET folder = ? WHERE id = ?',
          [folder, messageIds[index]]);
        if (message) {
          await this.enqueueOperation(message.accountId, messageIds[index], PendingOperationType.MOVE, folder);
        }
      }
    });
  }

  // 软删除：只把 folder 改为垃圾箱并入队远端 DELETE，附件文件保留供垃圾箱内查看。
  async deleteMessages(messageIds: string[]): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      for (let index: number = 0; index < messageIds.length; index++) {
        const message: MailMessage | undefined = await this.getMessage(messageIds[index]);
        await this.requireStore().executeSql('UPDATE messages SET folder = ? WHERE id = ?',
          [MailFolder.TRASH, messageIds[index]]);
        if (message) {
          await this.enqueueOperation(message.accountId, messageIds[index], PendingOperationType.DELETE,
            MailFolder.TRASH);
        }
      }
    });
  }

  // 硬删除（垃圾箱清空 / 永久删除）：删除数据库行并清理沙箱 attachments/<messageId>/ 目录。
  async purgeMessages(messageIds: string[]): Promise<void> {
    if (messageIds.length === 0) {
      return;
    }
    await this.enqueueWrite((): Promise<void> => this.purgeMessageRows(messageIds));
  }

  // 只在串行段内调用（调用方已持有写入锁）。
  private async purgeMessageRows(messageIds: string[],
    dropPendingOperations: boolean = false): Promise<void> {
    if (messageIds.length === 0) {
      return;
    }
    await this.discardAttachmentFiles(messageIds);
    await this.inTransaction(async (): Promise<void> => {
      const store: relationalStore.RdbStore = this.requireStore();
      for (let start: number = 0; start < messageIds.length; start += BIND_BATCH_SIZE) {
        const chunk: string[] = messageIds.slice(start, start + BIND_BATCH_SIZE);
        const clause: string = this.placeholders(chunk.length);
        const args: relationalStore.ValueType[] = this.toBindArgs(chunk);
        await store.executeSql(`DELETE FROM message_addresses WHERE message_id IN (${clause})`, args);
        await store.executeSql(`DELETE FROM message_attachments WHERE message_id IN (${clause})`, args);
        await store.executeSql(`DELETE FROM messages WHERE id IN (${clause})`, args);
        if (dropPendingOperations) {
          await store.executeSql(`DELETE FROM pending_operations WHERE message_id IN (${clause})`, args);
        }
      }
    });
  }

  // 清空垃圾箱：删除当前账户（或全部账户）垃圾箱内的全部邮件及其附件文件。
  async emptyTrash(accountId: string): Promise<number> {
    return this.enqueueWrite(async (): Promise<number> => {
      const query: string = accountId === 'all' ?
        'SELECT id FROM messages WHERE folder = ?' :
        'SELECT id FROM messages WHERE folder = ? AND account_id = ?';
      const args: relationalStore.ValueType[] =
        accountId === 'all' ? [MailFolder.TRASH] : [MailFolder.TRASH, accountId];
      const messageIds: string[] = await this.listMessageIds(query, args);
      await this.purgeMessageRows(messageIds);
      return messageIds.length;
    });
  }

  // UIDVALIDITY 变化时清空某账户某文件夹的旧邮件：删除 messages/message_addresses/
  // message_attachments 行并清理对应附件目录，返回清理的邮件数。旧 UID 在新 UIDVALIDITY 下
  // 可能指向完全不同的邮件，因此这些邮件上排队的远端操作一并丢弃，否则会在服务器上操作错邮件。
  async purgeFolderMessages(accountId: string, folder: MailFolder): Promise<number> {
    return this.enqueueWrite(async (): Promise<number> => {
      const messageIds: string[] = await this.listMessageIds(
        'SELECT id FROM messages WHERE account_id = ? AND folder = ?', [accountId, folder]);
      await this.purgeMessageRows(messageIds, true);
      return messageIds.length;
    });
  }

  async saveDraft(draft: DraftMessage): Promise<string> {
    return this.enqueueWrite((): Promise<string> => this.saveDraftLocked(draft));
  }

  // 把 picker 选中的文件复制进沙箱 attachments/<draftId>/，草稿只持有沙箱 URI：picker 授权
  // 重启后失效，留着它等于让 outbox 重试必然 EACCES。只碰文件、不碰数据库，但仍走写入串行器，
  // 与同目录的删除/迁移互斥。
  importDraftAttachment(draftId: string, fileName: string, sourceUri: string,
    mimeType: string): Promise<MailAttachment> {
    return this.enqueueWrite((): Promise<MailAttachment> =>
      this.attachmentFiles.importAttachment(draftId, fileName, sourceUri, mimeType));
  }

  // 删除单个附件文件；picker URI 与其它记录目录下的文件都不会被碰。
  removeAttachmentFile(uri: string): Promise<void> {
    return this.enqueueWrite((): Promise<void> => this.attachmentFiles.removeAttachmentFile(uri));
  }

  private async saveDraftLocked(draft: DraftMessage): Promise<string> {
    const account: EmailAccount | undefined = (await this.listAccounts())
      .find((item: EmailAccount) => item.id === draft.accountId);
    if (!account) {
      throw new Error('请选择发件账户');
    }
    const messageId: string = draft.id.length > 0 ? draft.id : `draft_${Date.now()}`;
    const recipients: MailAddress[] = this.parseAddresses(draft.to);
    const message: MailMessage = new MailMessage(messageId, account.id, MailFolder.DRAFTS,
      new MailAddress(account.displayName, account.email), recipients,
      draft.subject, draft.body, draft.body, '刚刚', true, false, false, '', draft.rfcMessageId,
      draft.inReplyTo);
    await this.insertMessage(message, Date.now(), this.parseAddresses(draft.cc), this.parseAddresses(draft.bcc),
      draft.attachments, draft.requestReadReceipt);
    return messageId;
  }

  async deleteDraft(messageId: string): Promise<void> {
    await this.enqueueWrite((): Promise<void> => this.deleteDraftRows(messageId));
  }

  // removeFiles 只在调用方确认这些文件已不再被别的记录引用时才为 true（发送时已迁移到 sent 目录）。
  private async deleteDraftRows(messageId: string, removeFiles: boolean = true): Promise<void> {
    if (messageId.length === 0) {
      return;
    }
    // 附件目录按草稿自己的 id 命名，只可能属于这封草稿：即使数据库里没有对应行
    // （从未保存草稿），目录也一并清掉，不留孤儿文件。
    if (removeFiles) {
      await this.discardAttachmentFiles([messageId]);
    }
    // 子表删除必须带上 folder 条件：只按 message_id 无条件删会把非草稿邮件的
    // addresses/attachments 行删掉，留下没有子行的孤儿邮件。
    if (!await this.messageExistsInFolder(messageId, MailFolder.DRAFTS)) {
      return;
    }
    await this.inTransaction(async (): Promise<void> => {
      const store: relationalStore.RdbStore = this.requireStore();
      const scope: string = 'message_id IN (SELECT id FROM messages WHERE id = ? AND folder = ?)';
      await store.executeSql(`DELETE FROM message_addresses WHERE ${scope}`,
        [messageId, MailFolder.DRAFTS]);
      await store.executeSql(`DELETE FROM message_attachments WHERE ${scope}`,
        [messageId, MailFolder.DRAFTS]);
      await store.executeSql('DELETE FROM messages WHERE id = ? AND folder = ?',
        [messageId, MailFolder.DRAFTS]);
    });
  }

  private async messageExistsInFolder(messageId: string, folder: MailFolder): Promise<boolean> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      'SELECT id FROM messages WHERE id = ? AND folder = ? LIMIT 1', [messageId, folder]);
    try {
      return result.goToFirstRow();
    } finally {
      result.close();
    }
  }

  async send(draft: DraftMessage): Promise<string> {
    return this.enqueueWrite((): Promise<string> => this.storeSent(draft, true));
  }

  private async storeSent(draft: DraftMessage, enqueue: boolean): Promise<string> {
    const account: EmailAccount | undefined = (await this.listAccounts())
      .find((item: EmailAccount) => item.id === draft.accountId);
    if (!account) {
      throw new Error('请选择发件账户');
    }
    const sender: EmailAccount = account;
    const now: number = Date.now();
    const messageId: string = `sent_${now}`;
    const rfcMessageId: string = draft.rfcMessageId.length > 0 ? draft.rfcMessageId :
      newMessageId(sender.email, messageId, now);
    // 附件目录所有权：投递入队那一刻把附件从草稿目录迁移到本封 sent 记录自己的目录，
    // 此后 sent 记录的清理只删自己的文件，草稿删除也不会带走已发送的附件。
    const migrated: MailAttachment[] = await this.attachmentFiles.migrateAttachments(messageId,
      draft.attachments);
    const attachments: MailAttachment[] = this.ownedAttachments(messageId, migrated);
    const message: MailMessage = new MailMessage(messageId, sender.id, MailFolder.SENT,
      new MailAddress(sender.displayName, sender.email), this.parseAddresses(draft.to),
      draft.subject, draft.body, draft.body, '刚刚', true, false, false, '', rfcMessageId,
      draft.inReplyTo);
    // 入库与入队必须同事务：两条独立语句时，入队失败或进程被杀会留下“永远 sending 且不在
    // 队列里”的邮件（既不会重发，也不会变成 failed）。
    try {
      await this.inTransaction(async (): Promise<void> => {
        await this.insertMessage(message, now, this.parseAddresses(draft.cc), this.parseAddresses(draft.bcc),
          attachments, draft.requestReadReceipt, enqueue ? SendStatus.SENDING : SendStatus.SENT);
        if (enqueue) {
          await this.enqueueOperation(sender.id, messageId, PendingOperationType.SEND);
        }
      });
    } catch (error) {
      // 入库失败就把附件迁回草稿目录，否则草稿行会指向已被搬走的文件。
      if (draft.id.length > 0) {
        await this.attachmentFiles.migrateAttachments(draft.id, attachments);
      }
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('写入发件记录失败');
    }
    if (draft.id.length > 0 && draft.id !== messageId) {
      // 迁移失败时附件仍留在草稿目录里，此时不能删草稿目录。
      await this.deleteDraftRows(draft.id, !this.referencesMessageDirectory(attachments, draft.id));
    }
    return messageId;
  }

  private ownedAttachments(messageId: string, attachments: MailAttachment[]): MailAttachment[] {
    const owned: MailAttachment[] = [];
    for (let index: number = 0; index < attachments.length; index++) {
      const attachment: MailAttachment = attachments[index];
      owned.push(new MailAttachment(`${messageId}_attachment_${index}`, attachment.uri, attachment.name,
        attachment.mimeType, attachment.size, attachment.inline));
    }
    return owned;
  }

  private referencesMessageDirectory(attachments: MailAttachment[], messageId: string): boolean {
    for (let index: number = 0; index < attachments.length; index++) {
      if (this.attachmentFiles.belongsToMessage(attachments[index].uri, messageId)) {
        return true;
      }
    }
    return false;
  }

  async listPendingOperations(accountId: string): Promise<PendingMailOperation[]> {
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      `SELECT * FROM pending_operations WHERE account_id = ?
       ORDER BY created_at ASC, id ASC`, [accountId]);
    const operations: PendingMailOperation[] = [];
    try {
      while (result.goToNextRow()) {
        operations.push(new PendingMailOperation(
          result.getString(result.getColumnIndex('id')),
          result.getString(result.getColumnIndex('account_id')),
          result.getString(result.getColumnIndex('message_id')),
          result.getString(result.getColumnIndex('operation_type')) as PendingOperationType,
          result.getString(result.getColumnIndex('payload')),
          result.getLong(result.getColumnIndex('created_at')),
          result.getLong(result.getColumnIndex('retry_count')),
          result.getLong(result.getColumnIndex('next_retry_at'))
        ));
      }
    } finally {
      result.close();
    }
    return operations;
  }

  async markMessageSendStatus(messageId: string, status: SendStatus): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      await this.requireStore().executeSql('UPDATE messages SET send_status = ? WHERE id = ?',
        [status, messageId]);
    });
  }

  async reschedulePendingOperation(operationId: string, retryCount: number,
    nextRetryAt: number): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      await this.requireStore().executeSql(
        'UPDATE pending_operations SET retry_count = ?, next_retry_at = ? WHERE id = ?',
        [retryCount, nextRetryAt, operationId]);
    });
  }

  async acknowledgePendingOperation(operationId: string): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      await this.requireStore().executeSql('DELETE FROM pending_operations WHERE id = ?', [operationId]);
    });
  }

  async recordPendingOperationFailure(operationId: string): Promise<void> {
    await this.enqueueWrite(async (): Promise<void> => {
      await this.requireStore().executeSql(
        'UPDATE pending_operations SET retry_count = retry_count + 1 WHERE id = ?', [operationId]);
    });
  }

  // 启动回收：send_status='sending' 但队列里已没有对应 SEND 项的邮件无法自行恢复
  // （既不会重发，也不会变成 failed）。这里把它们重新入队——这类记录只可能来自
  // “尚未尝试投递”的路径（投递成功后是先置 sent 再删队列项），重发能恢复投递；
  // 标成 failed 则等于把一封很可能从未发出的邮件永久判死。同一条 SQL 内完成，天然原子。
  // 入队 id 用 operation_replay_<messageId> 固定前缀，便于诊断且重复执行不会产生多条。
  private async recoverStuckSends(): Promise<void> {
    await this.requireStore().executeSql(
      `INSERT OR REPLACE INTO pending_operations
       (id, account_id, message_id, operation_type, payload, created_at, retry_count, next_retry_at)
       SELECT 'operation_replay_' || m.id, m.account_id, m.id, ?, '', ?, 0, 0
       FROM messages m
       WHERE m.send_status = ?
         AND NOT EXISTS (SELECT 1 FROM pending_operations p
           WHERE p.message_id = m.id AND p.operation_type = ?)`,
      [PendingOperationType.SEND, Date.now(), SendStatus.SENDING, PendingOperationType.SEND]);
  }
}
