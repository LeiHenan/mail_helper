import { DraftMessage } from '../model/MailModels';
import { AccountServerSettings, PendingMailOperation, RemoteFolder, RemoteMessageSummary } from '../model/MailServerModels';

export class MessagePage {
  messages: RemoteMessageSummary[];
  nextCursor: string;

  constructor(messages: RemoteMessageSummary[], nextCursor: string = '') {
    this.messages = messages;
    this.nextCursor = nextCursor;
  }
}

export interface MailBackendListener {
  onFoldersChanged(accountId: string, folders: RemoteFolder[]): void;
  onMessagesChanged(accountId: string, messages: RemoteMessageSummary[]): void;
  onNewMessage(accountId: string, message: RemoteMessageSummary): void;
}

// HarmonyOS equivalent of Thunderbird's backend boundary. UI and local storage
// never depend on an IMAP, SMTP, JMAP, or Graph implementation directly.
export interface MailBackend {
  validate(settings: AccountServerSettings, credential: string): Promise<void>;
  fetchFolders(): Promise<RemoteFolder[]>;
  fetchMessages(folderId: string, cursor: string, limit: number): Promise<MessagePage>;
  fetchMessageBody(folderId: string, messageId: string): Promise<string>;
  execute(operation: PendingMailOperation): Promise<void>;
  send(draft: DraftMessage): Promise<void>;
  startPush(listener: MailBackendListener): Promise<void>;
  stopPush(): Promise<void>;
  close(): Promise<void>;
}

export interface MailBackendFactory {
  create(accountId: string, settings: AccountServerSettings, credentialRef: string): Promise<MailBackend>;
}
