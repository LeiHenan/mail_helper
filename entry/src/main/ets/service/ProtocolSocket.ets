import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

export class ProtocolSocket {
  private connection?: socket.TLSSocket = undefined;
  private plainConnection?: socket.TCPSocket = undefined;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private buffer: string = '';
  private waiter?: (value: string) => void = undefined;
  private rejecter?: (reason: Error) => void = undefined;
  private predicate?: (value: string) => boolean = undefined;
  private timeoutId: number = -1;
  private idleTimeoutId: number = -1;
  private closed: boolean = false;
  private readonly readIdleTimeoutMs: number = 60000;
  private readonly maximumBufferSize: number = 32 * 1024 * 1024;

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
    this.resetState();
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
    this.resetState();
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
    this.plainConnection.off('close');
    this.plainConnection.off('error');
    this.connection = socket.constructTLSSocketInstance(this.plainConnection);
    this.attachTlsListeners(this.connection);
    await this.connection.connect({
      address: { address: host, family: this.addressFamily(host), port: port },
      secureOptions: { protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13] },
      timeout: timeoutMs
    });
    this.plainConnection = undefined;
    this.resetState();
  }

  private resetState(): void {
    this.clearWaiter();
    this.buffer = '';
    this.decoder = util.TextDecoder.create('utf-8');
    this.closed = false;
  }

  private attachTlsListeners(connection: socket.TLSSocket): void {
    connection.on('message', (messageInfo: socket.SocketMessageInfo) => {
      this.handleData(messageInfo);
    });
    connection.on('close', () => {
      this.handleDisconnect(new Error('邮件服务器已断开连接'));
    });
    connection.on('error', (error: Error) => {
      this.handleDisconnect(error);
    });
  }

  private attachTcpListeners(connection: socket.TCPSocket): void {
    connection.on('message', (messageInfo: socket.SocketMessageInfo) => {
      this.handleData(messageInfo);
    });
    connection.on('close', () => {
      this.handleDisconnect(new Error('邮件服务器已断开连接'));
    });
    connection.on('error', (error: Error) => {
      this.handleDisconnect(error);
    });
  }

  private handleData(messageInfo: socket.SocketMessageInfo): void {
    if (this.closed) {
      return;
    }
    this.buffer += this.decoder.decodeToString(new Uint8Array(messageInfo.message), { stream: true });
    if (this.buffer.length > this.maximumBufferSize) {
      this.buffer = '';
      this.failPending(new Error('邮件服务器响应数据过大'));
      return;
    }
    this.armIdleTimeout();
    this.resolveIfReady();
  }

  private handleDisconnect(reason: Error): void {
    this.closed = true;
    this.failPending(reason);
  }

  private failPending(reason: Error): void {
    const rejecter: ((reason: Error) => void) | undefined = this.rejecter;
    this.clearWaiter();
    if (rejecter) {
      rejecter(reason);
    }
  }

  private resolveIfReady(): void {
    if (!this.waiter || !this.predicate) {
      return;
    }
    if (!this.isReady(this.predicate)) {
      return;
    }
    const waiter: (value: string) => void = this.waiter;
    const response: string = this.takeBuffer();
    this.clearWaiter();
    waiter(response);
  }

  private isReady(predicate: (value: string) => boolean): boolean {
    return this.buffer.endsWith('\r\n') && predicate(this.buffer);
  }

  private takeBuffer(): string {
    const pending: string = this.buffer;
    this.buffer = '';
    return pending;
  }

  private clearWaiter(): void {
    if (this.timeoutId >= 0) {
      clearTimeout(this.timeoutId);
    }
    this.timeoutId = -1;
    if (this.idleTimeoutId >= 0) {
      clearTimeout(this.idleTimeoutId);
    }
    this.idleTimeoutId = -1;
    this.waiter = undefined;
    this.rejecter = undefined;
    this.predicate = undefined;
  }

  private armIdleTimeout(): void {
    if (this.idleTimeoutId >= 0) {
      clearTimeout(this.idleTimeoutId);
    }
    this.idleTimeoutId = -1;
    if (!this.waiter) {
      return;
    }
    this.idleTimeoutId = setTimeout(() => {
      this.idleTimeoutId = -1;
      this.failPending(new Error('邮件服务器长时间无响应'));
    }, this.readIdleTimeoutMs);
  }

  private requireOpen(): void {
    if (!this.connection && !this.plainConnection) {
      throw new Error('邮件服务器连接尚未建立');
    }
    if (this.closed) {
      throw new Error('邮件服务器连接已断开');
    }
  }

  async waitFor(predicate: (value: string) => boolean, timeoutMs: number = 12000): Promise<string> {
    this.requireOpen();
    if (this.isReady(predicate)) {
      return this.takeBuffer();
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
      this.armIdleTimeout();
    });
    return response;
  }

  async sendAndWait(data: string, predicate: (value: string) => boolean,
    timeoutMs: number = 12000): Promise<string> {
    this.requireOpen();
    const responsePromise: Promise<string> = this.waitFor(predicate, timeoutMs);
    try {
      await this.send(data);
    } catch (error) {
      this.clearWaiter();
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('邮件服务器数据发送失败');
    }
    return responsePromise;
  }

  async send(data: string): Promise<void> {
    this.requireOpen();
    if (this.connection) {
      await this.connection.send(data);
    } else if (this.plainConnection) {
      await this.plainConnection.send({ data: data, encoding: 'UTF-8' });
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    this.clearWaiter();
    this.buffer = '';
    if (this.connection) {
      await this.connection.close().catch(() => {});
      this.connection = undefined;
    }
    if (this.plainConnection) {
      await this.plainConnection.close().catch(() => {});
      this.plainConnection = undefined;
    }
    this.decoder = util.TextDecoder.create('utf-8');
  }
}
