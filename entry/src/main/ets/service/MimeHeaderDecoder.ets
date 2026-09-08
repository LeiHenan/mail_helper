import { util } from '@kit.ArkTS';

export class MimeHeaderDecoder {
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();

  decode(value: string): string {
    if (!value.includes('=?')) {
      return value;
    }
    // RFC 2047 规定，相邻 encoded-word 之间的折行空白不属于显示内容。
    const joined: string = value.replace(/\?=[ \t\r\n]+=\?/g, '?==?');
    return joined.replace(/=\?([^?]+)\?([bq])\?([^?]*)\?=/gi,
      (_whole: string, charset: string, encoding: string, encoded: string): string => {
        try {
          const bytes: Uint8Array = encoding.toLowerCase() === 'b' ?
            this.base64.decodeSync(encoded.replace(/\s+/g, '')) : this.decodeQBytes(encoded);
          return this.decodeBytes(bytes, charset);
        } catch (_error) {
          return _whole;
        }
      });
  }

  private decodeQBytes(value: string): Uint8Array {
    const source: string = value.replace(/_/g, ' ');
    const bytes: number[] = [];
    for (let index: number = 0; index < source.length;) {
      const hexadecimal: string = source.substring(index + 1, index + 3);
      if (source[index] === '=' && /^[0-9A-Fa-f]{2}$/.test(hexadecimal)) {
        bytes.push(Number.parseInt(hexadecimal, 16));
        index += 3;
        continue;
      }
      const encodedCharacter: Uint8Array = this.encoder.encodeInto(source[index]);
      for (let byteIndex: number = 0; byteIndex < encodedCharacter.length; byteIndex++) {
        bytes.push(encodedCharacter[byteIndex]);
      }
      index++;
    }
    return new Uint8Array(bytes);
  }

  private decodeBytes(bytes: Uint8Array, charset: string): string {
    const normalized: string = charset.trim().toLowerCase() === 'utf8' ? 'utf-8' :
      charset.trim().toLowerCase();
    try {
      return new util.TextDecoder(normalized).decode(bytes);
    } catch (_error) {
      return new util.TextDecoder('utf-8').decode(bytes);
    }
  }
}
