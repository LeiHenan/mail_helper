import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { BackgroundSyncScheduler } from '../service/BackgroundSyncScheduler';
import { initializeOAuthClientConfigs } from '../config/OAuthClientConfig';

const DOMAIN: number = 0x0000;
const APPEARANCE_SETTING_KEY: string = 'appearance_mode';

export default class EntryAbility extends UIAbility {
  private mainWindowStage?: window.WindowStage;
  private mainWindow?: window.Window;
  private pendingOAuthReturn: boolean = false;
  private appearanceMode: string = 'system';
  // 数据库就绪后要做的启动项（外观、隐私模式、后台同步）挂在这条链上：
  // 首屏不等待它，初始化失败也只是一次日志，不影响首页可用。
  private databaseReady: Promise<void> = Promise.resolve();

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    initializeOAuthClientConfigs(this.context);
    this.pendingOAuthReturn = this.isOAuthReturn(want);
    this.databaseReady = this.initializeDatabase();
    hilog.info(DOMAIN, 'MailHelper', 'Application created');
  }

  // 建库 + 种子数据 + 恢复外观 + 配置后台同步。全部异步进行，任何一步失败都只记日志：
  // 首页此时已经渲染出来，会以空账户状态可用（页面侧各自 await initialize 兜底）。
  private async initializeDatabase(): Promise<void> {
    try {
      await LocalMailRepository.shared().initialize(this.context);
    } catch (error) {
      hilog.error(DOMAIN, 'MailHelper', 'Failed to initialize database: %{public}s',
        (error as Error).message);
      return;
    }
    try {
      // 外观设置读库后才能拿到，因此首帧先按系统配色，这里再切一次（接受一次配色刷新）。
      this.appearanceMode = await LocalMailRepository.shared().getSetting(APPEARANCE_SETTING_KEY, 'system');
      this.applyColorMode();
    } catch (error) {
      hilog.error(DOMAIN, 'MailHelper', 'Failed to apply appearance mode: %{public}s',
        (error as Error).message);
    }
    try {
      await this.configureBackgroundSync();
    } catch (error) {
      hilog.error(DOMAIN, 'MailHelper', 'Failed to configure background sync: %{public}s',
        (error as Error).message);
    }
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    if (!this.isOAuthReturn(want)) return;
    this.pendingOAuthReturn = true;
    this.presentMainWindow();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.mainWindowStage = windowStage;
    this.applySystemBarAppearance(windowStage);
    this.loadIndex(windowStage);
    if (this.pendingOAuthReturn) {
      this.presentMainWindow();
    }
    // 隐私模式要写窗口属性，需要在窗口创建后执行；其余启动项已由 initializeDatabase 完成。
    this.databaseReady.then(() => this.applyPrivacyMode(windowStage)).catch(() => {});
  }

  onConfigurationUpdate(_newConfig: Configuration): void {
    // 深浅色切换后资源会自动换色，这里只需要同步状态栏前景色。
    this.applySystemBarAppearance(this.mainWindowStage);
  }

  onWindowStageDestroy(): void {
    this.mainWindowStage = undefined;
    this.mainWindow = undefined;
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

  // 外观设置（跟随系统 / 浅色 / 深色）转成系统枚举；跟随系统对应「不设置」。
  private resolveColorMode(): ConfigurationConstant.ColorMode {
    if (this.appearanceMode === 'dark') {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    if (this.appearanceMode === 'light') {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }

  // 跟随系统时看当前生效配置，显式指定时以设置为准，避免配置更新滞后的窗口期里判断错误。
  private isDarkMode(): boolean {
    const colorMode: ConfigurationConstant.ColorMode = this.resolveColorMode();
    if (colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      return colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private applyColorMode(): void {
    try {
      const applicationContext: common.ApplicationContext = this.context.getApplicationContext();
      applicationContext.setColorMode(this.resolveColorMode());
    } catch (error) {
      hilog.error(DOMAIN, 'MailHelper', 'Failed to set color mode: %{public}s', (error as Error).message);
    }
  }

  private async applySystemBarAppearance(windowStage?: window.WindowStage): Promise<void> {
    if (!windowStage) return;
    try {
      const mainWindow: window.Window = this.mainWindow ?? await windowStage.getMainWindow();
      this.mainWindow = mainWindow;
      // 浅色模式用深色前景，深色模式用浅色前景，避免状态栏内容与背景同色。
      const properties: window.SystemBarProperties = {
        statusBarContentColor: this.isDarkMode() ? '#FFFFFF' : '#000000'
      };
      await mainWindow.setWindowSystemBarProperties(properties);
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
      } else {
        this.applySystemBarAppearance(windowStage);
      }
    });
  }
}
