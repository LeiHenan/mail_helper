import { LocalMailRepository } from '../data/LocalMailRepository';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { MailNotificationService } from '../service/MailNotificationService';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BackgroundSyncScheduler } from '../service/BackgroundSyncScheduler';

interface SettingsDetailParams {
  section?: string;
}

@Entry
@Component
struct SettingsDetail {
  private repository: LocalMailRepository = LocalMailRepository.shared();
  private notificationService: MailNotificationService = new MailNotificationService();
  private backgroundScheduler: BackgroundSyncScheduler = new BackgroundSyncScheduler();
  private pendingSettingWrite: Promise<void> = Promise.resolve();
  @State private section: string = 'mail_list';
  @State private settingsLoaded: boolean = false;
  @State private compactMode: boolean = false;
  @State private showPreview: boolean = true;
  @State private swipeEnabled: boolean = true;
  @State private swipeDelete: boolean = false;
  @State private notificationsEnabled: boolean = true;
  @State private quietHours: boolean = false;
  @State private backgroundSync: boolean = true;
  @State private wifiOnly: boolean = false;
  @State private remoteImages: boolean = false;
  @State private protectContent: boolean = true;

  aboutToAppear(): void {
    const params: SettingsDetailParams = this.getUIContext().getRouter().getParams() as SettingsDetailParams;
    this.section = params.section ?? 'mail_list';
    this.loadSettings();
  }

  private async loadBoolean(key: string, defaultValue: boolean): Promise<boolean> {
    return (await this.repository.getSetting(key, defaultValue ? 'true' : 'false')) === 'true';
  }

  private async loadSettings(): Promise<void> {
    this.settingsLoaded = false;
    try {
      this.compactMode = await this.loadBoolean('mail_list_compact', false);
      this.showPreview = await this.loadBoolean('mail_list_preview', true);
      this.swipeEnabled = await this.loadBoolean('swipe_enabled', true);
      this.swipeDelete = await this.loadBoolean('swipe_delete', false);
      this.notificationsEnabled = await this.loadBoolean('notifications_enabled', true);
      this.quietHours = await this.loadBoolean('notifications_quiet_hours', false);
      this.backgroundSync = await this.loadBoolean('background_sync', true);
      this.wifiOnly = await this.loadBoolean('sync_wifi_only', false);
      this.remoteImages = await this.loadBoolean('remote_images', false);
      this.protectContent = await this.loadBoolean('protect_content', true);
    } finally {
      this.settingsLoaded = true;
    }
  }

  private saveBoolean(key: string, value: boolean): Promise<void> {
    this.pendingSettingWrite = this.pendingSettingWrite.then(async () => {
      await this.repository.setSetting(key, value ? 'true' : 'false');
    }).catch((error: Error) => {
      this.showToast(`设置保存失败：${error.message}`);
    });
    return this.pendingSettingWrite;
  }

  private async closePage(): Promise<void> {
    await this.pendingSettingWrite;
    this.getUIContext().getRouter().back();
  }

  private async changeNotifications(enabled: boolean): Promise<void> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (enabled && !await this.notificationService.requestPermission(context)) {
      this.notificationsEnabled = false;
      await this.saveBoolean('notifications_enabled', false);
      return;
    }
    this.notificationsEnabled = enabled;
    await this.saveBoolean('notifications_enabled', enabled);
  }

  private async changeContentProtection(enabled: boolean): Promise<void> {
    this.protectContent = enabled;
    await this.saveBoolean('protect_content', enabled);
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mainWindow: window.Window = await window.getLastWindow(context);
      await mainWindow.setWindowPrivacyMode(enabled);
    } catch (_error) {
    }
  }

  private async changeBackgroundSync(enabled: boolean): Promise<void> {
    const error: string = this.backgroundScheduler.configure(enabled, this.wifiOnly);
    if (error.length > 0) {
      this.backgroundSync = false;
      await this.saveBoolean('background_sync', false);
      this.showToast(`无法启用后台同步：${error}`);
      return;
    }
    this.backgroundSync = enabled;
    await this.saveBoolean('background_sync', enabled);
    this.showToast(enabled ? '后台同步已启用' : '后台同步已关闭');
  }

  private async changeWifiOnly(enabled: boolean): Promise<void> {
    const error: string = this.backgroundScheduler.configure(this.backgroundSync, enabled);
    if (error.length > 0 && this.backgroundSync) {
      this.showToast(`无法更新后台同步网络条件：${error}`);
      return;
    }
    this.wifiOnly = enabled;
    await this.saveBoolean('sync_wifi_only', enabled);
  }

  private showToast(_message: string): void {
  }

  private title(): string {
    if (this.section === 'mail_list') return '邮件列表';
    if (this.section === 'swipe') return '滑动手势';
    if (this.section === 'notifications') return '通知';
    if (this.section === 'sync') return '同步';
    if (this.section === 'privacy') return '隐私与安全';
    if (this.section === 'help') return '帮助';
    return '关于';
  }

  @Builder
  private toggleRow(title: string, subtitle: string, value: boolean, change: (value: boolean) => void) {
    Row({ space: 14 }) {
      Column({ space: 4 }) {
        Text(title).fontSize(15).fontColor(ThunderbirdTheme.onSurface)
        Text(subtitle).fontSize(12).lineHeight(18).fontColor(ThunderbirdTheme.onSurfaceVariant)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .width(48).height(30).selectedColor(ThunderbirdTheme.primary).onChange(change)
    }
    .width('100%').constraintSize({ minHeight: 72 })
    .padding({ left: 16, right: 14, top: 12, bottom: 12 })
    .margin({ bottom: 8 })
    .backgroundColor(ThunderbirdTheme.surfaceLowest)
    .border({ width: 1, color: ThunderbirdTheme.cardBorder })
    .borderRadius(ThunderbirdTheme.cardRadius)
  }

  @Builder
  private settingsContent() {
    Column() {
      if (this.section === 'mail_list') {
        this.toggleRow('紧凑列表', '缩小邮件行高度，适合同时浏览更多邮件', this.compactMode,
          (value: boolean) => {
            this.compactMode = value;
            this.saveBoolean('mail_list_compact', value);
          })
        this.toggleRow('显示正文预览', '在邮件主题下显示一行正文摘要', this.showPreview,
          (value: boolean) => {
            this.showPreview = value;
            this.saveBoolean('mail_list_preview', value);
          })
      } else if (this.section === 'swipe') {
        this.toggleRow('启用滑动操作', '允许在邮件列表中使用快速操作', this.swipeEnabled,
          (value: boolean) => {
            this.swipeEnabled = value;
            this.saveBoolean('swipe_enabled', value);
          })
        this.toggleRow('左滑删除', '关闭时左滑操作为归档', this.swipeDelete,
          (value: boolean) => {
            this.swipeDelete = value;
            this.saveBoolean('swipe_delete', value);
          })
      } else if (this.section === 'notifications') {
        this.toggleRow('新邮件通知', '收到新邮件时允许显示系统通知', this.notificationsEnabled,
          (value: boolean) => {
            this.changeNotifications(value);
          })
        this.toggleRow('安静时段', '夜间同步时不发出声音和振动', this.quietHours,
          (value: boolean) => {
            this.quietHours = value;
            this.saveBoolean('notifications_quiet_hours', value);
          })
      } else if (this.section === 'sync') {
        this.toggleRow('后台同步', '允许应用在后台检查新邮件', this.backgroundSync,
          (value: boolean) => {
            this.changeBackgroundSync(value);
          })
        this.toggleRow('仅 Wi-Fi 同步', '使用移动网络时暂停附件和邮件同步', this.wifiOnly,
          (value: boolean) => {
            this.changeWifiOnly(value);
          })
      } else if (this.section === 'privacy') {
        this.toggleRow('自动加载远程图片', '关闭可减少跟踪像素和隐私泄露', this.remoteImages,
          (value: boolean) => {
            this.remoteImages = value;
            this.saveBoolean('remote_images', value);
          })
        this.toggleRow('保护邮件内容', '应用切入后台时隐藏邮件预览', this.protectContent,
          (value: boolean) => {
            this.changeContentProtection(value);
          })
      } else if (this.section === 'help') {
        Column({ space: 16 }) {
          Text('账户连接').fontSize(17).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface)
          Text('QQ 和 163 邮箱需要在网页版邮箱中开启 IMAP/SMTP，并使用生成的授权码登录。')
            .fontSize(14).lineHeight(22).fontColor(ThunderbirdTheme.onSurfaceVariant)
          Text('Gmail 与 Outlook').fontSize(17).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface)
          Text('这两类邮箱通过服务商的 OAuth 安全登录。应用不会要求或保存邮箱登录密码。')
            .fontSize(14).lineHeight(22).fontColor(ThunderbirdTheme.onSurfaceVariant)
          Text('离线操作').fontSize(17).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface)
          Text('星标、已读、归档和删除会先保存在本地，服务器可用时再依次同步。')
            .fontSize(14).lineHeight(22).fontColor(ThunderbirdTheme.onSurfaceVariant)
        }.width('100%').padding(18).alignItems(HorizontalAlign.Start)
          .backgroundColor(ThunderbirdTheme.surfaceLowest)
          .border({ width: 1, color: ThunderbirdTheme.cardBorder })
          .borderRadius(ThunderbirdTheme.cardRadius)
      } else {
        Column({ space: 14 }) {
          Image($r('app.media.app_icon')).width(72).height(72).objectFit(ImageFit.Contain)
          Text('邮箱助手').fontSize(22).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface)
          Text('版本 1.0.0').fontSize(13).fontColor(ThunderbirdTheme.onSurfaceVariant)
          Text('原生 HarmonyOS 多账户邮件客户端。界面与交互参考 Thunderbird 的信息架构。')
            .fontSize(14).lineHeight(22).textAlign(TextAlign.Center).fontColor(ThunderbirdTheme.onSurfaceVariant)
        }.width('100%').padding({ left: 28, right: 28, top: 36, bottom: 36 })
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(ThunderbirdTheme.surfaceLowest)
          .border({ width: 1, color: ThunderbirdTheme.cardBorder })
          .borderRadius(ThunderbirdTheme.cardRadius)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: '100%' })
    .padding({ left: 16, right: 16, top: 8, bottom: 24 })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .align(Alignment.TopStart)
  }

  build() {
    Column() {
      Row() {
        Button() {
          Image($r('app.media.ic_back')).width(23).height(23).objectFit(ImageFit.Contain)
        }.width(48).height(48).backgroundColor(Color.Transparent)
          .onClick(() => this.closePage())
        Text(this.title()).layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThunderbirdTheme.onSurface)
        Row() {}.width(48)
      }
      .width('100%').height(56).padding({ left: 4, right: 4 })
      .backgroundColor(ThunderbirdTheme.surface).zIndex(1)
      if (this.settingsLoaded) {
        Scroll() {
          this.settingsContent()
        }
        .layoutWeight(1).width('100%').scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      } else {
        Column({ space: 10 }) {
          LoadingProgress().width(26).height(26).color(ThunderbirdTheme.primary)
          Text('正在读取设置').fontSize(13).fontColor(ThunderbirdTheme.onSurfaceVariant)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      }
    }.width('100%').height('100%').backgroundColor(ThunderbirdTheme.surface)
  }
}
