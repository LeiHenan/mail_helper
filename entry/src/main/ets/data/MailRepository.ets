import { DraftMessage, EmailAccount, MailAttachment, MailFolder, MailFolderCounts, MailMessage,
  SendStatus } from '../model/MailModels';
import { AccountServerSettings } from '../model/MailServerModels';

// 列表摘要查询条件：键集（keyset）分页 + 筛选下推。
// - 排序键固定为 (sort_order DESC, id DESC)，游标取上一页末行的这两个值；
//   cursorActive=false 时取最新一页（忽略游标字段）。
// - starredOnly 时跨文件夹取星标邮件（与原 listStarredMessageSummaries 语义一致），此时 folder 被忽略；
//   否则按 folder 过滤。accountId === 'all' 表示跨账户。
// - unreadOnly / attachmentOnly 直接进 WHERE，而不是只过滤已加载窗口。
// - limit <= 0 表示不限制条数。
export class MailSummaryQuery {
  accountId: string;
  folder: MailFolder;
  starredOnly: boolean;
  unreadOnly: boolean;
  attachmentOnly: boolean;
  limit: number;
  cursorSortOrder: number;
  cursorMessageId: string;
  cursorActive: boolean;

  constructor(accountId: string, folder: MailFolder, starredOnly: boolean = false,
    unreadOnly: boolean = false, attachmentOnly: boolean = false, limit: number = 0,
    cursorSortOrder: number = 0, cursorMessageId: string = '', cursorActive: boolean = false) {
    this.accountId = accountId;
    this.folder = folder;
    this.starredOnly = starredOnly;
    this.unreadOnly = unreadOnly;
    this.attachmentOnly = attachmentOnly;
    this.limit = limit;
    this.cursorSortOrder = cursorSortOrder;
    this.cursorMessageId = cursorMessageId;
    this.cursorActive = cursorActive;
  }
}

export interface MailRepository {
  listAccounts(): Promise<EmailAccount[]>;
  listMessages(accountId: string, folder: MailFolder): Promise<MailMessage[]>;
  listMessageSummaries(query: MailSummaryQuery): Promise<MailMessage[]>;
  listStarredMessages(accountId: string): Promise<MailMessage[]>;
  folderCounts(accountId: string): Promise<MailFolderCounts>;
  getMessage(messageId: string): Promise<MailMessage | undefined>;
  getDraft(messageId: string): Promise<DraftMessage | undefined>;
  getSendableMessage(messageId: string): Promise<DraftMessage | undefined>;
  listAttachments(messageId: string): Promise<MailAttachment[]>;
  addAccount(account: EmailAccount, secret: string, settings: AccountServerSettings): Promise<void>;
  getAccountServerSettings(accountId: string): Promise<AccountServerSettings | undefined>;
  readAccountCredential(accountId: string): Promise<string>;
  removeAccount(accountId: string): Promise<void>;
  setAccountSyncEnabled(accountId: string, enabled: boolean): Promise<void>;
  getSetting(key: string, defaultValue: string): Promise<string>;
  getSettingsByPrefix(prefix: string): Promise<Map<string, string>>;
  setSetting(key: string, value: string): Promise<void>;
  markRead(messageId: string): Promise<void>;
  toggleRead(messageId: string): Promise<void>;
  toggleStar(messageId: string): Promise<void>;
  moveMessages(messageIds: string[], folder: MailFolder): Promise<void>;
  deleteMessages(messageIds: string[]): Promise<void>;
  purgeMessages(messageIds: string[]): Promise<void>;
  emptyTrash(accountId: string): Promise<number>;
  saveDraft(draft: DraftMessage): Promise<string>;
  deleteDraft(messageId: string): Promise<void>;
  send(draft: DraftMessage): Promise<string>;
  markMessageSendStatus(messageId: string, status: SendStatus): Promise<void>;
}
