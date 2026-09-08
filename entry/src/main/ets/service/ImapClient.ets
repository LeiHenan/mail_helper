import { util } from '@kit.ArkTS';
import { MailAddress, MailFolder } from '../model/MailModels';
import { AuthenticationMethod, ConnectionSecurity, MailServerSettings } from '../model/MailServerModels';
import { PendingMailOperation, PendingOperationType } from '../model/MailServerModels';
import { ProtocolSocket } from './ProtocolSocket';
import { MimeBodyContent, MimeBodyParser } from './MimeBodyParser';
import { MimeHeaderDecoder } from './MimeHeaderDecoder';

export class ImapMessageRecord {
  uid: string;
  sender: MailAddress;
  recipients: MailAddress[];
  subject: string;
  body: string;
  htmlBody: string;
  receivedAt: number;
  isRead: boolean;
  isStarred: boolean;
  hasAttachments: boolean;

  constructor(uid: string, sender: MailAddress, recipients: MailAddress[], subject: string,
    body: string, htmlBody: string, receivedAt: number, isRead: boolean, isStarred: boolean,
    hasAttachments: boolean) {
    this.uid = uid;
    this.sender = sender;
    this.recipients = recipients;
    this.subject = subject;
    this.body = body;
    this.htmlBody = htmlBody;
    this.receivedAt = receivedAt;
    this.isRead = isRead;
    this.isStarred = isStarred;
    this.hasAttachments = hasAttachments;
  }
}

export class ImapMessagePage {
  records: ImapMessageRecord[];
  highestUid: number;
  lowestUid: number;
  uidValidity: string;
  hasMore: boolean;

  constructor(records: ImapMessageRecord[] = [], highestUid: number = 0, lowestUid: number = 0,
    uidValidity: string = '', hasMore: boolean = false) {
    this.records = records;
    this.highestUid = highestUid;
    this.lowestUid = lowestUid;
    this.uidValidity = uidValidity;
    this.hasMore = hasMore;
  }
}

export class ImapClient {
  private readonly bodyChunkSize: number = 131072;
  private readonly maximumBodySize: number = 8 * 1024 * 1024;
  private channel: ProtocolSocket = new ProtocolSocket();
  private tagSequence: number = 0;
  private bodyParser: MimeBodyParser = new MimeBodyParser();
  private headerDecoder: MimeHeaderDecoder = new MimeHeaderDecoder();
  private encoder: util.TextEncoder = new util.TextEncoder();
  private base64: util.Base64Helper = new util.Base64Helper();

  async connect(settings: MailServerSettings, username: string, secret: string): Promise<void> {
    if (settings.security === ConnectionSecurity.NONE) {
      throw new Error('为保护授权凭据，不支持未加密的 IMAP 登录');
    }
    if (settings.security === ConnectionSecurity.TLS) {
      await this.channel.connect(settings.host, settings.port);
    } else {
      await this.channel.connectPlain(settings.host, settings.port);
    }
    const greeting: string = await this.channel.waitFor((value: string) => value.includes('\r\n'));
    if (!greeting.toUpperCase().includes('* OK')) {
      throw new Error('IMAP 服务器未返回可用状态');
    }
    if (settings.security === ConnectionSecurity.STARTTLS) {
      const startTls: string = await this.command('STARTTLS');
      this.requireOk(startTls, 'IMAP 服务器拒绝 STARTTLS');
      await this.channel.upgradeToTls(settings.host, settings.port);
    }
    if (settings.authentication === AuthenticationMethod.OAUTH2) {
      await this.authenticateOAuth(username, secret);
    } else {
      const response: string = await this.command(`LOGIN ${this.quote(username)} ${this.quote(secret)}`);
      this.requireOk(response, '邮箱地址或授权码验证失败');
    }
    await this.identifyClient(settings.host);
  }

  private async authenticateOAuth(username: string, accessToken: string): Promise<void> {
    this.tagSequence++;
    const tag: string = `A${this.tagSequence.toString().padStart(4, '0')}`;
    const payload: string = `user=${username}\u0001auth=Bearer ${accessToken}\u0001\u0001`;
    const encoded: string = this.base64.encodeToStringSync(this.encoder.encodeInto(payload));
    let response: string = await this.channel.sendAndWait(
      `${tag} AUTHENTICATE XOAUTH2 ${encoded}\r\n`,
      (value: string) => this.hasTaggedResponse(value, tag) || this.hasContinuation(value), 15000);
    if (!this.hasTaggedResponse(response, tag) && this.hasContinuation(response)) {
      response += await this.channel.sendAndWait('\r\n',
        (value: string) => this.hasTaggedResponse(value, tag), 15000);
    }
    this.requireOk(response, 'OAuth 登录失败，请重新授权邮箱账户');
  }

  private hasTaggedResponse(response: string, tag: string): boolean {
    return response.startsWith(`${tag} `) || response.includes(`\r\n${tag} `);
  }

  private hasContinuation(response: string): boolean {
    return response.startsWith('+') || response.includes('\r\n+');
  }

  private async identifyClient(host: string): Promise<void> {
    if (!this.isCoremailHost(host)) {
      return;
    }
    const identified: string = await this.command(
      'ID ("name" "MailHelper" "version" "1.0" "vendor" "HarmonyOS")');
    this.requireOk(identified, '邮件服务器拒绝客户端身份声明');
  }

  private isCoremailHost(host: string): boolean {
    const normalizedHost: string = host.trim().toLowerCase();
    return normalizedHost === 'imap.163.com' || normalizedHost === 'imap.126.com' ||
      normalizedHost === 'imap.yeah.net' || normalizedHost.endsWith('.163.com') ||
      normalizedHost.endsWith('.126.com') || normalizedHost.endsWith('.yeah.net');
  }

  private quote(value: string): string {
    return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  }

  private async command(commandText: string, timeoutMs: number = 15000): Promise<string> {
    this.tagSequence++;
    const tag: string = `A${this.tagSequence.toString().padStart(4, '0')}`;
    return this.channel.sendAndWait(`${tag} ${commandText}\r\n`,
      (value: string) => value.includes(`\r\n${tag} `) || value.startsWith(`${tag} `), timeoutMs);
  }

  private requireOk(response: string, message: string): void {
    const upper: string = response.toUpperCase();
    const tag: string = `A${this.tagSequence.toString().padStart(4, '0')} OK`;
    if (!upper.includes(tag)) {
      const detail: string = this.responseDetail(response);
      throw new Error(detail.length > 0 ? `${message}：${detail}` : message);
    }
  }

  private responseDetail(response: string): string {
    const currentTag: string = `A${this.tagSequence.toString().padStart(4, '0')}`;
    const lines: string[] = response.split('\r\n');
    for (let index: number = lines.length - 1; index >= 0; index--) {
      const line: string = lines[index].trim();
      if (line.toUpperCase().startsWith(`${currentTag} `)) {
        return line.substring(currentTag.length).trim().substring(0, 300);
      }
    }
    return response.replace(/[\r\n]+/g, ' ').trim().substring(0, 300);
  }

  async fetchInitial(folder: MailFolder, days: number = 30, limit: number = 200): Promise<ImapMessagePage> {
    const uidValidity: string = await this.selectFolder(folder);
    const allUids: string[] = await this.searchUids(folder, 'ALL');
    const since: Date = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
    const recentUids: string[] = await this.searchUids(folder, `SINCE ${this.imapDate(since)}`);
    const selectedUids: string[] = recentUids.slice(Math.max(0, recentUids.length - limit)).reverse();
    const records: ImapMessageRecord[] = await this.fetchRecords(selectedUids);
    const highestUid: number = this.highestUid(allUids);
    const lowestUid: number = this.lowestUid(selectedUids, highestUid > 0 ? highestUid + 1 : 0);
    const hasMore: boolean = allUids.some((uid: string) => Number.parseInt(uid, 10) < lowestUid);
    return new ImapMessagePage(records, highestUid, lowestUid, uidValidity, hasMore);
  }

  async fetchIncremental(folder: MailFolder, lastUid: number): Promise<ImapMessagePage> {
    const uidValidity: string = await this.selectFolder(folder);
    const allUids: string[] = await this.searchUids(folder, 'ALL');
    const newUids: string[] = allUids.filter((uid: string) => Number.parseInt(uid, 10) > lastUid).reverse();
    const records: ImapMessageRecord[] = await this.fetchRecords(newUids);
    return new ImapMessagePage(records, this.highestUid(allUids), this.lowestUid(newUids, 0),
      uidValidity, false);
  }

  async fetchOlder(folder: MailFolder, beforeUid: number, limit: number = 50): Promise<ImapMessagePage> {
    const uidValidity: string = await this.selectFolder(folder);
    const allUids: string[] = await this.searchUids(folder, 'ALL');
    const olderUids: string[] = allUids.filter((uid: string) =>
      beforeUid <= 0 || Number.parseInt(uid, 10) < beforeUid);
    const selectedUids: string[] = olderUids.slice(Math.max(0, olderUids.length - limit)).reverse();
    const records: ImapMessageRecord[] = await this.fetchRecords(selectedUids);
    return new ImapMessagePage(records, this.highestUid(allUids), this.lowestUid(selectedUids, beforeUid),
      uidValidity, olderUids.length > selectedUids.length);
  }

  private async searchUids(folder: MailFolder, criteria: string): Promise<string[]> {
    const searched: string = await this.command(`UID SEARCH ${criteria}`);
    this.requireOk(searched, `无法读取${this.folderLabel(folder)}邮件列表`);
    const searchLine: RegExpMatchArray | null = searched.match(/\* SEARCH([^\r\n]*)/i);
    return searchLine ? searchLine[1].trim().split(/\s+/)
      .filter((value: string) => /^\d+$/.test(value)) : [];
  }

  private async fetchRecords(uids: string[]): Promise<ImapMessageRecord[]> {
    const records: ImapMessageRecord[] = [];
    for (let index: number = 0; index < uids.length; index++) {
      const response: string = await this.command(`UID FETCH ${uids[index]} ` +
        '(UID FLAGS INTERNALDATE BODY.PEEK[HEADER])', 30000);
      this.requireOk(response, `读取邮件 ${uids[index]} 失败`);
      const rawBody: string = await this.fetchBodyText(uids[index]);
      const record: ImapMessageRecord | undefined = this.parseFetch(response, uids[index], rawBody);
      if (record) {
        records.push(record);
      }
    }
    return records;
  }

  private highestUid(uids: string[]): number {
    return uids.length > 0 ? Number.parseInt(uids[uids.length - 1], 10) : 0;
  }

  private lowestUid(uids: string[], fallback: number): number {
    if (uids.length === 0) return fallback;
    let lowest: number = Number.parseInt(uids[0], 10);
    for (let index: number = 1; index < uids.length; index++) {
      lowest = Math.min(lowest, Number.parseInt(uids[index], 10));
    }
    return lowest;
  }

  private imapDate(date: Date): string {
    const months: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return `${date.getDate()}-${months[date.getMonth()]}-${date.getFullYear()}`;
  }

  private async fetchBodyText(uid: string): Promise<string> {
    let offset: number = 0;
    let body: string = '';
    while (offset < this.maximumBodySize) {
      const response: string = await this.command(
        `UID FETCH ${uid} (BODY.PEEK[TEXT]<${offset}.${this.bodyChunkSize}>)`, 30000);
      this.requireOk(response, `读取邮件 ${uid} 正文失败`);
      const literalSize: number = this.textLiteralSize(response);
      if (literalSize <= 0) {
        break;
      }
      body += this.extractTextChunk(response);
      offset += literalSize;
      if (literalSize < this.bodyChunkSize) {
        break;
      }
    }
    return body;
  }

  private textLiteralSize(response: string): number {
    const matched: RegExpMatchArray | null = response.match(
      /BODY\[TEXT\](?:<\d+>)?\s+\{(\d+)\}\r\n/i);
    return matched ? Number.parseInt(matched[1], 10) : 0;
  }

  private extractTextChunk(response: string): string {
    const marker: RegExpMatchArray | null = response.match(
      /BODY\[TEXT\](?:<\d+>)?\s+\{\d+\}\r\n/i);
    if (!marker || marker.index === undefined) {
      return '';
    }
    return this.extractBody(response, marker.index);
  }

  private async selectFolder(folder: MailFolder): Promise<string> {
    const mailbox: string = await this.resolveDestination(folder);
    const selected: string = await this.command(`SELECT ${this.quote(mailbox)}`);
    this.requireOk(selected, `无法打开${this.folderLabel(folder)}`);
    const matched: RegExpMatchArray | null = selected.match(/\[UIDVALIDITY\s+(\d+)\]/i);
    return matched ? matched[1] : '';
  }

  private folderLabel(folder: MailFolder): string {
    if (folder === MailFolder.SPAM) return '垃圾邮件';
    if (folder === MailFolder.TRASH) return '垃圾箱';
    if (folder === MailFolder.SENT) return '已发送';
    if (folder === MailFolder.DRAFTS) return '草稿箱';
    if (folder === MailFolder.ARCHIVE) return '归档文件夹';
    return '收件箱';
  }

  async execute(operation: PendingMailOperation): Promise<void> {
    if (operation.type === PendingOperationType.SEND) {
      throw new Error('发件操作需要通过 SMTP 处理');
    }
    const uid: string = this.uidFromMessageId(operation.messageId);
    await this.selectFolder(this.sourceFolder(operation.messageId));
    let response: string = '';
    if (operation.type === PendingOperationType.MARK_READ) {
      response = await this.command(`UID STORE ${uid} +FLAGS.SILENT (\\Seen)`);
    } else if (operation.type === PendingOperationType.MARK_UNREAD) {
      response = await this.command(`UID STORE ${uid} -FLAGS.SILENT (\\Seen)`);
    } else if (operation.type === PendingOperationType.STAR) {
      response = await this.command(`UID STORE ${uid} +FLAGS.SILENT (\\Flagged)`);
    } else if (operation.type === PendingOperationType.UNSTAR) {
      response = await this.command(`UID STORE ${uid} -FLAGS.SILENT (\\Flagged)`);
    } else {
      const destination: string = await this.resolveDestination(operation.destinationFolder);
      response = await this.command(`UID MOVE ${uid} ${this.quote(destination)}`);
      if (!this.isOk(response)) {
        response = await this.command(`UID COPY ${uid} ${this.quote(destination)}`);
        this.requireOk(response, '服务器不支持移动此邮件');
        response = await this.command(`UID STORE ${uid} +FLAGS.SILENT (\\Deleted)`);
        this.requireOk(response, '服务器未能标记原邮件为已删除');
        response = await this.command('EXPUNGE');
      }
    }
    this.requireOk(response, '服务器未接受邮件状态变更');
  }

  private isOk(response: string): boolean {
    const tag: string = `A${this.tagSequence.toString().padStart(4, '0')} OK`;
    return response.toUpperCase().includes(tag);
  }

  private uidFromMessageId(messageId: string): string {
    const matched: RegExpMatchArray | null = messageId.match(/_(\d+)$/);
    if (!matched) {
      throw new Error('本地演示邮件没有可同步的服务器 UID');
    }
    return matched[1];
  }

  private sourceFolder(messageId: string): MailFolder {
    if (messageId.includes(`_${MailFolder.SPAM}_`)) return MailFolder.SPAM;
    if (messageId.includes(`_${MailFolder.TRASH}_`)) return MailFolder.TRASH;
    if (messageId.includes(`_${MailFolder.SENT}_`)) return MailFolder.SENT;
    if (messageId.includes(`_${MailFolder.DRAFTS}_`)) return MailFolder.DRAFTS;
    if (messageId.includes(`_${MailFolder.ARCHIVE}_`)) return MailFolder.ARCHIVE;
    return MailFolder.INBOX;
  }

  private async resolveDestination(folder: string): Promise<string> {
    if (folder === 'inbox') return 'INBOX';
    const listed: string = await this.command('LIST "" "*"');
    this.requireOk(listed, '无法读取服务器文件夹');
    const specialFlag: string = folder === 'trash' ? '\\TRASH' :
      (folder === 'spam' ? '\\JUNK' : (folder === 'archive' ? '\\ARCHIVE' :
        (folder === 'sent' ? '\\SENT' : (folder === 'drafts' ? '\\DRAFTS' : ''))));
    if (specialFlag.length > 0) {
      const lines: string[] = listed.split('\r\n');
      for (let index: number = 0; index < lines.length; index++) {
        if (lines[index].toUpperCase().includes(specialFlag)) {
          const quoted: RegExpMatchArray | null = lines[index].match(/"([^"]+)"\s*$/);
          if (quoted) return quoted[1];
          const pieces: string[] = lines[index].trim().split(/\s+/);
          if (pieces.length > 0) return pieces[pieces.length - 1];
        }
      }
    }
    if (folder === 'trash') return 'Trash';
    if (folder === 'spam') return 'Junk';
    if (folder === 'archive') return 'Archive';
    if (folder === 'sent') return 'Sent';
    if (folder === 'drafts') return 'Drafts';
    return folder;
  }

  private parseFetch(response: string, fallbackUid: string, rawBody: string): ImapMessageRecord | undefined {
    const uidMatch: RegExpMatchArray | null = response.match(/UID\s+(\d+)/i);
    const uid: string = uidMatch ? uidMatch[1] : fallbackUid;
    const flagsMatch: RegExpMatchArray | null = response.match(/FLAGS\s+\(([^)]*)\)/i);
    const flags: string = flagsMatch ? flagsMatch[1].toUpperCase() : '';
    const headerMarker: RegExpMatchArray | null = response.match(/BODY\[HEADER\]\s+\{\d+\}\r\n/i);
    if (!headerMarker || headerMarker.index === undefined) {
      return undefined;
    }
    const headerStart: number = headerMarker.index + headerMarker[0].length;
    const headerBlock: string = response.substring(headerStart);
    const from: MailAddress = this.parseAddress(this.headerValue(headerBlock, 'From'));
    const to: MailAddress[] = this.parseAddressList(this.headerValue(headerBlock, 'To'));
    const subject: string = this.decodeMimeWords(this.headerValue(headerBlock, 'Subject'));
    const dateValue: string = this.headerValue(headerBlock, 'Date');
    const headerDate: number = this.parseMailDate(dateValue);
    const internalDate: number = this.parseInternalDate(response);
    let receivedAt: number = Number.isNaN(headerDate) ? internalDate : headerDate;
    if (Number.isNaN(receivedAt)) {
      receivedAt = Date.now();
    }
    const bodyContent: MimeBodyContent = this.bodyParser.parse(headerBlock, rawBody);
    return new ImapMessageRecord(uid, from, to, subject, bodyContent.plainText, bodyContent.htmlText, receivedAt,
      flags.includes('\\SEEN'), flags.includes('\\FLAGGED'), bodyContent.hasAttachments);
  }

  private parseMailDate(value: string): number {
    if (value.trim().length === 0) {
      return Number.NaN;
    }
    const withoutComments: string = value.replace(/\([^)]*\)/g, ' ').replace(/\s+/g, ' ').trim();
    const matched: RegExpMatchArray | null = withoutComments.match(
      /^(?:[A-Za-z]{3},?\s+)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s+([+-])(\d{2})(\d{2})$/i);
    if (!matched) {
      return Date.parse(withoutComments);
    }
    const months: string[] = ['jan', 'feb', 'mar', 'apr', 'may', 'jun',
      'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
    const month: number = months.indexOf(matched[2].toLowerCase());
    if (month < 0) {
      return Number.NaN;
    }
    let year: number = Number.parseInt(matched[3], 10);
    if (year < 100) {
      year += year >= 70 ? 1900 : 2000;
    }
    const day: number = Number.parseInt(matched[1], 10);
    const hour: number = Number.parseInt(matched[4], 10);
    const minute: number = Number.parseInt(matched[5], 10);
    const second: number = matched[6] ? Number.parseInt(matched[6], 10) : 0;
    const offsetHour: number = Number.parseInt(matched[8], 10);
    const offsetMinute: number = Number.parseInt(matched[9], 10);
    const offsetSign: number = matched[7] === '+' ? 1 : -1;
    const offsetMilliseconds: number = offsetSign * (offsetHour * 60 + offsetMinute) * 60 * 1000;
    return Date.UTC(year, month, day, hour, minute, second) - offsetMilliseconds;
  }

  private parseInternalDate(response: string): number {
    const matched: RegExpMatchArray | null = response.match(
      /INTERNALDATE\s+"(\d{1,2})-([A-Za-z]{3})-(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+([+-])(\d{2})(\d{2})"/i);
    if (!matched) {
      return Number.NaN;
    }
    const months: string[] = ['jan', 'feb', 'mar', 'apr', 'may', 'jun',
      'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
    const month: number = months.indexOf(matched[2].toLowerCase());
    if (month < 0) {
      return Number.NaN;
    }
    const year: number = Number.parseInt(matched[3], 10);
    const day: number = Number.parseInt(matched[1], 10);
    const hour: number = Number.parseInt(matched[4], 10);
    const minute: number = Number.parseInt(matched[5], 10);
    const second: number = Number.parseInt(matched[6], 10);
    const offsetHour: number = Number.parseInt(matched[8], 10);
    const offsetMinute: number = Number.parseInt(matched[9], 10);
    const offsetSign: number = matched[7] === '+' ? 1 : -1;
    const offsetMilliseconds: number = offsetSign * (offsetHour * 60 + offsetMinute) * 60 * 1000;
    return Date.UTC(year, month, day, hour, minute, second) - offsetMilliseconds;
  }

  private headerValue(headers: string, name: string): string {
    const unfolded: string = headers.replace(/\r\n[ \t]+/g, ' ');
    const expression: RegExp = new RegExp(`(?:^|\\r\\n)${name}:\\s*([^\\r\\n]*)`, 'i');
    const matched: RegExpMatchArray | null = unfolded.match(expression);
    return matched ? matched[1].trim() : '';
  }

  private extractBody(response: string, markerIndex: number): string {
    if (markerIndex < 0) {
      return '';
    }
    const markerEnd: number = response.indexOf('\r\n', markerIndex);
    if (markerEnd < 0) {
      return '';
    }
    const taggedIndex: number = response.lastIndexOf('\r\nA');
    const fetchEnd: number = response.lastIndexOf('\r\n)', taggedIndex > 0 ? taggedIndex : response.length);
    const end: number = fetchEnd > markerEnd ? fetchEnd : (taggedIndex > markerEnd ? taggedIndex : response.length);
    return response.substring(markerEnd + 2, end);
  }

  private parseAddress(value: string): MailAddress {
    const decoded: string = this.decodeMimeWords(value).trim();
    const angle: RegExpMatchArray | null = decoded.match(/^(.*)<([^>]+)>/);
    if (angle) {
      return new MailAddress(angle[1].replace(/^"|"$/g, '').trim(), angle[2].trim());
    }
    return new MailAddress('', decoded.replace(/^<|>$/g, '').trim());
  }

  private parseAddressList(value: string): MailAddress[] {
    if (value.trim().length === 0) {
      return [];
    }
    return value.split(',').map((item: string) => this.parseAddress(item))
      .filter((address: MailAddress) => address.address.length > 0);
  }

  private decodeMimeWords(value: string): string {
    return this.headerDecoder.decode(value);
  }

  async close(): Promise<void> {
    try {
      await this.command('LOGOUT', 3000);
    } catch (_error) {
    }
    await this.channel.close();
  }
}
