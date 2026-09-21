import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EmailAccount } from '../model/MailModels';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { MailAccountSyncService } from '../service/MailAccountSyncService';
import { MailNotificationService } from '../service/MailNotificationService';
import { initializeOAuthClientConfigs } from '../config/OAuthClientConfig';

const DOMAIN: number = 0x0002;
// onWorkStop 与 onWorkStart 不保证落在同一个扩展实例上，取消标志与原因放模块级。
let cancelRequested: boolean = false;
let cancelReason: string = '';

function isCancelRequested(): boolean {
  return cancelRequested;
}

export default class MailSyncWorkSchedulerExtensionAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    // 上一轮可能被系统停过：开始新一轮前清掉取消标志，否则本次同步会被立即中断。
    cancelRequested = false;
    cancelReason = '';
    this.performSync(work);
  }

  // 系统要求停止（超时 / 条件不再满足）：只置位取消标志并记下原因，不动数据库——
  // 同步流程会在下一个账户 / 文件夹边界看到标志并中断，由它把原因落到 background_last_error。
  onWorkStop(_work: workScheduler.WorkInfo): void {
    cancelRequested = true;
    cancelReason = '后台同步被系统中断（任务已停止）';
    hilog.info(DOMAIN, 'MailSync', 'Work stop requested');
  }

  private async performSync(work: workScheduler.WorkInfo): Promise<void> {
    const repository: LocalMailRepository = LocalMailRepository.shared();
    try {
      initializeOAuthClientConfigs(this.context);
      await repository.initialize(this.context);
      if ((await repository.getSetting('background_sync', 'true')) !== 'true') {
        return;
      }
      const accounts: EmailAccount[] = (await repository.listAccounts())
        .filter((account: EmailAccount) => account.syncEnabled);
      const syncService: MailAccountSyncService = new MailAccountSyncService(repository);
      let newMailCount: number = 0;
      for (let index: number = 0; index < accounts.length; index++) {
        // 取消后不再启动剩余账户的同步；已完成的账户结果保留。
        if (cancelRequested) {
          break;
        }
        newMailCount += (await syncService.synchronize(accounts[index], isCancelRequested)).receivedCount;
      }
      if (cancelRequested) {
        await repository.setSetting('background_last_error', cancelReason);
        return;
      }
      await repository.setSetting('background_last_run', `${Date.now()}`);
      const notificationsEnabled: boolean =
        (await repository.getSetting('notifications_enabled', 'true')) === 'true';
      const quietHours: boolean =
        (await repository.getSetting('notifications_quiet_hours', 'false')) === 'true';
      const hour: number = new Date().getHours();
      if (notificationsEnabled && !(quietHours && (hour >= 22 || hour < 8)) && newMailCount > 0) {
        await new MailNotificationService().notifyNewMail(newMailCount);
      }
    } catch (error) {
      await repository.setSetting('background_last_error', `${error}`).catch(() => {});
    } finally {
      try {
        workScheduler.stopWork(work, false);
      } catch (_error) {
      }
    }
  }
}
