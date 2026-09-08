import { util } from '@kit.ArkTS';

class MimeTextResult {
  plainText: string;
  htmlText: string;
  hasAttachments: boolean;

  constructor(plainText: string = '', htmlText: string = '', hasAttachments: boolean = false) {
    this.plainText = plainText;
    this.htmlText = htmlText;
    this.hasAttachments = hasAttachments;
  }
}

export class MimeBodyContent {
  plainText: string;
  htmlText: string;
  hasAttachments: boolean;

  constructor(plainText: string = '', htmlText: string = '', hasAttachments: boolean = false) {
    this.plainText = plainText;
    this.htmlText = htmlText;
    this.hasAttachments = hasAttachments;
  }
}

export class MimeBodyParser {
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();

  parse(headers: string, body: string): MimeBodyContent {
    const result: MimeTextResult = this.parseEntity(headers, body, 0);
    if (result.plainText.length > 0 || result.htmlText.length > 0) {
      return new MimeBodyContent(result.plainText, result.htmlText, result.hasAttachments);
    }
    if (this.looksLikeHtml(body)) {
      return new MimeBodyContent(this.cleanHtml(body), this.sanitizeHtml(body), result.hasAttachments);
    }
    return new MimeBodyContent(this.cleanPlain(body), '', result.hasAttachments);
  }

  private parseEntity(headers: string, body: string, depth: number): MimeTextResult {
    if (depth > 8) {
      return new MimeTextResult();
    }
    const contentTypeValue: string = this.headerValue(headers, 'Content-Type');
    const contentType: string = contentTypeValue.toLowerCase();
    const disposition: string = this.headerValue(headers, 'Content-Disposition').toLowerCase();
    if (this.isAttachment(contentTypeValue, disposition)) {
      return new MimeTextResult('', '', true);
    }
    if (contentType.startsWith('multipart/')) {
      const boundary: string = this.boundary(contentTypeValue);
      if (boundary.length === 0) {
        return new MimeTextResult();
      }
      return this.parseMultipart(body, boundary, depth + 1);
    }
    if (contentType.startsWith('message/rfc822')) {
      const decodedMessage: string = this.decodeContent(body, headers);
      const separator: number = this.headerSeparator(decodedMessage);
      if (separator >= 0) {
        const skip: number = decodedMessage.substring(separator, separator + 4) === '\r\n\r\n' ? 4 : 2;
        return this.parseEntity(decodedMessage.substring(0, separator), decodedMessage.substring(separator + skip),
          depth + 1);
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

  private parseMultipart(body: string, boundary: string, depth: number): MimeTextResult {
    const rawParts: string[] = body.split(`--${boundary}`);
    let plainText: string = '';
    let htmlText: string = '';
    let hasAttachments: boolean = false;
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
        part.substring(separator + skip), depth);
      if (plainText.length === 0 && candidate.plainText.length > 0) plainText = candidate.plainText;
      if (htmlText.length === 0 && candidate.htmlText.length > 0) htmlText = candidate.htmlText;
      if (candidate.hasAttachments) hasAttachments = true;
    }
    return new MimeTextResult(plainText, htmlText, hasAttachments);
  }

  private isAttachment(contentType: string, disposition: string): boolean {
    if (disposition.includes('attachment')) {
      return true;
    }
    if (disposition.includes('inline')) {
      return false;
    }
    return /(?:filename|name)\s*=\s*(?:"[^"]+"|[^;\s]+)/i.test(`${disposition};${contentType}`) &&
      !contentType.toLowerCase().startsWith('text/');
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
