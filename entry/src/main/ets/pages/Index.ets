import { LocalMailRepository } from '../data/LocalMailRepository';
import { MailSummaryQuery } from '../data/MailRepository';
import { EmailAccount, MailFolder, MailFolderCounts, MailMessage } from '../model/MailModels';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { AccountSyncResult, MailAccountSyncService } from '../service/MailAccountSyncService';
import { MailNotificationService } from '../service/MailNotificationService';
import { MailSendService, SendDeliveryResult } from '../service/MailSendService';
import { MessageCard } from '../common/components/MessageCard';
import { UndoSnackbar } from '../common/components/UndoSnackbar';
import { MailListRow } from '../common/MailListRow';
import { MailRowDataSource } from '../common/MailRowDataSource';
import { connection } from '@kit.NetworkKit';
import { Context } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { showToast } from '../common/Toast';

const DOMAIN: number = 0x0001;

// 搜索栏下方的筛选 chip：未读 / 附件 / 星标都下推到查询（参与分页），
// 只有关键词仍是客户端对已加载窗口的过滤。
enum MailListFilter {
  ALL = 'all',
  UNREAD = 'unread',
  STARRED = 'starred',
  ATTACHMENT = 'attachment'
}

// 滑动 / 批量操作的撤销记录：记住每封邮件的原文件夹，撤销就是把它们 move 回去。
class UndoEntry {
  messageId: string;
  folder: MailFolder;
  accountId: string;

  constructor(messageId: string, folder: MailFolder, accountId: string) {
    this.messageId = messageId;
    this.folder = folder;
    this.accountId = accountId;
  }
}

@Entry
@Component
struct Index {
  private readonly foregroundSyncInterval: number = 60 * 1000;
  private readonly pageSize: number = 50;
  private readonly searchDebounceMs: number = 300;
  // 骨架屏占位行（6 行，静态不闪动）。
  private readonly skeletonRowIndexes: number[] = [0, 1, 2, 3, 4, 5];
  // 抽屉宽度上限 320，滑入前的位移取略大值保证完全移出屏幕。
  private readonly drawerHiddenOffset: number = -340;
  private repository: LocalMailRepository = LocalMailRepository.shared();
  private syncService: MailAccountSyncService = new MailAccountSyncService(this.repository);
  private sendService: MailSendService = new MailSendService(this.repository);
  private notificationService: MailNotificationService = new MailNotificationService();
  private autoSyncTimer: number = -1;
  private searchTimer: number = -1;
  private searchController: TextInputController = new TextInputController();
  private lastAutomaticSyncAt: number = 0;
  // 顶部触底（列表滚回顶部）触发的同步节流：与前台定时同步互补，避免连续回弹打服务器。
  private lastReachStartSyncAt: number = 0;
  // LocalMailRepository.initialize 是幂等的：EntryAbility 已在后台建库，页面侧这里只是兜底，
  // 保证首屏不再等初始化完成（页面先渲染骨架屏）。
  private repositoryReady?: Promise<void> = undefined;
  // 列表数据源：行 = 日期分组表头 / 邮件，LazyForEach 直接消费，增删改只发精确通知。
  private dataSource: MailRowDataSource = new MailRowDataSource();
  // messages 是已加载窗口（显示顺序）。build 不读它，因此不需要 @State，改动只通过 dataSource 通知列表。
  private messages: MailMessage[] = [];
  // 搜索关键词，输入后 300ms 才更新，避免每次击键全量过滤。
  private searchKeyword: string = '';
  private hasMoreInDatabase: boolean = true;
  // 键集分页游标 = 窗口末行的 (sort_order, id)。删除 / 归档不会让它错位，因此翻页不会漏邮件。
  private cursorSortOrder: number = 0;
  private cursorMessageId: string = '';
  private pendingStarIds: Set<string> = new Set<string>();
  // 撤销窗口内待恢复的邮件；超时后直接丢弃，因为操作本身早已生效。
  private pendingUndo: UndoEntry[] = [];
  private drawerClosing: boolean = false;
  @State private accounts: EmailAccount[] = [];
  @State private selectedAccountId: string = 'all';
  @State private selectedFolder: MailFolder = MailFolder.INBOX;
  @State private selectedFolderTitle: string = '统一收件箱';
  @State private filterMode: MailListFilter = MailListFilter.ALL;
  @State private searchText: string = '';
  @State private searchFocused: boolean = false;
  @State private drawerOpen: boolean = false;
  @State private drawerOffset: number = -340;
  @State private scrimOpacity: number = 0;
  @State private showAccountSelector: boolean = false;
  @State private isRefreshing: boolean = false;
  // 冷启动时先显示骨架屏：DB 未就绪前不能落到“这里还没有邮件”的空态（会闪一帧）。
  @State private isLoadingList: boolean = true;
  @State private selectedIds: Set<string> = new Set<string>();
  @State private isOpeningComposer: boolean = false;
  @State private isOpeningMessage: boolean = false;
  @State private newestFirst: boolean = true;
  @State private compactMode: boolean = false;
  @State private showMessagePreview: boolean = true;
  @State private swipeEnabled: boolean = true;
  @State private swipeDelete: boolean = false;
  @State private isSyncing: boolean = false;
  @State private isLoadingOlder: boolean = false;
  @State private isLoadingPage: boolean = false;
  @State private displayCount: number = 0;
  @State private hasMoreHistory: boolean = true;
  @State private syncStatusText: string = '';
  @State private undoVisible: boolean = false;
  @State private undoSessionId: number = 0;
  @State private undoText: string = '';
  @State private inboxUnreadCount: number = 0;
  @State private starredCount: number = 0;
  @State private draftsCount: number = 0;
  @State private sentCount: number = 0;
  @State private archiveCount: number = 0;
  @State private spamCount: number = 0;
  @State private trashCount: number = 0;

  aboutToAppear(): void {
    // 冷启动续投发件箱：尽力而为，不阻塞首屏，也不触发整表同步。
    this.deliverPendingSends();
  }

  // 抽屉 / 多选态优先吃掉返回事件，避免直接退出页面。
  onBackPress(): boolean {
    if (this.drawerOpen) {
      this.closeDrawer();
      return true;
    }
    if (this.selectedIds.size > 0) {
      this.clearSelection();
      return true;
    }
    return false;
  }

  onPageShow(): void {
    this.notificationService.clearMailIndicator();
    // 前台恢复的整条链路都不能让一次 rejection 变成未处理异常：出错只提示 + 记日志，
    // 页面本身仍然可用（首屏列表随后由用户下拉或再次进入触发重试）。
    this.resumeMailbox().catch((error: Error) => {
      hilog.error(DOMAIN, 'Index', '恢复邮箱状态失败：%{public}s', error.message);
      // 建库失败时不能把骨架屏留在屏上：退回空列表状态，让页面仍然可操作。
      this.isLoadingList = false;
      showToast(`加载邮箱失败：${error.message}`);
    });
  }

  onPageHide(): void {
    this.stopForegroundSync();
  }

  private ensureRepositoryReady(): Promise<void> {
    if (!this.repositoryReady) {
      // getHostContext 在页面极早期可能为空：此时不建库，等下一次页面显示再试，
      // 避免把 undefined 传进 initialize 污染进程级的初始化缓存。
      const context: Context | undefined = this.getUIContext().getHostContext();
      if (!context) {
        return Promise.reject(new Error('页面上下文尚未就绪'));
      }
      this.repositoryReady = this.repository.initialize(context);
    }
    return this.repositoryReady;
  }

  private async deliverPendingSends(): Promise<void> {
    let delivered: number = 0;
    try {
      await this.ensureRepositoryReady();
      const accounts: EmailAccount[] = await this.repository.listAccounts();
      for (let index: number = 0; index < accounts.length; index++) {
        if (!accounts[index].syncEnabled) {
          continue;
        }
        try {
          const result: SendDeliveryResult = await this.sendService.deliverPendingSends(accounts[index].id);
          delivered += result.delivered;
        } catch (_error) {
          continue;
        }
      }
      if (delivered > 0) {
        await this.loadFolderCounts();
      }
    } catch (_error) {
      return;
    }
  }

  private async resumeMailbox(): Promise<void> {
    await this.ensureRepositoryReady();
    await this.refreshMailboxState();
    await this.loadDisplaySettings();
    this.startForegroundSync();
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
    this.drawerClosing = false;
    this.drawerOpen = true;
    // 抽屉只需要账户与计数：不改列表窗口，避免打开抽屉就把分页打回第一页。
    this.refreshDrawerState().catch(() => {});
  }

  private async refreshDrawerState(): Promise<void> {
    await this.loadAccounts();
    await this.loadFolderCounts();
  }

  // 抽屉退场动画结束后再卸载，避免直接消失。
  private closeDrawer(): void {
    if (!this.drawerOpen || this.drawerClosing) {
      return;
    }
    this.drawerClosing = true;
    this.getUIContext().animateTo({
      duration: 200, curve: Curve.EaseIn,
      onFinish: () => {
        this.drawerOpen = false;
        this.drawerClosing = false;
      }
    }, () => {
      this.drawerOffset = this.drawerHiddenOffset;
      this.scrimOpacity = 0;
    });
  }

  private playDrawerIn(): void {
    this.drawerOffset = this.drawerHiddenOffset;
    this.scrimOpacity = 0;
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, () => {
      this.drawerOffset = 0;
      this.scrimOpacity = 1;
    });
  }

  private onSearchChange(value: string): void {
    this.searchText = value;
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
    }
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.searchKeyword = value.trim().toLowerCase();
      this.refreshList();
    }, this.searchDebounceMs);
  }

  private cancelSearch(): void {
    this.searchController.stopEditing();
    this.searchFocused = false;
    this.resetSearch();
  }

  private resetSearch(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.searchText = '';
    this.searchKeyword = '';
    this.refreshList();
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
      this.filterMode = MailListFilter.ALL;
    }
  }

  // 只查摘要列并按键集（keyset）分页：多取一条用于判断是否还有下一页。
  // cursorActive=false 取最新一页；true 取游标之后的下一页。
  // hasMoreInDatabase 由“第一页是否取满”推出，它对整库始终成立（第一页取满 ⟺ 库里不止一页），
  // 因此同步后重探一次也是对的。
  private async fetchPage(cursorActive: boolean): Promise<MailMessage[]> {
    const query: MailSummaryQuery = new MailSummaryQuery(this.selectedAccountId, this.selectedFolder,
      this.isStarredOnly(), this.filterMode === MailListFilter.UNREAD,
      this.filterMode === MailListFilter.ATTACHMENT, this.pageSize + 1,
      this.cursorSortOrder, this.cursorMessageId, cursorActive);
    const fetched: MailMessage[] = await this.repository.listMessageSummaries(query);
    this.hasMoreInDatabase = fetched.length > this.pageSize;
    return fetched.length > this.pageSize ? fetched.slice(0, this.pageSize) : fetched;
  }

  // 游标取本页末行（数据库顺序的最后一封，即窗口里最旧的一封）。
  private advanceCursor(page: MailMessage[]): void {
    if (page.length === 0) {
      return;
    }
    const last: MailMessage = page[page.length - 1];
    this.cursorSortOrder = last.receivedAtMs;
    this.cursorMessageId = last.id;
  }

  // 切文件夹 / 换账户 / 改筛选：整窗替换，游标从头开始。
  private resetWindowAndLoad(): void {
    this.cursorSortOrder = 0;
    this.cursorMessageId = '';
    this.hasMoreInDatabase = true;
    this.loadMessages();
  }

  // 加载第一页：窗口整体替换，已加载的后续页被丢弃（换文件夹 / 账户 / 筛选 / 下拉刷新）。
  private async loadMessages(): Promise<void> {
    this.isLoadingList = true;
    try {
      const page: MailMessage[] = await this.fetchPage(false);
      this.advanceCursor(page);
      this.messages = this.newestFirst ? page : page.slice().reverse();
      this.refreshList();
      await this.loadFolderCounts();
    } finally {
      this.isLoadingList = false;
    }
  }

  // 同步完成后只做“窗口头部合并”：新邮件 prepend 进窗口，窗口后续页与翻页游标都不动。
  // 之前这里走的是整窗替换，导致每 60 秒的前台同步都把已翻的页打回第一页。
  private async mergeNewHeadMessages(): Promise<void> {
    if (this.messages.length === 0) {
      await this.loadMessages();
      return;
    }
    const latest: MailMessage[] = await this.fetchPage(false);
    const known: Set<string> = new Set<string>();
    for (let index: number = 0; index < this.messages.length; index++) {
      known.add(this.messages[index].id);
    }
    const fresh: MailMessage[] = [];
    for (let index: number = 0; index < latest.length; index++) {
      if (!known.has(latest[index].id)) {
        fresh.push(latest[index]);
      }
    }
    if (fresh.length === 0) {
      return;
    }
    // 显示顺序与查询顺序一致（newestFirst 时都在前插，否则都追加到末尾），保证分组表头顺序正确。
    this.messages = this.newestFirst ? fresh.concat(this.messages) :
      this.messages.concat(fresh.slice().reverse());
    this.refreshList();
  }

  private async loadFolderCounts(): Promise<void> {
    const counts: MailFolderCounts = await this.repository.folderCounts(this.selectedAccountId);
    this.inboxUnreadCount = counts.inboxUnread;
    this.starredCount = counts.starred;
    this.draftsCount = counts.drafts;
    this.sentCount = counts.sent;
    this.archiveCount = counts.archive;
    this.spamCount = counts.spam;
    this.trashCount = counts.trash;
  }

  // 未读 / 附件 / 星标已下推到 SQL（每一页都满足条件），这里只对已加载窗口做一次关键词过滤，
  // 不再重复判断筛选条件，避免 DB 与窗口两份判定分叉。
  private visibleMessages(): MailMessage[] {
    const keyword: string = this.searchKeyword;
    if (keyword.length === 0) {
      return this.messages;
    }
    return this.messages.filter((message: MailMessage) => {
      return message.sender.name.toLowerCase().includes(keyword) ||
        message.sender.address.toLowerCase().includes(keyword) ||
        message.subject.toLowerCase().includes(keyword) ||
        message.preview.toLowerCase().includes(keyword);
    });
  }

  // 把当前窗口发布给 LazyForEach：按日期分组拍平成行，同 key 的行会被复用，不会整表重建。
  private refreshList(): void {
    const visible: MailMessage[] = this.visibleMessages();
    this.dataSource.setRows(MailListRow.buildRows(visible));
    this.displayCount = visible.length;
  }

  private isStarredOnly(): boolean {
    return this.filterMode === MailListFilter.STARRED;
  }

  private emptyIcon(): Resource {
    if (this.searchText.length > 0) {
      return $r('app.media.ic_search');
    }
    if (this.filterMode === MailListFilter.UNREAD) {
      return $r('app.media.ic_check_circle');
    }
    if (this.filterMode === MailListFilter.ATTACHMENT) {
      return $r('app.media.ic_attachment');
    }
    return $r('app.media.ic_mail');
  }

  private emptyTitle(): string {
    if (this.searchText.length > 0) {
      return '没有找到邮件';
    }
    if (this.filterMode === MailListFilter.UNREAD) {
      return '没有未读邮件';
    }
    if (this.filterMode === MailListFilter.ATTACHMENT) {
      return '没有带附件的邮件';
    }
    if (this.isStarredOnly()) {
      return '还没有星标邮件';
    }
    return '这里还没有邮件';
  }

  private emptyHint(): string {
    if (this.searchText.length > 0) {
      return '换个关键词，或清除搜索条件';
    }
    if (this.filterMode !== MailListFilter.ALL) {
      return '切回“全部”可以查看其他邮件';
    }
    return '下拉同步或切换其他文件夹';
  }

  private titleForFolder(folder: MailFolder): string {
    if (folder === MailFolder.INBOX) {
      return this.selectedAccountId === 'all' ? '统一收件箱' : '收件箱';
    }
    if (folder === MailFolder.DRAFTS) {
      return '草稿';
    }
    if (folder === MailFolder.SENT) {
      return '已发送';
    }
    if (folder === MailFolder.ARCHIVE) {
      return '归档';
    }
    if (folder === MailFolder.SPAM) {
      return '垃圾邮件';
    }
    return '垃圾箱';
  }

  // 切换筛选 chip：全部四种筛选都改变查询条件（未读 / 附件已下推到 SQL，星标跨文件夹），
  // 因此一律从第一页整窗重查；只对已加载窗口做客户端过滤会让分页与筛选条件错位。
  private applyFilter(next: MailListFilter): void {
    if (this.filterMode === next) {
      return;
    }
    this.filterMode = next;
    this.selectedIds = new Set<string>();
    const isStarred: boolean = next === MailListFilter.STARRED;
    this.selectedFolderTitle = isStarred ? '星标邮件' : this.titleForFolder(this.selectedFolder);
    // 星标没有服务器侧的历史翻页，其余筛选沿用当前文件夹的历史能力。
    this.hasMoreHistory = !isStarred;
    this.resetWindowAndLoad();
  }

  // 追加一页：窗口已由查询条件过滤，无关键词时走增量 ADD 通知；有关键词时重算过滤结果。
  private appendPage(page: MailMessage[]): void {
    const loaded: Set<string> = new Set<string>();
    for (let index: number = 0; index < this.messages.length; index++) {
      loaded.add(this.messages[index].id);
    }
    const fresh: MailMessage[] = [];
    for (let index: number = 0; index < page.length; index++) {
      if (!loaded.has(page[index].id)) {
        fresh.push(page[index]);
      }
    }
    if (fresh.length === 0) {
      return;
    }
    this.messages = this.messages.concat(fresh);
    if (this.searchKeyword.length > 0) {
      this.refreshList();
      return;
    }
    this.dataSource.appendRows(MailListRow.appendRows(this.dataSource.tailGroupLabel(), fresh));
    this.displayCount = this.dataSource.messageCount();
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
    this.filterMode = starredOnly ? MailListFilter.STARRED : MailListFilter.ALL;
    this.closeDrawer();
    this.selectedIds = new Set<string>();
    this.hasMoreHistory = !starredOnly;
    this.resetWindowAndLoad();
  }

  private selectAccount(accountId: string): void {
    this.selectedAccountId = accountId;
    this.showAccountSelector = false;
    this.selectedFolderTitle = accountId === 'all' ? '统一收件箱' : '收件箱';
    this.selectedFolder = MailFolder.INBOX;
    this.filterMode = MailListFilter.ALL;
    this.hasMoreHistory = true;
    this.resetWindowAndLoad();
  }

  private selectedIdList(): string[] {
    const ids: string[] = [];
    this.selectedIds.forEach((messageId: string) => {
      ids.push(messageId);
    });
    return ids;
  }

  private toggleSelection(messageId: string): void {
    const next: Set<string> = new Set<string>();
    this.selectedIds.forEach((id: string) => {
      next.add(id);
    });
    if (next.has(messageId)) {
      next.delete(messageId);
    } else {
      next.add(messageId);
    }
    this.selectedIds = next;
  }

  private clearSelection(): void {
    this.selectedIds = new Set<string>();
  }

  // 记录被操作邮件的原文件夹，供撤销时 move 回去。
  private captureUndoEntries(messageIds: string[]): UndoEntry[] {
    const entries: UndoEntry[] = [];
    for (let index: number = 0; index < messageIds.length; index++) {
      const message: MailMessage | undefined =
        this.messages.find((item: MailMessage) => item.id === messageIds[index]);
      if (message === undefined) {
        continue;
      }
      entries.push(new UndoEntry(message.id, message.folder, message.accountId));
    }
    return entries;
  }

  private showUndo(text: string, entries: UndoEntry[]): void {
    if (entries.length === 0) {
      return;
    }
    this.pendingUndo = entries;
    this.undoText = text;
    this.undoSessionId++;
    this.undoVisible = true;
  }

  private hideUndo(): void {
    this.undoVisible = false;
    this.pendingUndo = [];
  }

  // 撤销：按原文件夹分组移回，再刷新首屏（顺序由本地库的排序决定，本地插入容易和分页错位）。
  private async undoPendingAction(): Promise<void> {
    const entries: UndoEntry[] = this.pendingUndo;
    this.pendingUndo = [];
    if (entries.length === 0) {
      return;
    }
    const folders: MailFolder[] = [];
    const groupedIds: string[][] = [];
    const accountIds: string[] = [];
    for (let index: number = 0; index < entries.length; index++) {
      const entry: UndoEntry = entries[index];
      const groupIndex: number = folders.indexOf(entry.folder);
      if (groupIndex < 0) {
        folders.push(entry.folder);
        groupedIds.push([entry.messageId]);
      } else {
        groupedIds[groupIndex].push(entry.messageId);
      }
      if (accountIds.indexOf(entry.accountId) < 0) {
        accountIds.push(entry.accountId);
      }
    }
    try {
      for (let index: number = 0; index < folders.length; index++) {
        await this.repository.moveMessages(groupedIds[index], folders[index]);
      }
      showToast('已撤销');
      await this.loadMessages();
      await this.pushAccountOperations(accountIds);
    } catch (error) {
      showToast(`撤销失败：${error}`);
    }
  }

  private async toggleReadSelected(): Promise<void> {
    const messageIds: string[] = this.selectedIdList();
    const accountIds: string[] = await this.accountIdsForMessages(messageIds);
    for (let index: number = 0; index < messageIds.length; index++) {
      await this.repository.toggleRead(messageIds[index]);
    }
    this.clearSelection();
    this.applyReadToggle(messageIds);
    await this.loadFolderCounts();
    await this.pushAccountOperations(accountIds);
  }

  private async archiveSelected(): Promise<void> {
    const messageIds: string[] = this.selectedIdList();
    const undoEntries: UndoEntry[] = this.captureUndoEntries(messageIds);
    const accountIds: string[] = await this.accountIdsForMessages(messageIds);
    await this.repository.moveMessages(messageIds, MailFolder.ARCHIVE);
    this.clearSelection();
    this.removeFromList(messageIds);
    this.showUndo(`${messageIds.length} 封邮件已归档`, undoEntries);
    await this.loadFolderCounts();
    await this.pushAccountOperations(accountIds);
  }

  private async deleteSelected(): Promise<void> {
    const messageIds: string[] = this.selectedIdList();
    const undoEntries: UndoEntry[] = this.captureUndoEntries(messageIds);
    const accountIds: string[] = await this.accountIdsForMessages(messageIds);
    await this.repository.deleteMessages(messageIds);
    this.clearSelection();
    this.removeFromList(messageIds);
    this.showUndo(`${messageIds.length} 封邮件已移至垃圾箱`, undoEntries);
    await this.loadFolderCounts();
    await this.pushAccountOperations(accountIds);
  }

  private selectAllVisible(): void {
    const next: Set<string> = new Set<string>();
    const visible: MailMessage[] = this.visibleMessages();
    for (let index: number = 0; index < visible.length; index++) {
      next.add(visible[index].id);
    }
    this.selectedIds = next;
  }

  private async moveSelectedTo(folder: MailFolder, successMessage: string): Promise<void> {
    if (this.selectedIds.size === 0) {
      return;
    }
    const messageIds: string[] = this.selectedIdList();
    const undoEntries: UndoEntry[] = this.captureUndoEntries(messageIds);
    const accountIds: string[] = await this.accountIdsForMessages(messageIds);
    await this.repository.moveMessages(messageIds, folder);
    this.clearSelection();
    this.removeFromList(messageIds);
    this.showUndo(successMessage, undoEntries);
    await this.loadFolderCounts();
    await this.pushAccountOperations(accountIds);
  }

  private toggleSortOrder(): void {
    this.newestFirst = !this.newestFirst;
    this.messages = this.messages.slice().reverse();
    this.refreshList();
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

  // 下拉刷新：用户主动语义，同步后整窗替换（回到第一页）。
  private async pullRefresh(): Promise<void> {
    try {
      await this.syncAccounts(false);
      await this.loadMessages();
    } finally {
      this.isRefreshing = false;
    }
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
              showToast('当前不是 Wi-Fi 网络，已暂停同步');
            }
            return;
          }
        } catch (_error) {
          if (showFeedback) {
            showToast('无法确认当前网络，已暂停仅 Wi-Fi 同步');
          }
          return;
        }
      }
      const targets: EmailAccount[] = this.accounts.filter((account: EmailAccount) =>
        account.syncEnabled && (this.selectedAccountId === 'all' || account.id === this.selectedAccountId));
      if (targets.length === 0) {
        if (showFeedback) {
          showToast('没有启用同步的账户');
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
        // 每个账户同步完只刷新账户 / 计数，并把窗口头部的新邮件合并进来：
        // 不整窗替换，已翻的页与翻页游标都保留（前台同步每 60 秒跑一次）。
        await this.loadAccounts();
        await this.loadFolderCounts();
        await this.mergeNewHeadMessages();
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
            showToast(`新邮件通知发送失败：${error}`);
          }
        }
      }
      if (!showFeedback && !inQuietHours && mailCount > 0) {
        showToast(`收到 ${mailCount} 封新邮件`);
      }
      if (showFeedback) {
        if (failures.length === 0) {
          showToast(`同步完成，共更新 ${mailCount} 封邮件`);
        } else if (successCount > 0) {
          showToast(`已同步 ${successCount} 个账户；${failures[0]}`);
        } else {
          showToast(failures[0]);
        }
      }
    } finally {
      this.isSyncing = false;
      this.syncStatusText = '';
    }
  }

  // 滚动到底部：先翻本地分页，本地翻尽再走服务器拉取历史邮件。
  private async loadMoreMessages(): Promise<void> {
    if (this.isLoadingOlder || this.isLoadingPage || this.isLoadingList || this.isRefreshing) {
      return;
    }
    if (this.hasMoreInDatabase) {
      await this.loadNextPage();
      return;
    }
    await this.loadOlderMessages();
  }

  private async loadNextPage(): Promise<void> {
    this.isLoadingPage = true;
    try {
      // 键集分页：用窗口末行的排序键续查，删除 / 归档 / 新邮件都不会让后续页漏邮件。
      const page: MailMessage[] = await this.fetchPage(true);
      if (page.length === 0) {
        this.hasMoreInDatabase = false;
        return;
      }
      this.advanceCursor(page);
      if (this.newestFirst) {
        this.appendPage(page);
      } else {
        // 从旧到新时更早的邮件插在列表开头，增量通知无法表达前插，改为整体重排（同 key 仍复用行）。
        this.messages = page.slice().reverse().concat(this.messages);
        this.refreshList();
      }
    } finally {
      this.isLoadingPage = false;
    }
  }

  private async loadOlderMessages(): Promise<void> {
    if (this.isLoadingOlder || this.isStarredOnly() || !this.hasMoreHistory) {
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
      // 服务器拉回的历史邮件已入库，接着本地分页把它们接进列表末尾（不再整表重刷）。
      await this.loadNextPage();
      await this.loadFolderCounts();
      this.hasMoreHistory = failures.length > 0 || serverHasMore;
      if (loadedCount > 0) {
        showToast(`已加载 ${loadedCount} 封更早邮件`);
      } else if (failures.length > 0) {
        showToast(failures[0]);
      } else if (serverHasMore) {
        showToast(fetchedCount > 0 ? '已跳过本地重复邮件，请继续加载' : '服务器仍有更早邮件，请继续加载');
      } else {
        showToast('没有更早的邮件了');
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
    if (this.pendingStarIds.has(message.id)) {
      return;
    }
    const previousValue: boolean = message.isStarred;
    this.pendingStarIds.add(message.id);
    this.applyStar(message.id, !previousValue);
    try {
      await this.repository.toggleStar(message.id);
      if (this.isStarredOnly() && previousValue) {
        this.removeFromList([message.id]);
      }
      await this.loadFolderCounts();
      showToast(previousValue ? '已取消星标' : '已添加星标');
      await this.pushAccountOperations([message.accountId]);
    } catch (error) {
      this.applyStar(message.id, previousValue);
      showToast(`星标操作失败：${error}`);
    } finally {
      this.pendingStarIds.delete(message.id);
    }
  }

  // 星标只改命中的那一行：窗口数组替换 + 单条 CHANGE 通知，其余行不动。
  private applyStar(messageId: string, isStarred: boolean): void {
    const next: MailMessage[] = [];
    let updated: MailMessage | undefined = undefined;
    for (let index: number = 0; index < this.messages.length; index++) {
      const item: MailMessage = this.messages[index];
      if (item.id === messageId) {
        updated = this.copyMessage(item, item.isRead, isStarred);
        next.push(updated);
      } else {
        next.push(item);
      }
    }
    this.messages = next;
    if (updated !== undefined) {
      this.dataSource.updateMessage(updated);
    }
  }

  // 已读状态变化：未读筛选下“变成已读”的行必须移出列表（否则它留在窗口里但已不满足查询条件，
  // 翻页与计数都会错位）；其它筛选原位更新即可。
  private applyRead(messageId: string, isRead: boolean): void {
    if (this.filterMode === MailListFilter.UNREAD && isRead) {
      this.removeFromList([messageId]);
      return;
    }
    const next: MailMessage[] = [];
    let updated: MailMessage | undefined = undefined;
    for (let index: number = 0; index < this.messages.length; index++) {
      const item: MailMessage = this.messages[index];
      if (item.id === messageId) {
        updated = this.copyMessage(item, isRead, item.isStarred);
        next.push(updated);
      } else {
        next.push(item);
      }
    }
    this.messages = next;
    if (updated !== undefined) {
      this.dataSource.updateMessage(updated);
    }
  }

  private applyReadToggle(messageIds: string[]): void {
    const next: MailMessage[] = [];
    const updated: MailMessage[] = [];
    const dropped: string[] = [];
    for (let index: number = 0; index < this.messages.length; index++) {
      const item: MailMessage = this.messages[index];
      if (messageIds.indexOf(item.id) >= 0) {
        const flipped: MailMessage = this.copyMessage(item, !item.isRead, item.isStarred);
        if (this.filterMode === MailListFilter.UNREAD && flipped.isRead) {
          // 未读筛选下反转成已读 = 不再满足查询条件，直接移出窗口。
          dropped.push(flipped.id);
          continue;
        }
        next.push(flipped);
        updated.push(flipped);
      } else {
        next.push(item);
      }
    }
    this.messages = next;
    if (dropped.length > 0) {
      this.dataSource.removeMessages(dropped);
      this.displayCount = this.dataSource.messageCount();
    }
    for (let index: number = 0; index < updated.length; index++) {
      this.dataSource.updateMessage(updated[index]);
    }
  }

  private removeFromList(messageIds: string[]): void {
    const remaining: MailMessage[] = [];
    for (let index: number = 0; index < this.messages.length; index++) {
      if (messageIds.indexOf(this.messages[index].id) < 0) {
        remaining.push(this.messages[index]);
      }
    }
    this.messages = remaining;
    this.dataSource.removeMessages(messageIds);
    this.displayCount = this.dataSource.messageCount();
  }

  private copyMessage(message: MailMessage, isRead: boolean, isStarred: boolean): MailMessage {
    return new MailMessage(message.id, message.accountId, message.folder, message.sender,
      message.recipients, message.subject, message.preview, message.plainBody, message.receivedAt,
      isRead, isStarred, message.hasAttachments, message.htmlBody, message.rfcMessageId,
      message.inReplyTo, message.receivedAtMs);
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
      showToast(`无法打开写信页面：${error}`);
    } finally {
      this.isOpeningComposer = false;
    }
  }

  private async openMessage(message: MailMessage): Promise<void> {
    if (this.selectedIds.size > 0) {
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
      this.applyRead(message.id, true);
      await this.loadAccounts();
      await this.loadFolderCounts();
      this.pushAccountOperations([message.accountId]).catch(() => {});
      await this.getUIContext().getRouter()
        .pushUrl({ url: 'pages/MailDetail', params: { mailId: message.id } });
    } catch (error) {
      showToast(`无法打开邮件：${error}`);
    } finally {
      this.isOpeningMessage = false;
    }
  }

  private async swipeToggleRead(message: MailMessage): Promise<void> {
    const previousRead: boolean = message.isRead;
    this.applyRead(message.id, !previousRead);
    try {
      await this.repository.toggleRead(message.id);
      await this.loadFolderCounts();
      await this.pushAccountOperations([message.accountId]);
    } catch (error) {
      // 未读筛选下这行已按“变成已读”移出窗口，回滚只能整窗重查（行不在原位，无法原位更新）。
      if (this.filterMode === MailListFilter.UNREAD) {
        await this.loadMessages();
      } else {
        this.applyRead(message.id, previousRead);
      }
      showToast(`更新已读状态失败：${error}`);
    }
  }

  private async swipeEndAction(message: MailMessage): Promise<void> {
    const undoEntries: UndoEntry[] = [new UndoEntry(message.id, message.folder, message.accountId)];
    if (this.swipeDelete) {
      await this.repository.deleteMessages([message.id]);
      this.removeFromList([message.id]);
      this.showUndo('邮件已移至垃圾箱', undoEntries);
    } else {
      await this.repository.moveMessages([message.id], MailFolder.ARCHIVE);
      this.removeFromList([message.id]);
      this.showUndo('邮件已归档', undoEntries);
    }
    await this.loadFolderCounts();
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
        showToast(`本地操作已保存，将稍后同步：${result.errorMessage}`);
      }
    }
  }

  @Builder
  private swipeReadBuilder(message: MailMessage) {
    Row({ space: 6 }) {
      Image($r('app.media.ic_mail')).width(22).height(22).objectFit(ImageFit.Contain)
        .fillColor($r('app.color.onPrimary'))
      Text(message.isRead ? '未读' : '已读').fontSize(13).fontColor($r('app.color.onPrimary'))
    }.width(82).height('100%').justifyContent(FlexAlign.Center).backgroundColor($r('app.color.primary'))
  }

  @Builder
  private swipeEndBuilder() {
    Row({ space: 6 }) {
      Image(this.swipeDelete ? $r('app.media.ic_delete') : $r('app.media.ic_archive'))
        .width(22).height(22).objectFit(ImageFit.Contain)
        .fillColor($r('app.color.onPrimary'))
      Text(this.swipeDelete ? '删除' : '归档').fontSize(13).fontColor($r('app.color.onPrimary'))
    }.width(82).height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor(this.swipeDelete ? $r('app.color.error') : $r('app.color.primary'))
  }

  private swipeOptionsFor(row: MailListRow): SwipeActionOptions {
    if (!this.swipeEnabled || row.message === undefined) {
      return {};
    }
    return this.swipeOptions(row.message);
  }

  private swipeOptions(message: MailMessage): SwipeActionOptions {
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

  @Builder
  private roundIconButton(icon: Resource, action: () => void) {
    Button() {
      Image(icon).width(23).height(23).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurface'))
    }
    .width(ThunderbirdTheme.touchTarget).height(ThunderbirdTheme.touchTarget)
    .backgroundColor(Color.Transparent).borderRadius(ThunderbirdTheme.pillRadius).onClick(action)
  }

  // 常驻搜索框：不再依赖点击图标展开，聚焦时右侧补出取消按钮。
  @Builder
  private searchField() {
    Row({ space: 8 }) {
      Image($r('app.media.ic_search')).width(20).height(20).objectFit(ImageFit.Contain)
        .fillColor($r('app.color.onSurfaceVariant'))
      TextInput({ placeholder: '搜索邮件、联系人、附件…', text: this.searchText,
        controller: this.searchController })
        .layoutWeight(1).height(42).fontSize(15)
        .fontColor($r('app.color.onSurface'))
        .placeholderColor($r('app.color.onSurfaceVariant'))
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .onChange((value: string) => this.onSearchChange(value))
        .onFocus(() => {
          this.searchFocused = true;
        })
        .onBlur(() => {
          this.searchFocused = false;
        })
      if (this.searchText.length > 0) {
        Button() {
          Image($r('app.media.ic_close')).width(18).height(18).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.onSurfaceVariant'))
        }
        .width(32).height(32).backgroundColor(Color.Transparent).borderRadius(16)
        .onClick(() => this.resetSearch())
      }
    }
    .layoutWeight(1).height(46).padding({ left: 14, right: 10 })
    .backgroundColor($r('app.color.surfaceLowest'))
    .border({ width: 1, color: $r('app.color.cardBorder') })
    .borderRadius(ThunderbirdTheme.pillRadius)
  }

  @Builder
  private filterChip(label: string, filter: MailListFilter) {
    Text(label)
      .fontSize(13).fontWeight(FontWeight.Medium)
      .fontColor(this.filterMode === filter ? $r('app.color.onPrimaryContainer') :
        $r('app.color.onSurfaceVariant'))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.filterMode === filter ? $r('app.color.primaryContainer') :
        $r('app.color.surfaceLowest'))
      .border({
        width: 1,
        color: this.filterMode === filter ? $r('app.color.primaryContainer') : $r('app.color.cardBorder')
      })
      .borderRadius(ThunderbirdTheme.pillRadius)
      .onClick(() => this.applyFilter(filter))
  }

  @Builder
  private filterChips() {
    Scroll() {
      Row({ space: 8 }) {
        this.filterChip('全部', MailListFilter.ALL)
        this.filterChip('未读', MailListFilter.UNREAD)
        this.filterChip('星标', MailListFilter.STARRED)
        this.filterChip('附件', MailListFilter.ATTACHMENT)
      }
      .padding({ left: 16, right: 16 })
    }
    .width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
  }

  @Builder
  private regularTopBar() {
    Column() {
      Row() {
        this.roundIconButton($r('app.media.ic_menu'), () => this.openDrawer())
        Text(this.selectedFolderTitle)
          .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface')).maxLines(1)
        Button() {
          Image($r('app.media.ic_more')).width(23).height(23).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.onSurface'))
        }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
        .bindMenu(this.listMoreMenuItems(), { placement: Placement.BottomRight, enableArrow: true })
      }
      .width('100%').height(56).padding({ left: 6, right: 6 })

      Row({ space: 8 }) {
        this.searchField()
        if (this.searchFocused) {
          Button() {
            Text('取消').fontSize(14).fontColor($r('app.color.primary'))
          }
          .height(40).padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent)
          .onClick(() => this.cancelSearch())
        }
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 10 })

      this.filterChips()
    }
    .width('100%').padding({ bottom: 10 }).backgroundColor($r('app.color.surface'))
  }

  @Builder
  private selectionTopBar() {
    Row() {
      this.roundIconButton($r('app.media.ic_close'), () => this.clearSelection())
      Text(`${this.selectedIds.size}`)
        .layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.onSurface'))
      this.roundIconButton($r('app.media.ic_mail'), () => this.toggleReadSelected())
      this.roundIconButton($r('app.media.ic_archive'), () => this.archiveSelected())
      this.roundIconButton($r('app.media.ic_delete'), () => this.deleteSelected())
      Button() {
        Image($r('app.media.ic_more')).width(23).height(23).objectFit(ImageFit.Contain)
          .fillColor($r('app.color.onSurface'))
      }
      .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
      .bindMenu(this.selectionMoreMenuItems(), { placement: Placement.BottomRight, enableArrow: true })
    }
    .width('100%').height(56).padding({ left: 6, right: 6 })
    .backgroundColor($r('app.color.infoContainer'))
  }

  @Builder
  private dateHeaderRow(label: string) {
    Text(label)
      .width('100%').fontSize(13).fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.onSurfaceVariant'))
      .padding({ left: 4, top: 10, bottom: 2 })
  }

  @Builder
  private mailCard(row: MailListRow) {
    if (row.message !== undefined) {
      MessageCard({
        message: row.message,
        selected: this.selectedIds.has(row.message.id),
        compactMode: this.compactMode,
        showPreview: this.showMessagePreview,
        onOpen: (item: MailMessage) => this.openMessage(item),
        onLongPress: (item: MailMessage) => this.toggleSelection(item.id),
        onToggleStar: (item: MailMessage) => this.toggleStar(item),
        onToggleSelection: (messageId: string) => this.toggleSelection(messageId)
      })
    }
  }

  @Builder
  private folderItem(icon: Resource, label: string, count: number, active: boolean,
    folder: MailFolder, starredOnly: boolean = false, unreadBadge: boolean = false) {
    Row({ space: 16 }) {
      Image(icon).width(24).height(24).objectFit(ImageFit.Contain)
        .fillColor(active ? $r('app.color.primary') : $r('app.color.onSurfaceVariant'))
      Text(label).layoutWeight(1).fontSize(15)
        .fontWeight(active ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(active ? $r('app.color.primary') : $r('app.color.onSurface'))
      if (count > 0) {
        if (unreadBadge) {
          Text(`${count}`).fontSize(12).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.onPrimaryContainer'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .constraintSize({ minWidth: 22 })
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.primaryContainer'))
            .borderRadius(10)
        } else {
          Text(`${count}`).fontSize(12).fontColor($r('app.color.onSurfaceVariant'))
        }
      }
    }
    .width('100%').height(48).padding({ left: 16, right: 16 })
    .margin({ left: 8, right: 8 })
    .backgroundColor(active ? $r('app.color.primaryContainer') : Color.Transparent)
    .borderRadius(ThunderbirdTheme.pillRadius)
    .onClick(() => this.selectFolder(label, folder, starredOnly))
  }

  @Builder
  private skeletonList() {
    List({ space: 8 }) {
      ForEach(this.skeletonRowIndexes, (skeletonIndex: number) => {
        ListItem() {
          Row({ space: 9 }) {
            Circle().width(42).height(42).fill($r('app.color.surfaceContainer'))
            Column({ space: 6 }) {
              Rect().width('55%').height(12).radius(6).fill($r('app.color.surfaceContainer'))
              Rect().width('92%').height(12).radius(6).fill($r('app.color.surfaceContainer'))
              Rect().width('38%').height(10).radius(5).fill($r('app.color.surfaceContainer'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }
          .width('100%').height(86).padding({ left: 10, right: 8, top: 9, bottom: 9 })
          .backgroundColor($r('app.color.surfaceLowest'))
          .border({ width: 1, color: $r('app.color.cardBorder') })
          .borderRadius(ThunderbirdTheme.cardRadius)
        }
      }, (skeletonIndex: number) => `skeleton_${skeletonIndex}`)
    }
    .layoutWeight(1).width('100%').scrollBar(BarState.Off)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  private emptyState() {
    Column({ space: 12 }) {
      Image(this.emptyIcon())
        .width(48).height(48).objectFit(ImageFit.Contain)
        .fillColor($r('app.color.outline'))
      Text(this.emptyTitle())
        .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.onSurface'))
      Text(this.emptyHint()).fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
      if (this.searchText.length === 0 && this.filterMode === MailListFilter.ALL) {
        Button() {
          Row({ space: 8 }) {
            if (this.isSyncing) {
              LoadingProgress().width(18).height(18).color($r('app.color.onPrimary'))
            } else {
              Image($r('app.media.ic_sync')).width(18).height(18).objectFit(ImageFit.Contain)
                .fillColor($r('app.color.onPrimary'))
            }
            Text('立即同步').fontSize(14).fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.onPrimary'))
          }
        }
        .height(44).padding({ left: 20, right: 20 })
        .backgroundColor($r('app.color.primary')).borderRadius(ThunderbirdTheme.pillRadius)
        .enabled(!this.isSyncing)
        .margin({ top: 6 })
        .onClick(() => this.syncAccounts())
      }
    }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  private drawerContent() {
    Column() {
      Row({ space: 14 }) {
        Stack() {
          Circle().width(48).height(48).fill($r('app.color.primary'))
          if (this.selectedAccountId === 'all') {
            Image($r('app.media.ic_mail')).width(24).height(24).objectFit(ImageFit.Contain)
              .fillColor($r('app.color.onPrimary'))
          } else {
            Text(this.currentAccountTitle().substring(0, 1))
              .fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.onPrimary'))
          }
        }
        Column({ space: 3 }) {
          Text(this.currentAccountTitle()).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.onSurface')).maxLines(1)
          Text(this.currentAccountSubtitle()).fontSize(12).fontColor($r('app.color.onSurfaceVariant')).maxLines(1)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Image(this.showAccountSelector ? $r('app.media.ic_chevron_up') : $r('app.media.ic_chevron_down'))
          .width(22).height(22).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurfaceVariant'))
      }
      .width('100%').height(80).padding({ left: 22, right: 18 })
      .onClick(() => this.showAccountSelector = !this.showAccountSelector)
      Divider().color($r('app.color.outlineVariant'))

      if (this.showAccountSelector) {
        List() {
          ListItem() {
            Row({ space: 16 }) {
              Stack() {
                Circle().width(32).height(32).fill($r('app.color.primary'))
                Image($r('app.media.ic_mail')).width(18).height(18).objectFit(ImageFit.Contain)
                  .fillColor($r('app.color.onPrimary'))
              }
              Text('统一账户').layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.onSurface'))
              Text(`${this.accounts.reduce((sum: number, account: EmailAccount) => sum + account.unreadCount, 0)}`)
                .fontSize(12).fontColor($r('app.color.onSurfaceVariant'))
            }
            .width('100%').height(58).padding({ left: 24, right: 20 })
            .backgroundColor(this.selectedAccountId === 'all' ? $r('app.color.infoContainer') : Color.Transparent)
            .onClick(() => this.selectAccount('all'))
          }
          ForEach(this.accounts, (account: EmailAccount) => {
            ListItem() {
              Row({ space: 16 }) {
                Circle().width(30).height(30).fill(account.color)
                Column({ space: 2 }) {
                  Text(account.displayName).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.onSurface')).maxLines(1)
                  Text(account.email).fontSize(12).fontColor($r('app.color.onSurfaceVariant')).maxLines(1)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                if (account.unreadCount > 0) {
                  Text(`${account.unreadCount}`).fontSize(12).fontColor($r('app.color.onSurfaceVariant'))
                }
              }
              .width('100%').height(58).padding({ left: 24, right: 20 })
              .backgroundColor(this.selectedAccountId === account.id ? $r('app.color.infoContainer') : Color.Transparent)
              .onClick(() => this.selectAccount(account.id))
            }
          }, (account: EmailAccount) => account.id)
        }
        .layoutWeight(1).width('100%').scrollBar(BarState.Off)
      } else {
        Column({ space: 2 }) {
          this.folderItem($r('app.media.ic_inbox'), this.selectedAccountId === 'all' ? '统一收件箱' : '收件箱',
            this.inboxUnreadCount,
            this.selectedFolder === MailFolder.INBOX && !this.isStarredOnly(), MailFolder.INBOX, false, true)
          this.folderItem($r('app.media.ic_star'), '星标邮件', this.starredCount,
            this.isStarredOnly(), MailFolder.INBOX, true)
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

      Divider().color($r('app.color.outlineVariant'))
      Row({ space: 18 }) {
        if (this.isSyncing) {
          LoadingProgress().width(24).height(24).color($r('app.color.primary'))
        } else {
          Image($r('app.media.ic_sync')).width(24).height(24).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.onSurfaceVariant'))
        }
        Column({ space: 2 }) {
          Text('同步账户').width('100%').fontSize(15).fontColor($r('app.color.onSurface'))
          if (this.syncStatusText.length > 0) {
            Text(this.syncStatusText).width('100%').fontSize(12).fontColor($r('app.color.onSurfaceVariant'))
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width('100%').height(52).padding({ left: 22, right: 18 }).onClick(() => {
        this.syncAccounts();
      })
      Row({ space: 18 }) {
        Image($r('app.media.ic_settings')).width(24).height(24).objectFit(ImageFit.Contain)
          .fillColor($r('app.color.onSurfaceVariant'))
        Text('设置').layoutWeight(1).fontSize(15).fontColor($r('app.color.onSurface'))
      }
      .width('100%').height(52).padding({ left: 22, right: 18 })
      .onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/Accounts' }).catch(() => {}))
    }
    .width('86%').constraintSize({ maxWidth: 320 }).height('100%')
    .backgroundColor($r('app.color.surfaceLowest'))
    .translate({ x: this.drawerOffset })
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        if (this.selectedIds.size > 0) {
          this.selectionTopBar()
        } else {
          this.regularTopBar()
        }
        if (this.displayCount === 0 && this.isLoadingList) {
          this.skeletonList()
        } else if (this.displayCount === 0) {
          this.emptyState()
        } else {
          Refresh({ refreshing: $$this.isRefreshing }) {
            List({ space: 8 }) {
              LazyForEach(this.dataSource, (row: MailListRow) => {
                if (row.isHeader()) {
                  ListItem() {
                    this.dateHeaderRow(row.label)
                  }
                } else {
                  ListItem() {
                    this.mailCard(row)
                  }
                  .swipeAction(this.swipeOptionsFor(row))
                }
              }, (row: MailListRow) => row.key)
              if (this.newestFirst) {
                if (this.isLoadingOlder || this.isLoadingPage) {
                  ListItem() {
                    Row({ space: 8 }) {
                      LoadingProgress().width(18).height(18).color($r('app.color.primary'))
                      Text('正在加载更早邮件').fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
                    }.width('100%').height(52).justifyContent(FlexAlign.Center)
                  }
                } else if (!this.hasMoreHistory && !this.hasMoreInDatabase && !this.isStarredOnly()) {
                  ListItem() {
                    Text('没有更早的邮件了').width('100%').height(44).textAlign(TextAlign.Center)
                      .fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
                  }
                }
              }
            }
            .width('100%').height('100%').scrollBar(BarState.Off)
            .cachedCount(6)
            .padding({ left: 16, right: 16, top: 8, bottom: 12 })
            .backgroundColor($r('app.color.surface'))
            .clip(true)
            .onReachStart(() => {
              if (this.newestFirst) {
                // 回弹到顶部会连续触发，15 秒内只同步一次（前台定时同步另有 15 秒节流）。
                const now: number = Date.now();
                if (now - this.lastReachStartSyncAt < 15 * 1000) {
                  return;
                }
                this.lastReachStartSyncAt = now;
                this.syncAccounts();
              } else {
                this.loadMoreMessages();
              }
            })
            .onReachEnd(() => {
              if (this.newestFirst) {
                this.loadMoreMessages();
              } else {
                this.syncAccounts();
              }
            })
          }
          .layoutWeight(1).width('100%')
          .onRefreshing(() => {
            this.pullRefresh().catch(() => {});
          })
        }
      }
      .width('100%').height('100%').backgroundColor($r('app.color.surface'))

      if (this.selectedIds.size === 0) {
        Button() {
          if (this.isOpeningComposer) {
            LoadingProgress().width(24).height(24).color($r('app.color.primary'))
          } else {
            Image($r('app.media.ic_compose')).width(25).height(25).objectFit(ImageFit.Contain)
              .fillColor($r('app.color.onPrimary'))
          }
        }
          .width(56).height(56)
          .backgroundColor($r('app.color.primary')).borderRadius(28)
          .shadow({ radius: 6, color: '#1F007DFF', offsetY: 2 })
          .margin({ right: 18, bottom: 22 })
          .enabled(!this.isOpeningComposer)
          .onClick(() => this.openComposer())
      }

      if (this.undoVisible) {
        Row() {
          UndoSnackbar({
            sessionId: this.undoSessionId,
            text: this.undoText,
            onUndo: () => this.undoPendingAction(),
            onDismiss: () => this.hideUndo()
          })
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 90 })
        .align(Alignment.Bottom)
      }

      if (this.drawerOpen) {
        Row() {
          this.drawerContent()
          Column() {}.layoutWeight(1).height('100%').backgroundColor('#66000000')
            .opacity(this.scrimOpacity)
            .onClick(() => this.closeDrawer())
        }
        .width('100%').height('100%').align(Alignment.Start)
        .onAppear(() => this.playDrawerIn())
      }
    }
    .width('100%').height('100%')
  }
}
