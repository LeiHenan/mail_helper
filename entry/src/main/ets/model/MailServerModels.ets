import { EmailProviderType, MailAddress, MailFolder } from './MailModels';

export enum MailProtocol {
  IMAP = 'imap',
  SMTP = 'smtp',
  JMAP = 'jmap',
  GRAPH = 'graph'
}

export enum ConnectionSecurity {
  TLS = 'tls',
  STARTTLS = 'starttls',
  NONE = 'none'
}

export enum AuthenticationMethod {
  PASSWORD = 'password',
  OAUTH2 = 'oauth2',
  CLIENT_CERTIFICATE = 'client_certificate'
}

export class MailServerSettings {
  protocol: MailProtocol;
  host: string;
  port: number;
  security: ConnectionSecurity;
  authentication: AuthenticationMethod;
  username: string;

  constructor(protocol: MailProtocol, host: string, port: number, security: ConnectionSecurity,
    authentication: AuthenticationMethod, username: string = '') {
    this.protocol = protocol;
    this.host = host;
    this.port = port;
    this.security = security;
    this.authentication = authentication;
    this.username = username;
  }
}

export class AccountServerSettings {
  provider: EmailProviderType;
  email: string;
  incoming: MailServerSettings;
  outgoing: MailServerSettings;

  constructor(provider: EmailProviderType, email: string, incoming: MailServerSettings,
    outgoing: MailServerSettings) {
    this.provider = provider;
    this.email = email;
    this.incoming = incoming;
    this.outgoing = outgoing;
  }
}

export enum RemoteFolderType {
  INBOX = 'inbox',
  SENT = 'sent',
  DRAFTS = 'drafts',
  TRASH = 'trash',
  ARCHIVE = 'archive',
  SPAM = 'spam',
  REGULAR = 'regular'
}

export class RemoteFolder {
  serverId: string;
  displayName: string;
  type: RemoteFolderType;
  unreadCount: number;

  constructor(serverId: string, displayName: string, type: RemoteFolderType,
    unreadCount: number = 0) {
    this.serverId = serverId;
    this.displayName = displayName;
    this.type = type;
    this.unreadCount = unreadCount;
  }
}

export class RemoteMessageSummary {
  serverId: string;
  folder: MailFolder;
  sender: MailAddress;
  recipients: MailAddress[];
  subject: string;
  preview: string;
  receivedAt: number;
  isRead: boolean;
  isStarred: boolean;
  hasAttachments: boolean;

  constructor(serverId: string, folder: MailFolder, sender: MailAddress, recipients: MailAddress[],
    subject: string, preview: string, receivedAt: number, isRead: boolean = false,
    isStarred: boolean = false, hasAttachments: boolean = false) {
    this.serverId = serverId;
    this.folder = folder;
    this.sender = sender;
    this.recipients = recipients;
    this.subject = subject;
    this.preview = preview;
    this.receivedAt = receivedAt;
    this.isRead = isRead;
    this.isStarred = isStarred;
    this.hasAttachments = hasAttachments;
  }
}

export enum PendingOperationType {
  MARK_READ = 'mark_read',
  MARK_UNREAD = 'mark_unread',
  STAR = 'star',
  UNSTAR = 'unstar',
  MOVE = 'move',
  DELETE = 'delete',
  SEND = 'send'
}

export class PendingMailOperation {
  id: string;
  accountId: string;
  messageId: string;
  type: PendingOperationType;
  destinationFolder: string;
  createdAt: number;
  retryCount: number;
  nextRetryAt: number;

  constructor(id: string, accountId: string, messageId: string, type: PendingOperationType,
    destinationFolder: string = '', createdAt: number = Date.now(), retryCount: number = 0,
    nextRetryAt: number = 0) {
    this.id = id;
    this.accountId = accountId;
    this.messageId = messageId;
    this.type = type;
    this.destinationFolder = destinationFolder;
    this.createdAt = createdAt;
    this.retryCount = retryCount;
    this.nextRetryAt = nextRetryAt;
  }
}

export enum SyncPhase {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  FOLDERS = 'folders',
  MESSAGES = 'messages',
  OPERATIONS = 'operations',
  COMPLETE = 'complete',
  FAILED = 'failed'
}

export class AccountSyncState {
  accountId: string;
  phase: SyncPhase;
  progress: number;
  lastSuccessAt: number;
  errorMessage: string;

  constructor(accountId: string, phase: SyncPhase = SyncPhase.IDLE, progress: number = 0,
    lastSuccessAt: number = 0, errorMessage: string = '') {
    this.accountId = accountId;
    this.phase = phase;
    this.progress = progress;
    this.lastSuccessAt = lastSuccessAt;
    this.errorMessage = errorMessage;
  }
}
