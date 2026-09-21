import { common, Want, wantConstant } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { EmailAccount, MailAddress, MailAttachment, MailFolder, MailMessage } from '../model/MailModels';
import { MailDateGroup } from '../common/MailListRow';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { AccountSyncResult, MailAccountSyncService } from '../service/MailAccountSyncService';
import { showToast } from '../common/Toast';

interface MailDetailParams {
  mailId: string;
}

// 与 MimeBodyParser 的单附件上限一致：超过它的附件本就不会下载，文案要区分“太大”和“只下了一部分”。
const ATTACHMENT_SIZE_LIMIT: number = 15 * 1024 * 1024;

@Entry
@Component
struct MailDetail {
  private repository: LocalMailRepository = LocalMailRepository.shared();
  private syncService: MailAccountSyncService = new MailAccountSyncService(this.repository);
  @State private message?: MailMessage = undefined;
  @State private showRecipientDetails: boolean = false;
  @State private showQuotedText: boolean = false;
  @State private attachments: MailAttachment[] = [];
  @State private ccRecipients: MailAddress[] = [];
  @State private actionInProgress: boolean = false;
  @State private remoteImages: boolean = false;
  // 邮件不存在（已删除 / 被同步清掉）时不再永久转圈，直接给可返回的空状态。
  @State private loadFailed: boolean = false;
  // 已经发起过一次返回（删除 / 归档 / 移动后的 router.back()），防止二次 back 把上一层也弹掉。
  private leaving: boolean = false;
  // 洗好的 HTML 与引用正文缓存：只在邮件加载完成或切换“显示远程图片”时重算，build 直接消费。
  // 用 @State 是为了让 RichText / Text 节点登记依赖（普通成员改动不会触发节点更新）。
  @State private styledHtmlCache: string = '';
  @State private quotedTextCache: string = '';

  aboutToAppear(): void {
    const params: MailDetailParams = this.getUIContext().getRouter().getParams() as MailDetailParams;
    this.loadMessage(params.mailId);
  }

  // 返回键在动作进行中 / 已发起返回时吃掉，避免与动作自己的 router.back() 叠加成两次返回。
  onBackPress(): boolean {
    return this.actionInProgress || this.leaving;
  }

  private async loadMessage(messageId: string): Promise<void> {
    try {
      const message: MailMessage | undefined = await this.repository.getMessage(messageId);
      if (!message) {
        this.loadFailed = true;
        return;
      }
      this.attachments = await this.repository.listAttachments(messageId);
      this.ccRecipients = await this.repository.listMessageAddresses(messageId, 'cc');
      this.remoteImages = (await this.repository.getSetting('remote_images', 'false')) === 'true';
      this.quotedTextCache = this.extractQuotedText(message.plainBody);
      this.styledHtmlCache = this.buildStyledHtml(message, this.remoteImages);
      this.message = message;
    } catch (error) {
      this.loadFailed = true;
      showToast(`无法加载邮件：${error}`);
    }
  }

  private showRemoteImages(): void {
    this.remoteImages = true;
    this.styledHtmlCache = this.buildStyledHtml(this.message, true);
  }

  private buildStyledHtml(message: MailMessage | undefined, remoteImages: boolean): string {
    if (!message || message.htmlBody.length === 0) return '';
    let html: string = message.htmlBody;
    html = html.replace(/<meta\b[^>]*name\s*=\s*["']?viewport["']?[^>]*>/gi, '');
    if (!remoteImages) {
      html = html.replace(/\s+src\s*=\s*(["'])https?:\/\/[\s\S]*?\1/gi, '')
        .replace(/\s+src\s*=\s*https?:\/\/[^\s>]+/gi, '')
        .replace(/\s+srcset\s*=\s*(["'])[\s\S]*?\1/gi, '')
        .replace(/\s+background\s*=\s*(["'])https?:\/\/[\s\S]*?\1/gi, '')
        .replace(/url\(\s*(["']?)https?:\/\/[^)]*\)/gi, 'none');
    }
    html = html
      .replace(/font-size\s*:\s*(?:[6-9]|1[0-5])(?:\.\d+)?px(?:\s*!important)?/gi,
        'font-size:16px!important')
      .replace(/font-size\s*:\s*(?:[4-9]|1[01])(?:\.\d+)?pt(?:\s*!important)?/gi,
        'font-size:16px!important');
    const responsiveStyle: string =
      '<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=5.0,user-scalable=yes">' +
      '<style>' +
      'html,body{width:100%!important;min-width:0!important;max-width:100%!important;' +
      'height:auto!important;min-height:0!important;' +
      'margin:0!important;padding:0!important;background:transparent;overflow-x:hidden;' +
      'overflow-wrap:anywhere;word-break:normal;' +
      '-webkit-text-size-adjust:100%;box-sizing:border-box;}' +
      'body{font-size:18px!important;line-height:1.65!important;}' +
      'body p,body li,body td,body th{font-size:max(16px,1em)!important;line-height:1.65!important;}' +
      'body span,body a{font-size:max(16px,1em)!important;}' +
      'table{width:100%!important;min-width:0!important;max-width:100%!important;' +
      'height:auto!important;min-height:0!important;table-layout:auto!important;border-collapse:collapse;}' +
      'tbody,tr,td,th,div,section,article,main,center{min-width:0!important;max-width:100%!important;' +
      'height:auto!important;min-height:0!important;box-sizing:border-box;}' +
      'td,th{overflow-wrap:anywhere;word-break:break-word;}' +
      '[width],body [style*="width"]{max-width:100%!important;}' +
      'img,video,svg,canvas{max-width:100%!important;height:auto!important;}' +
      'pre{max-width:100%;white-space:pre-wrap;overflow-wrap:anywhere;}' +
      'blockquote{max-width:100%;margin-left:12px!important;margin-right:0!important;}' +
      '</style>';
    if (/<\/head>/i.test(html)) {
      return html.replace(/<\/head>/i, `${responsiveStyle}</head>`);
    }
    if (/<html\b/i.test(html)) {
      return html.replace(/<html([^>]*)>/i, `<html$1><head>${responsiveStyle}</head>`);
    }
    return `<!doctype html><html><head>${responsiveStyle}</head><body>${html}</body></html>`;
  }

  private async archive(): Promise<void> {
    await this.moveTo(MailFolder.ARCHIVE, '邮件已归档');
  }

  private async remove(): Promise<void> {
    if (!this.message || this.actionInProgress || this.leaving) return;
    this.actionInProgress = true;
    try {
      await this.repository.deleteMessages([this.message.id]);
      showToast('邮件已移至垃圾箱');
      await this.pushCurrentAccountOperations();
      this.leaving = true;
      this.getUIContext().getRouter().back();
    } catch (error) {
      showToast(`删除失败：${error}`);
    } finally {
      this.actionInProgress = false;
    }
  }

  private async moveTo(folder: MailFolder, message: string): Promise<void> {
    if (!this.message || this.actionInProgress || this.leaving) return;
    this.actionInProgress = true;
    try {
      await this.repository.moveMessages([this.message.id], folder);
      showToast(message);
      await this.pushCurrentAccountOperations();
      this.leaving = true;
      this.getUIContext().getRouter().back();
    } catch (error) {
      showToast(`移动失败：${error}`);
    } finally {
      this.actionInProgress = false;
    }
  }

  private replySubject(kind: string): string {
    if (!this.message) return '';
    const subject: string = this.message.subject;
    if (kind === 'forward') {
      return /^fwd?:\s/i.test(subject) ? subject : `Fwd: ${subject}`;
    }
    return /^re:\s/i.test(subject) ? subject : `Re: ${subject}`;
  }

  private uniqueReplyAllAddresses(accountEmail: string): string {
    if (!this.message) return '';
    const excluded: string[] = [accountEmail.toLowerCase(), this.message.sender.address.toLowerCase()];
    const candidates: MailAddress[] = this.message.recipients.concat(this.ccRecipients);
    const values: string[] = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const address: string = candidates[index].address.trim();
      if (address.length > 0 && !excluded.includes(address.toLowerCase()) &&
        !values.map((value: string) => value.toLowerCase()).includes(address.toLowerCase())) {
        values.push(address);
      }
    }
    return values.join(', ');
  }

  private extractQuotedText(body: string): string {
    const separator: RegExpMatchArray | null = body.match(/\n(?:On .+wrote:|在.+写道：|[-]{5,}\s*(?:Original Message|转发邮件)\s*[-]{5,})/i);
    if (separator && separator.index !== undefined) {
      return body.substring(separator.index + 1).trim();
    }
    const lines: string[] = body.split('\n');
    const firstQuoted: number = lines.findIndex((line: string) => line.trim().startsWith('>'));
    return firstQuoted >= 0 ? lines.slice(firstQuoted).join('\n').replace(/^> ?/gm, '').trim() : '';
  }

  private quotedText(): string {
    return this.quotedTextCache;
  }

  private visibleBody(): string {
    if (!this.message) return '';
    const quoted: string = this.quotedTextCache;
    if (quoted.length === 0) return this.message.plainBody;
    const quotedIndex: number = this.message.plainBody.indexOf(quoted);
    if (quotedIndex > 0) return this.message.plainBody.substring(0, quotedIndex).replace(/\n?> ?$/, '').trim();
    const firstQuotedLine: number = this.message.plainBody.split('\n')
      .findIndex((line: string) => line.trim().startsWith('>'));
    return firstQuotedLine > 0 ? this.message.plainBody.split('\n').slice(0, firstQuotedLine).join('\n').trim() :
      this.message.plainBody;
  }

  private recipientDetailText(): string {
    if (!this.message) return '';
    const to: string = this.message.recipients.map((address: MailAddress) => address.address).join(', ');
    const cc: string = this.ccRecipients.map((address: MailAddress) => address.address).join(', ');
    return cc.length > 0 ? `收件人：${to}\n抄送：${cc}` : `收件人：${to.length > 0 ? to : '我'}`;
  }

  private async toggleRead(): Promise<void> {
    if (!this.message || this.actionInProgress) return;
    this.actionInProgress = true;
    try {
      await this.repository.toggleRead(this.message.id);
      this.message = await this.repository.getMessage(this.message.id);
      showToast(this.message?.isRead ? '已标为已读' : '已标为未读');
      await this.pushCurrentAccountOperations();
    } catch (error) {
      showToast(`更新已读状态失败：${error}`);
    } finally {
      this.actionInProgress = false;
    }
  }

  private async toggleStar(): Promise<void> {
    if (!this.message || this.actionInProgress) return;
    const wasStarred: boolean = this.message.isStarred;
    this.actionInProgress = true;
    try {
      await this.repository.toggleStar(this.message.id);
      this.message = await this.repository.getMessage(this.message.id);
      showToast(wasStarred ? '已取消星标' : '已添加星标');
      await this.pushCurrentAccountOperations();
    } catch (error) {
      showToast(`星标操作失败：${error}`);
    } finally {
      this.actionInProgress = false;
    }
  }

  private async pushCurrentAccountOperations(): Promise<void> {
    if (!this.message) return;
    const accounts: EmailAccount[] = await this.repository.listAccounts();
    const account: EmailAccount | undefined = accounts.find((item: EmailAccount) =>
      item.id === this.message?.accountId);
    if (!account) return;
    const result: AccountSyncResult = await this.syncService.pushPendingOperations(account);
    if (result.errorMessage.length > 0) {
      showToast(`本地操作已保存，将稍后同步：${result.errorMessage}`);
    }
  }

  private detailMoreMenuItems(): MenuElement[] {
    return [
      {
        value: '移到收件箱',
        icon: $r('app.media.ic_inbox'),
        action: () => this.moveTo(MailFolder.INBOX, '邮件已移到收件箱')
      },
      {
        value: '标为垃圾邮件',
        icon: $r('app.media.ic_spam'),
        action: () => this.moveTo(MailFolder.SPAM, '邮件已移到垃圾邮件')
      }
    ];
  }

  private async openComposer(kind: string): Promise<void> {
    if (!this.message) {
      return;
    }
    const accounts: EmailAccount[] = await this.repository.listAccounts();
    const currentAccount: EmailAccount | undefined = accounts.find((account: EmailAccount) =>
      account.id === this.message?.accountId);
    const cc: string = kind === 'replyAll' ? this.uniqueReplyAllAddresses(currentAccount?.email ?? '') : '';
    this.getUIContext().getRouter().pushUrl({ url: 'pages/Compose', params: {
      accountId: this.message.accountId,
      to: kind === 'forward' ? '' : this.message.sender.address,
      cc: cc,
      subject: this.replySubject(kind),
      rfcMessageId: kind === 'forward' ? '' : this.message.rfcMessageId,
      body: kind === 'forward' ?
        `\n\n---------- 转发邮件 ----------\n发件人：${this.message.sender.address}\n主题：${this.message.subject}\n\n${this.message.plainBody}` :
        `\n\n> ${this.message.plainBody.replace(/\n/g, '\n> ')}`
    } }).catch((error: Error) => showToast(`无法打开写信页面：${error.message}`));
  }

  private formatAttachmentSize(size: number): string {
    if (size < 1024) {
      return `${size} B`;
    }
    if (size < 1024 * 1024) {
      return `${(size / 1024).toFixed(1)} KB`;
    }
    return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  }

  // 没有本地文件时按大小区分原因：有大小但没落盘 = 正文被截断，只保留了元数据（未完整下载）；
  // 无大小或本身就超过下载上限 = 附件过大，压根不会下载。
  private attachmentDetail(attachment: MailAttachment): string {
    if (attachment.uri.length === 0) {
      return attachment.size > 0 && attachment.size <= ATTACHMENT_SIZE_LIMIT ? '未完整下载' : '附件过大未下载';
    }
    return attachment.size > 0 ? this.formatAttachmentSize(attachment.size) : '已下载';
  }

  private unavailableAttachmentHint(attachment: MailAttachment): string {
    return attachment.size > 0 && attachment.size <= ATTACHMENT_SIZE_LIMIT ?
      '附件未完整下载，请到网页邮箱查看' : '附件过大未下载，请到网页邮箱查看';
  }

  private attachmentUri(attachment: MailAttachment): string {
    const raw: string = attachment.uri;
    const path: string = raw.startsWith('file://') ? raw.substring(7) : raw;
    return path.startsWith('/') ? fileUri.getUriFromPath(path) : raw;
  }

  private async openAttachment(attachment: MailAttachment): Promise<void> {
    if (attachment.uri.length === 0) {
      showToast(this.unavailableAttachmentHint(attachment));
      return;
    }
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: this.attachmentUri(attachment),
        type: attachment.mimeType,
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      };
      await context.startAbility(want);
    } catch (error) {
      showToast(`无法打开附件：${error}`);
    }
  }

  @Builder
  private toolbarButton(icon: Resource, action: () => void) {
    Button() {
      Image(icon).width(23).height(23).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurface'))
    }
    .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22).onClick(action)
  }

  @Builder
  private attachment(attachment: MailAttachment) {
    Row({ space: 12 }) {
      Stack() {
        Rect().width(42).height(42).radius(10).fill($r('app.color.primaryContainer'))
        Image(attachment.mimeType.startsWith('image/') ? $r('app.media.ic_image') :
          $r('app.media.ic_attachment')).width(22).height(22).objectFit(ImageFit.Contain)
          .fillColor($r('app.color.primary'))
      }
      Column({ space: 3 }) {
        Text(attachment.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.onSurface'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.attachmentDetail(attachment))
          .fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button() {
        Image($r('app.media.ic_chevron_right')).width(22).height(22).objectFit(ImageFit.Contain).fillColor($r('app.color.outline'))
      }
      .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
      .onClick(() => this.openAttachment(attachment))
    }
    .width('100%').height(66).padding({ left: 12, right: 8 })
    .border({ width: 1, color: $r('app.color.cardBorder') }).borderRadius(ThunderbirdTheme.cardRadius)
    .backgroundColor($r('app.color.surfaceLow'))
  }

  @Builder
  private replyAction(icon: Resource, label: string, kind: string) {
    Button() {
      Row({ space: 8 }) {
        Image(icon).width(21).height(21).objectFit(ImageFit.Contain)
          .fillColor(kind === 'reply' ? $r('app.color.onPrimary') : $r('app.color.primary'))
        Text(label).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(kind === 'reply' ? $r('app.color.onPrimary') : $r('app.color.primary'))
      }
    }
    .layoutWeight(1).height(46)
    .backgroundColor(kind === 'reply' ? $r('app.color.primary') : $r('app.color.surfaceLowest'))
    .border({ width: 1, color: kind === 'reply' ? $r('app.color.primary') : $r('app.color.outlineVariant') })
    .borderRadius(ThunderbirdTheme.controlRadius)
    .onClick(() => this.openComposer(kind))
  }

  build() {
    Column() {
      Row() {
        Button() {
          Image($r('app.media.ic_back')).width(23).height(23).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.onSurface'))
        }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
        .enabled(!this.actionInProgress && !this.leaving)
        .onClick(() => this.getUIContext().getRouter().back())
        Blank()
        this.toolbarButton($r('app.media.ic_archive'), () => this.archive())
        this.toolbarButton($r('app.media.ic_delete'), () => this.remove())
        this.toolbarButton($r('app.media.ic_mail'), () => this.toggleRead())
        Button() {
          Image($r('app.media.ic_more')).width(23).height(23).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurface'))
        }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
        .bindMenu(this.detailMoreMenuItems(), { placement: Placement.BottomRight, enableArrow: true })
      }
      .width('100%').height(56).padding({ left: 4, right: 4 })
      .backgroundColor($r('app.color.surface'))

      if (this.message) {
        Scroll() {
          Column() {
            Row({ space: 10 }) {
              Text(this.message.subject)
                .layoutWeight(1).fontSize(22).lineHeight(29).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.onSurface'))
              Button() {
                Image(this.message.isStarred ? $r('app.media.ic_star_filled') : $r('app.media.ic_star'))
                  .width(25).height(25).objectFit(ImageFit.Contain)
              }
              .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
              .enabled(!this.actionInProgress).onClick(() => this.toggleStar())
            }
            .width('100%').alignItems(VerticalAlign.Top).margin({ bottom: 18 })

            Row({ space: 12 }) {
              Stack() {
                Circle().width(44).height(44).fill($r('app.color.primary'))
                Text(this.message.sender.name.substring(0, 1).toUpperCase())
                  .fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.onPrimary'))
              }
              Column({ space: 4 }) {
                Row() {
                  Text(this.message.sender.name).layoutWeight(1).fontSize(16)
                    .fontWeight(FontWeight.Bold).fontColor($r('app.color.onSurface')).maxLines(1)
                  Text(MailDateGroup.formatDetailTime(this.message.receivedAtMs))
                    .fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
                    .constraintSize({ maxWidth: 140 }).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.End)
                }.width('100%')
                Text(this.message.sender.address).fontSize(13).fontColor($r('app.color.onSurfaceVariant')).maxLines(1)
                Row({ space: 4 }) {
                  Text(this.showRecipientDetails ? this.recipientDetailText() : '收件人：我')
                    .fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
                    .maxLines(this.showRecipientDetails ? 3 : 1)
                  Image(this.showRecipientDetails ? $r('app.media.ic_chevron_up') :
                    $r('app.media.ic_chevron_down'))
                    .width(15).height(15).objectFit(ImageFit.Contain).fillColor($r('app.color.onSurfaceVariant'))
                }.onClick(() => this.showRecipientDetails = !this.showRecipientDetails)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }
            .width('100%').padding({ bottom: 18 })

            Divider().color($r('app.color.outlineVariant')).margin({ bottom: 18 })

            if (this.message.htmlBody.length > 0) {
              if (!this.remoteImages) {
                Row({ space: 8 }) {
                  Image($r('app.media.ic_image')).width(18).height(18).objectFit(ImageFit.Contain)
                    .fillColor($r('app.color.onSurfaceVariant'))
                  Text('已阻止远程图片').layoutWeight(1).fontSize(13)
                    .fontColor($r('app.color.onSurfaceVariant'))
                  Text('显示图片').fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.primary'))
                }
                .width('100%').height(44).padding({ left: 10, right: 10 })
                .backgroundColor($r('app.color.surfaceContainer')).borderRadius(8)
                .margin({ bottom: 14 }).onClick(() => this.showRemoteImages())
              }
              RichText(this.styledHtmlCache).width('100%').constraintSize({ minHeight: 120 })
                .margin({ bottom: 20 })
            } else {
              Text(this.visibleBody())
                .width('100%').fontSize(17).lineHeight(28).fontColor($r('app.color.onSurface'))
                .margin({ bottom: 24 })
            }

            if (this.message.htmlBody.length === 0 && this.quotedText().length > 0) {
              Row({ space: 8 }) {
                Image($r('app.media.ic_more_horizontal')).width(20).height(20).objectFit(ImageFit.Contain)
                  .fillColor($r('app.color.primary'))
                Text(this.showQuotedText ? '隐藏引用内容' : '显示引用内容')
                  .fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.primary'))
              }
              .height(44).padding({ left: 12, right: 12 })
              .backgroundColor($r('app.color.surfaceContainer')).borderRadius(8)
              .margin({ bottom: this.showQuotedText ? 10 : 24 })
              .onClick(() => this.showQuotedText = !this.showQuotedText)

              if (this.showQuotedText) {
                Row() {
                  Rect().width(3).height(84).fill($r('app.color.outlineVariant')).margin({ right: 12 })
                  Text(this.quotedText())
                    .layoutWeight(1).fontSize(15).lineHeight(24).fontColor($r('app.color.onSurfaceVariant'))
                }.width('100%').margin({ bottom: 24 })
              }
            }

            if (this.attachments.length > 0) {
              Text(`附件 (${this.attachments.length})`).width('100%').fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.onSurface')).margin({ bottom: 12 })
              Column({ space: 10 }) {
                ForEach(this.attachments, (attachment: MailAttachment) => {
                  this.attachment(attachment)
                }, (attachment: MailAttachment) => attachment.id)
              }.width('100%').margin({ bottom: 26 })
            }

          }
          .width('100%')
          .constraintSize({ minHeight: '100%' })
          .padding({ left: 16, right: 16, top: 16, bottom: 20 })
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)
        }
        .layoutWeight(1).width('100%').scrollBar(BarState.Off)
        .backgroundColor($r('app.color.surfaceLowest'))

        Row({ space: 10 }) {
          this.replyAction($r('app.media.ic_reply'), '回复', 'reply')
          this.replyAction($r('app.media.ic_forward'), '转发', 'forward')
        }
        .width('100%').height(70).padding({ left: 16, right: 16, top: 10, bottom: 14 })
        .backgroundColor($r('app.color.surfaceLowest'))
        .border({ width: { top: 1 }, color: $r('app.color.outlineVariant') })
      } else if (this.loadFailed) {
        Column({ space: 12 }) {
          Image($r('app.media.ic_mail')).width(48).height(48).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.outline'))
          Text('邮件不存在或已删除').fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.onSurface'))
          Text('它可能已被删除，或随账户同步被移除').fontSize(13)
            .fontColor($r('app.color.onSurfaceVariant'))
          Button('返回')
            .height(44).padding({ left: 20, right: 20 })
            .backgroundColor($r('app.color.primary')).borderRadius(ThunderbirdTheme.pillRadius)
            .fontColor($r('app.color.onPrimary')).margin({ top: 6 })
            .onClick(() => this.getUIContext().getRouter().back())
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 12 }) {
          LoadingProgress().width(36).height(36).color($r('app.color.primary'))
          Text('正在加载邮件').fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').height('100%').backgroundColor($r('app.color.surfaceLowest'))
  }
}
