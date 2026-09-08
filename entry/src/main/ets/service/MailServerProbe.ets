import { ConnectionSecurity, MailServerSettings } from '../model/MailServerModels';
import { describeError } from './ErrorFormatter';
import { ImapClient } from './ImapClient';
import { ProtocolSocket } from './ProtocolSocket';

export class ProbeResult {
  reachable: boolean;
  latencyMs: number;
  detail: string;

  constructor(reachable: boolean, latencyMs: number, detail: string = '') {
    this.reachable = reachable;
    this.latencyMs = latencyMs;
    this.detail = detail;
  }
}

export class MailServerProbe {
  async probe(settings: MailServerSettings, timeoutMs: number = 8000): Promise<ProbeResult> {
    const startedAt: number = Date.now();
    const channel: ProtocolSocket = new ProtocolSocket();
    try {
      if (settings.security === ConnectionSecurity.TLS) {
        await channel.connect(settings.host, settings.port, timeoutMs);
      } else {
        await channel.connectPlain(settings.host, settings.port, timeoutMs);
      }
      const detail: string = settings.security === ConnectionSecurity.STARTTLS ?
        '服务器可连接；STARTTLS 升级将在协议握手阶段验证' : 'TLS 连接成功';
      return new ProbeResult(true, Date.now() - startedAt, detail);
    } catch (error) {
      return new ProbeResult(false, Date.now() - startedAt, describeError(error));
    } finally {
      await channel.close();
    }
  }

  async validateImapLogin(settings: MailServerSettings, username: string, secret: string,
    timeoutMs: number = 10000): Promise<ProbeResult> {
    const startedAt: number = Date.now();
    const client: ImapClient = new ImapClient();
    try {
      await client.connect(settings, username, secret);
      return new ProbeResult(true, Date.now() - startedAt, 'IMAP 登录验证成功');
    } catch (error) {
      return new ProbeResult(false, Date.now() - startedAt, describeError(error));
    } finally {
      await client.close();
    }
  }
}
