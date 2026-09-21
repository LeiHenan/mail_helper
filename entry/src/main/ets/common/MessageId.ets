const FALLBACK_DOMAIN: string = 'mail-helper.local';

export function messageIdDomain(email: string): string {
  const at: number = email.lastIndexOf('@');
  const domain: string = at > 0 ? email.substring(at + 1).trim() : '';
  return /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$/.test(domain) ? domain : FALLBACK_DOMAIN;
}

export function normalizeMessageId(value: string): string {
  return value.replace(/[\r\n]/g, '').trim().replace(/^</, '').replace(/>$/, '').trim();
}

export function bracketMessageId(value: string): string {
  const id: string = normalizeMessageId(value);
  return id.length > 0 ? `<${id}>` : '';
}

export function newMessageId(email: string, localPart: string, now: number = Date.now()): string {
  const cleaned: string = localPart.replace(/[^A-Za-z0-9._-]/g, '').substring(0, 40);
  const prefix: string = cleaned.length > 0 ? cleaned : 'm';
  return `${prefix}.${now}@${messageIdDomain(email)}`;
}
