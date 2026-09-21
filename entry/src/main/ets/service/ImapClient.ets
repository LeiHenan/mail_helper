import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MailAddress, MailAttachmentPayload, MailFolder } from '../model/MailModels';
import { AuthenticationMethod, ConnectionSecurity, MailServerSettings } from '../model/MailServerModels';
import { PendingMailOperation, PendingOperationType } from '../model/MailServerModels';
import { ProtocolSocket } from './ProtocolSocket';
import { MimeBodyContent, MimeBodyParser } from './MimeBodyParser';
import { MimeHeaderDecoder } from './MimeHeaderDecoder';
import { normalizeMessageId } from '../common/MessageId';

const DOMAIN: number = 0x0000;

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
  attachments: MailAttachmentPayload[];
  rfcMessageId: string;

  constructor(uid: string, sender: MailAddress, recipients: MailAddress[], subject: string,
    body: string, htmlBody: string, receivedAt: number, isRead: boolean, isStarred: boolean,
    hasAttachments: boolean, attachments: MailAttachmentPayload[] = [], rfcMessageId: string = '') {
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
    this.attachments = attachments;
    this.rfcMessageId = rfcMessageId;
  }
}

export class ImapMessagePage {
  records: ImapMessageRecord[];
  highestUid: number;
  lowestUid: number;
  uidValidity: string;
  hasMore: boolean;
  // 单封读取/解析失败被跳过的 UID：只跳过这些邮件，不再让整批乃至整个文件夹同步失败。
  skippedUids: string[];

  constructor(records: ImapMessageRecord[] = [], highestUid: number = 0, lowestUid: number = 0,
    uidValidity: string = '', hasMore: boolean = false, skippedUids: string[] = []) {
    this.records = records;
    this.highestUid = highestUid;
    this.lowestUid = lowestUid;
    this.uidValidity = uidValidity;
    this.hasMore = hasMore;
    this.skippedUids = skippedUids;
  }
}

class FetchResponseBlock {
  protocol: string;
  header: string;
  text: string;
  textSize: number;

  constructor(protocol: string, header: string, text: string, textSize: number) {
    this.protocol = protocol;
    this.header = header;
    this.text = text;
    this.textSize = textSize;
  }
}

// 补齐正文的结果：truncated 为 true 表示服务器还有内容没取完（命中 maximumBodySize 上限），
// 此时解析出的附件不可信，必须交给解析侧按截断处理。
class BodyTextResult {
  text: string;
  truncated: boolean;

  constructor(text: string = '', truncated: boolean = false) {
    this.text = text;
    this.truncated = truncated;
  }
}

export class ImapClient {
  private readonly bodyChunkSize: number = 131072;
  private readonly maximumBodySize: number = 8 * 1024 * 1024;
  private readonly fetchTextChunkSize: number = 262144;
  private readonly fetchBatchSize: number = 20;
  private channel: ProtocolSocket = new ProtocolSocket();
  private tagSequence: number = 0;
  private bodyParser: MimeBodyParser = new MimeBodyParser();
  private headerDecoder: MimeHeaderDecoder = new MimeHeaderDecoder();
  private encoder: util.TextEncoder = new util.TextEncoder();
  private base64: util.Base64Helper = new util.Base64Helper();
  private folderListing: string = '';
  private destinationCache: Map<string, string> = new Map<string, string>();

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
    const skippedUids: string[] = [];
    const records: ImapMessageRecord[] = await this.fetchRecords(selectedUids, skippedUids);
    const highestUid: number = this.highestUid(allUids);
    const lowestUid: number = this.lowestUid(selectedUids, highestUid > 0 ? highestUid + 1 : 0);
    const hasMore: boolean = allUids.some((uid: string) => Number.parseInt(uid, 10) < lowestUid);
    return new ImapMessagePage(records, highestUid, lowestUid, uidValidity, hasMore, skippedUids);
  }

  async fetchIncremental(folder: MailFolder, lastUid: number): Promise<ImapMessagePage> {
    const uidValidity: string = await this.selectFolder(folder);
    const matchedUids: string[] = await this.searchUids(folder,
      lastUid > 0 ? `UID ${lastUid}:*` : 'ALL');
    const newUids: string[] = matchedUids.filter((uid: string) =>
      Number.parseInt(uid, 10) > lastUid).reverse();
    const skippedUids: string[] = [];
    const records: ImapMessageRecord[] = await this.fetchRecords(newUids, skippedUids);
    return new ImapMessagePage(records, Math.max(lastUid, this.highestUid(matchedUids)),
      this.lowestUid(newUids, 0), uidValidity, false, skippedUids);
  }

  async fetchOlder(folder: MailFolder, beforeUid: number, limit: number = 50): Promise<ImapMessagePage> {
    const uidValidity: string = await this.selectFolder(folder);
    const allUids: string[] = await this.searchUids(folder, 'ALL');
    const olderUids: string[] = allUids.filter((uid: string) =>
      beforeUid <= 0 || Number.parseInt(uid, 10) < beforeUid);
    const selectedUids: string[] = olderUids.slice(Math.max(0, olderUids.length - limit)).reverse();
    const skippedUids: string[] = [];
    const records: ImapMessageRecord[] = await this.fetchRecords(selectedUids, skippedUids);
    return new ImapMessagePage(records, this.highestUid(allUids), this.lowestUid(selectedUids, beforeUid),
      uidValidity, olderUids.length > selectedUids.length, skippedUids);
  }

  private async searchUids(folder: MailFolder, criteria: string): Promise<string[]> {
    const searched: string = await this.command(`UID SEARCH ${criteria}`);
    this.requireOk(searched, `无法读取${this.folderLabel(folder)}邮件列表`);
    const searchLine: RegExpMatchArray | null = searched.match(/\* SEARCH([^\r\n]*)/i);
    return searchLine ? searchLine[1].trim().split(/\s+/)
      .filter((value: string) => /^\d+$/.test(value)) : [];
  }

  private async fetchRecords(uids: string[], skippedUids: string[]): Promise<ImapMessageRecord[]> {
    const records: ImapMessageRecord[] = [];
    for (let start: number = 0; start < uids.length; start += this.fetchBatchSize) {
      await this.fetchBatch(uids.slice(start, start + this.fetchBatchSize), records, skippedUids);
    }
    return records;
  }

  // 单封失败（命令超时、服务器拒绝、正文解析不出）只跳过该 UID 并记入 skippedUids：
  // 之前这里直接 throw，会让整个文件夹同步失败、游标不动，账户再也收不到新邮件。
  private async fetchBatch(uids: string[], records: ImapMessageRecord[],
    skippedUids: string[]): Promise<void> {
    let response: string = '';
    try {
      response = await this.command(`UID FETCH ${uids.join(',')} ` +
        `(UID FLAGS INTERNALDATE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.${this.fetchTextChunkSize}>)`,
        this.fetchTimeout(uids.length));
      this.requireOk(response, `读取邮件 ${uids[0]} 失败`);
    } catch (error) {
      const reason: string = error instanceof Error ? error.message : `${error}`;
      if (uids.length > 1) {
        await this.fetchBatchIndividually(uids, records, skippedUids);
        return;
      }
      this.recordSkipped(skippedUids, uids[0], reason);
      return;
    }
    const blocks: FetchResponseBlock[] = this.splitFetchBlocks(response);
    const parsed: ImapMessageRecord[] = [];
    const fetchedUids: Set<string> = new Set<string>();
    for (let index: number = 0; index < blocks.length; index++) {
      const record: ImapMessageRecord | undefined = await this.buildRecord(blocks[index]);
      if (record) {
        parsed.push(record);
        fetchedUids.add(record.uid);
      }
      if (index % 4 === 3) {
        await this.yieldToUi();
      }
    }
    const missingUids: string[] = uids.filter((uid: string): boolean => !fetchedUids.has(uid));
    if (uids.length > 1) {
      if (missingUids.length > 0) {
        await this.fetchBatchIndividually(missingUids, records, skippedUids);
        return;
      }
      if (parsed.length < blocks.length) {
        await this.fetchBatchIndividually(uids, records, skippedUids);
        return;
      }
    }
    if (missingUids.length > 0) {
      // 单封解析不出：跳过它，其余 UID 继续处理。
      this.recordSkipped(skippedUids, missingUids[0], '邮件内容无法解析');
      return;
    }
    for (let index: number = 0; index < parsed.length; index++) {
      records.push(parsed[index]);
    }
  }

  private async fetchBatchIndividually(uids: string[], records: ImapMessageRecord[],
    skippedUids: string[]): Promise<void> {
    for (let index: number = 0; index < uids.length; index++) {
      await this.fetchBatch([uids[index]], records, skippedUids);
    }
  }

  private recordSkipped(skippedUids: string[], uid: string, reason: string): void {
    if (!skippedUids.includes(uid)) {
      skippedUids.push(uid);
      hilog.warn(DOMAIN, 'ImapClient', '跳过无法读取的邮件 UID %{public}s：%{public}s', uid, reason);
    }
  }

  private fetchTimeout(batchSize: number): number {
    return 30000 + batchSize * 2000;
  }

  // 批量解析是主线程上的纯 CPU 工作，每处理几封就让出一次，避免同步期间卡顿。
  private async yieldToUi(): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, 0);
    });
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

  private async fetchBodyText(uid: string, startOffset: number = 0): Promise<BodyTextResult> {
    let offset: number = startOffset;
    let body: string = '';
    let complete: boolean = false;
    while (offset < this.maximumBodySize) {
      const response: string = await this.command(
        `UID FETCH ${uid} (BODY.PEEK[TEXT]<${offset}.${this.bodyChunkSize}>)`, 30000);
      this.requireOk(response, `读取邮件 ${uid} 正文失败`);
      const literalSize: number = this.textLiteralSize(response);
      if (literalSize <= 0) {
        // 服务器没再返回内容，说明正文已经取完。
        complete = true;
        break;
      }
      body += this.extractTextChunk(response);
      offset += literalSize;
      if (literalSize < this.bodyChunkSize) {
        complete = true;
        break;
      }
    }
    return new BodyTextResult(body, !complete);
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

  isRemoteMessage(messageId: string): boolean {
    return this.remoteUid(messageId).length > 0;
  }

  private remoteUid(messageId: string): string {
    const matched: RegExpMatchArray | null = messageId.match(/^imap_.+_(\d+)$/);
    return matched ? matched[1] : '';
  }

  private uidFromMessageId(messageId: string): string {
    const uid: string = this.remoteUid(messageId);
    if (uid.length === 0) {
      throw new Error('本地邮件没有可同步的服务器 UID');
    }
    return uid;
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
    const cached: string | undefined = this.destinationCache.get(folder);
    if (cached !== undefined) {
      return cached;
    }
    if (this.folderListing.length === 0) {
      const listed: string = await this.command('LIST "" "*"');
      this.requireOk(listed, '无法读取服务器文件夹');
      this.folderListing = listed;
    }
    const destination: string = this.matchDestination(this.folderListing, folder);
    this.destinationCache.set(folder, destination);
    return destination;
  }

  private matchDestination(listed: string, folder: string): string {
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

  private async buildRecord(block: FetchResponseBlock): Promise<ImapMessageRecord | undefined> {
    const uidMatch: RegExpMatchArray | null = block.protocol.match(/UID\s+(\d+)/i);
    if (!uidMatch || block.header.length === 0) {
      return undefined;
    }
    const uid: string = uidMatch[1];
    const flagsMatch: RegExpMatchArray | null = block.protocol.match(/FLAGS\s+\(([^)]*)\)/i);
    const flags: string = flagsMatch ? flagsMatch[1].toUpperCase() : '';
    let rawBody: string = block.text;
    // 首块 256KB 被填满时说明正文更长：继续抓取，并把是否命中上限如实传给解析侧。
    let truncated: boolean = false;
    if (block.textSize >= this.fetchTextChunkSize) {
      const rest: BodyTextResult = await this.fetchBodyText(uid, this.fetchTextChunkSize);
      rawBody += rest.text;
      truncated = rest.truncated;
    }
    const headerBlock: string = block.header;
    const from: MailAddress = this.parseAddress(this.headerValue(headerBlock, 'From'));
    const to: MailAddress[] = this.parseAddressList(this.headerValue(headerBlock, 'To'));
    const subject: string = this.decodeMimeWords(this.headerValue(headerBlock, 'Subject'));
    const dateValue: string = this.headerValue(headerBlock, 'Date');
    const headerDate: number = this.parseMailDate(dateValue);
    const internalDate: number = this.parseInternalDate(block.protocol);
    let receivedAt: number = Number.isNaN(headerDate) ? internalDate : headerDate;
    if (Number.isNaN(receivedAt)) {
      receivedAt = Date.now();
    }
    const bodyContent: MimeBodyContent = this.bodyParser.parse(headerBlock, rawBody, truncated);
    if (bodyContent.truncated) {
      hilog.warn(DOMAIN, 'ImapClient', '邮件 UID %{public}s 正文超过抓取上限，附件按未完整下载处理', uid);
    }
    return new ImapMessageRecord(uid, from, to, subject, bodyContent.plainText, bodyContent.htmlText, receivedAt,
      flags.includes('\\SEEN'), flags.includes('\\FLAGGED'),
      bodyContent.hasAttachments || bodyContent.attachments.length > 0, bodyContent.attachments,
      normalizeMessageId(this.headerValue(headerBlock, 'Message-ID')));
  }

  private splitFetchBlocks(response: string): FetchResponseBlock[] {
    const starts: number[] = this.fetchBlockStarts(response);
    const blocks: FetchResponseBlock[] = [];
    for (let index: number = 0; index < starts.length; index++) {
      const bound: number = index + 1 < starts.length ? starts[index + 1] : response.length;
      const terminator: number = response.lastIndexOf('\r\n)', bound - 1);
      const block: FetchResponseBlock = this.readFetchBlock(response, starts[index], bound,
        terminator > starts[index] ? terminator : -1);
      blocks.push(block);
    }
    return blocks;
  }

  private fetchBlockStarts(response: string): number[] {
    const candidates: number[] = [];
    let cursor: number = 0;
    while (cursor < response.length) {
      const found: number = response.indexOf('* ', cursor);
      if (found < 0) {
        break;
      }
      if (this.isFetchStart(response, found)) {
        const previous: number = candidates.length > 0 ? candidates[candidates.length - 1] : -1;
        if (previous < 0 || response.lastIndexOf('\r\n)', found - 1) > previous) {
          candidates.push(found);
        }
      }
      cursor = found + 2;
    }
    const starts: number[] = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const bound: number = index + 1 < candidates.length ? candidates[index + 1] : response.length;
      const headerMarker: number = response.indexOf('[HEADER]', candidates[index]);
      if (index === 0 || (headerMarker >= 0 && headerMarker < bound)) {
        starts.push(candidates[index]);
      }
    }
    return starts;
  }

  private isFetchStart(response: string, index: number): boolean {
    if (index > 0 && response.substring(index - 2, index) !== '\r\n') {
      return false;
    }
    return /^\* \d+ FETCH \(/.test(response.substring(index, index + 24));
  }

  private readFetchBlock(response: string, start: number, bound: number, textEnd: number): FetchResponseBlock {
    let protocol: string = '';
    let protocolCursor: number = start;
    let header: string = '';
    let text: string = '';
    let textSize: number = 0;
    let cursor: number = start;
    while (cursor < bound) {
      const marker: number = this.nextLiteralMarker(response, cursor, bound);
      if (marker < 0) {
        protocol += response.substring(protocolCursor, bound);
        break;
      }
      const matched: RegExpMatchArray | null = response.substring(marker, marker + 16).match(/^\{(\d+)\}\r\n/);
      if (!matched) {
        break;
      }
      const size: number = Number.parseInt(matched[1], 10);
      const contentStart: number = marker + matched[0].length;
      const segment: string = response.substring(protocolCursor, marker);
      const upperSegment: string = segment.toUpperCase();
      protocol += segment;
      if (upperSegment.includes('[HEADER]')) {
        const nextMarker: number = this.nextLiteralMarker(response, contentStart, bound);
        const contentEnd: number = this.headerLiteralEnd(response, contentStart, size,
          nextMarker < 0 ? bound : nextMarker);
        header = response.substring(contentStart, contentEnd);
        protocolCursor = contentEnd;
        cursor = contentEnd;
      } else if (upperSegment.includes('[TEXT]')) {
        const contentEnd: number = textEnd >= 0 ? textEnd : this.literalEnd(response, contentStart, size, bound);
        text = response.substring(contentStart, contentEnd);
        textSize = size;
        cursor = bound;
      } else {
        const skipped: number = this.literalEnd(response, contentStart, size, bound);
        protocolCursor = skipped;
        cursor = skipped;
      }
    }
    return new FetchResponseBlock(protocol, header, text, textSize);
  }

  private nextLiteralMarker(response: string, from: number, limit: number): number {
    let cursor: number = from;
    while (cursor < limit) {
      const found: number = response.indexOf('{', cursor);
      if (found < 0 || found >= limit) {
        return -1;
      }
      if (/^\{\d+\}\r\n/.test(response.substring(found, found + 16))) {
        return found;
      }
      cursor = found + 1;
    }
    return -1;
  }

  private headerLiteralEnd(response: string, contentStart: number, size: number, bound: number): number {
    const separator: number = response.indexOf('\r\n\r\n', contentStart);
    if (separator >= 0 && separator + 4 <= bound) {
      return separator + 4;
    }
    return this.literalEnd(response, contentStart, size, bound);
  }

  private literalEnd(response: string, start: number, byteLength: number, limit: number): number {
    let consumed: number = 0;
    let index: number = start;
    while (index < limit && consumed < byteLength) {
      const code: number = response.charCodeAt(index);
      let width: number = 1;
      let widthInChars: number = 1;
      if (code < 0x80 || code === 0xFFFD) {
        width = 1;
      } else if (code < 0x800) {
        width = 2;
      } else if (code >= 0xD800 && code <= 0xDBFF) {
        width = 4;
        widthInChars = 2;
      } else {
        width = 3;
      }
      if (consumed + width > byteLength) {
        break;
      }
      consumed += width;
      index += widthInChars;
    }
    return index;
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
