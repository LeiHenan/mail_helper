import { BusinessError } from '@kit.BasicServicesKit';

export function errorCode(error: Object): number {
  return (error as BusinessError).code ?? 0;
}

export function describeError(error: Object): string {
  const businessError: BusinessError = error as BusinessError;
  if (businessError.code && businessError.message && businessError.message.length > 0) {
    return `错误码 ${businessError.code}：${businessError.message}`;
  }
  if (businessError.message && businessError.message.length > 0) {
    return businessError.message;
  }
  try {
    const serialized: string = JSON.stringify(error);
    if (serialized.length > 2) {
      return serialized;
    }
  } catch (_serializationError) {
  }
  return '未知错误';
}
