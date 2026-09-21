import { ThunderbirdTheme } from '../../theme/ThunderbirdTheme';

// 底部浮层：滑动归档 / 删除后的反悔窗口。
// 操作本身已经生效（本地库 + 待推送队列），这里只是给用户 5 秒撤销机会，超时无需做任何事。
@Component
export struct UndoSnackbar {
  private static readonly autoDismissMs: number = 5000;

  // 每次新的撤销会话自增；@Watch 让同一文案重复出现时也能重放动画与倒计时。
  @Prop @Watch('onSessionChanged') sessionId: number = 0;
  @Prop text: string = '';
  @Prop actionLabel: string = '撤销';
  onUndo: () => void = () => {};
  onDismiss: () => void = () => {};

  @State private offsetY: number = 20;
  @State private contentOpacity: number = 0;
  private timer: number = -1;
  private closing: boolean = false;

  aboutToDisappear(): void {
    this.clearTimer();
  }

  onSessionChanged(): void {
    this.play();
  }

  private play(): void {
    this.clearTimer();
    this.closing = false;
    this.offsetY = 20;
    this.contentOpacity = 0;
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.offsetY = 0;
      this.contentOpacity = 1;
    });
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.hide();
    }, UndoSnackbar.autoDismissMs);
  }

  private hide(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    this.clearTimer();
    this.getUIContext().animateTo({
      duration: 180, curve: Curve.EaseIn,
      onFinish: () => {
        this.onDismiss();
      }
    }, () => {
      this.offsetY = 20;
      this.contentOpacity = 0;
    });
  }

  private clearTimer(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Row({ space: 12 }) {
      Text(this.text)
        .layoutWeight(1).fontSize(14).fontColor($r('app.color.surfaceLowest')).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button() {
        Text(this.actionLabel).fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.onSurface'))
      }
      .height(34).padding({ left: 14, right: 14 })
      .backgroundColor($r('app.color.surfaceLowest')).borderRadius(ThunderbirdTheme.pillRadius)
      .onClick(() => {
        this.onUndo();
        this.hide();
      })
    }
    .width('100%').constraintSize({ minHeight: 52 })
    .padding({ left: 16, right: 10, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.onSurface'))
    .borderRadius(ThunderbirdTheme.cardRadius)
    .opacity(this.contentOpacity)
    .translate({ y: this.offsetY })
    .onAppear(() => this.play())
  }
}
