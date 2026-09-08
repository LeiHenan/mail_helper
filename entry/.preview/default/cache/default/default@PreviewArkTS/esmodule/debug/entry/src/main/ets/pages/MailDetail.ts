if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface MailDetail_Params {
    repository?: MockMailRepository;
    message?: MailMessage;
}
import { MockMailRepository } from "@bundle:com.mailhelper.app/entry/ets/data/MockMailRepository";
import type { MailMessage } from '../model/MailModels';
interface MailDetailParams {
    mailId: string;
}
class MailDetail extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.repository = MockMailRepository.shared();
        this.__message = new ObservedPropertyObjectPU(undefined, this, "message");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: MailDetail_Params) {
        if (params.repository !== undefined) {
            this.repository = params.repository;
        }
        if (params.message !== undefined) {
            this.message = params.message;
        }
    }
    updateStateVars(params: MailDetail_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__message.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__message.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private repository: MockMailRepository;
    private __message?: ObservedPropertyObjectPU<MailMessage>;
    get message() {
        return this.__message.get();
    }
    set message(newValue: MailMessage) {
        this.__message.set(newValue);
    }
    aboutToAppear(): void {
        const params: MailDetailParams = this.getUIContext().getRouter().getParams() as MailDetailParams;
        this.loadMessage(params.mailId);
    }
    private async loadMessage(messageId: string): Promise<void> {
        this.message = await this.repository.getMessage(messageId);
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/MailDetail.ets(24:5)", "entry");
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor('#FFFFFF');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/MailDetail.ets(25:7)", "entry");
            Row.width('100%');
            Row.padding({ left: 10, right: 10, top: 10 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('‹');
            Button.debugLine("entry/src/main/ets/pages/MailDetail.ets(26:9)", "entry");
            Button.width(42);
            Button.height(42);
            Button.fontSize(30);
            Button.fontColor('#263047');
            Button.backgroundColor(Color.Transparent);
            Button.onClick(() => this.getUIContext().getRouter().back());
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/MailDetail.ets(33:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel(this.message?.isStarred ? '★' : '☆');
            Button.debugLine("entry/src/main/ets/pages/MailDetail.ets(34:9)", "entry");
            Button.width(42);
            Button.height(42);
            Button.fontSize(23);
            Button.fontColor(this.message?.isStarred ? '#FFB33E' : '#687086');
            Button.backgroundColor(Color.Transparent);
            Button.onClick(async () => {
                if (this.message) {
                    await this.repository.toggleStar(this.message.id);
                    this.message = await this.repository.getMessage(this.message.id);
                }
            });
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('⋯');
            Button.debugLine("entry/src/main/ets/pages/MailDetail.ets(46:9)", "entry");
            Button.width(42);
            Button.height(42);
            Button.fontSize(24);
            Button.fontColor('#687086');
            Button.backgroundColor(Color.Transparent);
        }, Button);
        Button.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (this.message) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Scroll.create();
                        Scroll.debugLine("entry/src/main/ets/pages/MailDetail.ets(57:9)", "entry");
                        Scroll.layoutWeight(1);
                        Scroll.scrollBar(BarState.Off);
                    }, Scroll);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create({ space: 18 });
                        Column.debugLine("entry/src/main/ets/pages/MailDetail.ets(58:11)", "entry");
                        Column.padding({ left: 22, right: 22, bottom: 24 });
                        Column.alignItems(HorizontalAlign.Start);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.message.subject);
                        Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(59:13)", "entry");
                        Text.fontSize(25);
                        Text.fontWeight(FontWeight.Bold);
                        Text.fontColor('#1D263C');
                        Text.width('100%');
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create({ space: 12 });
                        Row.debugLine("entry/src/main/ets/pages/MailDetail.ets(65:13)", "entry");
                        Row.width('100%');
                    }, Row);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Stack.create();
                        Stack.debugLine("entry/src/main/ets/pages/MailDetail.ets(66:15)", "entry");
                    }, Stack);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Circle.create();
                        Circle.debugLine("entry/src/main/ets/pages/MailDetail.ets(67:17)", "entry");
                        Circle.width(48);
                        Circle.height(48);
                        Circle.fill('#DDE6FF');
                    }, Circle);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.message.sender.name.substring(0, 1));
                        Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(68:17)", "entry");
                        Text.fontSize(18);
                        Text.fontWeight(FontWeight.Bold);
                        Text.fontColor('#3157D5');
                    }, Text);
                    Text.pop();
                    Stack.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create({ space: 3 });
                        Column.debugLine("entry/src/main/ets/pages/MailDetail.ets(71:15)", "entry");
                        Column.alignItems(HorizontalAlign.Start);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.message.sender.name);
                        Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(72:17)", "entry");
                        Text.fontSize(16);
                        Text.fontWeight(FontWeight.Medium);
                        Text.fontColor('#273048');
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.message.sender.address);
                        Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(73:17)", "entry");
                        Text.fontSize(13);
                        Text.fontColor('#858CA0');
                    }, Text);
                    Text.pop();
                    Column.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Blank.create();
                        Blank.debugLine("entry/src/main/ets/pages/MailDetail.ets(76:15)", "entry");
                    }, Blank);
                    Blank.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.message.receivedAt);
                        Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(77:15)", "entry");
                        Text.fontSize(13);
                        Text.fontColor('#858CA0');
                    }, Text);
                    Text.pop();
                    Row.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Divider.create();
                        Divider.debugLine("entry/src/main/ets/pages/MailDetail.ets(81:13)", "entry");
                        Divider.color('#ECEEF4');
                    }, Divider);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create(this.message.plainBody);
                        Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(83:13)", "entry");
                        Text.fontSize(16);
                        Text.lineHeight(26);
                        Text.fontColor('#30384E');
                        Text.width('100%');
                    }, Text);
                    Text.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        If.create();
                        if (this.message.hasAttachments) {
                            this.ifElseBranchUpdateFunction(0, () => {
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Row.create({ space: 12 });
                                    Row.debugLine("entry/src/main/ets/pages/MailDetail.ets(90:15)", "entry");
                                    Row.width('100%');
                                    Row.padding(14);
                                    Row.backgroundColor('#F3F5FA');
                                    Row.borderRadius(14);
                                }, Row);
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Text.create('▧');
                                    Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(91:17)", "entry");
                                    Text.fontSize(26);
                                    Text.fontColor('#3157D5');
                                }, Text);
                                Text.pop();
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Column.create({ space: 3 });
                                    Column.debugLine("entry/src/main/ets/pages/MailDetail.ets(92:17)", "entry");
                                    Column.alignItems(HorizontalAlign.Start);
                                }, Column);
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Text.create('评审材料.pdf');
                                    Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(93:19)", "entry");
                                    Text.fontSize(15);
                                    Text.fontWeight(FontWeight.Medium);
                                    Text.fontColor('#30384E');
                                }, Text);
                                Text.pop();
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Text.create('1.8 MB');
                                    Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(94:19)", "entry");
                                    Text.fontSize(12);
                                    Text.fontColor('#8B91A3');
                                }, Text);
                                Text.pop();
                                Column.pop();
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Blank.create();
                                    Blank.debugLine("entry/src/main/ets/pages/MailDetail.ets(96:17)", "entry");
                                }, Blank);
                                Blank.pop();
                                this.observeComponentCreation2((elmtId, isInitialRender) => {
                                    Text.create('下载');
                                    Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(97:17)", "entry");
                                    Text.fontSize(14);
                                    Text.fontColor('#3157D5');
                                }, Text);
                                Text.pop();
                                Row.pop();
                            });
                        }
                        else {
                            this.ifElseBranchUpdateFunction(1, () => {
                            });
                        }
                    }, If);
                    If.pop();
                    Column.pop();
                    Scroll.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Row.create({ space: 12 });
                        Row.debugLine("entry/src/main/ets/pages/MailDetail.ets(111:9)", "entry");
                        Row.padding({ left: 20, right: 20, top: 10, bottom: 16 });
                        Row.backgroundColor('#FFFFFF');
                    }, Row);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('回复');
                        Button.debugLine("entry/src/main/ets/pages/MailDetail.ets(112:11)", "entry");
                        Button.layoutWeight(1);
                        Button.height(46);
                        Button.fontColor('#3157D5');
                        Button.backgroundColor('#E9EEFF');
                        Button.onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/Compose', params: {
                                accountId: this.message?.accountId,
                                to: this.message?.sender.address,
                                subject: `Re: ${this.message?.subject ?? ''}`
                            } }).catch(() => { }));
                    }, Button);
                    Button.pop();
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Button.createWithLabel('转发');
                        Button.debugLine("entry/src/main/ets/pages/MailDetail.ets(122:11)", "entry");
                        Button.layoutWeight(1);
                        Button.height(46);
                        Button.fontColor('#FFFFFF');
                        Button.backgroundColor('#3157D5');
                        Button.onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/Compose', params: {
                                accountId: this.message?.accountId,
                                subject: `Fwd: ${this.message?.subject ?? ''}`,
                                body: this.message?.plainBody
                            } }).catch(() => { }));
                    }, Button);
                    Button.pop();
                    Row.pop();
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Column.create({ space: 12 });
                        Column.debugLine("entry/src/main/ets/pages/MailDetail.ets(136:9)", "entry");
                        Column.layoutWeight(1);
                        Column.width('100%');
                        Column.justifyContent(FlexAlign.Center);
                    }, Column);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        LoadingProgress.create();
                        LoadingProgress.debugLine("entry/src/main/ets/pages/MailDetail.ets(137:11)", "entry");
                        LoadingProgress.width(38);
                        LoadingProgress.height(38);
                        LoadingProgress.color('#3157D5');
                    }, LoadingProgress);
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        Text.create('正在加载邮件');
                        Text.debugLine("entry/src/main/ets/pages/MailDetail.ets(138:11)", "entry");
                        Text.fontSize(14);
                        Text.fontColor('#81889B');
                    }, Text);
                    Text.pop();
                    Column.pop();
                });
            }
        }, If);
        If.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "MailDetail";
    }
}
registerNamedRoute(() => new MailDetail(undefined, {}), "", { bundleName: "com.mailhelper.app", moduleName: "entry", pagePath: "pages/MailDetail", pageFullPath: "entry/src/main/ets/pages/MailDetail", integratedHsp: "false", moduleType: "followWithHap" });
