import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { EmailAccount } from '../model/MailModels';
import { AccountServerSettings } from '../model/MailServerModels';
import { describeError } from './ErrorFormatter';
import { ImapClient } from './ImapClient';
import { MailAccountSyncService, AccountSyncResult } from './MailAccountSyncService';

const DOMAIN: number = 0x0002;
// RFC 2177 建议 29 分钟内重新发一次 IDLE，取 25 分钟留余量。
const IDLE_CYCLE_MS: number = 25 * 60 * 1000;
// 事件去抖：服务器一次投递常连发多条 EXISTS，合并成一次同步。
const EVENT_DEBOUNCE_MS: number = 3000;
const RETRY_BACKOFF_MS: number = 30 * 1000;
// 连续失败超过此次数就放弃 IDLE（不支持 IDLE 的服务器、网络持续不通），由前台 30 秒轮询兜底。
const MAX_CONSECUTIVE_FAILURES: number = 3;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

// 前台 IMAP IDLE：每个启用同步的账户一条长连接挂在 INBOX 上，服务器一推新邮件事件
// 就立刻做一次增量同步，实现近实时收信。仅在前台运行（页面隐藏即 stopAll），
// 断线/失败时退避重连；彻底不可用时自动让位给定时轮询，不会把同步搞挂。
export class ImapIdleService {
  private repository: LocalMailRepository;
  private syncService: MailAccountSyncService;
  private loops: Map<string, IdleLoop> = new Map<string, IdleLoop>();

  constructor(repository: LocalMailRepository) {
    this.repository = repository;
    this.syncService = new MailAccountSyncService(repository);
  }

  // 按当前账户列表对齐 IDLE 循环：新账户补开，已删除/停用同步的账户关停。可反复调用。
  start(accounts: EmailAccount[]): void {
    const wanted: string[] = [];
    for (let index = 0; index < accounts.length; index++) {
      if (accounts[index].syncEnabled) {
        wanted.push(accounts[index].id);
      }
    }
    const toStop: string[] = [];
    this.loops.forEach((loop: IdleLoop, accountId: string) => {
      if (!wanted.includes(accountId)) {
        toStop.push(accountId);
      }
    });
    for (let index = 0; index < toStop.length; index++) {
      const loop: IdleLoop | undefined = this.loops.get(toStop[index]);
      if (loop) {
        loop.stop();
      }
      this.loops.delete(toStop[index]);
    }
    for (let index = 0; index < accounts.length; index++) {
      const account: EmailAccount = accounts[index];
      if (!account.syncEnabled || this.loops.has(account.id)) {
        continue;
      }
      const loop: IdleLoop = new IdleLoop(account, this.repository, this.syncService);
      this.loops.set(account.id, loop);
      loop.run().catch(() => {});
    }
  }

  stopAll(): void {
    this.loops.forEach((loop: IdleLoop) => {
      loop.stop();
    });
    this.loops.clear();
  }
}

class IdleLoop {
  private account: EmailAccount;
  private repository: LocalMailRepository;
  private syncService: MailAccountSyncService;
  private stopped: boolean = false;
  private client?: ImapClient = undefined;

  constructor(account: EmailAccount, repository: LocalMailRepository, syncService: MailAccountSyncService) {
    this.account = account;
    this.repository = repository;
    this.syncService = syncService;
  }

  stop(): void {
    this.stopped = true;
    // 关掉当前连接：挂起的 IDLE 等待会立即被拒绝，run() 得以干净退出。
    const client: ImapClient | undefined = this.client;
    if (client) {
      client.close().catch(() => {});
    }
  }

  async run(): Promise<void> {
    let failures: number = 0;
    while (!this.stopped) {
      const client: ImapClient = new ImapClient();
      this.client = client;
      try {
        const settings: AccountServerSettings | undefined =
          await this.repository.getAccountServerSettings(this.account.id);
        if (!settings || settings.incoming.host.length === 0) {
          return;
        }
        const credential: string = await this.syncService.resolveCredential(this.account, settings);
        if (credential.length === 0) {
          return;
        }
        const username: string =
          settings.incoming.username.length > 0 ? settings.incoming.username : this.account.email;
        await client.connect(settings.incoming, username, credential);
        failures = 0;
        hilog.info(DOMAIN, 'ImapIdleService', 'IDLE 已挂起：%{public}s', this.account.email);
        while (!this.stopped) {
          const hasEvent: boolean = await client.idleInbox(IDLE_CYCLE_MS);
          if (this.stopped || !hasEvent) {
            continue;
          }
          // 去抖后再同步：一次新邮件投递通常伴随多条 untagged 事件。
          await sleep(EVENT_DEBOUNCE_MS);
          if (this.stopped) {
            break;
          }
          const result: AccountSyncResult = await this.syncService.synchronize(this.account);
          if (result.errorMessage.length > 0 && !result.skipped) {
            failures++;
            hilog.warn(DOMAIN, 'ImapIdleService', 'IDLE 触发同步失败(%{public}s)：%{public}s',
              this.account.email, result.errorMessage);
            if (failures >= MAX_CONSECUTIVE_FAILURES) {
              return;
            }
          }
        }
      } catch (error) {
        if (this.stopped) {
          return;
        }
        failures++;
        hilog.warn(DOMAIN, 'ImapIdleService', 'IDLE 连接中断(%{public}s，第%{public}d次)：%{public}s',
          this.account.email, failures, describeError(error));
        if (failures >= MAX_CONSECUTIVE_FAILURES) {
          hilog.warn(DOMAIN, 'ImapIdleService', 'IDLE 连续失败，让位给定时轮询：%{public}s',
            this.account.email);
          return;
        }
        await sleep(RETRY_BACKOFF_MS);
      } finally {
        await client.close();
        if (this.client === client) {
          this.client = undefined;
        }
      }
    }
  }
}
