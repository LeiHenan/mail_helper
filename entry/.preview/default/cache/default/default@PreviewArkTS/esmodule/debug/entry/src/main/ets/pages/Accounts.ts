if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface Accounts_Params {
    repository?: MockMailRepository;
    accounts?: EmailAccount[];
}
import { MockMailRepository } from "@bundle:com.mailhelper.app/entry/ets/data/MockMailRepository";
import type { EmailAccount } from '../model/MailModels';
import { findProvider } from "@bundle:com.mailhelper.app/entry/ets/model/ProviderConfig";
class Accounts extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.repository = MockMailRepository.shared();
        this.__accounts = new ObservedPropertyObjectPU([], this, "accounts");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: Accounts_Params) {
        if (params.repository !== undefined) {
            this.repository = params.repository;
        }
        if (params.accounts !== undefined) {
            this.accounts = params.accounts;
        }
    }
    updateStateVars(params: Accounts_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__accounts.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__accounts.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private repository: MockMailRepository;
    private __accounts: ObservedPropertyObjectPU<EmailAccount[]>;
    get accounts() {
        return this.__accounts.get();
    }
    set accounts(newValue: EmailAccount[]) {
        this.__accounts.set(newValue);
    }
    aboutToAppear(): void {
        this.loadAccounts();
    }
    private async loadAccounts(): Promise<void> {
        this.accounts = await this.repository.listAccounts();
    }
    private async removeAccount(accountId: string): Promise<void> {
        await this.repository.removeAccount(accountId);
        await this.loadAccounts();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/Accounts.ets(25:5)", "entry");
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor('#F6F7FB');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Accounts.ets(26:7)", "entry");
            Row.width('100%');
            Row.padding({ left: 8, right: 18, top: 12, bottom: 12 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('‹');
            Button.debugLine("entry/src/main/ets/pages/Accounts.ets(27:9)", "entry");
            Button.width(42);
            Button.height(42);
            Button.fontSize(30);
            Button.fontColor('#263047');
            Button.backgroundColor(Color.Transparent);
            Button.onClick(() => this.getUIContext().getRouter().back());
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('邮箱账户');
            Text.debugLine("entry/src/main/ets/pages/Accounts.ets(31:9)", "entry");
            Text.fontSize(22);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor('#20283D');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/Accounts.ets(32:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('添加');
            Button.debugLine("entry/src/main/ets/pages/Accounts.ets(33:9)", "entry");
            Button.height(38);
            Button.fontSize(14);
            Button.fontColor('#3157D5');
            Button.backgroundColor('#E9EEFF');
            Button.onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/AddAccount' }).catch(() => { }));
        }, Button);
        Button.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            List.create({ space: 12 });
            List.debugLine("entry/src/main/ets/pages/Accounts.ets(40:7)", "entry");
            List.layoutWeight(1);
            List.width('100%');
            List.padding({ left: 16, right: 16 });
            List.scrollBar(BarState.Off);
        }, List);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const account = _item;
                {
                    const itemCreation = (elmtId, isInitialRender) => {
                        ViewStackProcessor.StartGetAccessRecordingFor(elmtId);
                        ListItem.create(deepRenderFunction, true);
                        if (!isInitialRender) {
                            ListItem.pop();
                        }
                        ViewStackProcessor.StopGetAccessRecording();
                    };
                    const itemCreation2 = (elmtId, isInitialRender) => {
                        ListItem.create(deepRenderFunction, true);
                        ListItem.debugLine("entry/src/main/ets/pages/Accounts.ets(42:11)", "entry");
                    };
                    const deepRenderFunction = (elmtId, isInitialRender) => {
                        itemCreation(elmtId, isInitialRender);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Column.create({ space: 14 });
                            Column.debugLine("entry/src/main/ets/pages/Accounts.ets(43:13)", "entry");
                            Column.width('100%');
                            Column.padding(16);
                            Column.backgroundColor('#FFFFFF');
                            Column.borderRadius(18);
                        }, Column);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Row.create({ space: 13 });
                            Row.debugLine("entry/src/main/ets/pages/Accounts.ets(44:15)", "entry");
                            Row.width('100%');
                        }, Row);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Stack.create();
                            Stack.debugLine("entry/src/main/ets/pages/Accounts.ets(45:17)", "entry");
                        }, Stack);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Circle.create();
                            Circle.debugLine("entry/src/main/ets/pages/Accounts.ets(46:19)", "entry");
                            Circle.width(48);
                            Circle.height(48);
                            Circle.fill(account.color);
                        }, Circle);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Text.create(findProvider(account.provider).shortName);
                            Text.debugLine("entry/src/main/ets/pages/Accounts.ets(47:19)", "entry");
                            Text.fontSize(16);
                            Text.fontWeight(FontWeight.Bold);
                            Text.fontColor('#FFFFFF');
                        }, Text);
                        Text.pop();
                        Stack.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Column.create({ space: 4 });
                            Column.debugLine("entry/src/main/ets/pages/Accounts.ets(50:17)", "entry");
                            Column.alignItems(HorizontalAlign.Start);
                            Column.layoutWeight(1);
                        }, Column);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Text.create(account.displayName);
                            Text.debugLine("entry/src/main/ets/pages/Accounts.ets(51:19)", "entry");
                            Text.fontSize(17);
                            Text.fontWeight(FontWeight.Medium);
                            Text.fontColor('#242D44');
                        }, Text);
                        Text.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Text.create(account.email);
                            Text.debugLine("entry/src/main/ets/pages/Accounts.ets(52:19)", "entry");
                            Text.fontSize(13);
                            Text.fontColor('#7B8296');
                        }, Text);
                        Text.pop();
                        Column.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            If.create();
                            if (account.unreadCount > 0) {
                                this.ifElseBranchUpdateFunction(0, () => {
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(`${account.unreadCount}`);
                                        Text.debugLine("entry/src/main/ets/pages/Accounts.ets(57:19)", "entry");
                                        Text.fontSize(12);
                                        Text.fontColor('#FFFFFF');
                                        Text.backgroundColor('#3157D5');
                                        Text.borderRadius(12);
                                        Text.padding({ left: 8, right: 8, top: 4, bottom: 4 });
                                    }, Text);
                                    Text.pop();
                                });
                            }
                            else {
                                this.ifElseBranchUpdateFunction(1, () => {
                                });
                            }
                        }, If);
                        If.pop();
                        Row.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Divider.create();
                            Divider.debugLine("entry/src/main/ets/pages/Accounts.ets(64:15)", "entry");
                            Divider.color('#ECEEF4');
                        }, Divider);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Row.create();
                            Row.debugLine("entry/src/main/ets/pages/Accounts.ets(66:15)", "entry");
                            Row.width('100%');
                        }, Row);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Text.create('后台同步');
                            Text.debugLine("entry/src/main/ets/pages/Accounts.ets(67:17)", "entry");
                            Text.fontSize(14);
                            Text.fontColor('#596078');
                        }, Text);
                        Text.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Blank.create();
                            Blank.debugLine("entry/src/main/ets/pages/Accounts.ets(68:17)", "entry");
                        }, Blank);
                        Blank.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Toggle.create({ type: ToggleType.Switch, isOn: account.syncEnabled });
                            Toggle.debugLine("entry/src/main/ets/pages/Accounts.ets(69:17)", "entry");
                            Toggle.selectedColor('#3157D5');
                            Toggle.onChange((isOn: boolean) => account.syncEnabled = isOn);
                        }, Toggle);
                        Toggle.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Button.createWithLabel('移除');
                            Button.debugLine("entry/src/main/ets/pages/Accounts.ets(72:17)", "entry");
                            Button.fontSize(13);
                            Button.fontColor('#D84B4B');
                            Button.backgroundColor('#FFF0F0');
                            Button.margin({ left: 12 });
                            Button.onClick(() => this.removeAccount(account.id));
                        }, Button);
                        Button.pop();
                        Row.pop();
                        Column.pop();
                        ListItem.pop();
                    };
                    this.observeComponentCreation2(itemCreation2, ListItem);
                    ListItem.pop();
                }
            };
            this.forEachUpdateFunction(elmtId, this.accounts, forEachItemGenFunction, (account: EmailAccount) => account.id, false, false);
        }, ForEach);
        ForEach.pop();
        List.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 6 });
            Column.debugLine("entry/src/main/ets/pages/Accounts.ets(91:7)", "entry");
            Column.padding({ left: 24, right: 24, top: 12, bottom: 20 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('隐私与安全');
            Text.debugLine("entry/src/main/ets/pages/Accounts.ets(92:9)", "entry");
            Text.fontSize(14);
            Text.fontWeight(FontWeight.Medium);
            Text.fontColor('#394158');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('应用只保存加密凭证引用；OAuth 邮箱不保存密码。');
            Text.debugLine("entry/src/main/ets/pages/Accounts.ets(93:9)", "entry");
            Text.fontSize(12);
            Text.fontColor('#878EA2');
            Text.textAlign(TextAlign.Center);
        }, Text);
        Text.pop();
        Column.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "Accounts";
    }
}
registerNamedRoute(() => new Accounts(undefined, {}), "", { bundleName: "com.mailhelper.app", moduleName: "entry", pagePath: "pages/Accounts", pageFullPath: "entry/src/main/ets/pages/Accounts", integratedHsp: "false", moduleType: "followWithHap" });
