import { promptAction } from '@kit.ArkUI';

const DEFAULT_DURATION_MS: number = 2600;

export function showToast(message: string, duration: number = DEFAULT_DURATION_MS): void {
  const text: string = message.trim();
  if (text.length === 0) {
    return;
  }
  try {
    promptAction.showToast({
      message: text.length > 120 ? `${text.substring(0, 117)}...` : text,
      duration,
      bottom: 96,
      showMode: promptAction.ToastShowMode.DEFAULT
    });
  } catch (_error) {
  }
}
