import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

export class ProtocolSocket {
  private connection?: socket.TLSSocket = undefined;
  private plainConnection?: socket.TCPSocket = undefined;
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');
  private buffer: string = '';
  private waiter?: (value: string) => void = undefined;
  private rejecter?: (reason: Error) => void = undefined;
  private predicate?: (value: string) => boolean = undefined;
  private timeoutId: number = -1;

  private addressFamily(address: string): number {
    if (address.includes(':')) {
      return 2;
    }
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(address)) {
      return 1;
    }
    return 3;
  }

  async connect(host: string, port: number, timeoutMs: number = 12000): Promise<void> {
    this.connection = socket.constructTLSSocketInstance();
    await this.connection.bind({ address: '0.0.0.0', family: 1, port: 0 });
    this.attachTlsListeners(this.connection);
    await this.connection.connect({
      address: { address: host, family: this.addressFamily(host), port: port },
      secureOptions: { protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13] },
      timeout: timeoutMs
    });
  }

  async connectPlain(host: string, port: number, timeoutMs: number = 12000): Promise<void> {
    this.plainConnection = socket.constructTCPSocketInstance();
    await this.plainConnection.bind({ address: '0.0.0.0', family: 1, port: 0 });
    this.attachTcpListeners(this.plainConnection);
    await this.plainConnection.connect({
      address: { address: host, family: this.addressFamily(host), port: port }, timeout: timeoutMs
    });
  }

  async upgradeToTls(host: string, port: number, timeoutMs: number = 12000): Promise<void> {
    if (!this.plainConnection) {
      throw new Error('STARTTLS 基础连接尚未建立');
    }
    this.plainConnection.off('message');
    this.plainConnection.off('error');
    this.connection = socket.constructTLSSocketInstance(this.plainConnection);
    this.attachTlsListeners(this.connection);
    await this.connection.connect({
      address: { address: host, family: this.addressFamily(host), port: port },
      secureOptions: { protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13] },
      timeout: timeoutMs
    });
    this.plainConnection = undefined;
    this.buffer = '';
  }

  private attachTlsListeners(connection: socket.TLSSocket): void {
    connection.on('message', (messageInfo: socket.SocketMessageInfo) => {
      this.buffer += this.decoder.decode(new Uint8Array(messageInfo.message));
      this.resolveIfReady();
    });
    connection.on('error', (error: Error) => {
      if (this.rejecter) {
        this.rejecter(error);
        this.clearWaiter();
      }
    });
  }

  private attachTcpListeners(connection: socket.TCPSocket): void {
    connection.on('message', (messageInfo: socket.SocketMessageInfo) => {
      this.buffer += this.decoder.decode(new Uint8Array(messageInfo.message));
      this.resolveIfReady();
    });
    connection.on('error', (error: Error) => {
      if (this.rejecter) {
        this.rejecter(error);
        this.clearWaiter();
      }
    });
  }

  private resolveIfReady(): void {
    if (this.waiter && this.predicate && this.predicate(this.buffer)) {
      const response: string = this.buffer;
      this.waiter(response);
      this.clearWaiter();
    }
  }

  private clearWaiter(): void {
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
    }
    this.timeoutId = -1;
    this.waiter = undefined;
    this.rejecter = undefined;
    this.predicate = undefined;
  }

  async waitFor(predicate: (value: string) => boolean, timeoutMs: number = 12000): Promise<string> {
    if (predicate(this.buffer)) {
      const ready: string = this.buffer;
      this.buffer = '';
      return ready;
    }
    const response: string = await new Promise<string>((resolve: (value: string) => void,
      reject: (reason: Error) => void) => {
      this.waiter = resolve;
      this.rejecter = reject;
      this.predicate = predicate;
      this.timeoutId = setTimeout(() => {
        reject(new Error('邮件服务器响应超时'));
        this.clearWaiter();
      }, timeoutMs);
    });
    this.buffer = '';
    return response;
  }

  async sendAndWait(data: string, predicate: (value: string) => boolean,
    timeoutMs: number = 12000): Promise<string> {
    if (!this.connection && !this.plainConnection) {
      throw new Error('邮件服务器连接尚未建立');
    }
    this.buffer = '';
    const responsePromise: Promise<string> = this.waitFor(predicate, timeoutMs);
    if (this.connection) {
      await this.connection.send(data);
    } else if (this.plainConnection) {
      await this.plainConnection.send({ data: data, encoding: 'UTF-8' });
    }
    return responsePromise;
  }

  async send(data: string): Promise<void> {
    if (!this.connection && !this.plainConnection) {
      throw new Error('邮件服务器连接尚未建立');
    }
    if (this.connection) {
      await this.connection.send(data);
    } else if (this.plainConnection) {
      await this.plainConnection.send({ data: data, encoding: 'UTF-8' });
    }
  }

  async close(): Promise<void> {
    this.clearWaiter();
    if (this.connection) {
      await this.connection.close().catch(() => {});
      this.connection = undefined;
    }
    if (this.plainConnection) {
      await this.plainConnection.close().catch(() => {});
      this.plainConnection = undefined;
    }
  }
}
