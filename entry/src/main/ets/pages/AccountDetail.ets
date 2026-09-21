import { LocalMailRepository } from '../data/LocalMailRepository';
import { EmailAccount } from '../model/MailModels';
import { findProvider } from '../model/ProviderConfig';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { AccountServerSettings, AuthenticationMethod } from '../model/MailServerModels';
import { MailServerProbe, ProbeResult } from '../service/MailServerProbe';
import { AccountSyncResult, MailAccountSyncService } from '../service/MailAccountSyncService';
import { describeError } from '../service/ErrorFormatter';
import { OAuthResolvedCredential, OAuthService } from '../service/OAuthService';
import { showToast } from '../common/Toast';

interface AccountDetailParams {
  accountId?: string;
}

@Entry
@Component
struct AccountDetail {
  private repository: LocalMailRepository = LocalMailRepository.shared();
  private probe: MailServerProbe = new MailServerProbe();
  private syncService: MailAccountSyncService = new MailAccountSyncService(this.repository);
  private oauthService: OAuthService = new OAuthService();
  @State private account?: EmailAccount = undefined;
  @State private serverSettings?: AccountServerSettings = undefined;
  @State private isWorking: boolean = false;
  @State private operationStatus: string = '';
  @State private lastSyncText: string = '尚未同步';

  aboutToAppear(): void {
    const params: AccountDetailParams = this.getUIContext().getRouter().getParams() as AccountDetailParams;
    this.loadAccount(params.accountId ?? '');
  }

  private async loadAccount(accountId: string): Promise<void> {
    this.account = (await this.repository.listAccounts()).find((account: EmailAccount) => account.id === accountId);
    this.serverSettings = await this.repository.getAccountServerSettings(accountId);
    const lastSync: string = await this.repository.getSetting(`last_sync_${accountId}`, '0');
    this.lastSyncText = this.formatLastSync(Number.parseInt(lastSync));
  }

  private formatLastSync(timestamp: number): string {
    if (!timestamp || timestamp <= 0) return '尚未同步';
    const minutes: number = Math.floor((Date.now() - timestamp) / 60000);
    if (minutes < 1) return '刚刚同步';
    if (minutes < 60) return `${minutes} 分钟前同步`;
    const hours: number = Math.floor(minutes / 60);
    return hours < 24 ? `${hours} 小时前同步` : `${Math.floor(hours / 24)} 天前同步`;
  }

  
  private async toggleSync(enabled: boolean): Promise<void> {
    if (!this.account) return;
    try {
      await this.repository.setAccountSyncEnabled(this.account.id, enabled);
      this.account = new EmailAccount(this.account.id, this.account.email, this.account.displayName,
        this.account.provider, this.account.color, this.account.credentialRef, this.account.unreadCount, enabled);
    } catch (error) {
      showToast(`更新同步设置失败：${error}`);
    }
  }

  private async testConnection(): Promise<void> {
    if (!this.account || !this.serverSettings || this.isWorking) return;
    this.isWorking = true;
    this.operationStatus = '正在验证 IMAP 登录';
    try {
      let secret: string = await this.repository.readAccountCredential(this.account.id);
      if (secret.length === 0) throw new Error('账户没有可用的授权凭据');
      if (this.serverSettings.incoming.authentication === AuthenticationMethod.OAUTH2) {
        const resolved: OAuthResolvedCredential = await this.oauthService.resolveAccessToken(
          this.account.provider, secret);
        secret = resolved.accessToken;
        if (resolved.wasRefreshed) {
          await this.repository.updateAccountCredential(this.account.id, resolved.serializedCredential);
        }
      }
      const username: string = this.serverSettings.incoming.username.length > 0 ?
        this.serverSettings.incoming.username : this.account.email;
      const result: ProbeResult = await this.probe.validateImapLogin(
        this.serverSettings.incoming, username, secret);
      this.operationStatus = result.reachable ? `连接正常 · ${result.latencyMs} ms` : result.detail;
      showToast(result.reachable ? '账户连接正常' : `连接失败：${result.detail}`);
    } catch (error) {
      this.operationStatus = `${error}`;
      showToast(`连接失败：${error}`);
    } finally {
      this.isWorking = false;
    }
  }

  private async syncNow(): Promise<void> {
    if (!this.account || this.isWorking) return;
    if (!this.account.syncEnabled) {
      showToast('请先启用此账户的同步');
      return;
    }
    this.isWorking = true;
    this.operationStatus = '正在同步邮件';
    try {
      const result: AccountSyncResult = await this.syncService.synchronize(this.account);
      if (result.errorMessage.length > 0) throw new Error(result.errorMessage);
      this.operationStatus = `同步完成 · 更新 ${result.receivedCount} 封邮件`;
      this.lastSyncText = '刚刚同步';
      showToast(this.operationStatus);
      await this.loadAccount(this.account.id);
    } catch (error) {
      this.operationStatus = `同步失败：${describeError(error)}`;
      showToast(this.operationStatus);
    } finally {
      this.isWorking = false;
    }
  }

  private confirmDelete(): void {
    if (!this.account) return;
    AlertDialog.show({
      title: '删除账户',
      message: `确定从本机删除 ${this.account.email} 吗？本地邮件和待同步操作也会被移除。`,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: () => this.deleteAccount()
      }
    });
  }

  private async deleteAccount(): Promise<void> {
    if (!this.account) return;
    try {
      await this.repository.removeAccount(this.account.id);
      showToast('账户已删除');
      this.getUIContext().getRouter().back();
    } catch (error) {
      showToast(`删除账户失败：${error}`);
    }
  }

  build() {
    Column() {
      Row() {
        Button() {
          Image($r('app.media.ic_back')).width(23).height(23).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.onSurface'))
        }.width(48).height(48).backgroundColor(Color.Transparent)
          .onClick(() => this.getUIContext().getRouter().back())
        Text('账户设置').layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface'))
        Row() {}.width(48)
      }.width('100%').height(56).padding({ left: 4, right: 4 }).backgroundColor($r('app.color.surface'))

      if (this.account) {
        Scroll() {
          Column({ space: 12 }) {
            Column({ space: 12 }) {
              Stack() {
                Circle().width(68).height(68).fill(this.account.color)
                Text(findProvider(this.account.provider).shortName).fontSize(16).fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.onPrimary'))
              }
              Text(this.account.displayName).fontSize(21).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.onSurface'))
              Text(this.account.email).fontSize(14).fontColor($r('app.color.onSurfaceVariant'))
            }
            .width('100%').padding({ top: 24, bottom: 24 }).alignItems(HorizontalAlign.Center)
            .backgroundColor($r('app.color.surfaceLowest'))
            .border({ width: 1, color: $r('app.color.cardBorder') })
            .borderRadius(ThunderbirdTheme.cardRadius)

            Row() {
              Column({ space: 4 }) {
                Text('同步此账户').fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.onSurface'))
                Text(this.account.syncEnabled ? '账户会参与手动和后台同步' : '账户同步已暂停')
                  .fontSize(12).fontColor($r('app.color.onSurfaceVariant'))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.account.syncEnabled })
                .width(48).height(30).selectedColor($r('app.color.primary'))
                .onChange((value: boolean) => this.toggleSync(value))
            }
            .width('100%').constraintSize({ minHeight: 76 })
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor($r('app.color.surfaceLowest'))
            .border({ width: 1, color: $r('app.color.cardBorder') })
            .borderRadius(ThunderbirdTheme.cardRadius)

            Column({ space: 12 }) {
              Row() {
                Text('上次同步').fontSize(14).fontColor($r('app.color.onSurfaceVariant'))
                Blank()
                Text(this.lastSyncText).fontSize(13).fontColor($r('app.color.onSurface'))
              }.width('100%')
              if (this.serverSettings) {
                Divider().color($r('app.color.outlineVariant'))
                Row() {
                  Text('接收服务器').fontSize(14).fontColor($r('app.color.onSurfaceVariant'))
                  Blank()
                  Text(`${this.serverSettings.incoming.host}:${this.serverSettings.incoming.port}`)
                    .fontSize(13).fontColor($r('app.color.onSurface')).maxLines(1)
                }.width('100%')
                Row() {
                  Text('发送服务器').fontSize(14).fontColor($r('app.color.onSurfaceVariant'))
                  Blank()
                  Text(`${this.serverSettings.outgoing.host}:${this.serverSettings.outgoing.port}`)
                    .fontSize(13).fontColor($r('app.color.onSurface')).maxLines(1)
                }.width('100%')
              }
              if (this.operationStatus.length > 0) {
                Text(this.operationStatus).width('100%').fontSize(12).lineHeight(18)
                  .fontColor($r('app.color.primary'))
                  .padding(10).backgroundColor($r('app.color.primaryContainer'))
                  .borderRadius(ThunderbirdTheme.controlRadius)
              }
            }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
              .backgroundColor($r('app.color.surfaceLowest'))
              .border({ width: 1, color: $r('app.color.cardBorder') })
              .borderRadius(ThunderbirdTheme.cardRadius)

            Row({ space: 10 }) {
              Button('测试连接').layoutWeight(1).height(46).enabled(!this.isWorking)
                .backgroundColor($r('app.color.surfaceLowest')).fontColor($r('app.color.primary'))
                .border({ width: 1, color: $r('app.color.outlineVariant') })
                .borderRadius(ThunderbirdTheme.controlRadius).onClick(() => this.testConnection())
              Button('立即同步').layoutWeight(1).height(46).enabled(!this.isWorking && this.account.syncEnabled)
                .backgroundColor($r('app.color.primary')).fontColor($r('app.color.onPrimary'))
                .borderRadius(ThunderbirdTheme.controlRadius).onClick(() => this.syncNow())
            }.width('100%')

            Button('删除账户').width('100%').height(46).margin({ top: 4 })
              .fontColor($r('app.color.error')).backgroundColor($r('app.color.surfaceLowest'))
              .border({ width: 1, color: $r('app.color.error') })
              .borderRadius(ThunderbirdTheme.controlRadius).onClick(() => this.confirmDelete())
          }
          .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 28 })
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
  }
}
