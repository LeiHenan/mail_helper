import { util } from '@kit.ArkTS';
import { DraftMessage, EmailAccount } from '../model/MailModels';
import { AuthenticationMethod, ConnectionSecurity, MailServerSettings } from '../model/MailServerModels';
import { MimeMessageBuilder } from './MimeMessageBuilder';
import { ProtocolSocket } from './ProtocolSocket';

export class SmtpClient {
  private channel: ProtocolSocket = new ProtocolSocket();
  private encoder: util.TextEncoder = new util.TextEncoder();
  private base64: util.Base64Helper = new util.Base64Helper();
  private mimeBuilder: MimeMessageBuilder = new MimeMessageBuilder();

  async send(settings: MailServerSettings, account: EmailAccount, credential: string,
    draft: DraftMessage): Promise<void> {
    if (settings.security === ConnectionSecurity.NONE) {
      throw new Error('为保护授权凭据，不支持未加密的 SMTP 登录');
    }
    // 先把整封 MIME 构建完（这一步会读附件文件、可能抛错）。构建必须发生在建立连接之前：
    // 否则失败会把会话停在 DATA 状态，之后的 QUIT 会被服务器当成邮件内容。
    const mime: string = this.mimeBuilder.build(account, draft);
    const dotStuffed: string = mime.replace(/\r\n\./g, '\r\n..');
    if (settings.security === ConnectionSecurity.TLS) {
      await this.channel.connect(settings.host, settings.port);
    } else {
      await this.channel.connectPlain(settings.host, settings.port);
    }
    this.requireCode(await this.channel.waitFor((value: string) => this.hasCode(value, 220)), 220,
      'SMTP 服务器没有接受连接');
    this.requireCode(await this.command('EHLO mail-helper', 250), 250, 'SMTP 服务器拒绝 EHLO');
    if (settings.security === ConnectionSecurity.STARTTLS) {
      this.requireCode(await this.command('STARTTLS', 220), 220, 'SMTP 服务器拒绝 STARTTLS');
      await this.channel.upgradeToTls(settings.host, settings.port);
      this.requireCode(await this.command('EHLO mail-helper', 250), 250, 'STARTTLS 后 EHLO 失败');
    }
    const username: string = settings.username.length > 0 ? settings.username : account.email;
    if (settings.authentication === AuthenticationMethod.OAUTH2) {
      const oauthPayload: string = `user=${username}\u0001auth=Bearer ${credential}\u0001\u0001`;
      const oauthResponse: string = await this.command(`AUTH XOAUTH2 ${this.base64Text(oauthPayload)}`,
        235, [235, 334]);
      if (this.hasCode(oauthResponse, 334)) {
        const rejected: string = await this.command('', 535, [535, 454]);
        throw new Error(`SMTP OAuth 登录失败，请重新授权邮箱账户：${rejected.trim().substring(0, 160)}`);
      }
      this.requireCode(oauthResponse, 235, 'SMTP OAuth 登录失败，请重新授权邮箱账户');
    } else {
      this.requireCode(await this.command('AUTH LOGIN', 334), 334, 'SMTP 服务器不支持 AUTH LOGIN');
      this.requireCode(await this.command(this.base64Text(username), 334), 334, 'SMTP 用户名未被接受');
      this.requireCode(await this.command(this.base64Text(credential), 235), 235, 'SMTP 授权码验证失败');
    }
    this.requireCode(await this.command(`MAIL FROM:<${account.email}>`, 250), 250, '发件人地址被拒绝');
    const recipients: string[] = this.allRecipients(draft);
    if (recipients.length === 0) {
      throw new Error('请输入有效的收件人');
    }
    for (let index: number = 0; index < recipients.length; index++) {
      const response: string = await this.command(`RCPT TO:<${recipients[index]}>`, 250, [250, 251]);
      this.requireAnyCode(response, [250, 251], `收件人 ${recipients[index]} 被服务器拒绝`);
    }
    this.requireCode(await this.command('DATA', 354), 354, 'SMTP 服务器未进入邮件内容接收状态');
    const accepted: string = await this.channel.sendAndWait(`${dotStuffed}\r\n.\r\n`,
      (value: string) => this.hasCode(value, 250), 30000);
    this.requireCode(accepted, 250, 'SMTP 服务器未接受邮件内容');
  }

  private async command(value: string, expectedCode: number, acceptedCodes: number[] = []): Promise<string> {
    const codes: number[] = acceptedCodes.length > 0 ? acceptedCodes : [expectedCode];
    return this.channel.sendAndWait(`${value}\r\n`, (response: string) => {
      for (let index: number = 0; index < codes.length; index++) {
        if (this.hasCode(response, codes[index])) return true;
      }
      return this.hasFinalResponse(response);
    });
  }

  private hasCode(response: string, code: number): boolean {
    return response.startsWith(`${code} `) || response.includes(`\r\n${code} `);
  }

  private hasFinalResponse(response: string): boolean {
    return /(?:^|\r\n)[245]\d\d /.test(response);
  }

  private requireCode(response: string, code: number, message: string): void {
    if (!this.hasCode(response, code)) {
      throw new Error(`${message}：${response.trim().substring(0, 160)}`);
    }
  }

  private requireAnyCode(response: string, codes: number[], message: string): void {
    for (let index: number = 0; index < codes.length; index++) {
      if (this.hasCode(response, codes[index])) return;
    }
    throw new Error(`${message}：${response.trim().substring(0, 160)}`);
  }

  private base64Text(value: string): string {
    return this.base64.encodeToStringSync(this.encoder.encodeInto(value));
  }

  private allRecipients(draft: DraftMessage): string[] {
    const values: string[] = `${draft.to},${draft.cc},${draft.bcc}`.split(/[;,]/)
      .map((value: string) => this.mailbox(value)).filter((value: string) => value.length > 0);
    const unique: string[] = [];
    for (let index: number = 0; index < values.length; index++) {
      if (!unique.map((value: string) => value.toLowerCase()).includes(values[index].toLowerCase())) {
        unique.push(values[index]);
      }
    }
    return unique;
  }

  private mailbox(value: string): string {
    const clean: string = value.replace(/[\r\n]+/g, ' ').trim();
    const angle: RegExpMatchArray | null = clean.match(/<([^<>]+)>/);
    return (angle ? angle[1] : clean).trim();
  }

  async close(): Promise<void> {
    try {
      await this.command('QUIT', 221);
    } catch (_error) {
    }
    await this.channel.close();
  }
}
