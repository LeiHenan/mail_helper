import { common, Want } from '@kit.AbilityKit';
import { LocalMailRepository } from '../data/LocalMailRepository';
import { EmailAccount, MailAddress, MailAttachment, MailFolder, MailMessage } from '../model/MailModels';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { AccountSyncResult, MailAccountSyncService } from '../service/MailAccountSyncService';

interface MailDetailParams {
  mailId: string;
}

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

  aboutToAppear(): void {
    const params: MailDetailParams = this.getUIContext().getRouter().getParams() as MailDetailParams;
    this.loadMessage(params.mailId);
  }

  private async loadMessage(messageId: string): Promise<void> {
    this.message = await this.repository.getMessage(messageId);
    this.attachments = await this.repository.listAttachments(messageId);
    this.ccRecipients = await this.repository.listMessageAddresses(messageId, 'cc');
    this.remoteImages = (await this.repository.getSetting('remote_images', 'false')) === 'true';
  }

  private styledHtml(): string {
    if (!this.message || this.message.htmlBody.length === 0) return '';
    let html: string = this.message.htmlBody;
    html = html.replace(/<meta\b[^>]*name\s*=\s*["']?viewport["']?[^>]*>/gi, '');
    if (!this.remoteImages) {
      html = html.replace(/\s+src\s*=\s*(["'])https?:\/\/[\s\S]*?\1/gi, '')
        .replace(/\s+src\s*=\s*https?:\/\/[^\s>]+/gi, '')
        .replace(/\s+srcset\s*=\s*(["'])[\s\S]*?\1/gi, '')
        .replace(/\s+background\s*=\s*(["'])https?:\/\/[\s\S]*?\1/gi, '')
        .replace(/url\(\s*(["']?)https?:\/\/[^)]*\)/gi, 'none');
    }
    html = html
      .replace(/font-size\s*:\s*(?:[6-9]|1[0-3])(?:\.\d+)?px(?:\s*!important)?/gi,
        'font-size:14px!important')
      .replace(/font-size\s*:\s*(?:[4-9]|10)(?:\.\d+)?pt(?:\s*!important)?/gi,
        'font-size:14px!important');
    const responsiveStyle: string =
      '<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=5.0,user-scalable=yes">' +
      '<style>' +
      'html,body{width:100%!important;min-width:0!important;max-width:100%!important;' +
      'height:auto!important;min-height:0!important;' +
      'margin:0!important;padding:0!important;background:transparent;overflow-x:hidden;' +
      'overflow-wrap:anywhere;word-break:normal;' +
      '-webkit-text-size-adjust:100%;box-sizing:border-box;}' +
      'body{font-size:16px!important;line-height:1.6!important;}' +
      'body p,body li,body td,body th{font-size:max(14px,1em)!important;line-height:1.6!important;}' +
      'body span,body a{font-size:max(14px,1em)!important;}' +
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
    if (!this.message || this.actionInProgress) return;
    this.actionInProgress = true;
    try {
      await this.repository.deleteMessages([this.message.id]);
      this.showToast('邮件已移至垃圾箱');
      await this.pushCurrentAccountOperations();
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.showToast(`删除失败：${error}`);
    } finally {
      this.actionInProgress = false;
    }
  }

  private showToast(_message: string): void {
  }

  private async moveTo(folder: MailFolder, message: string): Promise<void> {
    if (!this.message || this.actionInProgress) return;
    this.actionInProgress = true;
    try {
      await this.repository.moveMessages([this.message.id], folder);
      this.showToast(message);
      await this.pushCurrentAccountOperations();
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.showToast(`移动失败：${error}`);
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

  private quotedText(): string {
    if (!this.message) return '';
    const body: string = this.message.plainBody;
    const separator: RegExpMatchArray | null = body.match(/\n(?:On .+wrote:|在.+写道：|[-]{5,}\s*(?:Original Message|转发邮件)\s*[-]{5,})/i);
    if (separator && separator.index !== undefined) {
      return body.substring(separator.index + 1).trim();
    }
    const lines: string[] = body.split('\n');
    const firstQuoted: number = lines.findIndex((line: string) => line.trim().startsWith('>'));
    return firstQuoted >= 0 ? lines.slice(firstQuoted).join('\n').replace(/^> ?/gm, '').trim() : '';
  }

  private visibleBody(): string {
    if (!this.message) return '';
    const quoted: string = this.quotedText();
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
      this.showToast(this.message?.isRead ? '已标为已读' : '已标为未读');
      await this.pushCurrentAccountOperations();
    } catch (error) {
      this.showToast(`更新已读状态失败：${error}`);
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
      this.showToast(wasStarred ? '已取消星标' : '已添加星标');
      await this.pushCurrentAccountOperations();
    } catch (error) {
      this.showToast(`星标操作失败：${error}`);
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
      this.showToast(`本地操作已保存，将稍后同步：${result.errorMessage}`);
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
      body: kind === 'forward' ?
        `\n\n---------- 转发邮件 ----------\n发件人：${this.message.sender.address}\n主题：${this.message.subject}\n\n${this.message.plainBody}` :
        `\n\n> ${this.message.plainBody.replace(/\n/g, '\n> ')}`
    } }).catch((error: Error) => this.showToast(`无法打开写信页面：${error.message}`));
  }

  private async openAttachment(attachment: MailAttachment): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: attachment.uri,
        type: attachment.mimeType
      };
      await context.startAbility(want);
    } catch (error) {
      this.showToast(`无法打开附件：${error}`);
    }
  }

  @Builder
  private toolbarButton(icon: Resource, action: () => void) {
    Button() {
      Image(icon).width(23).height(23).objectFit(ImageFit.Contain)
    }
    .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22).onClick(action)
  }

  @Builder
  private attachment(attachment: MailAttachment) {
    Row({ space: 12 }) {
      Stack() {
        Rect().width(42).height(42).radius(10).fill(ThunderbirdTheme.primaryContainer)
        Image(attachment.mimeType === 'image/*' ? $r('app.media.ic_image') :
          $r('app.media.ic_attachment')).width(22).height(22).objectFit(ImageFit.Contain)
          .fillColor(ThunderbirdTheme.primary)
      }
      Column({ space: 3 }) {
        Text(attachment.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(ThunderbirdTheme.onSurface)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(attachment.size > 0 ? `${attachment.size} B` : '本地附件')
          .fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button() {
        Image($r('app.media.ic_chevron_right')).width(22).height(22).objectFit(ImageFit.Contain)
      }
      .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
      .onClick(() => this.openAttachment(attachment))
    }
    .width('100%').height(66).padding({ left: 12, right: 8 })
    .border({ width: 1, color: ThunderbirdTheme.cardBorder }).borderRadius(ThunderbirdTheme.cardRadius)
    .backgroundColor(ThunderbirdTheme.surfaceLow)
  }

  @Builder
  private replyAction(icon: Resource, label: string, kind: string) {
    Button() {
      Row({ space: 8 }) {
        Image(icon).width(21).height(21).objectFit(ImageFit.Contain)
          .fillColor(kind === 'reply' ? ThunderbirdTheme.onPrimary : ThunderbirdTheme.primary)
        Text(label).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(kind === 'reply' ? ThunderbirdTheme.onPrimary : ThunderbirdTheme.primary)
      }
    }
    .layoutWeight(1).height(46)
    .backgroundColor(kind === 'reply' ? ThunderbirdTheme.primary : ThunderbirdTheme.surfaceLowest)
    .border({ width: 1, color: kind === 'reply' ? ThunderbirdTheme.primary : ThunderbirdTheme.outlineVariant })
    .borderRadius(ThunderbirdTheme.controlRadius)
    .onClick(() => this.openComposer(kind))
  }

  build() {
    Column() {
      Row() {
        this.toolbarButton($r('app.media.ic_back'), () => this.getUIContext().getRouter().back())
        Blank()
        this.toolbarButton($r('app.media.ic_archive'), () => this.archive())
        this.toolbarButton($r('app.media.ic_delete'), () => this.remove())
        this.toolbarButton($r('app.media.ic_mail'), () => this.toggleRead())
        Button() {
          Image($r('app.media.ic_more')).width(23).height(23).objectFit(ImageFit.Contain)
        }
        .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
        .bindMenu(this.detailMoreMenuItems(), { placement: Placement.BottomRight, enableArrow: true })
      }
      .width('100%').height(56).padding({ left: 4, right: 4 })
      .backgroundColor(ThunderbirdTheme.surface)

      if (this.message) {
        Scroll() {
          Column() {
            Row({ space: 10 }) {
              Text(this.message.subject)
                .layoutWeight(1).fontSize(20).lineHeight(27).fontWeight(FontWeight.Bold)
                .fontColor(ThunderbirdTheme.onSurface)
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
                Circle().width(44).height(44).fill(ThunderbirdTheme.primary)
                Text(this.message.sender.name.substring(0, 1).toUpperCase())
                  .fontSize(17).fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onPrimary)
              }
              Column({ space: 4 }) {
                Row() {
                  Text(this.message.sender.name).layoutWeight(1).fontSize(15)
                    .fontWeight(FontWeight.Bold).fontColor(ThunderbirdTheme.onSurface).maxLines(1)
                  Text(this.message.receivedAt).fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
                    .constraintSize({ maxWidth: 120 }).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.End)
                }.width('100%')
                Text(this.message.sender.address).fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant).maxLines(1)
                Row({ space: 4 }) {
                  Text(this.showRecipientDetails ? this.recipientDetailText() : '收件人：我')
                    .fontSize(12).fontColor(ThunderbirdTheme.onSurfaceVariant)
                    .maxLines(this.showRecipientDetails ? 3 : 1)
                  Image(this.showRecipientDetails ? $r('app.media.ic_chevron_up') :
                    $r('app.media.ic_chevron_down'))
                    .width(15).height(15).objectFit(ImageFit.Contain)
                }.onClick(() => this.showRecipientDetails = !this.showRecipientDetails)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }
            .width('100%').padding({ bottom: 18 })

            Divider().color(ThunderbirdTheme.outlineVariant).margin({ bottom: 18 })

            if (this.message.htmlBody.length > 0) {
              if (!this.remoteImages) {
                Row({ space: 8 }) {
                  Image($r('app.media.ic_image')).width(18).height(18).objectFit(ImageFit.Contain)
                    .fillColor(ThunderbirdTheme.onSurfaceVariant)
                  Text('已阻止远程图片').layoutWeight(1).fontSize(12)
                    .fontColor(ThunderbirdTheme.onSurfaceVariant)
                  Text('显示图片').fontSize(12).fontWeight(FontWeight.Medium).fontColor(ThunderbirdTheme.primary)
                }
                .width('100%').height(44).padding({ left: 10, right: 10 })
                .backgroundColor(ThunderbirdTheme.surfaceContainer).borderRadius(8)
                .margin({ bottom: 14 }).onClick(() => this.remoteImages = true)
              }
              RichText(this.styledHtml()).width('100%').constraintSize({ minHeight: 120 })
                .margin({ bottom: 20 })
            } else {
              Text(this.visibleBody())
                .width('100%').fontSize(15).lineHeight(25).fontColor(ThunderbirdTheme.onSurface)
                .margin({ bottom: 24 })
            }

            if (this.message.htmlBody.length === 0 && this.quotedText().length > 0) {
              Row({ space: 8 }) {
                Image($r('app.media.ic_more_horizontal')).width(20).height(20).objectFit(ImageFit.Contain)
                Text(this.showQuotedText ? '隐藏引用内容' : '显示引用内容')
                  .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThunderbirdTheme.primary)
              }
              .height(44).padding({ left: 12, right: 12 })
              .backgroundColor(ThunderbirdTheme.surfaceContainer).borderRadius(8)
              .margin({ bottom: this.showQuotedText ? 10 : 24 })
              .onClick(() => this.showQuotedText = !this.showQuotedText)

              if (this.showQuotedText) {
                Row() {
                  Rect().width(3).height(84).fill(ThunderbirdTheme.outlineVariant).margin({ right: 12 })
                  Text(this.quotedText())
                    .layoutWeight(1).fontSize(13).lineHeight(21).fontColor(ThunderbirdTheme.onSurfaceVariant)
                }.width('100%').margin({ bottom: 24 })
              }
            }

            if (this.attachments.length > 0) {
              Text(`附件 (${this.attachments.length})`).width('100%').fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor(ThunderbirdTheme.onSurface).margin({ bottom: 12 })
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
        .backgroundColor(ThunderbirdTheme.surfaceLowest)

        Row({ space: 10 }) {
          this.replyAction($r('app.media.ic_reply'), '回复', 'reply')
          this.replyAction($r('app.media.ic_forward'), '转发', 'forward')
        }
        .width('100%').height(70).padding({ left: 16, right: 16, top: 10, bottom: 14 })
        .backgroundColor(ThunderbirdTheme.surfaceLowest)
        .border({ width: { top: 1 }, color: ThunderbirdTheme.outlineVariant })
      } else {
        Column({ space: 12 }) {
          LoadingProgress().width(36).height(36).color(ThunderbirdTheme.primary)
          Text('正在加载邮件').fontSize(13).fontColor(ThunderbirdTheme.onSurfaceVariant)
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').height('100%').backgroundColor(ThunderbirdTheme.surfaceLowest)
  }
}
