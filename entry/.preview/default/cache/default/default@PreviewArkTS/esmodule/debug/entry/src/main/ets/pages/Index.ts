if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface Index_Params {
    repository?: MockMailRepository;
    accounts?: EmailAccount[];
    messages?: MailMessage[];
    selectedAccountId?: string;
    isRefreshing?: boolean;
}
import { MockMailRepository } from "@bundle:com.mailhelper.app/entry/ets/data/MockMailRepository";
import { MailFolder } from "@bundle:com.mailhelper.app/entry/ets/model/MailModels";
import type { EmailAccount, MailMessage } from "@bundle:com.mailhelper.app/entry/ets/model/MailModels";
class Index extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.repository = MockMailRepository.shared();
        this.__accounts = new ObservedPropertyObjectPU([], this, "accounts");
        this.__messages = new ObservedPropertyObjectPU([], this, "messages");
        this.__selectedAccountId = new ObservedPropertySimplePU('all', this, "selectedAccountId");
        this.__isRefreshing = new ObservedPropertySimplePU(false, this, "isRefreshing");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: Index_Params) {
        if (params.repository !== undefined) {
            this.repository = params.repository;
        }
        if (params.accounts !== undefined) {
            this.accounts = params.accounts;
        }
        if (params.messages !== undefined) {
            this.messages = params.messages;
        }
        if (params.selectedAccountId !== undefined) {
            this.selectedAccountId = params.selectedAccountId;
        }
        if (params.isRefreshing !== undefined) {
            this.isRefreshing = params.isRefreshing;
        }
    }
    updateStateVars(params: Index_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__accounts.purgeDependencyOnElmtId(rmElmtId);
        this.__messages.purgeDependencyOnElmtId(rmElmtId);
        this.__selectedAccountId.purgeDependencyOnElmtId(rmElmtId);
        this.__isRefreshing.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__accounts.aboutToBeDeleted();
        this.__messages.aboutToBeDeleted();
        this.__selectedAccountId.aboutToBeDeleted();
        this.__isRefreshing.aboutToBeDeleted();
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
    private __messages: ObservedPropertyObjectPU<MailMessage[]>;
    get messages() {
        return this.__messages.get();
    }
    set messages(newValue: MailMessage[]) {
        this.__messages.set(newValue);
    }
    private __selectedAccountId: ObservedPropertySimplePU<string>;
    get selectedAccountId() {
        return this.__selectedAccountId.get();
    }
    set selectedAccountId(newValue: string) {
        this.__selectedAccountId.set(newValue);
    }
    private __isRefreshing: ObservedPropertySimplePU<boolean>;
    get isRefreshing() {
        return this.__isRefreshing.get();
    }
    set isRefreshing(newValue: boolean) {
        this.__isRefreshing.set(newValue);
    }
    aboutToAppear(): void {
        this.loadAccounts();
        this.loadMessages();
    }
    private async loadAccounts(): Promise<void> {
        this.accounts = await this.repository.listAccounts();
    }
    private async loadMessages(): Promise<void> {
        this.isRefreshing = true;
        this.messages = await this.repository.listMessages(this.selectedAccountId, MailFolder.INBOX);
        this.isRefreshing = false;
    }
    private selectAccount(accountId: string): void {
        this.selectedAccountId = accountId;
        this.loadMessages();
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/Index.ets(34:5)", "entry");
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor('#F6F7FB');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Index.ets(35:7)", "entry");
            Row.width('100%');
            Row.padding({ left: 20, right: 20, top: 18, bottom: 14 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 3 });
            Column.debugLine("entry/src/main/ets/pages/Index.ets(36:9)", "entry");
            Column.alignItems(HorizontalAlign.Start);
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('收件箱');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(37:11)", "entry");
            Text.fontSize(28);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor('#17203A');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(this.isRefreshing ? '正在同步…' : `共 ${this.messages.length} 封邮件`);
            Text.debugLine("entry/src/main/ets/pages/Index.ets(41:11)", "entry");
            Text.fontSize(13);
            Text.fontColor('#7D8499');
        }, Text);
        Text.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/Index.ets(47:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithChild();
            Button.debugLine("entry/src/main/ets/pages/Index.ets(49:9)", "entry");
            Button.width(42);
            Button.height(42);
            Button.backgroundColor('#E9EEFF');
            Button.borderRadius(21);
            Button.onClick(() => this.loadMessages());
        }, Button);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('↻');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(50:11)", "entry");
            Text.fontSize(22);
            Text.fontColor('#3157D5');
        }, Text);
        Text.pop();
        Button.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Scroll.create();
            Scroll.debugLine("entry/src/main/ets/pages/Index.ets(61:7)", "entry");
            Scroll.width('100%');
            Scroll.scrollable(ScrollDirection.Horizontal);
            Scroll.scrollBar(BarState.Off);
        }, Scroll);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: 10 });
            Row.debugLine("entry/src/main/ets/pages/Index.ets(62:9)", "entry");
            Row.padding({ left: 20, right: 20, bottom: 14 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('全部');
            Button.debugLine("entry/src/main/ets/pages/Index.ets(63:11)", "entry");
            Button.fontSize(14);
            Button.fontColor(this.selectedAccountId === 'all' ? '#FFFFFF' : '#4D5670');
            Button.backgroundColor(this.selectedAccountId === 'all' ? '#3157D5' : '#FFFFFF');
            Button.borderRadius(18);
            Button.height(36);
            Button.onClick(() => this.selectAccount('all'));
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const account = _item;
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Button.createWithLabel(`${account.displayName} ${account.unreadCount > 0 ? account.unreadCount : ''}`);
                    Button.debugLine("entry/src/main/ets/pages/Index.ets(72:13)", "entry");
                    Button.fontSize(14);
                    Button.fontColor(this.selectedAccountId === account.id ? '#FFFFFF' : '#4D5670');
                    Button.backgroundColor(this.selectedAccountId === account.id ? account.color : '#FFFFFF');
                    Button.borderRadius(18);
                    Button.height(36);
                    Button.onClick(() => this.selectAccount(account.id));
                }, Button);
                Button.pop();
            };
            this.forEachUpdateFunction(elmtId, this.accounts, forEachItemGenFunction, (account: EmailAccount) => account.id, false, false);
        }, ForEach);
        ForEach.pop();
        Row.pop();
        Scroll.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.messages.length === 0 && !this.isRefreshing) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create({ space: 12 });
                        Column.debugLine("entry/src/main/ets/pages/Index.ets(88:9)", "entry");
                        Column.layoutWeight(1);
                        Column.width('100%');
                        Column.justifyContent(FlexAlign.Center);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('✉');
                        Text.debugLine("entry/src/main/ets/pages/Index.ets(89:11)", "entry");
                        Text.fontSize(48);
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('收件箱是空的');
                        Text.debugLine("entry/src/main/ets/pages/Index.ets(90:11)", "entry");
                        Text.fontSize(18);
                        Text.fontWeight(FontWeight.Medium);
                        Text.fontColor('#30384F');
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('新邮件会在同步后显示在这里');
                        Text.debugLine("entry/src/main/ets/pages/Index.ets(91:11)", "entry");
                        Text.fontSize(14);
                        Text.fontColor('#8B91A3');
                    }, Text);
                    Text.pop();
                    Column.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        List.create({ space: 10 });
                        List.debugLine("entry/src/main/ets/pages/Index.ets(97:9)", "entry");
                        List.width('100%');
                        List.layoutWeight(1);
                        List.padding({ left: 14, right: 14, bottom: 8 });
                        List.scrollBar(BarState.Off);
                    }, List);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        ForEach.create();
                        const forEachItemGenFunction = _item => {
                            const message = _item;
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
                                    ListItem.debugLine("entry/src/main/ets/pages/Index.ets(99:13)", "entry");
                                };
                                const deepRenderFunction = (elmtId, isInitialRender) => {
                                    itemCreation(elmtId, isInitialRender);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Row.create({ space: 12 });
                                        Row.debugLine("entry/src/main/ets/pages/Index.ets(100:15)", "entry");
                                        Row.width('100%');
                                        Row.padding(15);
                                        Row.backgroundColor('#FFFFFF');
                                        Row.borderRadius(18);
                                        Row.onClick(async () => {
                                            await this.repository.markRead(message.id);
                                            this.getUIContext().getRouter()
                                                .pushUrl({ url: 'pages/MailDetail', params: { mailId: message.id } })
                                                .catch(() => { });
                                        });
                                    }, Row);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Stack.create();
                                        Stack.debugLine("entry/src/main/ets/pages/Index.ets(101:17)", "entry");
                                    }, Stack);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Circle.create();
                                        Circle.debugLine("entry/src/main/ets/pages/Index.ets(102:19)", "entry");
                                        Circle.width(46);
                                        Circle.height(46);
                                        Circle.fill(message.isRead ? '#E8EAF0' : '#DDE6FF');
                                    }, Circle);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(message.sender.name.substring(0, 1));
                                        Text.debugLine("entry/src/main/ets/pages/Index.ets(106:19)", "entry");
                                        Text.fontSize(17);
                                        Text.fontWeight(FontWeight.Bold);
                                        Text.fontColor(message.isRead ? '#73798C' : '#3157D5');
                                    }, Text);
                                    Text.pop();
                                    Stack.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Column.create({ space: 5 });
                                        Column.debugLine("entry/src/main/ets/pages/Index.ets(112:17)", "entry");
                                        Column.layoutWeight(1);
                                        Column.alignItems(HorizontalAlign.Start);
                                    }, Column);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Row.create();
                                        Row.debugLine("entry/src/main/ets/pages/Index.ets(113:19)", "entry");
                                        Row.width('100%');
                                    }, Row);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(message.sender.name);
                                        Text.debugLine("entry/src/main/ets/pages/Index.ets(114:21)", "entry");
                                        Text.fontSize(16);
                                        Text.fontWeight(message.isRead ? FontWeight.Regular : FontWeight.Bold);
                                        Text.fontColor('#20283D');
                                        Text.maxLines(1);
                                    }, Text);
                                    Text.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Blank.create();
                                        Blank.debugLine("entry/src/main/ets/pages/Index.ets(119:21)", "entry");
                                    }, Blank);
                                    Blank.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(message.receivedAt);
                                        Text.debugLine("entry/src/main/ets/pages/Index.ets(120:21)", "entry");
                                        Text.fontSize(12);
                                        Text.fontColor('#8B91A3');
                                    }, Text);
                                    Text.pop();
                                    Row.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Row.create({ space: 5 });
                                        Row.debugLine("entry/src/main/ets/pages/Index.ets(124:19)", "entry");
                                        Row.width('100%');
                                    }, Row);
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        Text.create(message.subject);
                                        Text.debugLine("entry/src/main/ets/pages/Index.ets(125:21)", "entry");
                                        Text.fontSize(15);
                                        Text.fontWeight(message.isRead ? FontWeight.Regular : FontWeight.Medium);
                                        Text.fontColor('#3A4258');
                                        Text.maxLines(1);
                                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                                    }, Text);
                                    Text.pop();
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        If.create();
                                        if (message.hasAttachments) {
                                            this.ifElseBranchUpdateFunction(0, () => {
                                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                                    Text.create('⌕');
                                                    Text.debugLine("entry/src/main/ets/pages/Index.ets(132:23)", "entry");
                                                    Text.fontSize(13);
                                                    Text.fontColor('#8B91A3');
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
                                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                                        If.create();
                                        if (message.isStarred) {
                                            this.ifElseBranchUpdateFunction(0, () => {
                                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                                    Text.create('★');
                                                    Text.debugLine("entry/src/main/ets/pages/Index.ets(135:23)", "entry");
                                                    Text.fontSize(14);
                                                    Text.fontColor('#FFB33E');
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
                                        Text.create(message.preview);
                                        Text.debugLine("entry/src/main/ets/pages/Index.ets(140:19)", "entry");
                                        Text.fontSize(13);
                                        Text.fontColor('#8B91A3');
                                        Text.maxLines(2);
                                        Text.textOverflow({ overflow: TextOverflow.Ellipsis });
                                        Text.width('100%');
                                    }, Text);
                                    Text.pop();
                                    Column.pop();
                                    Row.pop();
                                    ListItem.pop();
                                };
                                this.observeComponentCreation2(itemCreation2, ListItem);
                                ListItem.pop();
                            }
                        };
                        this.forEachUpdateFunction(elmtId, this.messages, forEachItemGenFunction, (message: MailMessage) => message.id, false, false);
                    }, ForEach);
                    ForEach.pop();
                    List.pop();
                });
            }
        }, If);
        If.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Index.ets(169:7)", "entry");
            Row.width('100%');
            Row.height(72);
            Row.padding({ left: 18, right: 18, bottom: 8 });
            Row.backgroundColor('#FFFFFF');
            Row.alignItems(VerticalAlign.Center);
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithChild();
            Button.debugLine("entry/src/main/ets/pages/Index.ets(170:9)", "entry");
            Button.layoutWeight(1);
            Button.height(58);
            Button.backgroundColor(Color.Transparent);
        }, Button);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 2 });
            Column.debugLine("entry/src/main/ets/pages/Index.ets(171:11)", "entry");
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('▤');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(172:13)", "entry");
            Text.fontSize(20);
            Text.fontColor('#3157D5');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('邮件');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(173:13)", "entry");
            Text.fontSize(11);
            Text.fontColor('#3157D5');
        }, Text);
        Text.pop();
        Column.pop();
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithChild();
            Button.debugLine("entry/src/main/ets/pages/Index.ets(180:9)", "entry");
            Button.width(54);
            Button.height(54);
            Button.borderRadius(27);
            Button.backgroundColor('#3157D5');
            Button.shadow({ radius: 18, color: '#553157D5', offsetY: 6 });
            Button.onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/Compose' }).catch(() => { }));
        }, Button);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('＋');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(181:11)", "entry");
            Text.fontSize(28);
            Text.fontColor('#FFFFFF');
        }, Text);
        Text.pop();
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithChild();
            Button.debugLine("entry/src/main/ets/pages/Index.ets(190:9)", "entry");
            Button.layoutWeight(1);
            Button.height(58);
            Button.backgroundColor(Color.Transparent);
            Button.onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/Accounts' }).catch(() => { }));
        }, Button);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 2 });
            Column.debugLine("entry/src/main/ets/pages/Index.ets(191:11)", "entry");
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('◎');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(192:13)", "entry");
            Text.fontSize(20);
            Text.fontColor('#70778C');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('账户');
            Text.debugLine("entry/src/main/ets/pages/Index.ets(193:13)", "entry");
            Text.fontSize(11);
            Text.fontColor('#70778C');
        }, Text);
        Text.pop();
        Column.pop();
        Button.pop();
        Row.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "Index";
    }
}
registerNamedRoute(() => new Index(undefined, {}), "", { bundleName: "com.mailhelper.app", moduleName: "entry", pagePath: "pages/Index", pageFullPath: "entry/src/main/ets/pages/Index", integratedHsp: "false", moduleType: "followWithHap" });
