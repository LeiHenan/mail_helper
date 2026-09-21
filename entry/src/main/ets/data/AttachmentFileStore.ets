import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MailAttachment, MailAttachmentPayload } from '../model/MailModels';

const DOMAIN: number = 0x0000;
const MAX_FILE_NAME_LENGTH: number = 80;
// 与 MimeMessageBuilder 的发送上限一致：导入 picker 文件前先看大小，避免把超大文件整个读进内存。
const MAX_IMPORT_BYTES: number = 20 * 1024 * 1024;

export class AttachmentFileStore {
  private root: string;
  // 文件内的自增序号，避免同一毫秒内导入/迁移多个附件时 id 重复。
  private sequence: number = 0;

  constructor(filesDir: string) {
    this.root = filesDir.length > 0 ? `${filesDir}/attachments` : '';
  }

  // keepExistingFiles 为 true 时不先清空目录：目录里的历史附件文件必须活到数据库事务提交。
  // 事务回滚后旧附件行仍然有效（指向旧文件），提交前删掉旧目录会让它们变成“uri 非空但文件没了”；
  // 不再被引用的旧文件由调用方在提交后通过 pruneMessageAttachments 删除。
  async writeMessageAttachments(messageId: string, payloads: MailAttachmentPayload[],
    keepExistingFiles: boolean = false): Promise<string[]> {
    if (this.root.length === 0) {
      return payloads.map((_payload: MailAttachmentPayload): string => '');
    }
    const directory: string = this.messageDirectory(messageId);
    if (!keepExistingFiles) {
      await this.removeDirectory(directory);
    }
    const uris: string[] = [];
    let directoryCreated: boolean = false;
    for (let index: number = 0; index < payloads.length; index++) {
      const payload: MailAttachmentPayload = payloads[index];
      // 落盘前最后一道校验：内容长度必须与声明的 size 一致，否则宁可只留元数据（uri 为空），
      // 也不能把半截文件写成“完整附件”。
      if (payload.content.length === 0 || (payload.size > 0 && payload.size !== payload.content.length)) {
        uris.push('');
        continue;
      }
      if (!directoryCreated) {
        await fileIo.mkdir(directory, true);
        directoryCreated = true;
      }
      const path: string = `${directory}/${index}_${this.safeFileName(payload.name)}`;
      await this.writeFile(path, payload.content);
      uris.push(`file://${path}`);
    }
    return uris;
  }

  // 把外部（picker）URI 的文件复制进沙箱 attachments/<messageId>/，返回沙箱 file:// URI。
  // picker 授权只对本次进程有效，重启后必然 EACCES，草稿必须持有沙箱副本才能重试投递。
  async importAttachment(messageId: string, fileName: string, sourceUri: string, mimeType: string): Promise<MailAttachment> {
    if (this.root.length === 0) {
      throw new Error('附件目录不可用');
    }
    const name: string = this.safeFileName(fileName);
    const source: fileIo.File = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
    const directory: string = this.messageDirectory(messageId);
    const stamp: number = Date.now();
    const path: string = `${directory}/${stamp}_${name}`;
    let size: number = 0;
    try {
      const info: fileIo.Stat = await fileIo.stat(source.fd);
      if (info.size > MAX_IMPORT_BYTES) {
        throw new Error(`附件 ${name} 超过 20 MB`);
      }
      await fileIo.mkdir(directory, true);
      // 整份复制而不是单次 read：read 只保证“最多读满缓冲区”，大文件一次读不满会被静默截断，
      // 而截断后的字节数又被当成附件大小写进库里。copyFile 的入参在 SDK 声明里写的是
      // “Path or FD of the file to copy”，所以用已经打开的 fd 做源（open 明确支持 URI 入参），
      // 目标用自家沙箱路径，不依赖 copyFile 是否接受 URI 这种文档未确认的行为。
      try {
        await fileIo.copyFile(source.fd, path);
      } catch (error) {
        // 复制中断可能留下半个目标文件：清掉它，否则后续按 uri 会读出一个不完整的附件。
        await this.removeAttachmentFile(`file://${path}`);
        if (error instanceof Error) {
          throw error;
        }
        throw new Error(`附件 ${name} 导入失败`);
      }
      size = (await fileIo.stat(path)).size;
      if (size !== info.size) {
        await this.removeAttachmentFile(`file://${path}`);
        throw new Error(`附件 ${name} 复制不完整（${size}/${info.size} 字节）`);
      }
    } finally {
      await fileIo.close(source);
    }
    return new MailAttachment(this.nextAttachmentId(), `file://${path}`, name, mimeType, size);
  }

  // 迁移某封邮件自己的附件文件到另一封邮件的目录（优先重命名，失败退回复制后删除），返回改写后的
  // MailAttachment。迁移失败时保留原 URI，绝不把可用附件改成空 URI。
  async migrateAttachments(targetMessageId: string, attachments: MailAttachment[]): Promise<MailAttachment[]> {
    const migrated: MailAttachment[] = [];
    for (let index: number = 0; index < attachments.length; index++) {
      const attachment: MailAttachment = attachments[index];
      const targetUri: string = await this.migrateAttachment(targetMessageId, attachment);
      if (targetUri === attachment.uri) {
        migrated.push(attachment);
        continue;
      }
      migrated.push(new MailAttachment(this.nextAttachmentId(), targetUri,
        attachment.name, attachment.mimeType, attachment.size, attachment.inline));
    }
    return migrated;
  }

  // 删除单个附件文件；只处理沙箱 attachments/ 下的路径，picker URI 一律不碰。
  async removeAttachmentFile(uri: string): Promise<void> {
    const path: string = this.localPath(uri);
    if (path.length === 0 || !this.isManagedPath(path)) {
      return;
    }
    try {
      if (await fileIo.access(path)) {
        await fileIo.unlink(path);
      }
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '删除附件文件失败 %{public}s：%{public}s', path, `${error}`);
    }
  }

  // 判断 URI 是否指向某封邮件自己的附件目录（迁移后据此决定草稿目录能否删除）。
  belongsToMessage(uri: string, messageId: string): boolean {
    const path: string = this.localPath(uri);
    return this.isManagedPath(path) && path.startsWith(`${this.messageDirectory(messageId)}/`);
  }

  async removeMessageAttachments(messageId: string): Promise<void> {
    if (this.root.length === 0) {
      return;
    }
    await this.removeDirectory(this.messageDirectory(messageId));
  }

  async removeMessageAttachmentDirectories(messageIds: string[]): Promise<void> {
    if (this.root.length === 0) {
      return;
    }
    for (let index: number = 0; index < messageIds.length; index++) {
      await this.removeDirectory(this.messageDirectory(messageIds[index]));
    }
  }

  // 只保留 keepUris 指向的文件，删掉目录里其余条目。用于“先落盘、事务后提交”的写入路径：
  // 提交成功后用新附件 uri 调一次，清掉本轮不再引用的旧文件；回滚后用旧附件 uri 调一次，
  // 清掉本轮新写、旧附件行并不认的文件（旧文件必须留下，否则回滚后旧行会指向空文件）。
  // 整目录删除只适合目录里所有文件都属于本轮写入的场景（新邮件）。
  async pruneMessageAttachments(messageId: string, keepUris: string[]): Promise<void> {
    if (this.root.length === 0) {
      return;
    }
    const directory: string = this.messageDirectory(messageId);
    let entries: string[] = [];
    try {
      if (!await fileIo.access(directory)) {
        return;
      }
      entries = await fileIo.listFile(directory);
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '读取附件目录失败 %{public}s：%{public}s', directory, `${error}`);
      return;
    }
    const keep: Set<string> = new Set<string>();
    for (let index: number = 0; index < keepUris.length; index++) {
      const path: string = this.localPath(keepUris[index]);
      if (path.length > 0) {
        keep.add(path);
      }
    }
    for (let index: number = 0; index < entries.length; index++) {
      const path: string = this.entryPath(directory, entries[index]);
      if (path.length === 0 || keep.has(path)) {
        continue;
      }
      await this.removeEntry(path);
    }
  }

  private messageDirectory(messageId: string): string {
    return `${this.root}/${this.safeSegment(messageId)}`;
  }

  private nextAttachmentId(): string {
    this.sequence++;
    return `attachment_${Date.now()}_${this.sequence}`;
  }

  private async migrateAttachment(targetMessageId: string, attachment: MailAttachment): Promise<string> {
    const sourcePath: string = this.localPath(attachment.uri);
    if (!this.isManagedPath(sourcePath)) {
      return attachment.uri;
    }
    const directory: string = this.messageDirectory(targetMessageId);
    const name: string = this.safeFileName(sourcePath.substring(sourcePath.lastIndexOf('/') + 1));
    const targetPath: string = `${directory}/${name}`;
    if (targetPath === sourcePath) {
      return attachment.uri;
    }
    try {
      await fileIo.mkdir(directory, true);
      await fileIo.rename(sourcePath, targetPath);
      return `file://${targetPath}`;
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '重命名附件失败，改用复制：%{public}s', `${error}`);
    }
    try {
      await fileIo.copyFile(sourcePath, targetPath);
      await fileIo.unlink(sourcePath);
      return `file://${targetPath}`;
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '迁移附件失败，保留原路径 %{public}s：%{public}s',
        sourcePath, `${error}`);
      return attachment.uri;
    }
  }

  private localPath(uri: string): string {
    const raw: string = uri.trim();
    if (raw.length === 0) {
      return '';
    }
    return raw.startsWith('file://') ? raw.substring(7) : raw;
  }

  private isManagedPath(path: string): boolean {
    return this.root.length > 0 && path.startsWith(`${this.root}/`);
  }

  private async writeFile(path: string, content: Uint8Array): Promise<void> {
    const buffer: ArrayBuffer = new ArrayBuffer(content.length);
    new Uint8Array(buffer).set(content);
    const file: fileIo.File = await fileIo.open(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await fileIo.write(file.fd, buffer);
    } finally {
      await fileIo.close(file);
    }
  }

  // rmdir 只能删空目录：先递归删掉目录下的文件/子目录，再删目录本身。任一步失败都记 warn，
  // 不再静默吞异常——否则会留下没人清理、也没人知道的附件残留。
  private async removeDirectory(directory: string): Promise<void> {
    try {
      if (!await fileIo.access(directory)) {
        return;
      }
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '无法访问附件目录 %{public}s：%{public}s', directory, `${error}`);
      return;
    }
    await this.removeDirectoryEntries(directory);
    try {
      await fileIo.rmdir(directory);
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '删除附件目录失败 %{public}s：%{public}s', directory, `${error}`);
    }
  }

  private async removeDirectoryEntries(directory: string): Promise<void> {
    let entries: string[] = [];
    try {
      entries = await fileIo.listFile(directory);
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '读取附件目录失败 %{public}s：%{public}s', directory, `${error}`);
      return;
    }
    for (let index: number = 0; index < entries.length; index++) {
      const path: string = this.entryPath(directory, entries[index]);
      if (path.length > 0) {
        await this.removeEntry(path);
      }
    }
  }

  private async removeEntry(path: string): Promise<void> {
    let isDirectory: boolean = false;
    try {
      isDirectory = (await fileIo.stat(path)).isDirectory();
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '读取附件条目失败 %{public}s：%{public}s', path, `${error}`);
      return;
    }
    if (isDirectory) {
      await this.removeDirectory(path);
      return;
    }
    try {
      await fileIo.unlink(path);
    } catch (error) {
      hilog.warn(DOMAIN, 'AttachmentFileStore', '删除附件文件失败 %{public}s：%{public}s', path, `${error}`);
    }
  }

  // listFile 返回的名字以 / 开头（子目录可能带尾随 /），这里统一成可拼接的相对路径。
  private entryPath(directory: string, entry: string): string {
    const trimmed: string = entry.replace(/^\/+/, '').replace(/\/+$/, '');
    return trimmed.length > 0 ? `${directory}/${trimmed}` : '';
  }

  private safeSegment(value: string): string {
    const cleaned: string = value.replace(/[\\/:*?"<>|\x00-\x1f]/g, '_').replace(/^\.+/, '').trim();
    return cleaned.length > 0 ? cleaned : 'message';
  }

  private safeFileName(value: string): string {
    const cleaned: string = value.replace(/[\\/:*?"<>|\x00-\x1f]/g, '_').replace(/^\.+/, '').trim();
    if (cleaned.length === 0) {
      return 'attachment';
    }
    if (cleaned.length <= MAX_FILE_NAME_LENGTH) {
      return cleaned;
    }
    const dot: number = cleaned.lastIndexOf('.');
    if (dot <= 0 || dot < cleaned.length - 12) {
      return cleaned.substring(0, MAX_FILE_NAME_LENGTH);
    }
    const extension: string = cleaned.substring(dot);
    return `${cleaned.substring(0, MAX_FILE_NAME_LENGTH - extension.length)}${extension}`;
  }
}
