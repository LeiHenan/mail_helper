import { Context } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { CredentialVault, HuksCredentialVault, MemoryCredentialVault } from '../security/CredentialVault';
import { DraftMessage, EmailAccount, EmailProviderType, MailAddress, MailAttachment, MailFolder,
  MailMessage } from '../model/MailModels';
import { AccountServerSettings, AuthenticationMethod, ConnectionSecurity, MailProtocol, MailServerSettings,
  PendingMailOperation, PendingOperationType } from '../model/MailServerModels';
import { findProvider } from '../model/ProviderConfig';
import { MailRepository } from './MailRepository';
import { PendingOperationStore } from './PendingOperationStore';
import { MimeHeaderDecoder } from '../service/MimeHeaderDecoder';

const DATABASE_NAME: string = 'mail_helper.db';
const DATABASE_VERSION: number = 6;

export class LocalMailRepository implements MailRepository, PendingOperationStore {
  private static instance: LocalMailRepository = new LocalMailRepository();
  private store?: relationalStore.RdbStore = undefined;
  private initialization?: Promise<void> = undefined;
  private vault: CredentialVault = new MemoryCredentialVault();
  private operationSequence: number = 0;
  private headerDecoder: MimeHeaderDecoder = new MimeHeaderDecoder();

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
    const config: relationalStore.StoreConfig = {
      name: DATABASE_NAME,
      securityLevel: relationalStore.SecurityLevel.S2
    };
    this.store = await relationalStore.getRdbStore(context, config);
    await this.createSchema();
    await this.seedIfEmpty();
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
      retry_count INTEGER NOT NULL DEFAULT 0
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
    store.version = DATABASE_VERSION;
  }

  private async seedIfEmpty(): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
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
      return;
    }

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
    for (let index: number = 0; index < messages.length; index++) {
      await this.insertMessage(messages[index], 1000 - index);
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
    requestReadReceipt: boolean = false): Promise<void> {
    const recipient: MailAddress = message.recipients.length > 0 ? message.recipients[0] : new MailAddress('', '');
    await this.requireStore().executeSql(
      `INSERT OR REPLACE INTO messages
      (id, account_id, folder, sender_name, sender_address, recipient_name, recipient_address,
       subject, preview, plain_body, html_body, received_at, is_read, is_starred, has_attachments,
       request_read_receipt, sort_order)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [message.id, message.accountId, message.folder, message.sender.name, message.sender.address,
        recipient.name, recipient.address, message.subject, message.preview, message.plainBody,
        message.htmlBody, message.receivedAt, message.isRead ? 1 : 0, message.isStarred ? 1 : 0,
        attachments.length > 0 || message.hasAttachments ? 1 : 0, requestReadReceipt ? 1 : 0, sortOrder]
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
        (id, message_id, uri, display_name, mime_type, size, position) VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [attachment.id, messageId, attachment.uri, attachment.name, attachment.mimeType,
          attachment.size, index]
      );
    }
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
      result.getString(result.getColumnIndex('html_body'))
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

  async listMessages(accountId: string, folder: MailFolder): Promise<MailMessage[]> {
    let sql: string = 'SELECT * FROM messages WHERE folder = ?';
    const args: relationalStore.ValueType[] = [folder];
    if (accountId !== 'all') {
      sql += ' AND account_id = ?';
      args.push(accountId);
    }
    sql += ' ORDER BY sort_order DESC';
    const result: relationalStore.ResultSet = await this.requireStore().querySql(sql, args);
    const messages: MailMessage[] = [];
    try {
      while (result.goToNextRow()) {
        messages.push(this.mapMessage(result));
      }
    } finally {
      result.close();
    }
    return messages;
  }

  async listStarredMessages(accountId: string): Promise<MailMessage[]> {
    let sql: string = 'SELECT * FROM messages WHERE is_starred = 1';
    const args: relationalStore.ValueType[] = [];
    if (accountId !== 'all') {
      sql += ' AND account_id = ?';
      args.push(accountId);
    }
    sql += ' ORDER BY sort_order DESC';
    const result: relationalStore.ResultSet = await this.requireStore().querySql(sql, args);
    const messages: MailMessage[] = [];
    try {
      while (result.goToNextRow()) {
        messages.push(this.mapMessage(result));
      }
    } finally {
      result.close();
    }
    return messages;
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
    const to: string = await this.addressText(messageId, 'to');
    const cc: string = await this.addressText(messageId, 'cc');
    const bcc: string = await this.addressText(messageId, 'bcc');
    const attachments: MailAttachment[] = await this.listAttachments(messageId);
    const result: relationalStore.ResultSet = await this.requireStore().querySql(
      'SELECT request_read_receipt FROM messages WHERE id = ? LIMIT 1', [messageId]);
    let requestReadReceipt: boolean = false;
    try {
      if (result.goToFirstRow()) {
        requestReadReceipt = result.getLong(result.getColumnIndex('request_read_receipt')) === 1;
      }
    } finally {
      result.close();
    }
    return new DraftMessage(message.accountId, to, cc, message.subject, message.plainBody, bcc,
      message.id, attachments, requestReadReceipt);
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
          result.getLong(result.getColumnIndex('size'))
        ));
      }
    } finally {
      result.close();
    }
    return attachments;
  }

  async upsertRemoteMessages(messages: MailMessage[], sortOrders: number[]): Promise<number> {
    let insertedCount: number = 0;
    for (let index: number = 0; index < messages.length; index++) {
      if (!await this.getMessage(messages[index].id)) {
        insertedCount++;
      }
      await this.insertMessage(messages[index], sortOrders[index] ?? Date.now());
    }
    return insertedCount;
  }

  async addAccount(account: EmailAccount, secret: string, settings: AccountServerSettings): Promise<void> {
    account.credentialRef = await this.vault.save(account.id, secret);
    await this.insertAccount(account, Date.now(), settings);
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
    const reference: string = await this.vault.save(accountId, secret);
    await this.requireStore().executeSql('UPDATE accounts SET credential_ref = ? WHERE id = ?',
      [reference, accountId]);
  }

  async removeAccount(accountId: string): Promise<void> {
    const accounts: EmailAccount[] = await this.listAccounts();
    const account: EmailAccount | undefined = accounts.find((item: EmailAccount) => item.id === accountId);
    if (account && account.credentialRef.length > 0) {
      await this.vault.remove(account.credentialRef);
    }
    await this.requireStore().executeSql(
      `DELETE FROM message_addresses WHERE message_id IN
       (SELECT id FROM messages WHERE account_id = ?)`, [accountId]);
    await this.requireStore().executeSql(
      `DELETE FROM message_attachments WHERE message_id IN
       (SELECT id FROM messages WHERE account_id = ?)`, [accountId]);
    await this.requireStore().executeSql('DELETE FROM messages WHERE account_id = ?', [accountId]);
    await this.requireStore().executeSql('DELETE FROM pending_operations WHERE account_id = ?', [accountId]);
    await this.requireStore().executeSql('DELETE FROM accounts WHERE id = ?', [accountId]);
  }

  async setAccountSyncEnabled(accountId: string, enabled: boolean): Promise<void> {
    await this.requireStore().executeSql('UPDATE accounts SET sync_enabled = ? WHERE id = ?',
      [enabled ? 1 : 0, accountId]);
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
    await this.requireStore().executeSql(
      'INSERT OR REPLACE INTO app_settings (setting_key, setting_value) VALUES (?, ?)', [key, value]);
  }

  async markRead(messageId: string): Promise<void> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    if (!message || message.isRead) {
      return;
    }
    await this.requireStore().executeSql('UPDATE messages SET is_read = 1 WHERE id = ?', [messageId]);
    await this.enqueueOperation(message.accountId, messageId, PendingOperationType.MARK_READ);
  }

  async toggleRead(messageId: string): Promise<void> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    await this.requireStore().executeSql(
      'UPDATE messages SET is_read = CASE is_read WHEN 1 THEN 0 ELSE 1 END WHERE id = ?', [messageId]);
    if (message) {
      await this.enqueueOperation(message.accountId, messageId,
        message.isRead ? PendingOperationType.MARK_UNREAD : PendingOperationType.MARK_READ);
    }
  }

  async toggleStar(messageId: string): Promise<void> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    await this.requireStore().executeSql(
      'UPDATE messages SET is_starred = CASE is_starred WHEN 1 THEN 0 ELSE 1 END WHERE id = ?', [messageId]);
    if (message) {
      await this.enqueueOperation(message.accountId, messageId,
        message.isStarred ? PendingOperationType.UNSTAR : PendingOperationType.STAR);
    }
  }

  async moveMessages(messageIds: string[], folder: MailFolder): Promise<void> {
    for (let index: number = 0; index < messageIds.length; index++) {
      const message: MailMessage | undefined = await this.getMessage(messageIds[index]);
      await this.requireStore().executeSql('UPDATE messages SET folder = ? WHERE id = ?',
        [folder, messageIds[index]]);
      if (message) {
        await this.enqueueOperation(message.accountId, messageIds[index], PendingOperationType.MOVE, folder);
      }
    }
  }

  async deleteMessages(messageIds: string[]): Promise<void> {
    for (let index: number = 0; index < messageIds.length; index++) {
      const message: MailMessage | undefined = await this.getMessage(messageIds[index]);
      await this.requireStore().executeSql('UPDATE messages SET folder = ? WHERE id = ?',
        [MailFolder.TRASH, messageIds[index]]);
      if (message) {
        await this.enqueueOperation(message.accountId, messageIds[index], PendingOperationType.DELETE,
          MailFolder.TRASH);
      }
    }
  }

  async saveDraft(draft: DraftMessage): Promise<string> {
    const account: EmailAccount | undefined = (await this.listAccounts())
      .find((item: EmailAccount) => item.id === draft.accountId);
    if (!account) {
      throw new Error('请选择发件账户');
    }
    const messageId: string = draft.id.length > 0 ? draft.id : `draft_${Date.now()}`;
    const recipients: MailAddress[] = this.parseAddresses(draft.to);
    const message: MailMessage = new MailMessage(messageId, account.id, MailFolder.DRAFTS,
      new MailAddress(account.displayName, account.email), recipients,
      draft.subject, draft.body, draft.body, '刚刚', true, false, false);
    await this.insertMessage(message, Date.now(), this.parseAddresses(draft.cc), this.parseAddresses(draft.bcc),
      draft.attachments, draft.requestReadReceipt);
    return messageId;
  }

  async deleteDraft(messageId: string): Promise<void> {
    await this.requireStore().executeSql('DELETE FROM message_addresses WHERE message_id = ?', [messageId]);
    await this.requireStore().executeSql('DELETE FROM message_attachments WHERE message_id = ?', [messageId]);
    await this.requireStore().executeSql('DELETE FROM messages WHERE id = ? AND folder = ?',
      [messageId, MailFolder.DRAFTS]);
  }

  async send(draft: DraftMessage): Promise<void> {
    await this.storeSent(draft, true);
  }

  async recordSent(draft: DraftMessage): Promise<void> {
    await this.storeSent(draft, false);
  }

  private async storeSent(draft: DraftMessage, enqueue: boolean): Promise<void> {
    const account: EmailAccount | undefined = (await this.listAccounts())
      .find((item: EmailAccount) => item.id === draft.accountId);
    if (!account) {
      throw new Error('请选择发件账户');
    }
    const message: MailMessage = new MailMessage(`sent_${Date.now()}`, account.id, MailFolder.SENT,
      new MailAddress(account.displayName, account.email), this.parseAddresses(draft.to),
      draft.subject, draft.body, draft.body, '刚刚', true, false, false);
    await this.insertMessage(message, Date.now(), this.parseAddresses(draft.cc), this.parseAddresses(draft.bcc),
      draft.attachments, draft.requestReadReceipt);
    if (enqueue) {
      await this.enqueueOperation(account.id, message.id, PendingOperationType.SEND);
    }
    if (draft.id.length > 0) {
      await this.requireStore().executeSql('DELETE FROM message_addresses WHERE message_id = ?', [draft.id]);
      await this.requireStore().executeSql('DELETE FROM message_attachments WHERE message_id = ?', [draft.id]);
      await this.requireStore().executeSql('DELETE FROM messages WHERE id = ? AND folder = ?',
        [draft.id, MailFolder.DRAFTS]);
    }
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
          result.getLong(result.getColumnIndex('retry_count'))
        ));
      }
    } finally {
      result.close();
    }
    return operations;
  }

  async acknowledgePendingOperation(operationId: string): Promise<void> {
    await this.requireStore().executeSql('DELETE FROM pending_operations WHERE id = ?', [operationId]);
  }

  async recordPendingOperationFailure(operationId: string): Promise<void> {
    await this.requireStore().executeSql(
      'UPDATE pending_operations SET retry_count = retry_count + 1 WHERE id = ?', [operationId]);
  }
}
