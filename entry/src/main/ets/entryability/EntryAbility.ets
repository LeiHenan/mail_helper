import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { BackgroundSyncScheduler } from '../service/BackgroundSyncScheduler';

const DOMAIN: number = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWindowStage?: window.WindowStage;
  private pendingOAuthReturn: boolean = false;

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.pendingOAuthReturn = this.isOAuthReturn(want);
    hilog.info(DOMAIN, 'MailHelper', 'Application created');
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    if (!this.isOAuthReturn(want)) return;
    this.pendingOAuthReturn = true;
    this.presentMainWindow();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.mainWindowStage = windowStage;
    LocalMailRepository.shared().initialize(this.context).then(() => {
      this.applyPrivacyMode(windowStage);
      this.configureBackgroundSync();
      this.loadIndex(windowStage);
      if (this.pendingOAuthReturn) {
        this.presentMainWindow();
      }
    }).catch((error: Error) => {
      hilog.error(DOMAIN, 'MailHelper', 'Failed to initialize database: %{public}s', error.message);
    });
  }

  onWindowStageDestroy(): void {
    this.mainWindowStage = undefined;
  }

  private isOAuthReturn(want: Want): boolean {
    return (want.uri ?? '').startsWith('mailhelper://oauth/complete');
  }

  private async presentMainWindow(): Promise<void> {
    if (!this.mainWindowStage) return;
    try {
      const mainWindow: window.Window = await this.mainWindowStage.getMainWindow();
      try {
        await mainWindow.restore();
      } catch (_error) {
      }
      await mainWindow.showWindow();
      this.pendingOAuthReturn = false;
    } catch (_error) {
    }
  }

  private async configureBackgroundSync(): Promise<void> {
    const repository: LocalMailRepository = LocalMailRepository.shared();
    const enabled: boolean = (await repository.getSetting('background_sync', 'true')) === 'true';
    const wifiOnly: boolean = (await repository.getSetting('sync_wifi_only', 'false')) === 'true';
    const error: string = new BackgroundSyncScheduler().configure(enabled, wifiOnly);
    await repository.setSetting('background_scheduler_error', error);
  }

  private async applyPrivacyMode(windowStage: window.WindowStage): Promise<void> {
    try {
      const enabled: boolean =
        (await LocalMailRepository.shared().getSetting('protect_content', 'true')) === 'true';
      const mainWindow: window.Window = await windowStage.getMainWindow();
      await mainWindow.setWindowPrivacyMode(enabled);
    } catch (_error) {
    }
  }

  private loadIndex(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(DOMAIN, 'MailHelper', 'Failed to load Index: %{public}s', JSON.stringify(error));
      }
    });
  }
}
