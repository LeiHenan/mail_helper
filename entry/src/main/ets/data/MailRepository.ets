import { DraftMessage, EmailAccount, MailAttachment, MailFolder, MailMessage } from '../model/MailModels';
import { AccountServerSettings } from '../model/MailServerModels';

export interface MailRepository {
  listAccounts(): Promise<EmailAccount[]>;
  listMessages(accountId: string, folder: MailFolder): Promise<MailMessage[]>;
  listStarredMessages(accountId: string): Promise<MailMessage[]>;
  getMessage(messageId: string): Promise<MailMessage | undefined>;
  getDraft(messageId: string): Promise<DraftMessage | undefined>;
  listAttachments(messageId: string): Promise<MailAttachment[]>;
  addAccount(account: EmailAccount, secret: string, settings: AccountServerSettings): Promise<void>;
  getAccountServerSettings(accountId: string): Promise<AccountServerSettings | undefined>;
  readAccountCredential(accountId: string): Promise<string>;
  removeAccount(accountId: string): Promise<void>;
  setAccountSyncEnabled(accountId: string, enabled: boolean): Promise<void>;
  getSetting(key: string, defaultValue: string): Promise<string>;
  setSetting(key: string, value: string): Promise<void>;
  markRead(messageId: string): Promise<void>;
  toggleRead(messageId: string): Promise<void>;
  toggleStar(messageId: string): Promise<void>;
  moveMessages(messageIds: string[], folder: MailFolder): Promise<void>;
  deleteMessages(messageIds: string[]): Promise<void>;
  saveDraft(draft: DraftMessage): Promise<string>;
  deleteDraft(messageId: string): Promise<void>;
  send(draft: DraftMessage): Promise<void>;
}
