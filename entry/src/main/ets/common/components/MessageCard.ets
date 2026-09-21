import { MailMessage } from '../../model/MailModels';
import { MailDateGroup } from '../MailListRow';
import { ThunderbirdTheme } from '../../theme/ThunderbirdTheme';

// 列表行组件：所有状态都由父组件通过参数驱动（@Prop），可复用。
// 内部不使用 if/else 分支，保证复用池中的节点结构一致；未读条与选中态改用颜色 / visibility 表达，
// 布局尺寸与原实现完全一致。
@Reusable
@Component
export struct MessageCard {
  @Prop message: MailMessage;
  @Prop selected: boolean = false;
  @Prop compactMode: boolean = false;
  @Prop showPreview: boolean = true;
  onOpen: (message: MailMessage) => void = () => {};
  onLongPress: (message: MailMessage) => void = () => {};
  onToggleStar: (message: MailMessage) => void = () => {};
  onToggleSelection: (messageId: string) => void = () => {};

  // 头像底色按发件人地址哈希取色，同一个发件人始终同色，与账户无关。
  // 色板全部来自现有资源色（不新增硬编码颜色）。
  private readonly avatarColors: Resource[] = [
    $r('app.color.primary'),
    $r('app.color.primaryPressed'),
    $r('app.color.onPrimaryContainer'),
    $r('app.color.error'),
    $r('app.color.warning'),
    $r('app.color.success'),
    $r('app.color.outline'),
    $r('app.color.onSurfaceVariant')
  ];

  // @Reusable 复用时普通成员不会自动更新，这里统一按本次构造参数重新赋值。
  aboutToReuse(params: Record<string, Object | undefined | null>): void {
    if (params === undefined) {
      return;
    }
    if (params.message !== undefined) {
      this.message = params.message as MailMessage;
    }
    if (params.selected !== undefined) {
      this.selected = params.selected as boolean;
    }
    if (params.compactMode !== undefined) {
      this.compactMode = params.compactMode as boolean;
    }
    if (params.showPreview !== undefined) {
      this.showPreview = params.showPreview as boolean;
    }
    if (params.onOpen !== undefined) {
      this.onOpen = params.onOpen as (message: MailMessage) => void;
    }
    if (params.onLongPress !== undefined) {
      this.onLongPress = params.onLongPress as (message: MailMessage) => void;
    }
    if (params.onToggleStar !== undefined) {
      this.onToggleStar = params.onToggleStar as (message: MailMessage) => void;
    }
    if (params.onToggleSelection !== undefined) {
      this.onToggleSelection = params.onToggleSelection as (messageId: string) => void;
    }
  }

  private avatarColor(): Resource {
    const key: string = this.message.sender.address.trim().toLowerCase();
    let hash: number = 0;
    for (let index: number = 0; index < key.length; index++) {
      hash = (hash * 31 + key.charCodeAt(index)) % 100000007;
    }
    return this.avatarColors[hash % this.avatarColors.length];
  }

  // 行内时间按 epoch 毫秒（receivedAtMs）格式化：今天 HH:mm、昨天「昨天」、更早 M月D日。
  // 不再解析 received_at 展示串，跨天 / 跨时区显示与分组因此保持一致。
  private listTime(receivedAtMs: number): string {
    return MailDateGroup.formatListTime(receivedAtMs);
  }

  @Builder
  private avatar() {
    Stack() {
      Circle().width(42).height(42).fill(this.avatarColor())
      Text(this.message.sender.name.substring(0, 1).toUpperCase())
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.onPrimary'))
        .visibility(this.selected ? Visibility.None : Visibility.Visible)
      Stack() {
        Circle().width(42).height(42).fill($r('app.color.primary'))
        Image($r('app.media.ic_check')).width(22).height(22).objectFit(ImageFit.Contain)
      }
      .width(44).height(44)
      .visibility(this.selected ? Visibility.Visible : Visibility.None)
    }
    .width(44).height(44).onClick(() => this.onToggleSelection(this.message.id))
  }

  build() {
    Row({ space: 9 }) {
      Rect().width(3).height(this.compactMode ? 40 : 54).radius(2)
        .fill(this.message.isRead ? Color.Transparent : $r('app.color.primary'))
      this.avatar()
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(this.message.sender.name)
            .layoutWeight(1).fontSize(15)
            .fontWeight(this.message.isRead ? FontWeight.Regular : FontWeight.Bold)
            .fontColor(this.message.isRead ? $r('app.color.onSurfaceVariant') : $r('app.color.onSurface'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.listTime(this.message.receivedAtMs))
            .width(54).textAlign(TextAlign.End).fontSize(12).lineHeight(17)
            .fontWeight(this.message.isRead ? FontWeight.Regular : FontWeight.Medium)
            .fontColor(this.message.isRead ? $r('app.color.onSurfaceVariant') : $r('app.color.primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
        Text(this.message.subject.length > 0 ? this.message.subject : '(无主题)')
          .width('100%').fontSize(14)
          .fontWeight(this.message.isRead ? FontWeight.Regular : FontWeight.Bold)
          .fontColor(this.message.isRead ? $r('app.color.onSurfaceVariant') : $r('app.color.onSurface'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(this.message.preview)
            .layoutWeight(1).fontSize(13).fontColor($r('app.color.onSurfaceVariant'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Image($r('app.media.ic_attachment')).width(16).height(16).objectFit(ImageFit.Contain)
            .fillColor($r('app.color.onSurfaceVariant'))
            .visibility(this.message.hasAttachments ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .visibility(this.showPreview && !this.compactMode ? Visibility.Visible : Visibility.None)
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
      .onClick(() => this.onOpen(this.message))
      .gesture(LongPressGesture({ repeat: false }).onAction(() => this.onLongPress(this.message)))
      Button() {
        Image(this.message.isStarred ? $r('app.media.ic_star_filled') : $r('app.media.ic_star'))
          .width(21).height(21).objectFit(ImageFit.Contain)
      }
      .width(44).height(44).backgroundColor(Color.Transparent).borderRadius(22)
      .onClick(() => this.onToggleStar(this.message))
    }
    .width('100%').height(this.compactMode ? 68 : 86)
    .padding({ left: 10, right: 8, top: this.compactMode ? 7 : 9, bottom: this.compactMode ? 7 : 9 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.selected ? $r('app.color.infoContainer') : $r('app.color.surfaceLowest'))
    .border({ width: 1, color: this.selected ? $r('app.color.primary') : $r('app.color.cardBorder') })
    .borderRadius(ThunderbirdTheme.cardRadius)
  }
}
