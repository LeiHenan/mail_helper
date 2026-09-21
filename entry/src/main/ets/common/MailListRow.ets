import { MailMessage } from '../model/MailModels';

// 列表行类型：日期分组表头与邮件行拍平到同一个 IDataSource，
// LazyForEach 只按行 key 复用，保证分组后仍是单层懒加载（而不是 ListItemGroup 内嵌 ForEach 全量构建）。
export enum MailRowKind {
  HEADER = 'header',
  MESSAGE = 'message'
}

export class MailDateGroup {
  static readonly TODAY: string = '今天';
  static readonly YESTERDAY: string = '昨天';
  static readonly THIS_WEEK: string = '本周';
  static readonly EARLIER: string = '更早';

  static readonly DAY_MS: number = 24 * 60 * 60 * 1000;

  // 时间语义以 epoch 毫秒（messages.sort_order → MailMessage.receivedAtMs）为准，
  // 边界一律按本地零点算：跨天、跨时区、跨年都不会把邮件分错桶。
  // 缺失时间（<= 0，例如老数据）统一归入“更早”，宁可少分组也不猜。
  static labelFor(receivedAtMs: number, now: Date = new Date()): string {
    if (!(receivedAtMs > 0)) {
      return MailDateGroup.EARLIER;
    }
    const todayStart: number = MailDateGroup.startOfDay(now);
    if (receivedAtMs >= todayStart) {
      return MailDateGroup.TODAY;
    }
    if (receivedAtMs >= todayStart - MailDateGroup.DAY_MS) {
      return MailDateGroup.YESTERDAY;
    }
    if (receivedAtMs >= todayStart - 6 * MailDateGroup.DAY_MS) {
      return MailDateGroup.THIS_WEEK;
    }
    return MailDateGroup.EARLIER;
  }

  // 列表行内时间：今天 HH:mm、昨天「昨天」、更早 M月D日。
  static formatListTime(receivedAtMs: number, now: Date = new Date()): string {
    if (!(receivedAtMs > 0)) {
      return '';
    }
    const todayStart: number = MailDateGroup.startOfDay(now);
    if (receivedAtMs >= todayStart + MailDateGroup.DAY_MS) {
      // 服务器时间略微超前（时钟偏差）：按今天显示，不显示未来日期。
      return MailDateGroup.clockTime(now);
    }
    if (receivedAtMs >= todayStart) {
      return MailDateGroup.clockTime(new Date(receivedAtMs));
    }
    if (receivedAtMs >= todayStart - MailDateGroup.DAY_MS) {
      return MailDateGroup.YESTERDAY;
    }
    const at: Date = new Date(receivedAtMs);
    return `${at.getMonth() + 1}月${at.getDate()}日`;
  }

  // 详情页时间：今天 / 昨天带时刻，更早按 年-月-日 时刻。
  static formatDetailTime(receivedAtMs: number, now: Date = new Date()): string {
    if (!(receivedAtMs > 0)) {
      return '';
    }
    const todayStart: number = MailDateGroup.startOfDay(now);
    if (receivedAtMs >= todayStart) {
      return `今天 ${MailDateGroup.clockTime(new Date(receivedAtMs))}`;
    }
    if (receivedAtMs >= todayStart - MailDateGroup.DAY_MS) {
      return `昨天 ${MailDateGroup.clockTime(new Date(receivedAtMs))}`;
    }
    const at: Date = new Date(receivedAtMs);
    const clock: string = MailDateGroup.clockTime(at);
    if (at.getFullYear() === now.getFullYear()) {
      return `${at.getMonth() + 1}月${at.getDate()}日 ${clock}`;
    }
    return `${at.getFullYear()}年${at.getMonth() + 1}月${at.getDate()}日 ${clock}`;
  }

  private static startOfDay(at: Date): number {
    return new Date(at.getFullYear(), at.getMonth(), at.getDate()).getTime();
  }

  private static clockTime(at: Date): string {
    return `${MailDateGroup.twoDigits(at.getHours())}:${MailDateGroup.twoDigits(at.getMinutes())}`;
  }

  private static twoDigits(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }
}

export class MailListRow {
  key: string;
  kind: MailRowKind;
  label: string;
  groupLabel: string;
  message: MailMessage | undefined;

  constructor(key: string, kind: MailRowKind, label: string = '', groupLabel: string = '',
    message: MailMessage | undefined = undefined) {
    this.key = key;
    this.kind = kind;
    this.label = label;
    this.groupLabel = groupLabel;
    this.message = message;
  }

  static header(key: string, label: string): MailListRow {
    return new MailListRow(key, MailRowKind.HEADER, label, label);
  }

  // 行 key 带上会被单条刷新影响的可变状态（已读 / 星标）：官方文档要求
  // 「使用 DataChangeListener 对象的 onDataChange 方法更新 UI 时，需要生成不同于原来的键值来触发组件刷新」
  // （docs/arkui/arkts-rendering-control-lazyforeach.md），否则点星标 / 标已读后行内图标与未读样式不重建。
  // 选中态 selected 由 @Prop 下发，不参与 key。行内换色的资源（$r('app.color.*')）不参与 key。
  static messageRow(message: MailMessage, groupLabel: string): MailListRow {
    const key: string = `${message.id}#${message.isRead ? 1 : 0}${message.isStarred ? 1 : 0}`;
    return new MailListRow(key, MailRowKind.MESSAGE, '', groupLabel, message);
  }

  isHeader(): boolean {
    return this.kind === MailRowKind.HEADER;
  }

  // 整表重建：按当前顺序逐条扫，分组标签变化处插入表头。
  // 表头 key 用 header_<label>，同一标签重复出现时才追加序号，保证 key 稳定且唯一。
  static buildRows(messages: MailMessage[], now: Date = new Date()): MailListRow[] {
    const rows: MailListRow[] = [];
    const seenLabels: Map<string, number> = new Map<string, number>();
    let currentLabel: string = '';
    for (let index: number = 0; index < messages.length; index++) {
      const label: string = MailDateGroup.labelFor(messages[index].receivedAtMs, now);
      if (label !== currentLabel) {
        rows.push(MailListRow.header(MailListRow.headerKey(label, seenLabels), label));
        currentLabel = label;
      }
      rows.push(MailListRow.messageRow(messages[index], label));
    }
    return rows;
  }

  // 追加一页（分页加载更早邮件）：只对新增区间发 ADD 通知。
  // 跨组时先补表头，因此从“本周”跨到“更早”也能保持表头齐全。
  static appendRows(tailLabel: string, messages: MailMessage[], now: Date = new Date()): MailListRow[] {
    const rows: MailListRow[] = [];
    let currentLabel: string = tailLabel;
    for (let index: number = 0; index < messages.length; index++) {
      const label: string = MailDateGroup.labelFor(messages[index].receivedAtMs, now);
      if (label !== currentLabel) {
        // 追加路径的 key 带首封邮件 id，避免与已有同名表头（异常数据下可能重复出现）撞 key。
        rows.push(MailListRow.header(`header_${label}#${messages[index].id}`, label));
        currentLabel = label;
      }
      rows.push(MailListRow.messageRow(messages[index], label));
    }
    return rows;
  }

  private static headerKey(label: string, seenLabels: Map<string, number>): string {
    const seen: number | undefined = seenLabels.get(label);
    const count: number = seen === undefined ? 0 : seen;
    seenLabels.set(label, count + 1);
    return count === 0 ? `header_${label}` : `header_${label}_${count}`;
  }
}
