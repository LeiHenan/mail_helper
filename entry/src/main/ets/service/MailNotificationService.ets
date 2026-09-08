import { notificationManager } from '@kit.NotificationKit';
import { common, WantAgent, wantAgent } from '@kit.AbilityKit';

const BUNDLE_NAME: string = 'com.mailhelper.app';
const ENTRY_ABILITY: string = 'EntryAbility';

export class MailNotificationService {
  async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    if (await notificationManager.isNotificationEnabled()) {
      return true;
    }
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (_error) {
    }
    return notificationManager.isNotificationEnabled();
  }

  async notifyNewMail(count: number): Promise<boolean> {
    if (count <= 0 || !await notificationManager.isNotificationEnabled()) {
      return false;
    }
    const launchAgent: WantAgent = await wantAgent.getWantAgent({
      wants: [{
        bundleName: BUNDLE_NAME,
        abilityName: ENTRY_ABILITY,
        parameters: { notificationSource: 'new_mail' }
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    const request: notificationManager.NotificationRequest = {
      id: 1001,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      wantAgent: launchAgent,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: '邮箱助手',
          text: `收到 ${count} 封新邮件`
        }
      }
    };
    await notificationManager.publish(request);
    await notificationManager.setBadgeNumber(count);
    return true;
  }

  async clearMailIndicator(): Promise<void> {
    await notificationManager.setBadgeNumber(0).catch(() => {});
    await notificationManager.cancel(1001).catch(() => {});
  }
}
