import { MemoryCredentialVault } from "@bundle:com.mailhelper.app/entry/ets/security/CredentialVault";
import type { CredentialVault } from "@bundle:com.mailhelper.app/entry/ets/security/CredentialVault";
import { EmailAccount, EmailProviderType, MailAddress, MailFolder, MailMessage } from "@bundle:com.mailhelper.app/entry/ets/model/MailModels";
import type { DraftMessage } from "@bundle:com.mailhelper.app/entry/ets/model/MailModels";
import type { MailRepository } from './MailRepository';
export class MockMailRepository implements MailRepository {
    private static instance: MockMailRepository = new MockMailRepository();
    private vault: CredentialVault = new MemoryCredentialVault();
    private accounts: EmailAccount[] = [];
    private messages: MailMessage[] = [];
    private constructor() {
        this.seed();
    }
    static shared(): MockMailRepository {
        return MockMailRepository.instance;
    }
    private seed(): void {
        const qq: EmailAccount = new EmailAccount('account_qq', 'hello@qq.com', '工作邮箱', EmailProviderType.QQ, '#2878FF', '', 3);
        const gmail: EmailAccount = new EmailAccount('account_gmail', 'hello@gmail.com', '个人邮箱', EmailProviderType.GMAIL, '#EA4335', '', 1);
        this.accounts = [qq, gmail];
        this.messages = [
            new MailMessage('mail_1', qq.id, MailFolder.INBOX, new MailAddress('项目团队', 'team@example.com'), [new MailAddress('我', qq.email)], '邮箱助手第一版设计评审', '界面稿和同步架构已经准备好了，请查看本周的评审安排。', '你好，\n\n邮箱助手第一版的界面稿和同步架构已经准备好了。请查看附件中的评审材料，我们将在本周五下午进行评审。\n\n谢谢！', '10:32', false, true, true),
            new MailMessage('mail_2', gmail.id, MailFolder.INBOX, new MailAddress('Google', 'no-reply@accounts.google.com'), [new MailAddress('我', gmail.email)], '安全提醒', '你的 Google 账号刚刚在新设备上完成了登录。', '你的 Google 账号刚刚在一台新设备上完成了登录。如果这是你本人操作，则无需执行任何操作。', '昨天', false, false, false),
            new MailMessage('mail_3', qq.id, MailFolder.INBOX, new MailAddress('李明', 'liming@example.com'), [new MailAddress('我', qq.email)], 'Re: 周报整理', '数据部分已经补充，剩余内容明天上午完成。', '数据部分已经补充到共享文档里，剩余内容明天上午完成。', '周二', false, false, false),
            new MailMessage('mail_4', qq.id, MailFolder.INBOX, new MailAddress('产品快讯', 'weekly@example.com'), [new MailAddress('我', qq.email)], '本周产品与技术快讯', '本期关注 HarmonyOS NEXT、端侧智能和隐私计算。', '本期关注 HarmonyOS NEXT、端侧智能和隐私计算。退订请访问订阅中心。', '周一', true, false, false)
        ];
    }
    async listAccounts(): Promise<EmailAccount[]> {
        return this.accounts.slice();
    }
    async listMessages(accountId: string, folder: MailFolder): Promise<MailMessage[]> {
        return this.messages.filter((message: MailMessage) => message.folder === folder && (accountId === 'all' || message.accountId === accountId));
    }
    async getMessage(messageId: string): Promise<MailMessage | undefined> {
        return this.messages.find((message: MailMessage) => message.id === messageId);
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
    async markRead(messageId: string): Promise<void> {
        const message: MailMessage | undefined = await this.getMessage(messageId);
        if (message) {
            message.isRead = true;
        }
    }
    async toggleStar(messageId: string): Promise<void> {
        const message: MailMessage | undefined = await this.getMessage(messageId);
        if (message) {
            message.isStarred = !message.isStarred;
        }
    }
    async send(draft: DraftMessage): Promise<void> {
        const account: EmailAccount | undefined = this.accounts.find((item: EmailAccount) => item.id === draft.accountId);
        if (!account) {
            throw new Error('请选择发件账户');
        }
        this.messages.unshift(new MailMessage(`sent_${Date.now()}`, account.id, MailFolder.SENT, new MailAddress(account.displayName, account.email), [new MailAddress('', draft.to)], draft.subject, draft.body, draft.body, '刚刚', true));
    }
}
