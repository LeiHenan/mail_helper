import { LocalMailRepository } from '../data/LocalMailRepository';
import { EmailAccount } from '../model/MailModels';
import { findProvider } from '../model/ProviderConfig';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';

@Entry
@Component
struct Accounts {
  private repository: LocalMailRepository = LocalMailRepository.shared();
  @State private accounts: EmailAccount[] = [];
  @State private showSearch: boolean = false;
  @State private searchText: string = '';
  @State private lastSyncTexts: string[] = [];

  onPageShow(): void {
    this.loadAccounts();
  }

  private async loadAccounts(): Promise<void> {
    this.accounts = await this.repository.listAccounts();
    const texts: string[] = [];
    for (let index: number = 0; index < this.accounts.length; index++) {
      const value: string = await this.repository.getSetting(`last_sync_${this.accounts[index].id}`, '0');
      texts.push(this.formatLastSync(Number.parseInt(value)));
    }
    this.lastSyncTexts = texts;
  }

  private syncText(account: EmailAccount): string {
    if (!account.syncEnabled) {
      return '同步已暂停';
    }
    const index: number = this.accounts.findIndex((item: EmailAccount) => item.id === account.id);
    const lastSync: string = index >= 0 ? this.lastSyncTexts[index] : '尚未同步';
    return account.unreadCount > 0 ? `${account.unreadCount} 封未读 · ${lastSync}` : lastSync;
  }

  private formatLastSync(timestamp: number): string {
    if (!timestamp || timestamp <= 0) return '尚未同步';
    const elapsedMinutes: number = Math.floor((Date.now() - timestamp) / 60000);
    if (elapsedMinutes < 1) return '刚刚同步';
    if (elapsedMinutes < 60) return `${elapsedMinutes} 分钟前同步`;
    const elapsedHours: number = Math.floor(elapsedMinutes / 60);
    if (elapsedHours < 24) return `${elapsedHours} 小时前同步`;
    return `${Math.floor(elapsedHours / 24)} 天前同步`;
  }

  private showToast(_message: string): void {
  }

  private matches(value: string): boolean {
    const keyword: string = this.searchText.trim().toLowerCase();
    return keyword.length === 0 || value.toLowerCase().includes(keyword);
  }

  private openSection(section: string): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/SettingsDetail', params: { section: section }
    }).catch(() => {});
  }

  @Builder
  private settingRow(icon: Resource, title: string, subtitle: string, action: () => void) {
    Row({ space: 12 }) {
      Stack() {
        Circle().width(38).height(38).fill(ThunderbirdTheme.surfaceLow)
        Image(icon).width(21).height(21).objectFit(ImageFit.Contain)
          .fillColor(ThunderbirdTheme.primary)
      }
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontColor(ThunderbirdTheme.onSurface)
        if (subtitle.length > 0) {
          Text(subtitle).fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant).maxLines(1)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Image($r('app.media.ic_chevron_right')).width(20).height(20).objectFit(ImageFit.Contain)
    }
    .width('100%').constraintSize({ minHeight: subtitle.length > 0 ? 68 : 60 })
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .margin({ bottom: 8 })
    .backgroundColor(ThunderbirdTheme.surfaceLowest)
    .border({ width: 1, color: ThunderbirdTheme.cardBorder })
    .borderRadius(ThunderbirdTheme.cardRadius).onClick(action)
  }

  @Builder
  private accountRow(account: EmailAccount) {
    Row({ space: 14 }) {
      Stack() {
        Circle().width(44).height(44).fill(account.color)
        Text(findProvider(account.provider).shortName)
          .fontSize(findProvider(account.provider).shortName.length > 2 ? 10 : 14)
          .fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onPrimary)
      }
      Column({ space: 3 }) {
        Text(account.displayName).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(ThunderbirdTheme.onSurface).maxLines(1)
        Text(account.email).fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant).maxLines(1)
        Text(this.syncText(account)).fontSize(12)
          .fontColor(account.syncEnabled ? ThunderbirdTheme.primary : ThunderbirdTheme.outline).maxLines(1)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: account.syncEnabled })
        .width(48).height(30).selectedColor(ThunderbirdTheme.primary)
        .onChange(async (isOn: boolean) => {
          await this.repository.setAccountSyncEnabled(account.id, isOn);
          account.syncEnabled = isOn;
          this.accounts = this.accounts.slice();
        })
      Image($r('app.media.ic_chevron_right')).width(20).height(20).objectFit(ImageFit.Contain)
    }
    .width('100%').constraintSize({ minHeight: 80 })
    .padding({ left: 12, right: 10, top: 10, bottom: 10 })
    .margin({ bottom: 8 })
    .backgroundColor(ThunderbirdTheme.surfaceLowest)
    .border({ width: 1, color: ThunderbirdTheme.cardBorder })
    .borderRadius(ThunderbirdTheme.cardRadius)
    .onClick(() => this.getUIContext().getRouter().pushUrl({
      url: 'pages/AccountDetail', params: { accountId: account.id }
    }).catch(() => {}))
  }

  build() {
    Column() {
      Row() {
        Button() {
          Image($r('app.media.ic_back')).width(23).height(23).objectFit(ImageFit.Contain)
        }
          .width(48).height(48).backgroundColor(Color.Transparent)
          .onClick(() => this.getUIContext().getRouter().back())
        Text('账户与设置').layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThunderbirdTheme.onSurface)
        Button() {
          Image(this.showSearch ? $r('app.media.ic_close') : $r('app.media.ic_search'))
            .width(22).height(22).objectFit(ImageFit.Contain)
        }
          .width(44).height(48).backgroundColor(Color.Transparent)
          .onClick(() => {
            this.showSearch = !this.showSearch;
            if (!this.showSearch) this.searchText = '';
          })
      }
      .width('100%').height(56).padding({ left: 4, right: 8 }).backgroundColor(ThunderbirdTheme.surface)

      if (this.showSearch) {
        Row() {
          Row({ space: 8 }) {
            Image($r('app.media.ic_search')).width(20).height(20).objectFit(ImageFit.Contain)
            TextInput({ placeholder: '搜索账户或设置', text: this.searchText })
              .layoutWeight(1).height(44).backgroundColor(Color.Transparent)
              .onChange((value: string) => this.searchText = value)
          }.width('100%').height(46).padding({ left: 14, right: 14 })
            .backgroundColor(ThunderbirdTheme.surfaceContainer)
            .borderRadius(ThunderbirdTheme.pillRadius)
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }

      Scroll() {
        Column() {
          Text('账户').width('100%').fontSize(13).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.primary)
            .padding({ left: 2, top: 14, bottom: 10 })
          ForEach(this.accounts, (account: EmailAccount) => {
            if (this.matches(`${account.displayName} ${account.email}`)) {
              this.accountRow(account)
            }
          }, (account: EmailAccount) => `${account.id}_${account.syncEnabled ? 'on' : 'off'}`)
          if (this.matches('添加账户 QQ 163 Gmail Outlook IMAP')) {
            Button() {
              Row({ space: 8 }) {
                Image($r('app.media.ic_add')).width(20).height(20).objectFit(ImageFit.Contain)
                  .fillColor(ThunderbirdTheme.onPrimary)
                Text('添加账户').fontSize(14).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onPrimary)
              }
            }
            .width('100%').height(48).backgroundColor(ThunderbirdTheme.primary)
            .borderRadius(ThunderbirdTheme.controlRadius).margin({ top: 2, bottom: 4 })
            .onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/AddAccount' }).catch(() => {}))
          }

          Text('常规设置').width('100%').fontSize(13).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.primary)
            .padding({ left: 2, top: 26, bottom: 10 })
          if (this.matches('邮件列表 显示密度 预览')) {
            this.settingRow($r('app.media.ic_mail'), '邮件列表', '显示密度与正文预览', () => this.openSection('mail_list'))
          }
          if (this.matches('滑动手势 归档 删除')) {
            this.settingRow($r('app.media.ic_swipe'), '滑动手势', '快速操作开关与左滑动作', () => this.openSection('swipe'))
          }
          if (this.matches('通知 新邮件 安静时段')) {
            this.settingRow($r('app.media.ic_notifications'), '通知', '新邮件通知与安静时段', () => this.openSection('notifications'))
          }
          if (this.matches('同步 后台 Wi-Fi 流量')) {
            this.settingRow($r('app.media.ic_sync'), '同步', '后台同步与网络限制', () => this.openSection('sync'))
          }
          if (this.matches('隐私 安全 远程图片 邮件保护')) {
            this.settingRow($r('app.media.ic_lock'), '隐私与安全', '远程图片与内容保护', () => this.openSection('privacy'))
          }

          Text('其他').width('100%').fontSize(13).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.primary)
            .padding({ left: 2, top: 26, bottom: 10 })
          if (this.matches('帮助 账户连接 授权码')) {
            this.settingRow($r('app.media.ic_help'), '帮助', '', () => this.openSection('help'))
          }
          if (this.matches('关于 版本 邮箱助手')) {
            this.settingRow($r('app.media.ic_info'), '关于', 'HarmonyOS 原生邮件客户端', () => this.openSection('about'))
          }
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 28 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }
    .width('100%').height('100%').backgroundColor(ThunderbirdTheme.surface)
  }
}
