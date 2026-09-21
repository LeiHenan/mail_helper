import { util } from '@kit.ArkTS';
import { MailAttachmentPayload } from '../model/MailModels';
import { MimeHeaderDecoder } from './MimeHeaderDecoder';

const MAX_ATTACHMENT_BYTES: number = 15 * 1024 * 1024;
const MAX_ATTACHMENT_TOTAL_BYTES: number = 30 * 1024 * 1024;

class MimeTextResult {
  plainText: string;
  htmlText: string;
  hasAttachments: boolean;
  attachments: MailAttachmentPayload[];

  constructor(plainText: string = '', htmlText: string = '', hasAttachments: boolean = false,
    attachments: MailAttachmentPayload[] = []) {
    this.plainText = plainText;
    this.htmlText = htmlText;
    this.hasAttachments = hasAttachments;
    this.attachments = attachments;
  }
}

class AttachmentBudget {
  count: number = 0;
  bytes: number = 0;
}

// 附件载荷完整性判定：expected 为期望的解码字节数（-1 表示无从推算，如 7bit 正文），
// incomplete 表示载荷本身就已残缺（base64 不完整分组、quoted-printable 结尾断裂）。
class AttachmentLengthCheck {
  expected: number;
  incomplete: boolean;

  constructor(expected: number = -1, incomplete: boolean = false) {
    this.expected = expected;
    this.incomplete = incomplete;
  }
}

export class MimeBodyContent {
  plainText: string;
  htmlText: string;
  hasAttachments: boolean;
  attachments: MailAttachmentPayload[];
  // 正文抓取命中 IMAP 上限时为 true：此时解析出的附件一律只保留元数据。
  truncated: boolean;

  constructor(plainText: string = '', htmlText: string = '', hasAttachments: boolean = false,
    attachments: MailAttachmentPayload[] = [], truncated: boolean = false) {
    this.plainText = plainText;
    this.htmlText = htmlText;
    this.hasAttachments = hasAttachments;
    this.attachments = attachments;
    this.truncated = truncated;
  }
}

export class MimeBodyParser {
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();
  private headerDecoder: MimeHeaderDecoder = new MimeHeaderDecoder();

  // truncated：IMAP 正文抓取命中上限时由 ImapClient 传入。此时解析出的附件必然不完整，
  // 一律清空内容只留元数据，交给上层按“未完整下载”呈现。
  parse(headers: string, body: string, truncated: boolean = false): MimeBodyContent {
    const result: MimeTextResult = this.parseEntity(headers, body, 0, new AttachmentBudget());
    const attachments: MailAttachmentPayload[] =
      truncated ? this.metadataOnly(result.attachments) : result.attachments;
    if (result.plainText.length > 0 || result.htmlText.length > 0) {
      return new MimeBodyContent(result.plainText, result.htmlText, result.hasAttachments,
        attachments, truncated);
    }
    if (this.looksLikeHtml(body)) {
      return new MimeBodyContent(this.cleanHtml(body), this.sanitizeHtml(body), result.hasAttachments,
        attachments, truncated);
    }
    return new MimeBodyContent(this.cleanPlain(body), '', result.hasAttachments, attachments, truncated);
  }

  private metadataOnly(attachments: MailAttachmentPayload[]): MailAttachmentPayload[] {
    const stripped: MailAttachmentPayload[] = [];
    for (let index: number = 0; index < attachments.length; index++) {
      const attachment: MailAttachmentPayload = attachments[index];
      stripped.push(new MailAttachmentPayload(attachment.name, attachment.mimeType, attachment.size,
        attachment.inline, new Uint8Array(0)));
    }
    return stripped;
  }

  private parseEntity(headers: string, body: string, depth: number,
    budget: AttachmentBudget): MimeTextResult {
    if (depth > 8) {
      return new MimeTextResult();
    }
    const contentTypeValue: string = this.headerValue(headers, 'Content-Type');
    const contentType: string = contentTypeValue.toLowerCase();
    const disposition: string = this.headerValue(headers, 'Content-Disposition');
    if (this.isAttachment(contentType, disposition)) {
      return new MimeTextResult('', '', true, [this.readAttachment(contentTypeValue, disposition, body, headers,
        budget)]);
    }
    if (contentType.startsWith('multipart/')) {
      const boundary: string = this.boundary(contentTypeValue);
      if (boundary.length === 0) {
        return new MimeTextResult();
      }
      return this.parseMultipart(body, boundary, depth + 1, budget);
    }
    if (contentType.startsWith('message/rfc822')) {
      const decodedMessage: string = this.decodeContent(body, headers);
      const separator: number = this.headerSeparator(decodedMessage);
      if (separator >= 0) {
        const skip: number = decodedMessage.substring(separator, separator + 4) === '\r\n\r\n' ? 4 : 2;
        return this.parseEntity(decodedMessage.substring(0, separator), decodedMessage.substring(separator + skip),
          depth + 1, budget);
      }
      return new MimeTextResult();
    }
    if (contentType.startsWith('text/plain') || contentType.length === 0) {
      const decodedPlain: string = this.decodeContent(body, headers);
      if (this.looksLikeHtml(decodedPlain)) {
        return new MimeTextResult(this.cleanHtml(decodedPlain), this.sanitizeHtml(decodedPlain));
      }
      return new MimeTextResult(this.cleanPlain(decodedPlain));
    }
    if (contentType.startsWith('text/html')) {
      const decodedHtml: string = this.decodeContent(body, headers);
      return new MimeTextResult(this.cleanHtml(decodedHtml), this.sanitizeHtml(decodedHtml));
    }
    return new MimeTextResult();
  }

  private parseMultipart(body: string, boundary: string, depth: number,
    budget: AttachmentBudget): MimeTextResult {
    const rawParts: string[] = body.split(`--${boundary}`);
    let plainText: string = '';
    let htmlText: string = '';
    let hasAttachments: boolean = false;
    let attachments: MailAttachmentPayload[] = [];
    for (let index: number = 1; index < rawParts.length; index++) {
      let part: string = rawParts[index];
      if (part.startsWith('--')) {
        break;
      }
      part = part.replace(/^\r?\n/, '').replace(/\r?\n$/, '');
      const separator: number = this.headerSeparator(part);
      if (separator < 0) {
        continue;
      }
      const skip: number = part.substring(separator, separator + 4) === '\r\n\r\n' ? 4 : 2;
      const candidate: MimeTextResult = this.parseEntity(part.substring(0, separator),
        part.substring(separator + skip), depth, budget);
      if (plainText.length === 0 && candidate.plainText.length > 0) plainText = candidate.plainText;
      if (htmlText.length === 0 && candidate.htmlText.length > 0) htmlText = candidate.htmlText;
      if (candidate.hasAttachments) hasAttachments = true;
      if (candidate.attachments.length > 0) attachments = attachments.concat(candidate.attachments);
    }
    return new MimeTextResult(plainText, htmlText, hasAttachments, attachments);
  }

  private isAttachment(contentType: string, disposition: string): boolean {
    if (disposition.toLowerCase().includes('attachment')) {
      return true;
    }
    if (contentType.startsWith('multipart/')) {
      return false;
    }
    return !contentType.startsWith('text/') &&
      /(?:filename|name)\s*=\s*(?:"[^"]+"|[^;\s]+)/i.test(`${disposition};${contentType}`);
  }

  private readAttachment(contentTypeValue: string, disposition: string, body: string, headers: string,
    budget: AttachmentBudget): MailAttachmentPayload {
    budget.count++;
    const name: string = this.attachmentName(contentTypeValue, disposition, budget.count);
    const mimeType: string = this.attachmentMimeType(contentTypeValue);
    const inline: boolean = !disposition.toLowerCase().includes('attachment');
    const check: AttachmentLengthCheck = this.attachmentLengthCheck(contentTypeValue, disposition, body, headers);
    let content: Uint8Array = new Uint8Array(0);
    try {
      content = this.transferDecodedBytes(body, headers);
    } catch (_error) {
      content = new Uint8Array(0);
    }
    const size: number = content.length;
    if (size > MAX_ATTACHMENT_BYTES || budget.bytes + size > MAX_ATTACHMENT_TOTAL_BYTES) {
      return new MailAttachmentPayload(name, mimeType, size, inline, new Uint8Array(0));
    }
    // 解码后字节数与声明长度对不上（正文被 IMAP 抓取上限截断的典型症状）：只保留元数据、清空内容，
    // 让上层标记“未完整下载”。绝不能把半截内容当完整附件落盘。
    if (check.incomplete || (check.expected >= 0 && size !== check.expected)) {
      const reported: number = check.expected > size ? check.expected : size;
      return new MailAttachmentPayload(name, mimeType, reported, inline, new Uint8Array(0));
    }
    budget.bytes += size;
    return new MailAttachmentPayload(name, mimeType, size, inline, content);
  }

  // 完整性判定：优先用 Content-Type/Content-Disposition 里声明的 size=，
  // 没有时用 base64 载荷长度反推（长度不是 4 的倍数即为残缺载荷）。
  private attachmentLengthCheck(contentTypeValue: string, disposition: string, body: string,
    headers: string): AttachmentLengthCheck {
    const declared: number = this.declaredSize(`${disposition};${contentTypeValue}`);
    const transferEncoding: string = this.headerValue(headers, 'Content-Transfer-Encoding').toLowerCase();
    if (transferEncoding.includes('base64')) {
      const payload: string = body.replace(/\s+/g, '');
      if (payload.length === 0) {
        return new AttachmentLengthCheck(declared);
      }
      const remainder: number = payload.length % 4;
      // 长度 ≡ 1 (mod 4) 的 base64 不可能是任何完整载荷的前缀，必然是截断的。
      if (remainder === 1) {
        return new AttachmentLengthCheck(declared, true);
      }
      let padding: number = 0;
      while (padding < payload.length && payload[payload.length - 1 - padding] === '=') {
        padding++;
      }
      const groups: number = Math.floor(payload.length / 4);
      const derived: number = remainder === 0 ? groups * 3 - padding :
        (remainder === 2 ? groups * 3 + 1 : groups * 3 + 2);
      return new AttachmentLengthCheck(declared >= 0 ? declared : derived, false);
    }
    return new AttachmentLengthCheck(declared, false);
  }

  private declaredSize(source: string): number {
    // 去掉引号内的内容，避免文件名里恰好出现 "size=" 被误当成声明大小。
    const bare: string = source.replace(/"[^"]*"/g, '""');
    const matched: RegExpMatchArray | null = bare.match(/(?:^|;)\s*size\s*=\s*(\d+)/i);
    if (!matched) {
      return -1;
    }
    const value: number = Number.parseInt(matched[1], 10);
    return Number.isNaN(value) || value <= 0 ? -1 : value;
  }

  private transferDecodedBytes(body: string, headers: string): Uint8Array {
    const transferEncoding: string = this.headerValue(headers, 'Content-Transfer-Encoding').toLowerCase();
    if (transferEncoding.includes('base64')) {
      return this.base64.decodeSync(body.replace(/\s+/g, ''));
    }
    if (transferEncoding.includes('quoted-printable')) {
      return this.quotedPrintableBytes(body);
    }
    return this.encoder.encodeInto(body);
  }

  private attachmentMimeType(contentTypeValue: string): string {
    const value: string = contentTypeValue.split(';')[0].trim().toLowerCase();
    return value.length > 0 ? value : 'application/octet-stream';
  }

  private attachmentName(contentTypeValue: string, disposition: string, index: number): string {
    const extended: string = this.parameterValue(disposition, 'filename*') ||
      this.parameterValue(contentTypeValue, 'name*');
    let decoded: string = extended.length > 0 ? this.decodeExtendedParameter(extended) : '';
    if (decoded.length === 0) {
      decoded = this.headerDecoder.decode(this.parameterValue(disposition, 'filename') ||
        this.parameterValue(contentTypeValue, 'name'));
    }
    const trimmed: string = decoded.trim();
    return trimmed.length > 0 ? trimmed : `attachment-${index}`;
  }

  private parameterValue(source: string, name: string): string {
    const escaped: string = name.replace(/\*/g, '\\*');
    const expression: RegExp = new RegExp(`(?:^|;)\\s*${escaped}\\s*=\\s*(?:"([^"]*)"|([^;]*))`, 'i');
    const matched: RegExpMatchArray | null = source.match(expression);
    return matched ? (matched[1] ?? matched[2] ?? '').trim() : '';
  }

  private decodeExtendedParameter(value: string): string {
    const pieces: string[] = value.split("'");
    if (pieces.length < 3) {
      return '';
    }
    const charset: string = pieces[0].length > 0 ? pieces[0] : 'utf-8';
    const encoded: string = pieces.slice(2).join("'");
    const bytes: number[] = [];
    for (let index: number = 0; index < encoded.length; index++) {
      const hexadecimal: string = encoded.substring(index + 1, index + 3);
      if (encoded[index] === '%' && /^[0-9A-Fa-f]{2}$/.test(hexadecimal)) {
        bytes.push(Number.parseInt(hexadecimal, 16));
        index += 2;
        continue;
      }
      const character: Uint8Array = this.encoder.encodeInto(encoded[index]);
      for (let byteIndex: number = 0; byteIndex < character.length; byteIndex++) {
        bytes.push(character[byteIndex]);
      }
    }
    return this.decodeBytes(new Uint8Array(bytes), charset);
  }

  private headerSeparator(value: string): number {
    const windows: number = value.indexOf('\r\n\r\n');
    return windows >= 0 ? windows : value.indexOf('\n\n');
  }

  private headerValue(headers: string, name: string): string {
    const unfolded: string = headers.replace(/\r?\n[ \t]+/g, ' ');
    const expression: RegExp = new RegExp(`(?:^|\\r?\\n)${name}:\\s*([^\\r\\n]*)`, 'i');
    const matched: RegExpMatchArray | null = unfolded.match(expression);
    return matched ? matched[1].trim() : '';
  }

  private boundary(contentType: string): string {
    const matched: RegExpMatchArray | null = contentType.match(/boundary\s*=\s*(?:"([^"]+)"|([^;\s]+))/i);
    return matched ? (matched[1] ?? matched[2] ?? '').trim() : '';
  }

  private decodeContent(body: string, headers: string): string {
    const transferEncoding: string = this.headerValue(headers, 'Content-Transfer-Encoding').toLowerCase();
    const charset: string = this.charset(this.headerValue(headers, 'Content-Type'));
    if (transferEncoding.includes('base64')) {
      try {
        const encoded: string = body.replace(/\s+/g, '');
        return this.decodeBytes(this.base64.decodeSync(encoded), charset);
      } catch (_error) {
        return body;
      }
    }
    if (transferEncoding.includes('quoted-printable')) {
      return this.decodeBytes(this.quotedPrintableBytes(body), charset);
    }
    return body;
  }

  private charset(contentType: string): string {
    const matched: RegExpMatchArray | null = contentType.match(/charset\s*=\s*(?:"([^"]+)"|([^;\s]+))/i);
    return matched ? (matched[1] ?? matched[2] ?? 'utf-8').trim().toLowerCase() : 'utf-8';
  }

  private decodeBytes(bytes: Uint8Array, charset: string): string {
    const normalized: string = charset === 'utf8' ? 'utf-8' : charset;
    try {
      return new util.TextDecoder(normalized).decode(bytes);
    } catch (_error) {
      return new util.TextDecoder('utf-8').decode(bytes);
    }
  }

  private quotedPrintableBytes(value: string): Uint8Array {
    const bytes: number[] = [];
    for (let index: number = 0; index < value.length;) {
      if (value[index] === '=' && value.substring(index, index + 3) === '=\r\n') {
        index += 3;
        continue;
      }
      if (value[index] === '=' && value.substring(index, index + 2) === '=\n') {
        index += 2;
        continue;
      }
      const hex: string = value.substring(index + 1, index + 3);
      if (value[index] === '=' && /^[0-9A-Fa-f]{2}$/.test(hex)) {
        bytes.push(Number.parseInt(hex, 16));
        index += 3;
        continue;
      }
      const encoded: Uint8Array = this.encoder.encodeInto(value[index]);
      for (let byteIndex: number = 0; byteIndex < encoded.length; byteIndex++) {
        bytes.push(encoded[byteIndex]);
      }
      index++;
    }
    return new Uint8Array(bytes);
  }

  private looksLikeHtml(value: string): boolean {
    return /<(?:!doctype|html|head|body|style|div|table|p|br)\b/i.test(value);
  }

  private cleanPlain(value: string): string {
    return this.decodeHtmlEntities(value.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\0/g, ''))
      .split('\n').map((line: string) => line.replace(/[ \t]+$/g, ''))
      .join('\n').replace(/\n{4,}/g, '\n\n\n').trim().substring(0, 500000);
  }

  private cleanHtml(value: string): string {
    let body: string = value
      .replace(/<style\b[\s\S]*?(?:<\/style>|$)/gi, ' ')
      .replace(/<script\b[\s\S]*?(?:<\/script>|$)/gi, ' ')
      .replace(/<head\b[\s\S]*?(?:<\/head>|$)/gi, ' ')
      .replace(/<!--?[\s\S]*?-->/g, ' ')
      .replace(/<(?:br|hr)\s*\/?>/gi, '\n')
      .replace(/<\/(?:p|div|section|article|header|footer|tr|h[1-6]|blockquote)>/gi, '\n')
      .replace(/<li\b[^>]*>/gi, '\n• ')
      .replace(/<\/li>/gi, '')
      .replace(/<[^>]+>/g, ' ');
    body = this.decodeHtmlEntities(body).replace(/\r/g, '')
      .replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n');
    return body.trim().substring(0, 500000);
  }

  private sanitizeHtml(value: string): string {
    return value
      .replace(/<script\b[\s\S]*?(?:<\/script>|$)/gi, '')
      .replace(/<(?:iframe|object|embed|form)\b[\s\S]*?(?:<\/(?:iframe|object|embed|form)>|$)/gi, '')
      .replace(/<meta\b[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*>/gi, '')
      .replace(/\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, '')
      .replace(/(?:href|src)\s*=\s*(["'])\s*javascript:[\s\S]*?\1/gi, 'href="#"')
      .substring(0, 2000000);
  }

  private decodeHtmlEntities(value: string): string {
    return value.replace(/&nbsp;/gi, ' ').replace(/&lt;/gi, '<').replace(/&gt;/gi, '>')
      .replace(/&amp;/gi, '&').replace(/&quot;/gi, '"').replace(/&apos;/gi, "'")
      .replace(/&#(\d+);/g, (_whole: string, decimal: string): string =>
        String.fromCharCode(Number.parseInt(decimal)))
      .replace(/&#x([0-9a-f]+);/gi, (_whole: string, hexadecimal: string): string =>
        String.fromCharCode(Number.parseInt(hexadecimal, 16)));
  }
}
