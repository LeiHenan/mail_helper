export enum EmailProviderType {
  QQ = 'qq',
  NETEASE_163 = '163',
  GMAIL = 'gmail',
  OUTLOOK = 'outlook',
  CUSTOM = 'custom'
}

export enum MailFolder {
  INBOX = 'inbox',
  SENT = 'sent',
  DRAFTS = 'drafts',
  ARCHIVE = 'archive',
  SPAM = 'spam',
  TRASH = 'trash'
}

export enum AuthType {
  AUTHORIZATION_CODE = 'authorization_code',
  OAUTH_PKCE = 'oauth_pkce'
}

export enum SendStatus {
  SENDING = 'sending',
  SENT = 'sent',
  FAILED = 'failed'
}

export class EmailAccount {
  id: string;
  email: string;
  displayName: string;
  provider: EmailProviderType;
  color: string;
  credentialRef: string;
  unreadCount: number;
  syncEnabled: boolean;

  constructor(id: string, email: string, displayName: string, provider: EmailProviderType,
    color: string, credentialRef: string = '', unreadCount: number = 0, syncEnabled: boolean = true) {
    this.id = id;
    this.email = email;
    this.displayName = displayName;
    this.provider = provider;
    this.color = color;
    this.credentialRef = credentialRef;
    this.unreadCount = unreadCount;
    this.syncEnabled = syncEnabled;
  }
}

export class MailAddress {
  name: string;
  address: string;

  constructor(name: string, address: string) {
    this.name = name;
    this.address = address;
  }
}

// 侧边栏 / 账户列表用的邮件计数快照。inboxUnread 是收件箱的未读数，其余均为对应文件夹的邮件总数，
// starred 为跨文件夹的星标总数——与页面原先 7 次查询的语义一一对应。
export class MailFolderCounts {
  inboxUnread: number;
  starred: number;
  drafts: number;
  sent: number;
  archive: number;
  spam: number;
  trash: number;

  constructor(inboxUnread: number = 0, starred: number = 0, drafts: number = 0, sent: number = 0,
    archive: number = 0, spam: number = 0, trash: number = 0) {
    this.inboxUnread = inboxUnread;
    this.starred = starred;
    this.drafts = drafts;
    this.sent = sent;
    this.archive = archive;
    this.spam = spam;
    this.trash = trash;
  }
}

export class MailMessage {
  id: string;
  accountId: string;
  folder: MailFolder;
  sender: MailAddress;
  recipients: MailAddress[];
  subject: string;
  preview: string;
  plainBody: string;
  // receivedAt 是入库时算好的展示串（历史字段，日期分组与列表时间已不再依赖它）；
  // receivedAtMs 是 messages.sort_order 里的 epoch 毫秒，分组 / 排序 / 行内时间一律用它。
  receivedAt: string;
  receivedAtMs: number;
  isRead: boolean;
  isStarred: boolean;
  hasAttachments: boolean;
  htmlBody: string;
  rfcMessageId: string;
  inReplyTo: string;

  constructor(id: string, accountId: string, folder: MailFolder, sender: MailAddress,
    recipients: MailAddress[], subject: string, preview: string, plainBody: string,
    receivedAt: string, isRead: boolean = false, isStarred: boolean = false,
    hasAttachments: boolean = false, htmlBody: string = '', rfcMessageId: string = '',
    inReplyTo: string = '', receivedAtMs: number = 0) {
    this.id = id;
    this.accountId = accountId;
    this.folder = folder;
    this.sender = sender;
    this.recipients = recipients;
    this.subject = subject;
    this.preview = preview;
    this.plainBody = plainBody;
    this.receivedAt = receivedAt;
    this.receivedAtMs = receivedAtMs;
    this.isRead = isRead;
    this.isStarred = isStarred;
    this.hasAttachments = hasAttachments;
    this.htmlBody = htmlBody;
    this.rfcMessageId = rfcMessageId;
    this.inReplyTo = inReplyTo;
  }
}

export class MailAttachment {
  id: string;
  uri: string;
  name: string;
  mimeType: string;
  size: number;
  inline: boolean;

  constructor(id: string, uri: string, name: string, mimeType: string = 'application/octet-stream',
    size: number = 0, inline: boolean = false) {
    this.id = id;
    this.uri = uri;
    this.name = name;
    this.mimeType = mimeType;
    this.size = size;
    this.inline = inline;
  }
}

export class MailAttachmentPayload {
  name: string;
  mimeType: string;
  size: number;
  inline: boolean;
  content: Uint8Array;

  constructor(name: string, mimeType: string, size: number, inline: boolean, content: Uint8Array) {
    this.name = name;
    this.mimeType = mimeType;
    this.size = size;
    this.inline = inline;
    this.content = content;
  }
}

export class DraftMessage {
  id: string;
  accountId: string;
  to: string;
  cc: string;
  bcc: string;
  subject: string;
  body: string;
  attachments: MailAttachment[];
  requestReadReceipt: boolean;
  inReplyTo: string;
  rfcMessageId: string;

  constructor(accountId: string, to: string, cc: string, subject: string, body: string,
    bcc: string = '', id: string = '', attachments: MailAttachment[] = [],
    requestReadReceipt: boolean = false, inReplyTo: string = '', rfcMessageId: string = '') {
    this.id = id;
    this.accountId = accountId;
    this.to = to;
    this.cc = cc;
    this.bcc = bcc;
    this.subject = subject;
    this.body = body;
    this.attachments = attachments;
    this.requestReadReceipt = requestReadReceipt;
    this.inReplyTo = inReplyTo;
    this.rfcMessageId = rfcMessageId;
  }
}
