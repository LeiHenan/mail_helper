import { workScheduler } from '@kit.BackgroundTasksKit';

const BACKGROUND_SYNC_WORK_ID: number = 1001;
const BACKGROUND_SYNC_ABILITY: string = 'MailSyncWorkSchedulerExtensionAbility';
const BUNDLE_NAME: string = 'com.mailhelper.app';
const SYNC_INTERVAL_MS: number = 30 * 60 * 1000;

export class BackgroundSyncScheduler {
  private workInfo(wifiOnly: boolean): workScheduler.WorkInfo {
    return {
      workId: BACKGROUND_SYNC_WORK_ID,
      bundleName: BUNDLE_NAME,
      abilityName: BACKGROUND_SYNC_ABILITY,
      isPersisted: true,
      isRepeat: true,
      repeatCycleTime: SYNC_INTERVAL_MS,
      networkType: wifiOnly ? workScheduler.NetworkType.NETWORK_TYPE_WIFI :
        workScheduler.NetworkType.NETWORK_TYPE_ANY
    };
  }

  configure(enabled: boolean, wifiOnly: boolean): string {
    const work: workScheduler.WorkInfo = this.workInfo(wifiOnly);
    try {
      workScheduler.stopWork(work, true);
    } catch (_error) {
    }
    if (!enabled) {
      return '';
    }
    try {
      workScheduler.startWork(work);
      return '';
    } catch (error) {
      return `${error}`;
    }
  }
}
