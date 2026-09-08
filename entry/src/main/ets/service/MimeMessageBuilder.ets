import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { DraftMessage, EmailAccount, MailAttachment } from '../model/MailModels';

export class MimeMessageBuilder {
  private encoder: util.TextEncoder = new util.TextEncoder();
  private base64: util.Base64Helper = new util.Base64Helper();

  build(account: EmailAccount, draft: DraftMessage): string {
    const boundary: string = `mail_helper_${Date.now()}`;
    const alternativeBoundary: string = `${boundary}_alternative`;
    const recipients: string[] = this.addresses(draft.to);
    const ccRecipients: string[] = this.addresses(draft.cc);
    const headers: string[] = [
      `From: ${this.formatFrom(account)}`,
      `To: ${recipients.join(', ')}`,
      `Subject: ${this.encodeHeader(this.headerSafe(draft.subject.length > 0 ? draft.subject : '无主题'))}`,
      `Date: ${new Date().toUTCString()}`,
      `Message-ID: <${Date.now()}.${account.id}@mail-helper.local>`,
      'MIME-Version: 1.0'
    ];
    if (ccRecipients.length > 0) {
      headers.push(`Cc: ${ccRecipients.join(', ')}`);
    }
    if (draft.requestReadReceipt) {
      headers.push(`Disposition-Notification-To: ${account.email}`);
    }
    if (draft.attachments.length === 0) {
      headers.push(`Content-Type: multipart/alternative; boundary="${alternativeBoundary}"`);
      return `${headers.join('\r\n')}\r\n\r\n${this.alternativeParts(alternativeBoundary, draft.body)}`;
    }
    headers.push(`Content-Type: multipart/mixed; boundary="${boundary}"`);
    const parts: string[] = [];
    parts.push(`--${boundary}\r\nContent-Type: multipart/alternative; ` +
      `boundary="${alternativeBoundary}"\r\n\r\n${this.alternativeParts(alternativeBoundary, draft.body)}`);
    for (let index: number = 0; index < draft.attachments.length; index++) {
      parts.push(this.attachmentPart(boundary, draft.attachments[index]));
    }
    parts.push(`--${boundary}--\r\n`);
    return `${headers.join('\r\n')}\r\n\r\n${parts.join('')}`;
  }

  private alternativeParts(boundary: string, body: string): string {
    const plain: string = this.foldBase64(this.encodeBase64(body));
    const html: string = this.foldBase64(this.encodeBase64(this.htmlBody(body)));
    return `--${boundary}\r\nContent-Type: text/plain; charset=UTF-8\r\n` +
      `Content-Transfer-Encoding: base64\r\n\r\n${plain}\r\n` +
      `--${boundary}\r\nContent-Type: text/html; charset=UTF-8\r\n` +
      `Content-Transfer-Encoding: base64\r\n\r\n${html}\r\n--${boundary}--\r\n`;
  }

  private htmlBody(value: string): string {
    const escaped: string = value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const lines: string[] = escaped.split(/\r?\n/);
    const htmlLines: string[] = [];
    let listOpen: boolean = false;
    for (let index: number = 0; index < lines.length; index++) {
      let line: string = lines[index].replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
        .replace(/_([^_]+)_/g, '<em>$1</em>');
      if (line.startsWith('- ')) {
        if (!listOpen) {
          htmlLines.push('<ul>');
          listOpen = true;
        }
        htmlLines.push(`<li>${line.substring(2)}</li>`);
      } else {
        if (listOpen) {
          htmlLines.push('</ul>');
          listOpen = false;
        }
        if (line.startsWith('&gt; ')) {
          htmlLines.push(`<blockquote>${line.substring(5)}</blockquote>`);
        } else if (line.length === 0) {
          htmlLines.push('<br>');
        } else {
          htmlLines.push(`<p>${line}</p>`);
        }
      }
    }
    if (listOpen) htmlLines.push('</ul>');
    return `<!doctype html><html><body>${htmlLines.join('')}</body></html>`;
  }

  private addresses(value: string): string[] {
    return value.split(/[;,]/).map((item: string) => this.headerSafe(item.trim()))
      .filter((item: string) => item.length > 0);
  }

  private formatFrom(account: EmailAccount): string {
    const email: string = this.headerSafe(account.email);
    const name: string = this.headerSafe(account.displayName);
    return name.length > 0 ? `${this.encodeHeader(name)} <${email}>` : email;
  }

  private headerSafe(value: string): string {
    return value.replace(/[\r\n]+/g, ' ').trim();
  }

  private encodeHeader(value: string): string {
    if (/^[\x20-\x7E]*$/.test(value)) {
      return value;
    }
    return `=?UTF-8?B?${this.encodeBase64(value)}?=`;
  }

  private encodeBase64(value: string): string {
    return this.base64.encodeToStringSync(this.encoder.encodeInto(value));
  }

  private foldBase64(value: string): string {
    const lines: string[] = [];
    for (let index: number = 0; index < value.length; index += 76) {
      lines.push(value.substring(index, Math.min(index + 76, value.length)));
    }
    return lines.join('\r\n');
  }

  private attachmentPart(boundary: string, attachment: MailAttachment): string {
    const file: fileIo.File = fileIo.openSync(attachment.uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      if (stat.size > 20 * 1024 * 1024) {
        throw new Error(`附件 ${attachment.name} 超过 20 MB`);
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const readSize: number = fileIo.readSync(file.fd, buffer);
      const bytes: Uint8Array = new Uint8Array(buffer, 0, readSize);
      const encoded: string = this.foldBase64(this.base64.encodeToStringSync(bytes));
      const mimeType: string = attachment.mimeType.length > 0 ? attachment.mimeType : 'application/octet-stream';
      const fileName: string = this.encodeHeader(attachment.name);
      return `--${boundary}\r\nContent-Type: ${mimeType}; name="${fileName}"\r\n` +
        `Content-Disposition: attachment; filename="${fileName}"\r\n` +
        `Content-Transfer-Encoding: base64\r\n\r\n${encoded}\r\n`;
    } finally {
      fileIo.closeSync(file);
    }
  }
}
