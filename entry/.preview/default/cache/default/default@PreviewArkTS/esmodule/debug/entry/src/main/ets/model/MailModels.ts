export enum EmailProviderType {
    QQ = "qq",
    NETEASE_163 = "163",
    GMAIL = "gmail",
    OUTLOOK = "outlook",
    CUSTOM = "custom"
}
export enum MailFolder {
    INBOX = "inbox",
    SENT = "sent",
    DRAFTS = "drafts",
    TRASH = "trash"
}
export enum AuthType {
    AUTHORIZATION_CODE = "authorization_code",
    OAUTH_PKCE = "oauth_pkce"
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
    constructor(id: string, email: string, displayName: string, provider: EmailProviderType, color: string, credentialRef: string = '', unreadCount: number = 0, syncEnabled: boolean = true) {
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
export class MailMessage {
    id: string;
    accountId: string;
    folder: MailFolder;
    sender: MailAddress;
    recipients: MailAddress[];
    subject: string;
    preview: string;
    plainBody: string;
    receivedAt: string;
    isRead: boolean;
    isStarred: boolean;
    hasAttachments: boolean;
    constructor(id: string, accountId: string, folder: MailFolder, sender: MailAddress, recipients: MailAddress[], subject: string, preview: string, plainBody: string, receivedAt: string, isRead: boolean = false, isStarred: boolean = false, hasAttachments: boolean = false) {
        this.id = id;
        this.accountId = accountId;
        this.folder = folder;
        this.sender = sender;
        this.recipients = recipients;
        this.subject = subject;
        this.preview = preview;
        this.plainBody = plainBody;
        this.receivedAt = receivedAt;
        this.isRead = isRead;
        this.isStarred = isStarred;
        this.hasAttachments = hasAttachments;
    }
}
export class DraftMessage {
    accountId: string;
    to: string;
    cc: string;
    subject: string;
    body: string;
    constructor(accountId: string, to: string, cc: string, subject: string, body: string) {
        this.accountId = accountId;
        this.to = to;
        this.cc = cc;
        this.subject = subject;
        this.body = body;
    }
}
