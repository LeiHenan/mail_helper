import UIAbility from "@ohos:app.ability.UIAbility";
import type AbilityConstant from "@ohos:app.ability.AbilityConstant";
import type Want from "@ohos:app.ability.Want";
import hilog from "@ohos:hilog";
import type window from "@ohos:window";
const DOMAIN: number = 0x0000;
export default class EntryAbility extends UIAbility {
    onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
        hilog.info(DOMAIN, 'MailHelper', 'Application created');
    }
    onWindowStageCreate(windowStage: window.WindowStage): void {
        windowStage.loadContent('pages/Index', (error) => {
            if (error.code) {
                hilog.error(DOMAIN, 'MailHelper', 'Failed to load Index: %{public}s', JSON.stringify(error));
            }
        });
    }
}
