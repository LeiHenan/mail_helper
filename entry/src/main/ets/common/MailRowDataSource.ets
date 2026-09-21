import { MailMessage } from '../model/MailModels';
import { MailListRow, MailRowKind } from './MailListRow';

// 分组列表数据源：行既有“日期表头”也有“邮件”，增删改仍走精确通知，
// 因此分组不会破坏 LazyForEach 的按行复用与 cachedCount 懒加载。
export class MailRowDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private rows: MailListRow[] = [];
  // 定位索引按邮件 id 建（不是行 key）：行 key 里含已读 / 星标状态，单条刷新后会变，id 不会。
  private indexByMessageId: Map<string, number> = new Map<string, number>();

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): MailListRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const position: number = this.listeners.indexOf(listener);
    if (position >= 0) {
      this.listeners.splice(position, 1);
    }
  }

  // 已加载窗口里的邮件条数（不含表头）：空态判断与“已选中 N 封”用它，而不是总行数。
  messageCount(): number {
    return this.indexByMessageId.size;
  }

  hasMessage(messageId: string): boolean {
    return this.indexByMessageId.has(messageId);
  }

  // 列表末尾所属分组，追加分页时用来判断是否需要补一个新表头。
  tailGroupLabel(): string {
    for (let index: number = this.rows.length - 1; index >= 0; index--) {
      if (this.rows[index].kind === MailRowKind.MESSAGE) {
        return this.rows[index].groupLabel;
      }
    }
    return '';
  }

  // 全量替换：换文件夹 / 搜索 / 排序 / 分组重排时使用，同 key 的行仍会复用。
  setRows(rows: MailListRow[]): void {
    this.rows = rows.slice();
    this.rebuildIndex();
    this.notifyDataReloaded();
  }

  // 末尾追加：按升序逐条发 ADD 通知，只影响新增区间。
  appendRows(rows: MailListRow[]): void {
    if (rows.length === 0) {
      return;
    }
    const start: number = this.rows.length;
    for (let index: number = 0; index < rows.length; index++) {
      this.rows.push(rows[index]);
      if (rows[index].kind === MailRowKind.MESSAGE && rows[index].message !== undefined) {
        this.indexByMessageId.set(rows[index].message!.id, start + index);
      }
    }
    for (let index: number = 0; index < rows.length; index++) {
      this.notifyDataAdd(start + index);
    }
  }

  // 单条更新（星标 / 已读）：只让该行重新取值。
  updateMessage(message: MailMessage): boolean {
    const position: number | undefined = this.indexByMessageId.get(message.id);
    if (position === undefined) {
      return false;
    }
    this.rows[position] = MailListRow.messageRow(message, this.rows[position].groupLabel);
    this.notifyDataChange(position);
    return true;
  }

  // 批量移出（归档 / 删除）：连带清掉因此空掉的分组表头，按倒序发 DELETE 保证下标逐个生效。
  removeMessages(messageIds: string[]): number {
    if (messageIds.length === 0) {
      return 0;
    }
    const removedPositions: number[] = [];
    const keptRows: MailListRow[] = [];
    const keptPositions: number[] = [];
    for (let index: number = 0; index < this.rows.length; index++) {
      const row: MailListRow = this.rows[index];
      const isTarget: boolean = row.kind === MailRowKind.MESSAGE && row.message !== undefined &&
        messageIds.indexOf(row.message!.id) >= 0;
      if (isTarget) {
        removedPositions.push(index);
        continue;
      }
      keptRows.push(row);
      keptPositions.push(index);
    }
    const survivingRows: MailListRow[] = [];
    for (let index: number = 0; index < keptRows.length; index++) {
      if (keptRows[index].kind === MailRowKind.HEADER && !this.hasNextMessage(keptRows, index)) {
        removedPositions.push(keptPositions[index]);
        continue;
      }
      survivingRows.push(keptRows[index]);
    }
    if (removedPositions.length === 0) {
      return 0;
    }
    this.rows = survivingRows;
    this.rebuildIndex();
    removedPositions.sort((left: number, right: number) => right - left);
    for (let index: number = 0; index < removedPositions.length; index++) {
      this.notifyDataDelete(removedPositions[index]);
    }
    return removedPositions.length;
  }

  private hasNextMessage(rows: MailListRow[], headerPosition: number): boolean {
    const next: MailListRow | undefined = rows[headerPosition + 1];
    return next !== undefined && next.kind === MailRowKind.MESSAGE;
  }

  private rebuildIndex(): void {
    this.indexByMessageId = new Map<string, number>();
    for (let index: number = 0; index < this.rows.length; index++) {
      const row: MailListRow = this.rows[index];
      if (row.kind === MailRowKind.MESSAGE && row.message !== undefined) {
        this.indexByMessageId.set(row.message.id, index);
      }
    }
  }

  private notifyDataReloaded(): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataReloaded();
    }
  }

  private notifyDataAdd(position: number): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataAdd(position);
    }
  }

  private notifyDataDelete(position: number): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataDelete(position);
    }
  }

  private notifyDataChange(position: number): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataChange(position);
    }
  }
}
