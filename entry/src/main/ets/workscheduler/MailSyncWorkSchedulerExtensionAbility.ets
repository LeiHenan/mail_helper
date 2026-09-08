import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { EmailAccount } from '../model/MailModels';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { MailAccountSyncService } from '../service/MailAccountSyncService';
import { MailNotificationService } from '../service/MailNotificationService';

export default class MailSyncWorkSchedulerExtensionAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    this.performSync(work);
  }

  onWorkStop(_work: workScheduler.WorkInfo): void {
  }

  private async performSync(work: workScheduler.WorkInfo): Promise<void> {
    const repository: LocalMailRepository = LocalMailRepository.shared();
    try {
      await repository.initialize(this.context);
      if ((await repository.getSetting('background_sync', 'true')) !== 'true') {
        return;
      }
      const accounts: EmailAccount[] = (await repository.listAccounts())
        .filter((account: EmailAccount) => account.syncEnabled);
      const syncService: MailAccountSyncService = new MailAccountSyncService(repository);
      let newMailCount: number = 0;
      for (let index: number = 0; index < accounts.length; index++) {
        newMailCount += (await syncService.synchronize(accounts[index])).receivedCount;
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
