import { picker } from '@kit.CoreFileKit';
import { contact } from '@kit.ContactsKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { DraftMessage, EmailAccount, MailAttachment } from '../model/MailModels';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { MailSendService, SendDeliveryResult } from '../service/MailSendService';
import { showToast } from '../common/Toast';

interface ComposeParams {
  draftId?: string;
  accountId?: string;
  to?: string;
  cc?: string;
  bcc?: string;
  subject?: string;
  body?: string;
  rfcMessageId?: string;
}

@Entry
@Component
struct Compose {
  private repository: LocalMailRepository = LocalMailRepository.shared();
  private sendService: MailSendService = new MailSendService(this.repository);
  @State private accounts: EmailAccount[] = [];
  @State private selectedAccountId: string = '';
  @State private showCcBcc: boolean = false;
  @State private isSending: boolean = false;
  @State private attachments: MailAttachment[] = [];
  @State private requestReadReceipt: boolean = false;
  @State private showFormatToolbar: boolean = false;
  @State private autoSaveText: string = '草稿自动保存';
  // 输入框内容是普通成员，输入过程中不再触发 build。
  // 但 TextInput/TextArea 的 text 只在节点重建时才重新取值，所以程序化改写内容
  // （草稿异步载入、插入格式、从联系人追加收件人）后要手动 +1，让输入框刷新一次。
  @State private inputRevision: number = 0;
  private to: string = '';
  private cc: string = '';
  private bcc: string = '';
  private subject: string = '';
  private body: string = '';
  private draftId: string = '';
  private inReplyTo: string = '';
  private rfcMessageId: string = '';
  private autoSaveTimer: number = -1;
  private draftIdSequence: number = 0;
  // 已经发起过一次返回（发送成功 / 关闭 / 舍弃草稿后的 router.back()），防止二次 back。
  private leaving: boolean = false;

  aboutToAppear(): void {
    const params: ComposeParams = this.getUIContext().getRouter().getParams() as ComposeParams;
    this.draftId = params.draftId ?? '';
    this.to = params.to ?? '';
    this.cc = params.cc ?? '';
    this.bcc = params.bcc ?? '';
    this.subject = params.subject ?? '';
    this.body = params.body ?? '';
    this.inReplyTo = params.rfcMessageId ?? '';
    this.showCcBcc = this.cc.length > 0 || this.bcc.length > 0;
    this.loadComposer(params.accountId ?? '');
  }

  // 页面销毁时清掉自动保存定时器：否则定时器会在页面已销毁后回调保存，白跑一次写库。
  aboutToDisappear(): void {
    this.clearAutoSaveTimer();
  }

  // 系统返回键与左上角关闭同一语义：走 close() 的草稿保存逻辑，而不是直接丢弃内容。
  onBackPress(): boolean {
    if (this.isSending || this.leaving) {
      return true;
    }
    this.close();
    return true;
  }

  private clearAutoSaveTimer(): void {
    if (this.autoSaveTimer >= 0) {
      clearTimeout(this.autoSaveTimer);
      this.autoSaveTimer = -1;
    }
  }

  private async loadComposer(preferredAccountId: string): Promise<void> {
    this.accounts = await this.repository.listAccounts();
    if (this.draftId.length > 0) {
      const draft: DraftMessage | undefined = await this.repository.getDraft(this.draftId);
      if (draft) {
        this.selectedAccountId = draft.accountId;
        this.to = draft.to;
        this.cc = draft.cc;
        this.bcc = draft.bcc;
        this.subject = draft.subject;
        this.body = draft.body;
        this.attachments = draft.attachments;
        this.requestReadReceipt = draft.requestReadReceipt;
        this.inReplyTo = draft.inReplyTo;
        this.rfcMessageId = draft.rfcMessageId;
        this.showCcBcc = draft.cc.length > 0 || draft.bcc.length > 0;
        this.refreshInputs();
        return;
      }
    }
    if (preferredAccountId.length > 0) {
      this.selectedAccountId = preferredAccountId;
    } else if (this.accounts.length > 0) {
      this.selectedAccountId = this.accounts[0].id;
    }
  }

  // 读取 inputRevision 让输入框节点登记依赖，值变化时用最新的普通成员刷新一次文本。
  private inputText(value: string): string {
    if (this.inputRevision < 0) {
      return '';
    }
    return value;
  }

  private refreshInputs(): void {
    this.inputRevision = this.inputRevision + 1;
  }

  private currentAccount(): EmailAccount | undefined {
    return this.accounts.find((account: EmailAccount) => account.id === this.selectedAccountId);
  }

  private accountMenuItems(): MenuElement[] {
    return this.accounts.map((account: EmailAccount): MenuElement => {
      return {
        value: account.id === this.selectedAccountId ?
          `已选 · ${account.displayName} · ${account.email}` : `${account.displayName} · ${account.email}`,
        icon: $r('app.media.ic_mail'),
        action: () => {
          this.selectedAccountId = account.id;
          this.scheduleAutoSave();
        }
      };
    });
  }

  private composeMoreMenuItems(): MenuElement[] {
    return [
      {
        value: '立即保存草稿',
        icon: $r('app.media.ic_draft'),
        action: () => this.saveCurrentDraft(true)
      },
      {
        value: this.requestReadReceipt ? '取消阅读回执' : '请求阅读回执',
        icon: $r('app.media.ic_mail'),
        action: () => {
          this.requestReadReceipt = !this.requestReadReceipt;
          this.scheduleAutoSave();
        }
      },
      {
        value: '舍弃草稿',
        icon: $r('app.media.ic_delete'),
        action: () => this.discardDraft()
      }
    ];
  }

  private buildDraft(): DraftMessage {
    return new DraftMessage(this.selectedAccountId, this.to, this.cc, this.subject, this.body,
      this.bcc, this.draftId, this.attachments, this.requestReadReceipt, this.inReplyTo,
      this.rfcMessageId);
  }

  private hasDraftContent(): boolean {
    return this.to.length > 0 || this.cc.length > 0 || this.bcc.length > 0 ||
      this.subject.length > 0 || this.body.length > 0 || this.attachments.length > 0;
  }

  private scheduleAutoSave(): void {
    this.clearAutoSaveTimer();
    this.autoSaveText = '等待自动保存';
    this.autoSaveTimer = setTimeout(() => {
      this.autoSaveTimer = -1;
      this.saveCurrentDraft(false);
    }, 1200);
  }

  private async saveCurrentDraft(showFeedback: boolean): Promise<void> {
    if (!this.hasDraftContent() || this.selectedAccountId.length === 0) {
      this.autoSaveText = '草稿自动保存';
      return;
    }
    try {
      this.autoSaveText = '正在保存草稿';
      this.draftId = await this.repository.saveDraft(this.buildDraft());
      this.autoSaveText = '草稿已保存';
      if (showFeedback) {
        showToast('草稿已保存');
      }
    } catch (error) {
      this.autoSaveText = '草稿保存失败';
      if (showFeedback) {
        showToast(`${error}`);
      }
    }
  }

  private async discardDraft(): Promise<void> {
    if (this.leaving) {
      return;
    }
    this.leaving = true;
    this.clearAutoSaveTimer();
    try {
      if (this.draftId.length > 0) {
        await this.repository.deleteDraft(this.draftId);
      }
      showToast('草稿已舍弃');
    } catch (error) {
      this.leaving = false;
      showToast(`舍弃草稿失败：${error}`);
      return;
    }
    this.getUIContext().getRouter().back();
  }

  private attachmentName(uri: string): string {
    const cleanUri: string = uri.split('?')[0];
    const parts: string[] = cleanUri.split('/');
    const name: string = parts.length > 0 ? parts[parts.length - 1] : '';
    return name.length > 0 ? name : '附件';
  }

  // 附件目录按草稿 id 命名，所以选附件时就得先把 id 定下来；之后保存草稿沿用同一个 id，
  // 目录才能随草稿一起清理。进程内自增序号避免同一毫秒创建两个草稿时撞 id（撞了会共用一个附件目录）。
  private ensureDraftId(): string {
    if (this.draftId.length === 0) {
      this.draftIdSequence++;
      this.draftId = `draft_${Date.now()}_${this.draftIdSequence}`;
    }
    return this.draftId;
  }

  // picker 给的是临时授权的 URI，进程重启后必然 EACCES：选中后立刻复制进沙箱，草稿只存沙箱路径。
  private async addAttachmentUris(uris: string[], mimeType: string): Promise<void> {
    const existingUris: string[] = this.attachments.map((attachment: MailAttachment) => attachment.uri);
    const existingNames: string[] = this.attachments.map((attachment: MailAttachment) => attachment.name);
    const additions: MailAttachment[] = [];
    for (let index: number = 0; index < uris.length; index++) {
      const name: string = this.attachmentName(uris[index]);
      if (existingUris.includes(uris[index]) || existingNames.includes(name)) {
        continue;
      }
      existingNames.push(name);
      try {
        additions.push(await this.repository.importDraftAttachment(this.ensureDraftId(), name,
          uris[index], mimeType));
      } catch (error) {
        showToast(`附件 ${name} 未能保存到本机：${error}`);
      }
    }
    if (additions.length > 0) {
      this.attachments = this.attachments.concat(additions);
      this.scheduleAutoSave();
    }
  }

  private async selectAttachments(): Promise<void> {
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 10;
      const uris: string[] = await documentPicker.select(options);
      await this.addAttachmentUris(uris, 'application/octet-stream');
    } catch (error) {
      showToast(`未能选择附件：${error}`);
    }
  }

  private async selectImages(): Promise<void> {
    try {
      const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 10;
      const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select(options);
      await this.addAttachmentUris(result.photoUris, 'image/*');
    } catch (error) {
      showToast(`未能选择图片：${error}`);
    }
  }

  private async selectContacts(): Promise<void> {
    try {
      const contacts: contact.Contact[] = await contact.selectContacts();
      const addresses: string[] = [];
      for (let contactIndex: number = 0; contactIndex < contacts.length; contactIndex++) {
        const emails: contact.Email[] = contacts[contactIndex].emails ?? [];
        for (let emailIndex: number = 0; emailIndex < emails.length; emailIndex++) {
          if (emails[emailIndex].email.length > 0) {
            addresses.push(emails[emailIndex].email);
          }
        }
      }
      if (addresses.length > 0) {
        this.to = this.to.trim().length > 0 ? `${this.to}, ${addresses.join(', ')}` : addresses.join(', ');
        this.refreshInputs();
        this.scheduleAutoSave();
      } else {
        showToast('所选联系人没有邮箱地址');
      }
    } catch (error) {
      showToast(`未能选择联系人：${error}`);
    }
  }

  // 移除附件时连同沙箱文件一起删，避免留下没人引用的残留文件。
  private async removeAttachment(attachmentId: string): Promise<void> {
    const removed: MailAttachment[] = this.attachments.filter(
      (attachment: MailAttachment) => attachment.id === attachmentId);
    this.attachments = this.attachments.filter((attachment: MailAttachment) => attachment.id !== attachmentId);
    for (let index: number = 0; index < removed.length; index++) {
      await this.repository.removeAttachmentFile(removed[index].uri);
    }
    this.scheduleAutoSave();
  }

  private insertFormatting(prefix: string, suffix: string): void {
    this.body = `${this.body}${this.body.length > 0 ? '\n' : ''}${prefix}文本${suffix}`;
    this.refreshInputs();
    this.scheduleAutoSave();
  }

  private async send(): Promise<void> {
    if (this.selectedAccountId.length === 0) {
      showToast('请先添加或选择发件账户');
      return;
    }
    if (this.to.trim().length === 0) {
      showToast('请输入收件人');
      return;
    }
    const invalidAddress: string = this.firstInvalidAddress();
    if (invalidAddress.length > 0) {
      showToast(`邮箱地址格式不正确：${invalidAddress}`);
      return;
    }
    if (this.subject.trim().length === 0) {
      AlertDialog.show({
        title: '邮件没有主题',
        message: '确定仍要发送这封邮件吗？',
        primaryButton: { value: '返回填写', action: () => {} },
        secondaryButton: { value: '继续发送', action: () => this.deliver() }
      });
      return;
    }
    await this.deliver();
  }

  private mailbox(value: string): string {
    const clean: string = value.trim();
    const angle: RegExpMatchArray | null = clean.match(/<([^<>]+)>/);
    return (angle ? angle[1] : clean).trim();
  }

  private firstInvalidAddress(): string {
    const values: string[] = `${this.to},${this.cc},${this.bcc}`.split(/[;,]/)
      .map((value: string) => value.trim()).filter((value: string) => value.length > 0);
    const pattern: RegExp = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;
    for (let index: number = 0; index < values.length; index++) {
      if (!pattern.test(this.mailbox(values[index]))) {
        return values[index];
      }
    }
    return '';
  }

  private async deliver(): Promise<void> {
    if (this.isSending || this.leaving) return;
    this.isSending = true;
    try {
      this.clearAutoSaveTimer();
      const accountId: string = this.selectedAccountId;
      await this.repository.send(this.buildDraft());
      showToast('已存入发件箱，正在发送…');
      this.flushOutbox(accountId);
      // 记下“已发起返回”，避免发送成功后用户再按返回键弹掉下一层页面。
      this.leaving = true;
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.leaving = false;
      await this.saveCurrentDraft(false);
      showToast(`发送失败，草稿已保留：${error}`);
    } finally {
      this.isSending = false;
    }
  }

  private async flushOutbox(accountId: string): Promise<void> {
    try {
      const result: SendDeliveryResult = await this.sendService.deliverPendingSends(accountId);
      if (result.delivered > 0) {
        showToast('邮件已发送');
      }
      if (result.firstError.length > 0) {
        showToast(`邮件暂未发出，将自动重试：${result.firstError}`);
      }
    } catch (_error) {
    }
  }

  private async close(): Promise<void> {
    if (this.leaving) {
      return;
    }
    this.leaving = true;
    this.clearAutoSaveTimer();
    if (this.hasDraftContent()) {
      await this.saveCurrentDraft(true);
    }
    this.getUIContext().getRouter().back();
  }

  @Builder
  private fieldLabel(label: string) {
    Text(label).width(58).fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
  }

  @Builder
  private bottomTool(icon: Resource, action: () => void) {
    Button() {
      Image(icon).width(22).height(22).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurfaceVariant'))
    }
    .width(48).height(48).backgroundColor(Color.Transparent).onClick(action)
  }

  build() {
    Column() {
      Row() {
        Button() {
          Image($r('app.media.ic_close')).width(23).height(23).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurface'))
        }
          .width(48).height(48).backgroundColor(Color.Transparent)
          .enabled(!this.isSending && !this.leaving)
          .onClick(() => this.close())
        Text('写邮件').layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface'))
        Row() {}.width(48).height(48)
      }
      .width('100%').height(56).padding({ left: 4, right: 8 })
      .backgroundColor($r('app.color.surfaceLowest'))

      Column() {
        Row() {
          this.fieldLabel('发件人')
          Column({ space: 2 }) {
            Text(this.currentAccount()?.displayName ?? '邮箱账户').fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.onSurface')).maxLines(1)
            Text(this.currentAccount()?.email ?? '').fontSize(12)
              .fontColor($r('app.color.onSurfaceVariant')).maxLines(1)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Image($r('app.media.ic_chevron_down')).width(20).height(20).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurfaceVariant'))
        }
        .width('100%').height(56).padding({ left: 16, right: 16 })
        .border({ width: { bottom: 1 }, color: $r('app.color.outlineVariant') })
        .bindMenu(this.accountMenuItems(), { placement: Placement.BottomRight, enableArrow: true })

        Row() {
          this.fieldLabel('收件人')
          TextInput({ placeholder: '输入邮箱地址', text: this.inputText(this.to) })
            .layoutWeight(1).height(52).fontSize(15).type(InputType.Email)
            .padding({ left: 2, right: 2 }).backgroundColor(Color.Transparent)
            .onChange((value: string) => {
              this.to = value;
              this.scheduleAutoSave();
            })
          Button() {
            Image(this.showCcBcc ? $r('app.media.ic_chevron_up') : $r('app.media.ic_chevron_down'))
              .width(20).height(20).objectFit(ImageFit.Contain).fillColor($r('app.color.primary'))
          }
          .width(44).height(44).backgroundColor(Color.Transparent)
          .onClick(() => this.showCcBcc = !this.showCcBcc)
          Button() {
            Image($r('app.media.ic_contacts_add')).width(22).height(22).objectFit(ImageFit.Contain)
              .fillColor($r('app.color.primary'))
          }
          .width(44).height(44).backgroundColor(Color.Transparent)
          .onClick(() => this.selectContacts())
        }
        .width('100%').padding({ left: 16, right: 8 })
        .border({ width: { bottom: 1 }, color: $r('app.color.outlineVariant') })

        if (this.showCcBcc) {
          Row() {
            this.fieldLabel('抄送')
            TextInput({ placeholder: '输入抄送地址', text: this.inputText(this.cc) })
              .layoutWeight(1).height(50).fontSize(14).backgroundColor(Color.Transparent)
              .onChange((value: string) => {
                this.cc = value;
                this.scheduleAutoSave();
              })
          }.width('100%').padding({ left: 16, right: 16 })
          Row() {
            this.fieldLabel('密送')
            TextInput({ placeholder: '输入密送地址', text: this.inputText(this.bcc) })
              .layoutWeight(1).height(50).fontSize(14).backgroundColor(Color.Transparent)
              .onChange((value: string) => {
                this.bcc = value;
                this.scheduleAutoSave();
              })
          }
          .width('100%').padding({ left: 16, right: 16 })
          .border({ width: { bottom: 1 }, color: $r('app.color.outlineVariant') })
        }

        Row() {
          this.fieldLabel('主题')
          TextInput({ placeholder: '主题', text: this.inputText(this.subject) })
            .layoutWeight(1).height(52).fontSize(15).backgroundColor(Color.Transparent)
            .onChange((value: string) => {
              this.subject = value;
              this.scheduleAutoSave();
            })
        }
        .width('100%').height(54).padding({ left: 16, right: 16 })
        .border({ width: { bottom: 1 }, color: $r('app.color.outlineVariant') })

        if (this.attachments.length > 0) {
          List({ space: 2 }) {
            ForEach(this.attachments, (attachment: MailAttachment) => {
              ListItem() {
                Row({ space: 10 }) {
                  Image(attachment.mimeType === 'image/*' ? $r('app.media.ic_image') :
                    $r('app.media.ic_attachment')).width(20).height(20).objectFit(ImageFit.Contain)
                    .fillColor($r('app.color.primary'))
                  Text(attachment.name).layoutWeight(1).fontSize(13).fontColor($r('app.color.onSurface'))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Button() {
                    Image($r('app.media.ic_close')).width(18).height(18).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurfaceVariant'))
                  }
                  .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
                  .onClick(() => this.removeAttachment(attachment.id))
                }
                .width('100%').height(52).padding({ left: 18, right: 6 })
                .backgroundColor($r('app.color.surfaceContainer'))
              }
            }, (attachment: MailAttachment) => attachment.id)
          }.width('100%').height(Math.min(this.attachments.length * 54, 162)).scrollBar(BarState.Off)
        }

        TextArea({ placeholder: '撰写邮件内容…', text: this.inputText(this.body) })
          .width('100%').layoutWeight(1).fontSize(16).lineHeight(25)
          .fontColor($r('app.color.onSurface')).backgroundColor($r('app.color.surfaceLowest'))
          .padding({ left: 18, right: 18, top: 16, bottom: 16 })
          .onChange((value: string) => {
            this.body = value;
            this.scheduleAutoSave();
          })

        if (this.showFormatToolbar) {
          Row({ space: 6 }) {
            Button('粗体').height(44).fontSize(12).borderRadius(ThunderbirdTheme.controlRadius)
              .backgroundColor($r('app.color.primaryContainer')).fontColor($r('app.color.primary'))
              .onClick(() => this.insertFormatting('**', '**'))
            Button('斜体').height(44).fontSize(12).borderRadius(ThunderbirdTheme.controlRadius)
              .backgroundColor($r('app.color.primaryContainer')).fontColor($r('app.color.primary'))
              .onClick(() => this.insertFormatting('_', '_'))
            Button('引用').height(44).fontSize(12).borderRadius(ThunderbirdTheme.controlRadius)
              .backgroundColor($r('app.color.primaryContainer')).fontColor($r('app.color.primary'))
              .onClick(() => this.insertFormatting('> ', ''))
            Button('列表').height(44).fontSize(12).borderRadius(ThunderbirdTheme.controlRadius)
              .backgroundColor($r('app.color.primaryContainer')).fontColor($r('app.color.primary'))
              .onClick(() => this.insertFormatting('- ', ''))
          }
          .width('100%').height(56).padding({ left: 10, right: 10 })
          .backgroundColor($r('app.color.surfaceLow'))
          .border({ width: { top: 1 }, color: $r('app.color.outlineVariant') })
        }

        Column() {
          Row() {
            Text(this.requestReadReceipt ? `阅读回执 · ${this.autoSaveText}` : this.autoSaveText)
              .layoutWeight(1).fontSize(12).fontColor(this.requestReadReceipt ?
                $r('app.color.primary') : $r('app.color.onSurfaceVariant'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%').height(24).padding({ left: 16, right: 16 })

          Row() {
            this.bottomTool($r('app.media.ic_attachment'), () => this.selectAttachments())
            this.bottomTool($r('app.media.ic_image'), () => this.selectImages())
            this.bottomTool($r('app.media.ic_format'), () => this.showFormatToolbar = !this.showFormatToolbar)
            Blank()
            Button() {
              if (this.isSending) {
                LoadingProgress().width(20).height(20).color($r('app.color.onPrimary'))
              } else {
                Row({ space: 6 }) {
                  Image($r('app.media.ic_send')).width(18).height(18).objectFit(ImageFit.Contain)
                    .fillColor($r('app.color.onPrimary'))
                  Text('发送').fontSize(13).fontWeight(FontWeight.Bold).fontColor($r('app.color.onPrimary'))
                }
              }
            }
            .width(84).height(44).borderRadius(ThunderbirdTheme.controlRadius)
            .backgroundColor($r('app.color.primary')).enabled(!this.isSending).onClick(() => this.send())
            Button() {
              Image($r('app.media.ic_more')).width(21).height(21).objectFit(ImageFit.Contain)
                .fillColor($r('app.color.onSurfaceVariant'))
            }
            .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
            .bindMenu(this.composeMoreMenuItems(), { placement: Placement.TopRight, enableArrow: true })
          }
          .width('100%').height(56).padding({ left: 4, right: 6 })
        }
        .width('100%').height(80)
        .border({ width: { top: 1 }, color: $r('app.color.outlineVariant') })
      }
      .layoutWeight(1).width('100%')
      .backgroundColor($r('app.color.surfaceLowest'))
    }
    .width('100%').height('100%').backgroundColor($r('app.color.surfaceLowest'))
  }
}
