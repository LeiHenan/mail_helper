import { common, Want } from '@kit.AbilityKit';
import { ThunderbirdTheme } from '../theme/ThunderbirdTheme';
import { showToast } from '../common/Toast';

const GOOGLE_SECURITY_URL: string = 'https://myaccount.google.com/security';
const GOOGLE_APP_PASSWORD_URL: string = 'https://myaccount.google.com/apppasswords';

interface GuideStep {
  title: string;
  description: string;
  actionLabel: string;
  actionUrl: string;
}

// actionUrl 为空表示该步骤不需要跳转（纯文字说明）。
const GUIDE_STEPS: GuideStep[] = [
  {
    title: '开启两步验证',
    description: '打开 Google 账号的「安全性」页面，在「如何登录 Google」中开启两步验证。'
      + '应用专用密码只有开启两步验证后才会出现。',
    actionLabel: '打开 Google 安全设置',
    actionUrl: GOOGLE_SECURITY_URL
  },
  {
    title: '生成应用专用密码',
    description: '在两步验证页面底部进入「应用专用密码」，应用和设备随意选择（例如“邮件 / HarmonyOS”）。'
      + '生成后立刻复制这串 16 位密码，离开页面后不会再显示。',
    actionLabel: '打开应用专用密码页面',
    actionUrl: GOOGLE_APP_PASSWORD_URL
  },
  {
    title: '启用 IMAP',
    description: '打开 Gmail 网页版，点右上角齿轮 →「查看所有设置」→「转发和 POP/IMAP」→ 选择「启用 IMAP」，'
      + '拉到页面底部点「保存更改」，否则连接收件服务器会失败。',
    actionLabel: '',
    actionUrl: ''
  },
  {
    title: '回到邮箱助手',
    description: '添加账户 → 选择 Gmail → 输入邮箱地址并继续 → 在页面顶部选择「应用专用密码」→ '
      + '粘贴刚才复制的密码，点「连接」即可完成添加。',
    actionLabel: '',
    actionUrl: ''
  }
];

@Entry
@Component
struct GmailGuide {
  private async openLink(url: string): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      await context.startAbility(want);
    } catch (error) {
      if (error instanceof Error) {
        showToast(`无法打开浏览器：${error.message}`);
        return;
      }
      showToast('无法打开浏览器，请手动访问 Google 账号页面');
    }
  }

  @Builder
  private stepCard(index: number, step: GuideStep) {
    Row({ space: 12 }) {
      Stack() {
        Circle().width(28).height(28).fill($r('app.color.primary'))
        Text(`${index}`).fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.onPrimary'))
      }
      Column({ space: 6 }) {
        Text(step.title).width('100%').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface'))
        Text(step.description).width('100%').fontSize(13).lineHeight(20)
          .fontColor($r('app.color.onSurfaceVariant'))
        if (step.actionUrl.length > 0) {
          Button(step.actionLabel)
            .height(ThunderbirdTheme.touchTarget).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary')).backgroundColor(Color.Transparent)
            .border({ width: 1, color: $r('app.color.primary') })
            .borderRadius(ThunderbirdTheme.controlRadius)
            .padding({ left: 16, right: 16 })
            .margin({ top: 2 })
            .onClick(() => {
              this.openLink(step.actionUrl);
            })
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%').padding(ThunderbirdTheme.cardPadding)
    .alignItems(VerticalAlign.Top)
    .backgroundColor($r('app.color.surfaceLowest'))
    .border({ width: 1, color: $r('app.color.cardBorder') })
    .borderRadius(ThunderbirdTheme.cardRadius)
  }

  @Builder
  private warningCard() {
    Row({ space: 10 }) {
      Image($r('app.media.ic_warning')).width(20).height(20).objectFit(ImageFit.Contain)
        .fillColor($r('app.color.warning'))
      Column({ space: 4 }) {
        Text('应用专用密码只显示一次，请妥善保存；忘记后只能在 Google 账号中重新生成。')
          .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.warning'))
        Text('网络需要能访问 Google 服务，否则添加账户时会连接失败。')
          .width('100%').fontSize(12).lineHeight(18).fontColor($r('app.color.onSurfaceVariant'))
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%').padding(14).alignItems(VerticalAlign.Top)
    .backgroundColor($r('app.color.surfaceLow'))
    .border({ width: 1, color: $r('app.color.cardBorder') })
    .borderRadius(ThunderbirdTheme.cardRadius)
  }

  build() {
    Column() {
      Row() {
        Button() {
          Image($r('app.media.ic_back')).width(23).height(23).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.onSurface'))
        }
          .width(48).height(48).backgroundColor(Color.Transparent)
          .onClick(() => this.getUIContext().getRouter().back())
        Text('Gmail 设置指南').layoutWeight(1).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface'))
        Row() {}.width(48)
      }
      .width('100%').height(56).padding({ left: 4, right: 4 })
      .backgroundColor($r('app.color.surface')).zIndex(1)

      Scroll() {
        Column({ space: 12 }) {
          Text('Gmail 不支持用账号密码直接登录 IMAP/SMTP，需要先在 Google 账号中完成两步验证并生成应用专用密码，'
            + '全程大约 3 分钟。下面 4 步都在 Google 侧完成，最后回到本应用添加账户。')
            .width('100%').fontSize(14).lineHeight(22).fontColor($r('app.color.onSurfaceVariant'))
            .margin({ bottom: 4 })

          ForEach(GUIDE_STEPS, (step: GuideStep, index: number) => {
            this.stepCard(index + 1, step)
          }, (step: GuideStep) => step.title)

          this.warningCard()
        }
        .width('100%')
        .padding({ left: ThunderbirdTheme.pagePadding, right: ThunderbirdTheme.pagePadding, top: 8, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1).width('100%').scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%').height('100%').backgroundColor($r('app.color.surface'))
  }
}
