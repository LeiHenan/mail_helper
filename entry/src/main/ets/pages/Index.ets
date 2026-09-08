import { LocalMailRepository } from '../data/LocalMailRepository';
import { EmailAccount, MailFolder, MailMessage } from '../model/MailModels';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { AccountSyncResult, MailAccountSyncService } from '../service/MailAccountSyncService';
import { MailNotificationService } from '../service/MailNotificationService';
import { connection } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct Index {
  private readonly foregroundSyncInterval: number = 60 * 1000;
  private repository: LocalMailRepository = LocalMailRepository.shared();
  private syncService: MailAccountSyncService = new MailAccountSyncService(this.repository);
  private notificationService: MailNotificationService = new MailNotificationService();
  private autoSyncTimer: number = -1;
  private lastAutomaticSyncAt: number = 0;
  private notificationPermissionChecked: boolean = false;
  @State private accounts: EmailAccount[] = [];
  @State private messages: MailMessage[] = [];
  @State private selectedAccountId: string = 'all';
  @State private selectedFolder: MailFolder = MailFolder.INBOX;
  @State private selectedFolderTitle: string = '统一收件箱';
  @State private starredOnly: boolean = false;
  @State private searchText: string = '';
  @State private showSearch: boolean = false;
  @State private drawerOpen: boolean = false;
  @State private showAccountSelector: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private selectedIds: string[] = [];
  @State private pendingStarIds: string[] = [];
  @State private isOpeningComposer: boolean = false;
  @State private isOpeningMessage: boolean = false;
  @State private newestFirst: boolean = true;
  @State private compactMode: boolean = false;
  @State private showMessagePreview: boolean = true;
  @State private swipeEnabled: boolean = true;
  @State private swipeDelete: boolean = false;
  @State private isSyncing: boolean = false;
  @State private isLoadingOlder: boolean = false;
  @State private hasMoreHistory: boolean = true;
  @State private syncStatusText: string = '';
  @State private inboxUnreadCount: number = 0;
  @State private starredCount: number = 0;
  @State private draftsCount: number = 0;
  @State private sentCount: number = 0;
  @State private archiveCount: number = 0;
  @State private spamCount: number = 0;
  @State private trashCount: number = 0;

  onPageShow(): void {
    this.notificationService.clearMailIndicator();
    this.resumeMailbox();
  }

  onPageHide(): void {
    this.stopForegroundSync();
  }

  private async resumeMailbox(): Promise<void> {
    await this.refreshMailboxState();
    await this.loadDisplaySettings();
    await this.ensureNotificationPermission();
    this.startForegroundSync();
    await this.runAutomaticSync();
  }

  private async ensureNotificationPermission(): Promise<void> {
    if (this.notificationPermissionChecked) {
      return;
    }
    const notificationsEnabled: boolean =
      (await this.repository.getSetting('notifications_enabled', 'true')) === 'true';
    if (!notificationsEnabled) {
      return;
    }
    this.notificationPermissionChecked = true;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const granted: boolean = await this.notificationService.requestPermission(context);
    if (!granted) {
      await this.repository.setSetting('notifications_enabled', 'false');
      this.showToast('系统通知权限未开启，可在设置中重新启用新邮件通知');
    }
  }

  private startForegroundSync(): void {
    this.stopForegroundSync();
    this.autoSyncTimer = setInterval(() => {
      this.runAutomaticSync();
    }, this.foregroundSyncInterval);
  }

  private stopForegroundSync(): void {
    if (this.autoSyncTimer >= 0) {
      clearInterval(this.autoSyncTimer);
      this.autoSyncTimer = -1;
    }
  }

  private async runAutomaticSync(): Promise<void> {
    const now: number = Date.now();
    if (this.isSyncing || now - this.lastAutomaticSyncAt < 15 * 1000) {
      return;
    }
    this.lastAutomaticSyncAt = now;
    await this.syncAccounts(false);
  }

  private async refreshMailboxState(): Promise<void> {
    await this.loadAccounts();
    await this.loadMessages();
  }

  private openDrawer(): void {
    this.drawerOpen = true;
    this.refreshMailboxState().catch(() => {});
  }

  private toggleSearch(): void {
    if (this.showSearch) {
      this.showSearch = false;
      this.searchText = '';
      return;
    }
    this.showSearch = true;
  }

  private async loadDisplaySettings(): Promise<void> {
    this.compactMode = (await this.repository.getSetting('mail_list_compact', 'false')) === 'true';
    this.showMessagePreview = (await this.repository.getSetting('mail_list_preview', 'true')) === 'true';
    this.swipeEnabled = (await this.repository.getSetting('swipe_enabled', 'true')) === 'true';
    this.swipeDelete = (await this.repository.getSetting('swipe_delete', 'false')) === 'true';
  }

  private async loadAccounts(): Promise<void> {
    this.accounts = await this.repository.listAccounts();
    if (this.selectedAccountId !== 'all' &&
      !this.accounts.some((account: EmailAccount) => account.id === this.selectedAccountId)) {
      this.selectedAccountId = 'all';
      this.selectedFolderTitle = '统一收件箱';
      this.selectedFolder = MailFolder.INBOX;
      this.starredOnly = false;
    }
  }

  private async loadMessages(): Promise<void> {
    this.isRefreshing = true;
    const result: MailMessage[] = this.starredOnly ?
      await this.repository.listStarredMessages(this.selectedAccountId) :
      await this.repository.listMessages(this.selectedAccountId, this.selectedFolder);
    this.messages = this.newestFirst ? result : result.slice().reverse();
    await this.loadFolderCounts();
    this.isRefreshing = false;
  }

  private async loadFolderCounts(): Promise<void> {
    const inbox: MailMessage[] = await this.repository.listMessages(this.selectedAccountId, MailFolder.INBOX);
    this.inboxUnreadCount = inbox.filter((message: MailMessage) => !message.isRead).length;
    this.starredCount = (await this.repository.listStarredMessages(this.selectedAccountId)).length;
    this.draftsCount = (await this.repository.listMessages(this.selectedAccountId, MailFolder.DRAFTS)).length;
    this.sentCount = (await this.repository.listMessages(this.selectedAccountId, MailFolder.SENT)).length;
    this.archiveCount = (await this.repository.listMessages(this.selectedAccountId, MailFolder.ARCHIVE)).length;
    this.spamCount = (await this.repository.listMessages(this.selectedAccountId, MailFolder.SPAM)).length;
    this.trashCount = (await this.repository.listMessages(this.selectedAccountId, MailFolder.TRASH)).length;
  }

  private visibleMessages(): MailMessage[] {
    const keyword: string = this.searchText.trim().toLowerCase();
    return this.messages.filter((message: MailMessage) => keyword.length === 0 ||
      message.sender.name.toLowerCase().includes(keyword) ||
      message.sender.address.toLowerCase().includes(keyword) ||
      message.subject.toLowerCase().includes(keyword) ||
      message.preview.toLowerCase().includes(keyword));
  }

  private listTime(receivedAt: string): string {
    const value: string = receivedAt.trim();
    if (/^\d{1,2}:\d{2}$/.test(value)) {
      return value;
    }
    return value.replace(/\s+\d{1,2}:\d{2}$/, '');
  }

  private accountById(accountId: string): EmailAccount | undefined {
    return this.accounts.find((account: EmailAccount) => account.id === accountId);
  }

  private currentAccountTitle(): string {
    if (this.selectedAccountId === 'all') {
      return '统一账户';
    }
    return this.accountById(this.selectedAccountId)?.displayName ?? '邮箱账户';
  }

  private currentAccountSubtitle(): string {
    if (this.selectedAccountId === 'all') {
      return `${this.accounts.length} 个账户`;
    }
    return this.accountById(this.selectedAccountId)?.email ?? '';
  }

  private selectFolder(title: string, folder: MailFolder, starredOnly: boolean = false): void {
    this.selectedFolderTitle = title;
    this.selectedFolder = folder;
    this.starredOnly = starredOnly;
    this.drawerOpen = false;
    this.selectedIds = [];
    this.hasMoreHistory = true;
    this.loadMessages();
  }

  private selectAccount(accountId: string): void {
    this.selectedAccountId = accountId;
    this.showAccountSelector = false;
    this.selectedFolderTitle = accountId === 'all' ? '统一收件箱' : '收件箱';
    this.selectedFolder = MailFolder.INBOX;
    this.starredOnly = false;
    this.hasMoreHistory = true;
    this.loadMessages();
  }

  private toggleSelection(messageId: string): void {
    if (this.selectedIds.includes(messageId)) {
      this.selectedIds = this.selectedIds.filter((id: string) => id !== messageId);
    } else {
      this.selectedIds = this.selectedIds.concat([messageId]);
    }
  }

  private async toggleReadSelected(): Promise<void> {
    const accountIds: string[] = await this.accountIdsForMessages(this.selectedIds);
    for (let index: number = 0; index < this.selectedIds.length; index++) {
      await this.repository.toggleRead(this.selectedIds[index]);
    }
    this.selectedIds = [];
    await this.loadMessages();
    await this.pushAccountOperations(accountIds);
  }

  private async archiveSelected(): Promise<void> {
    const accountIds: string[] = await this.accountIdsForMessages(this.selectedIds);
    await this.repository.moveMessages(this.selectedIds, MailFolder.ARCHIVE);
    this.selectedIds = [];
    this.showToast('邮件已归档');
    await this.loadMessages();
    await this.pushAccountOperations(accountIds);
  }

  private async deleteSelected(): Promise<void> {
    const accountIds: string[] = await this.accountIdsForMessages(this.selectedIds);
    await this.repository.deleteMessages(this.selectedIds);
    this.selectedIds = [];
    this.showToast('邮件已移至垃圾箱');
    await this.loadMessages();
    await this.pushAccountOperations(accountIds);
  }

  private selectAllVisible(): void {
    this.selectedIds = this.visibleMessages().map((message: MailMessage) => message.id);
  }

  private async moveSelectedTo(folder: MailFolder, successMessage: string): Promise<void> {
    if (this.selectedIds.length === 0) {
      return;
    }
    const accountIds: string[] = await this.accountIdsForMessages(this.selectedIds);
    await this.repository.moveMessages(this.selectedIds, folder);
    this.selectedIds = [];
    this.showToast(successMessage);
    await this.loadMessages();
    await this.pushAccountOperations(accountIds);
  }

  private toggleSortOrder(): void {
    this.newestFirst = !this.newestFirst;
    this.messages = this.messages.slice().reverse();
  }

  private listMoreMenuItems(): MenuElement[] {
    return [
      {
        value: this.newestFirst ? '时间：从旧到新' : '时间：从新到旧',
        icon: $r('app.media.ic_sync'),
        action: () => this.toggleSortOrder()
      },
      {
        value: '选择当前列表',
        icon: $r('app.media.ic_check'),
        action: () => this.selectAllVisible()
      },
      {
        value: '同步邮件',
        icon: $r('app.media.ic_sync'),
        action: () => this.syncAccounts()
      }
    ];
  }

  private async syncAccounts(showFeedback: boolean = true): Promise<void> {
    if (this.isSyncing) {
      return;
    }
    this.isSyncing = true;
    if (showFeedback) {
      this.syncStatusText = '正在连接邮件服务器';
    }
    try {
      const wifiOnly: boolean = (await this.repository.getSetting('sync_wifi_only', 'false')) === 'true';
      if (wifiOnly) {
        try {
          const handle: connection.NetHandle = await connection.getDefaultNet();
          const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(handle);
          if (!capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
            if (showFeedback) {
              this.showToast('当前不是 Wi-Fi 网络，已暂停同步');
            }
            return;
          }
        } catch (_error) {
          if (showFeedback) {
            this.showToast('无法确认当前网络，已暂停仅 Wi-Fi 同步');
          }
          return;
        }
      }
      const targets: EmailAccount[] = this.accounts.filter((account: EmailAccount) =>
        account.syncEnabled && (this.selectedAccountId === 'all' || account.id === this.selectedAccountId));
      if (targets.length === 0) {
        if (showFeedback) {
          this.showToast('没有启用同步的账户');
        }
        return;
      }
      let successCount: number = 0;
      let mailCount: number = 0;
      const failures: string[] = [];
      for (let index: number = 0; index < targets.length; index++) {
        if (showFeedback) {
          this.syncStatusText = `正在同步 ${targets[index].displayName}`;
        }
        const result: AccountSyncResult = await this.syncService.synchronize(targets[index]);
        if (result.errorMessage.length === 0) {
          successCount++;
          mailCount += result.receivedCount;
        } else {
          failures.push(`${result.accountName}：${result.errorMessage}`);
        }
        await this.refreshMailboxState();
      }
      const notificationsEnabled: boolean =
        (await this.repository.getSetting('notifications_enabled', 'true')) === 'true';
      const quietHours: boolean =
        (await this.repository.getSetting('notifications_quiet_hours', 'false')) === 'true';
      const currentHour: number = new Date().getHours();
      const inQuietHours: boolean = quietHours && (currentHour >= 22 || currentHour < 8);
      if (notificationsEnabled && !inQuietHours && mailCount > 0) {
        try {
          const notificationPublished: boolean = await this.notificationService.notifyNewMail(mailCount);
          if (!notificationPublished) {
            await this.repository.setSetting('last_notification_error', '系统通知权限未开启');
          } else {
            await this.repository.setSetting('last_notification_error', '');
          }
        } catch (error) {
          await this.repository.setSetting('last_notification_error', `${error}`).catch(() => {});
          if (showFeedback) {
            this.showToast(`新邮件通知发送失败：${error}`);
          }
        }
      }
      if (!showFeedback && !inQuietHours && mailCount > 0) {
        this.showToast(`收到 ${mailCount} 封新邮件`);
      }
      if (showFeedback) {
        if (failures.length === 0) {
          this.showToast(`同步完成，共更新 ${mailCount} 封邮件`);
        } else if (successCount > 0) {
          this.showToast(`已同步 ${successCount} 个账户；${failures[0]}`);
        } else {
          this.showToast(failures[0]);
        }
      }
    } finally {
      this.isSyncing = false;
      this.syncStatusText = '';
    }
  }

  private async loadOlderMessages(): Promise<void> {
    if (this.isLoadingOlder || this.starredOnly || !this.hasMoreHistory) {
      return;
    }
    if (this.selectedFolder !== MailFolder.INBOX && this.selectedFolder !== MailFolder.SPAM &&
      this.selectedFolder !== MailFolder.TRASH) {
      this.hasMoreHistory = false;
      return;
    }
    const targets: EmailAccount[] = this.accounts.filter((account: EmailAccount) =>
      account.syncEnabled && (this.selectedAccountId === 'all' || account.id === this.selectedAccountId));
    if (targets.length === 0) {
      return;
    }
    this.isLoadingOlder = true;
    let loadedCount: number = 0;
    let fetchedCount: number = 0;
    let serverHasMore: boolean = false;
    const failures: string[] = [];
    try {
      for (let index: number = 0; index < targets.length; index++) {
        const result: AccountSyncResult = await this.syncService.loadOlder(
          targets[index], this.selectedFolder, 50);
        loadedCount += result.receivedCount;
        fetchedCount += result.fetchedCount;
        serverHasMore = serverHasMore || result.hasMoreHistory;
        if (result.errorMessage.length > 0) {
          failures.push(`${result.accountName}：${result.errorMessage}`);
        }
      }
      await this.loadMessages();
      this.hasMoreHistory = failures.length > 0 || serverHasMore;
      if (loadedCount > 0) {
        this.showToast(`已加载 ${loadedCount} 封更早邮件`);
      } else if (failures.length > 0) {
        this.showToast(failures[0]);
      } else if (serverHasMore) {
        this.showToast(fetchedCount > 0 ? '已跳过本地重复邮件，请继续加载' : '服务器仍有更早邮件，请继续加载');
      } else {
        this.showToast('没有更早的邮件了');
      }
    } finally {
      this.isLoadingOlder = false;
    }
  }

  private selectionMoreMenuItems(): MenuElement[] {
    return [
      {
        value: '移到收件箱',
        icon: $r('app.media.ic_inbox'),
        action: () => this.moveSelectedTo(MailFolder.INBOX, '邮件已移到收件箱')
      },
      {
        value: '标为垃圾邮件',
        icon: $r('app.media.ic_spam'),
        action: () => this.moveSelectedTo(MailFolder.SPAM, '邮件已移到垃圾邮件')
      },
      {
        value: '选择当前列表',
        icon: $r('app.media.ic_check'),
        action: () => this.selectAllVisible()
      }
    ];
  }

  private async toggleStar(message: MailMessage): Promise<void> {
    if (this.pendingStarIds.includes(message.id)) {
      return;
    }
    const previousValue: boolean = message.isStarred;
    this.pendingStarIds = this.pendingStarIds.concat([message.id]);
    this.messages = this.messages.map((item: MailMessage) =>
      item.id === message.id ? this.copyMessageWithStar(item, !previousValue) : item);
    try {
      await this.repository.toggleStar(message.id);
      if (this.starredOnly && previousValue) {
        this.messages = this.messages.filter((item: MailMessage) => item.id !== message.id);
      }
      await this.loadFolderCounts();
      this.showToast(previousValue ? '已取消星标' : '已添加星标');
      await this.pushAccountOperations([message.accountId]);
    } catch (error) {
      this.messages = this.messages.map((item: MailMessage) =>
        item.id === message.id ? this.copyMessageWithStar(item, previousValue) : item);
      this.showToast(`星标操作失败：${error}`);
    } finally {
      this.pendingStarIds = this.pendingStarIds.filter((id: string) => id !== message.id);
    }
  }

  private copyMessageWithStar(message: MailMessage, isStarred: boolean): MailMessage {
    return new MailMessage(message.id, message.accountId, message.folder, message.sender,
      message.recipients, message.subject, message.preview, message.plainBody, message.receivedAt,
      message.isRead, isStarred, message.hasAttachments, message.htmlBody);
  }

  private messageRenderKey(message: MailMessage): string {
    const selected: string = this.selectedIds.includes(message.id) ? 'selected' : 'normal';
    const starred: string = message.isStarred ? 'starred' : 'plain';
    const read: string = message.isRead ? 'read' : 'unread';
    return `${message.id}_${selected}_${starred}_${read}`;
  }

  private async openComposer(): Promise<void> {
    if (this.isOpeningComposer) {
      return;
    }
    this.isOpeningComposer = true;
    try {
      const preferredAccountId: string = this.selectedAccountId === 'all' ? '' : this.selectedAccountId;
      await this.getUIContext().getRouter().pushUrl({
        url: 'pages/Compose',
        params: { accountId: preferredAccountId }
      });
    } catch (error) {
      this.showToast(`无法打开写信页面：${error}`);
    } finally {
      this.isOpeningComposer = false;
    }
  }

  private async openMessage(message: MailMessage): Promise<void> {
    if (this.selectedIds.length > 0) {
      this.toggleSelection(message.id);
      return;
    }
    if (this.isOpeningMessage) {
      return;
    }
    this.isOpeningMessage = true;
    try {
      if (message.folder === MailFolder.DRAFTS) {
        await this.getUIContext().getRouter()
          .pushUrl({ url: 'pages/Compose', params: { draftId: message.id } });
        return;
      }
      await this.repository.markRead(message.id);
      await this.loadAccounts();
      await this.loadFolderCounts();
      this.pushAccountOperations([message.accountId]).catch(() => {});
      await this.getUIContext().getRouter()
        .pushUrl({ url: 'pages/MailDetail', params: { mailId: message.id } });
    } catch (error) {
      this.showToast(`无法打开邮件：${error}`);
    } finally {
      this.isOpeningMessage = false;
    }
  }

  private async swipeToggleRead(message: MailMessage): Promise<void> {
    await this.repository.toggleRead(message.id);
    await this.loadMessages();
    await this.pushAccountOperations([message.accountId]);
  }

  private async swipeEndAction(message: MailMessage): Promise<void> {
    if (this.swipeDelete) {
      await this.repository.deleteMessages([message.id]);
      this.showToast('邮件已移至垃圾箱');
    } else {
      await this.repository.moveMessages([message.id], MailFolder.ARCHIVE);
      this.showToast('邮件已归档');
    }
    await this.loadMessages();
    await this.pushAccountOperations([message.accountId]);
  }

  private async accountIdsForMessages(messageIds: string[]): Promise<string[]> {
    const accountIds: string[] = [];
    for (let index: number = 0; index < messageIds.length; index++) {
      const message: MailMessage | undefined = await this.repository.getMessage(messageIds[index]);
      if (message && !accountIds.includes(message.accountId)) {
        accountIds.push(message.accountId);
      }
    }
    return accountIds;
  }

  private async pushAccountOperations(accountIds: string[]): Promise<void> {
    if (accountIds.length === 0) return;
    const availableAccounts: EmailAccount[] = this.accounts.length > 0 ? this.accounts :
      await this.repository.listAccounts();
    for (let index: number = 0; index < accountIds.length; index++) {
      const account: EmailAccount | undefined = availableAccounts.find((item: EmailAccount) =>
        item.id === accountIds[index]);
      if (!account) continue;
      const result: AccountSyncResult = await this.syncService.pushPendingOperations(account);
      if (result.errorMessage.length > 0) {
        this.showToast(`本地操作已保存，将稍后同步：${result.errorMessage}`);
      }
    }
  }

  @Builder
  private swipeReadBuilder(message: MailMessage) {
    Row({ space: 6 }) {
      Image($r('app.media.ic_mail')).width(22).height(22).objectFit(ImageFit.Contain)
      Text(message.isRead ? '未读' : '已读').fontSize(13).fontColor(ThunderbirdTheme.onPrimary)
    }.width(82).height('100%').justifyContent(FlexAlign.Center).backgroundColor(ThunderbirdTheme.primary)
  }

  @Builder
  private swipeEndBuilder() {
    Row({ space: 6 }) {
      Image(this.swipeDelete ? $r('app.media.ic_delete') : $r('app.media.ic_archive'))
        .width(22).height(22).objectFit(ImageFit.Contain)
      Text(this.swipeDelete ? '删除' : '归档').fontSize(13).fontColor(ThunderbirdTheme.onPrimary)
    }.width(82).height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor(this.swipeDelete ? ThunderbirdTheme.error : ThunderbirdTheme.primary)
  }

  private swipeOptions(message: MailMessage): SwipeActionOptions {
    if (!this.swipeEnabled) {
      return {};
    }
    return {
      start: {
        builder: () => { this.swipeReadBuilder(message) },
        actionAreaDistance: 82,
        onAction: () => this.swipeToggleRead(message)
      },
      end: {
        builder: () => { this.swipeEndBuilder() },
        actionAreaDistance: 82,
        onAction: () => this.swipeEndAction(message)
      }
    };
  }

  private showToast(_message: string): void {
  }

  @Builder
  private roundIconButton(icon: Resource, action: () => void) {
    Button() {
      Image(icon).width(23).height(23).objectFit(ImageFit.Contain)
    }
    .width(ThunderbirdTheme.touchTarget).height(ThunderbirdTheme.touchTarget)
    .backgroundColor(Color.Transparent).borderRadius(ThunderbirdTheme.pillRadius).onClick(action)
  }

  @Builder
  private regularTopBar() {
    Column() {
      Row() {
        this.roundIconButton($r('app.media.ic_menu'), () => this.openDrawer())
        Text(this.selectedFolderTitle)
          .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThunderbirdTheme.onSurface).maxLines(1)
        this.roundIconButton($r('app.media.ic_search'), () => this.toggleSearch())
        Button() {
          Image($r('app.media.ic_more')).width(23).height(23).objectFit(ImageFit.Contain)
        }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
        .bindMenu(this.listMoreMenuItems(), { placement: Placement.BottomRight, enableArrow: true })
      }
      .width('100%').height(56).padding({ left: 6, right: 6 })

      if (this.showSearch) {
        Row() {
          Row({ space: 8 }) {
            Image($r('app.media.ic_search')).width(20).height(20).objectFit(ImageFit.Contain)
              .fillColor(ThunderbirdTheme.onSurfaceVariant)
            TextInput({ placeholder: '搜索邮件', text: this.searchText })
              .layoutWeight(1).height(42).fontSize(15).backgroundColor(Color.Transparent)
              .padding({ left: 0, right: 0 })
              .onChange((value: string) => this.searchText = value)
            if (this.searchText.length > 0) {
              Button() {
                Image($r('app.media.ic_close')).width(18).height(18).objectFit(ImageFit.Contain)
              }
              .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
              .onClick(() => this.searchText = '')
            }
          }
          .width('100%').height(46).padding({ left: 14, right: 2 })
          .backgroundColor(ThunderbirdTheme.surfaceContainer)
          .borderRadius(ThunderbirdTheme.pillRadius)
        }.width('100%').padding({ left: 16, right: 16, bottom: 10 })
      }
    }
    .width('100%').backgroundColor(ThunderbirdTheme.surface)
  }

  @Builder
  private selectionTopBar() {
    Row() {
      this.roundIconButton($r('app.media.ic_close'), () => this.selectedIds = [])
      Text(`${this.selectedIds.length}`)
        .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface)
      this.roundIconButton($r('app.media.ic_mail'), () => this.toggleReadSelected())
      this.roundIconButton($r('app.media.ic_archive'), () => this.archiveSelected())
      this.roundIconButton($r('app.media.ic_delete'), () => this.deleteSelected())
      Button() {
        Image($r('app.media.ic_more')).width(23).height(23).objectFit(ImageFit.Contain)
      }
      .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
      .bindMenu(this.selectionMoreMenuItems(), { placement: Placement.BottomRight, enableArrow: true })
    }
    .width('100%').height(56).padding({ left: 6, right: 6 })
    .backgroundColor(ThunderbirdTheme.infoContainer)
  }

  @Builder
  private avatar(message: MailMessage) {
    Stack() {
      Circle().width(42).height(42)
        .fill(this.accountById(message.accountId)?.color ?? ThunderbirdTheme.primary)
      if (this.selectedIds.includes(message.id)) {
        Circle().width(42).height(42).fill(ThunderbirdTheme.primary)
        Image($r('app.media.ic_check')).width(22).height(22).objectFit(ImageFit.Contain)
      } else {
        Text(message.sender.name.substring(0, 1).toUpperCase())
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onPrimary)
      }
    }
    .width(44).height(44).onClick(() => this.toggleSelection(message.id))
  }

  @Builder
  private messageItem(message: MailMessage) {
    Row({ space: 9 }) {
      if (!message.isRead) {
        Rect().width(3).height(this.compactMode ? 40 : 54).radius(2).fill(ThunderbirdTheme.primary)
      } else {
        Row() {}.width(3).height(this.compactMode ? 40 : 54)
      }
      this.avatar(message)
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(message.sender.name)
            .layoutWeight(1).fontSize(15)
            .fontWeight(message.isRead ? FontWeight.Regular : FontWeight.Bold)
            .fontColor(message.isRead ? ThunderbirdTheme.onSurfaceVariant : ThunderbirdTheme.onSurface)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.listTime(message.receivedAt)).width(54).textAlign(TextAlign.End).fontSize(12).lineHeight(17)
            .fontWeight(message.isRead ? FontWeight.Regular : FontWeight.Medium)
            .fontColor(message.isRead ? ThunderbirdTheme.onSurfaceVariant : ThunderbirdTheme.primary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
        Text(message.subject.length > 0 ? message.subject : '(无主题)')
          .width('100%').fontSize(14)
          .fontWeight(message.isRead ? FontWeight.Regular : FontWeight.Bold)
          .fontColor(message.isRead ? ThunderbirdTheme.onSurfaceVariant : ThunderbirdTheme.onSurface)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.showMessagePreview && !this.compactMode) {
          Row({ space: 6 }) {
            Text(message.preview)
              .layoutWeight(1).fontSize(13).fontColor(ThunderbirdTheme.onSurfaceVariant)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (message.hasAttachments) {
              Image($r('app.media.ic_attachment')).width(16).height(16).objectFit(ImageFit.Contain)
            }
          }.width('100%')
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
      .onClick(() => this.openMessage(message))
      .gesture(LongPressGesture({ repeat: false }).onAction(() => this.toggleSelection(message.id)))
      Button() {
        Image(message.isStarred ? $r('app.media.ic_star_filled') : $r('app.media.ic_star'))
          .width(21).height(21).objectFit(ImageFit.Contain)
      }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
        .onClick(() => this.toggleStar(message))
    }
    .width('100%').height(this.compactMode ? 68 : 86)
    .padding({ left: 10, right: 8, top: this.compactMode ? 7 : 9, bottom: this.compactMode ? 7 : 9 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.selectedIds.includes(message.id) ? ThunderbirdTheme.infoContainer :
      ThunderbirdTheme.surfaceLowest)
    .border({ width: 1, color: this.selectedIds.includes(message.id) ?
      ThunderbirdTheme.primary : ThunderbirdTheme.cardBorder })
    .borderRadius(ThunderbirdTheme.cardRadius)
  }

  @Builder
  private folderItem(icon: Resource, label: string, count: number, active: boolean,
    folder: MailFolder, starredOnly: boolean = false) {
    Row({ space: 16 }) {
      Image(icon).width(24).height(24).objectFit(ImageFit.Contain)
        .fillColor(active ? ThunderbirdTheme.primary : ThunderbirdTheme.onSurfaceVariant)
      Text(label).layoutWeight(1).fontSize(15)
        .fontWeight(active ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(active ? ThunderbirdTheme.primary : ThunderbirdTheme.onSurface)
      if (count > 0) {
        Text(`${count}`).fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
      }
    }
    .width('100%').height(48).padding({ left: 16, right: 16 })
    .margin({ left: 8, right: 8 })
    .backgroundColor(active ? ThunderbirdTheme.primaryContainer : Color.Transparent)
    .borderRadius(ThunderbirdTheme.pillRadius)
    .onClick(() => this.selectFolder(label, folder, starredOnly))
  }

  @Builder
  private drawerContent() {
    Column() {
      Row({ space: 14 }) {
        Stack() {
          Circle().width(48).height(48).fill(ThunderbirdTheme.primary)
          if (this.selectedAccountId === 'all') {
            Image($r('app.media.ic_mail')).width(24).height(24).objectFit(ImageFit.Contain)
              .fillColor(ThunderbirdTheme.onPrimary)
          } else {
            Text(this.currentAccountTitle().substring(0, 1))
              .fontSize(19).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onPrimary)
          }
        }
        Column({ space: 3 }) {
          Text(this.currentAccountTitle()).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor(ThunderbirdTheme.onSurface).maxLines(1)
          Text(this.currentAccountSubtitle()).fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant).maxLines(1)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Image(this.showAccountSelector ? $r('app.media.ic_chevron_up') : $r('app.media.ic_chevron_down'))
          .width(22).height(22).objectFit(ImageFit.Contain)
      }
      .width('100%').height(80).padding({ left: 22, right: 18 })
      .onClick(() => this.showAccountSelector = !this.showAccountSelector)
      Divider().color(ThunderbirdTheme.outlineVariant)

      if (this.showAccountSelector) {
        List() {
          ListItem() {
            Row({ space: 16 }) {
              Stack() {
                Circle().width(32).height(32).fill(ThunderbirdTheme.primary)
                Image($r('app.media.ic_mail')).width(18).height(18).objectFit(ImageFit.Contain)
                  .fillColor(ThunderbirdTheme.onPrimary)
              }
              Text('统一账户').layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(ThunderbirdTheme.onSurface)
              Text(`${this.accounts.reduce((sum: number, account: EmailAccount) => sum + account.unreadCount, 0)}`)
                .fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
            }
            .width('100%').height(58).padding({ left: 24, right: 20 })
            .backgroundColor(this.selectedAccountId === 'all' ? ThunderbirdTheme.infoContainer : Color.Transparent)
            .onClick(() => this.selectAccount('all'))
          }
          ForEach(this.accounts, (account: EmailAccount) => {
            ListItem() {
              Row({ space: 16 }) {
                Circle().width(30).height(30).fill(account.color)
                Column({ space: 2 }) {
                  Text(account.displayName).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(ThunderbirdTheme.onSurface).maxLines(1)
                  Text(account.email).fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant).maxLines(1)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                if (account.unreadCount > 0) {
                  Text(`${account.unreadCount}`).fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
                }
              }
              .width('100%').height(58).padding({ left: 24, right: 20 })
              .backgroundColor(this.selectedAccountId === account.id ? ThunderbirdTheme.infoContainer : Color.Transparent)
              .onClick(() => this.selectAccount(account.id))
            }
          }, (account: EmailAccount) => account.id)
        }
        .layoutWeight(1).width('100%').scrollBar(BarState.Off)
      } else {
        Column({ space: 2 }) {
          this.folderItem($r('app.media.ic_inbox'), this.selectedAccountId === 'all' ? '统一收件箱' : '收件箱',
            this.inboxUnreadCount,
            this.selectedFolder === MailFolder.INBOX && !this.starredOnly, MailFolder.INBOX)
          this.folderItem($r('app.media.ic_star'), '星标邮件', this.starredCount,
            this.starredOnly, MailFolder.INBOX, true)
          this.folderItem($r('app.media.ic_draft'), '草稿', this.draftsCount,
            this.selectedFolder === MailFolder.DRAFTS, MailFolder.DRAFTS)
          this.folderItem($r('app.media.ic_sent'), '已发送', this.sentCount,
            this.selectedFolder === MailFolder.SENT, MailFolder.SENT)
          this.folderItem($r('app.media.ic_archive'), '归档', this.archiveCount,
            this.selectedFolder === MailFolder.ARCHIVE, MailFolder.ARCHIVE)
          this.folderItem($r('app.media.ic_spam'), '垃圾邮件', this.spamCount,
            this.selectedFolder === MailFolder.SPAM, MailFolder.SPAM)
          this.folderItem($r('app.media.ic_trash'), '垃圾箱', this.trashCount,
            this.selectedFolder === MailFolder.TRASH, MailFolder.TRASH)
        }.layoutWeight(1).width('100%').padding({ top: 10 })
      }

      Divider().color(ThunderbirdTheme.outlineVariant)
      Row({ space: 18 }) {
        if (this.isSyncing) {
          LoadingProgress().width(24).height(24).color(ThunderbirdTheme.primary)
        } else {
          Image($r('app.media.ic_sync')).width(24).height(24).objectFit(ImageFit.Contain)
            .fillColor(ThunderbirdTheme.onSurfaceVariant)
        }
        Column({ space: 2 }) {
          Text('同步账户').width('100%').fontSize(15).fontColor(ThunderbirdTheme.onSurface)
          if (this.syncStatusText.length > 0) {
            Text(this.syncStatusText).width('100%').fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width('100%').height(52).padding({ left: 22, right: 18 }).onClick(() => {
        this.syncAccounts();
      })
      Row({ space: 18 }) {
        Image($r('app.media.ic_settings')).width(24).height(24).objectFit(ImageFit.Contain)
          .fillColor(ThunderbirdTheme.onSurfaceVariant)
        Text('设置').layoutWeight(1).fontSize(15).fontColor(ThunderbirdTheme.onSurface)
      }
      .width('100%').height(52).padding({ left: 22, right: 18 })
      .onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/Accounts' }).catch(() => {}))
    }
    .width('86%').constraintSize({ maxWidth: 320 }).height('100%')
    .backgroundColor(ThunderbirdTheme.surfaceLowest)
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        if (this.selectedIds.length > 0) {
          this.selectionTopBar()
        } else {
          this.regularTopBar()
        }
        if (this.visibleMessages().length === 0 && !this.isRefreshing) {
          Column({ space: 12 }) {
            Image($r('app.media.ic_mail')).width(48).height(48).objectFit(ImageFit.Contain)
              .fillColor(ThunderbirdTheme.outline)
            Text(this.searchText.length > 0 ? '没有找到邮件' : '这里还没有邮件')
              .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThunderbirdTheme.onSurface)
            Text('下拉同步或切换其他文件夹').fontSize(13).fontColor(ThunderbirdTheme.onSurfaceVariant)
          }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8 }) {
            ForEach(this.visibleMessages(), (message: MailMessage) => {
              ListItem() { this.messageItem(message) }
                .swipeAction(this.swipeOptions(message))
            }, (message: MailMessage) => this.messageRenderKey(message))
            if (this.newestFirst) {
              if (this.isLoadingOlder) {
                ListItem() {
                  Row({ space: 8 }) {
                    LoadingProgress().width(18).height(18).color(ThunderbirdTheme.primary)
                    Text('正在加载更早邮件').fontSize(13).fontColor(ThunderbirdTheme.onSurfaceVariant)
                  }.width('100%').height(52).justifyContent(FlexAlign.Center)
                }
              } else if (!this.hasMoreHistory && !this.starredOnly) {
                ListItem() {
                  Text('没有更早的邮件了').width('100%').height(44).textAlign(TextAlign.Center)
                    .fontSize(13).fontColor(ThunderbirdTheme.onSurfaceVariant)
                }
              }
            }
          }
          .layoutWeight(1).width('100%').scrollBar(BarState.Off)
          .padding({ left: 16, right: 16, top: 8, bottom: 12 })
          .backgroundColor(ThunderbirdTheme.surface)
          .clip(true)
          .onReachStart(() => {
            if (this.newestFirst) {
              this.syncAccounts();
            } else {
              this.loadOlderMessages();
            }
          })
          .onReachEnd(() => {
            if (this.newestFirst) {
              this.loadOlderMessages();
            } else {
              this.syncAccounts();
            }
          })
        }
      }
      .width('100%').height('100%').backgroundColor(ThunderbirdTheme.surface)

      if (this.selectedIds.length === 0) {
        Button() {
          if (this.isOpeningComposer) {
            LoadingProgress().width(24).height(24).color(ThunderbirdTheme.primary)
          } else {
            Image($r('app.media.ic_compose')).width(25).height(25).objectFit(ImageFit.Contain)
          }
        }
          .width(56).height(56)
          .backgroundColor(ThunderbirdTheme.primary).borderRadius(28)
          .shadow({ radius: 6, color: '#1F007DFF', offsetY: 2 })
          .margin({ right: 18, bottom: 22 })
          .enabled(!this.isOpeningComposer)
          .onClick(() => this.openComposer())
      }

      if (this.drawerOpen) {
        Row() {
          this.drawerContent()
          Column() {}.layoutWeight(1).height('100%').backgroundColor('#66000000')
            .onClick(() => this.drawerOpen = false)
        }.width('100%').height('100%').align(Alignment.Start)
      }
    }
    .width('100%').height('100%')
  }
}
