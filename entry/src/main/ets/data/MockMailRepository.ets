import { CredentialVault, MemoryCredentialVault } from '../security/CredentialVault';
import { DraftMessage, EmailAccount, EmailProviderType, MailAddress, MailAttachment, MailFolder,
  MailMessage } from '../model/MailModels';
import { MailRepository } from './MailRepository';

export class MockMailRepository implements MailRepository {
  private static instance: MockMailRepository = new MockMailRepository();
  private vault: CredentialVault = new MemoryCredentialVault();
  private accounts: EmailAccount[] = [];
  private messages: MailMessage[] = [];
  private attachments: Map<string, MailAttachment[]> = new Map<string, MailAttachment[]>();
  private settings: Map<string, string> = new Map<string, string>();

  private constructor() {
    this.seed();
  }

  static shared(): MockMailRepository {
    return MockMailRepository.instance;
  }

  private seed(): void {
    const qq: EmailAccount = new EmailAccount('account_qq', 'hello@qq.com', '工作邮箱',
      EmailProviderType.QQ, '#2878FF', '', 3);
    const gmail: EmailAccount = new EmailAccount('account_gmail', 'hello@gmail.com', '个人邮箱',
      EmailProviderType.GMAIL, '#94A3B8', '', 0, false);
    const netease: EmailAccount = new EmailAccount('account_163', 'work_account@163.com', '163 邮箱',
      EmailProviderType.NETEASE_163, '#24A6A1', '', 0);
    const outlook: EmailAccount = new EmailAccount('account_outlook', 'business@outlook.com', 'Outlook',
      EmailProviderType.OUTLOOK, '#5367F8', '', 45);
    this.accounts = [qq, netease, gmail, outlook];

    this.messages = [
      new MailMessage('mail_1', qq.id, MailFolder.INBOX,
        new MailAddress('HarmonyOS 团队', 'developer@harmonyos.com'),
        [new MailAddress('我', qq.email)],
        'NEXT 版本更新说明与开发指南',
        '您好，全新的 HarmonyOS NEXT 开发者预览版已经发布。本次更新带来了全新的原生 UI 框架。',
        '团队成员大家好，\n\n随着第四季度的深入，我们的核心产品线即将迎来关键里程碑。为了确保按时交付并保证质量，我计划在下周二下午召开一次全面的进度评审会议。\n\n本次会议的主要议题包括：\n1. 各模块当前开发进度与目标核对。\n2. 识别并解决可能存在的研发阻塞点。\n3. 根据最新市场反馈调整后续资源。\n\n请大家在会前仔细阅读附件中的季度报告草案和进度追踪表。\n\n祝好，\nHarmonyOS 团队',
        '09:41', false, true, true),
      new MailMessage('mail_2', netease.id, MailFolder.INBOX,
        new MailAddress('财务部 - 张伟', 'finance@company.com'),
        [new MailAddress('我', netease.email)],
        '2023年第四季度报销审批进度通知',
        '您的Q4季度差旅报销申请已通过最终审批，预计款项将在3个工作日内到账。',
        '您的Q4季度差旅报销申请已通过最终审批，预计款项将在3个工作日内打入您的工资卡账户，请注意查收。',
        '08:15', true, false, false),
      new MailMessage('mail_3', outlook.id, MailFolder.INBOX,
        new MailAddress('设计系统周报', 'design@example.com'),
        [new MailAddress('我', outlook.email)],
        '【第42期】全新组件库资产已上线',
        '本周我们完成了 24 个核心组件的视觉规范升级，并引入了全新的微动效体系。',
        '本周我们完成了 24 个核心组件的视觉规范升级。重点优化了深色模式下的对比度问题，并引入了全新的微动效体系。',
        '昨天 16:30', false, false, false),
      new MailMessage('mail_4', gmail.id, MailFolder.INBOX,
        new MailAddress('Mozilla 社区', 'community@mozilla.org'),
        [new MailAddress('我', gmail.email)],
        '欢迎加入开放互联网社区',
        '感谢你关注开放互联网。本期社区通讯包含隐私、安全和开源项目的最新动态。',
        '感谢你关注开放互联网。\n\n本期社区通讯包含隐私、安全和开源项目的最新动态，也欢迎参与社区活动。',
        '周一', true, true, false),
      new MailMessage('mail_5', qq.id, MailFolder.SENT,
        new MailAddress('我', qq.email), [new MailAddress('产品团队', 'product@example.com')],
        'Re: NEXT 版本发布计划', '已收到，发布前我会完成最终检查。',
        '已收到，发布前我会完成最终检查。', '周日', true, false, false),
      new MailMessage('mail_6', netease.id, MailFolder.DRAFTS,
        new MailAddress('我', netease.email), [new MailAddress('', 'finance@company.com')],
        '报销材料补充说明', '附件中的发票信息已经重新整理。',
        '附件中的发票信息已经重新整理。', '周六', true, false, true)
    ];
  }

  async listAccounts(): Promise<EmailAccount[]> {
    return this.accounts.slice();
  }

  async listMessages(accountId: string, folder: MailFolder): Promise<MailMessage[]> {
    return this.messages.filter((message: MailMessage) =>
      message.folder === folder && (accountId === 'all' || message.accountId === accountId));
  }

  async listStarredMessages(accountId: string): Promise<MailMessage[]> {
    return this.messages.filter((message: MailMessage) =>
      message.isStarred && (accountId === 'all' || message.accountId === accountId));
  }

  async getMessage(messageId: string): Promise<MailMessage | undefined> {
    return this.messages.find((message: MailMessage) => message.id === messageId);
  }

  async getDraft(messageId: string): Promise<DraftMessage | undefined> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    if (!message || message.folder !== MailFolder.DRAFTS) {
      return undefined;
    }
    return new DraftMessage(message.accountId,
      message.recipients.map((address: MailAddress) => address.address).join(', '), '',
      message.subject, message.plainBody, '', message.id, await this.listAttachments(message.id));
  }

  async listAttachments(messageId: string): Promise<MailAttachment[]> {
    return (this.attachments.get(messageId) ?? []).slice();
  }

  async addAccount(account: EmailAccount, secret: string): Promise<void> {
    account.credentialRef = await this.vault.save(account.id, secret);
    this.accounts.push(account);
  }

  async removeAccount(accountId: string): Promise<void> {
    const account: EmailAccount | undefined = this.accounts.find((item: EmailAccount) => item.id === accountId);
    if (account && account.credentialRef.length > 0) {
      await this.vault.remove(account.credentialRef);
    }
    this.accounts = this.accounts.filter((item: EmailAccount) => item.id !== accountId);
    this.messages = this.messages.filter((item: MailMessage) => item.accountId !== accountId);
  }

  async setAccountSyncEnabled(accountId: string, enabled: boolean): Promise<void> {
    const account: EmailAccount | undefined = this.accounts.find((item: EmailAccount) => item.id === accountId);
    if (account) {
      account.syncEnabled = enabled;
    }
  }

  async getSetting(key: string, defaultValue: string): Promise<string> {
    return this.settings.get(key) ?? defaultValue;
  }

  async setSetting(key: string, value: string): Promise<void> {
    this.settings.set(key, value);
  }

  async markRead(messageId: string): Promise<void> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    if (message) {
      message.isRead = true;
    }
  }

  async toggleRead(messageId: string): Promise<void> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    if (message) {
      message.isRead = !message.isRead;
    }
  }

  async toggleStar(messageId: string): Promise<void> {
    const message: MailMessage | undefined = await this.getMessage(messageId);
    if (message) {
      message.isStarred = !message.isStarred;
    }
  }

  async moveMessages(messageIds: string[], folder: MailFolder): Promise<void> {
    this.messages.forEach((message: MailMessage) => {
      if (messageIds.includes(message.id)) {
        message.folder = folder;
      }
    });
  }

  async deleteMessages(messageIds: string[]): Promise<void> {
    this.messages.forEach((message: MailMessage) => {
      if (messageIds.includes(message.id)) {
        message.folder = MailFolder.TRASH;
      }
    });
  }

  async saveDraft(draft: DraftMessage): Promise<string> {
    const account: EmailAccount | undefined = this.accounts.find((item: EmailAccount) => item.id === draft.accountId);
    if (!account) {
      throw new Error('请选择发件账户');
    }
    const messageId: string = draft.id.length > 0 ? draft.id : `draft_${Date.now()}`;
    this.messages = this.messages.filter((message: MailMessage) => message.id !== messageId);
    this.messages.unshift(new MailMessage(messageId, account.id, MailFolder.DRAFTS,
      new MailAddress(account.displayName, account.email), [new MailAddress('', draft.to)],
      draft.subject, draft.body, draft.body, '刚刚', true, false, draft.attachments.length > 0));
    this.attachments.set(messageId, draft.attachments.slice());
    return messageId;
  }

  async deleteDraft(messageId: string): Promise<void> {
    this.messages = this.messages.filter((message: MailMessage) =>
      message.id !== messageId || message.folder !== MailFolder.DRAFTS);
    this.attachments.delete(messageId);
  }

  async send(draft: DraftMessage): Promise<void> {
    const account: EmailAccount | undefined = this.accounts.find((item: EmailAccount) => item.id === draft.accountId);
    if (!account) {
      throw new Error('请选择发件账户');
    }
    const messageId: string = `sent_${Date.now()}`;
    this.messages.unshift(new MailMessage(messageId, account.id, MailFolder.SENT,
      new MailAddress(account.displayName, account.email), [new MailAddress('', draft.to)],
      draft.subject, draft.body, draft.body, '刚刚', true, false, draft.attachments.length > 0));
    this.attachments.set(messageId, draft.attachments.slice());
    if (draft.id.length > 0) {
      this.messages = this.messages.filter((message: MailMessage) => message.id !== draft.id);
    }
  }
}
