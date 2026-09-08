if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface Compose_Params {
    repository?: MockMailRepository;
    accounts?: EmailAccount[];
    selectedAccountId?: string;
    to?: string;
    cc?: string;
    subject?: string;
    body?: string;
    isSending?: boolean;
}
import { MockMailRepository } from "@bundle:com.mailhelper.app/entry/ets/data/MockMailRepository";
import { DraftMessage } from "@bundle:com.mailhelper.app/entry/ets/model/MailModels";
import type { EmailAccount } from "@bundle:com.mailhelper.app/entry/ets/model/MailModels";
interface ComposeParams {
    accountId?: string;
    to?: string;
    subject?: string;
    body?: string;
}
class Compose extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.repository = MockMailRepository.shared();
        this.__accounts = new ObservedPropertyObjectPU([], this, "accounts");
        this.__selectedAccountId = new ObservedPropertySimplePU('', this, "selectedAccountId");
        this.__to = new ObservedPropertySimplePU('', this, "to");
        this.__cc = new ObservedPropertySimplePU('', this, "cc");
        this.__subject = new ObservedPropertySimplePU('', this, "subject");
        this.__body = new ObservedPropertySimplePU('', this, "body");
        this.__isSending = new ObservedPropertySimplePU(false, this, "isSending");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: Compose_Params) {
        if (params.repository !== undefined) {
            this.repository = params.repository;
        }
        if (params.accounts !== undefined) {
            this.accounts = params.accounts;
        }
        if (params.selectedAccountId !== undefined) {
            this.selectedAccountId = params.selectedAccountId;
        }
        if (params.to !== undefined) {
            this.to = params.to;
        }
        if (params.cc !== undefined) {
            this.cc = params.cc;
        }
        if (params.subject !== undefined) {
            this.subject = params.subject;
        }
        if (params.body !== undefined) {
            this.body = params.body;
        }
        if (params.isSending !== undefined) {
            this.isSending = params.isSending;
        }
    }
    updateStateVars(params: Compose_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__accounts.purgeDependencyOnElmtId(rmElmtId);
        this.__selectedAccountId.purgeDependencyOnElmtId(rmElmtId);
        this.__to.purgeDependencyOnElmtId(rmElmtId);
        this.__cc.purgeDependencyOnElmtId(rmElmtId);
        this.__subject.purgeDependencyOnElmtId(rmElmtId);
        this.__body.purgeDependencyOnElmtId(rmElmtId);
        this.__isSending.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__accounts.aboutToBeDeleted();
        this.__selectedAccountId.aboutToBeDeleted();
        this.__to.aboutToBeDeleted();
        this.__cc.aboutToBeDeleted();
        this.__subject.aboutToBeDeleted();
        this.__body.aboutToBeDeleted();
        this.__isSending.aboutToBeDeleted();
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
    private __selectedAccountId: ObservedPropertySimplePU<string>;
    get selectedAccountId() {
        return this.__selectedAccountId.get();
    }
    set selectedAccountId(newValue: string) {
        this.__selectedAccountId.set(newValue);
    }
    private __to: ObservedPropertySimplePU<string>;
    get to() {
        return this.__to.get();
    }
    set to(newValue: string) {
        this.__to.set(newValue);
    }
    private __cc: ObservedPropertySimplePU<string>;
    get cc() {
        return this.__cc.get();
    }
    set cc(newValue: string) {
        this.__cc.set(newValue);
    }
    private __subject: ObservedPropertySimplePU<string>;
    get subject() {
        return this.__subject.get();
    }
    set subject(newValue: string) {
        this.__subject.set(newValue);
    }
    private __body: ObservedPropertySimplePU<string>;
    get body() {
        return this.__body.get();
    }
    set body(newValue: string) {
        this.__body.set(newValue);
    }
    private __isSending: ObservedPropertySimplePU<boolean>;
    get isSending() {
        return this.__isSending.get();
    }
    set isSending(newValue: boolean) {
        this.__isSending.set(newValue);
    }
    aboutToAppear(): void {
        const params: ComposeParams = this.getUIContext().getRouter().getParams() as ComposeParams;
        this.to = params.to ?? '';
        this.subject = params.subject ?? '';
        this.body = params.body ?? '';
        this.loadAccounts(params.accountId ?? '');
    }
    private async loadAccounts(preferredAccountId: string): Promise<void> {
        this.accounts = await this.repository.listAccounts();
        if (preferredAccountId.length > 0) {
            this.selectedAccountId = preferredAccountId;
        }
        else if (this.accounts.length > 0) {
            this.selectedAccountId = this.accounts[0].id;
        }
    }
    private async send(): Promise<void> {
        if (this.to.trim().length === 0) {
            this.showToast('请输入收件人');
            return;
        }
        this.isSending = true;
        try {
            await this.repository.send(new DraftMessage(this.selectedAccountId, this.to, this.cc, this.subject, this.body));
            this.showToast('邮件已发送');
            this.getUIContext().getRouter().back();
        }
        catch (error) {
            this.showToast(`${error}`);
        }
        finally {
            this.isSending = false;
        }
    }
    private showToast(message: string): void {
        try {
            this.getUIContext().getPromptAction().showToast({ message: message });
        }
        catch (_error) {
        }
    }
    initialRender() {
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create();
            Column.debugLine("entry/src/main/ets/pages/Compose.ets(65:5)", "entry");
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor('#FFFFFF');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Compose.ets(66:7)", "entry");
            Row.width('100%');
            Row.height(62);
            Row.padding({ left: 12, right: 16 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('取消');
            Button.debugLine("entry/src/main/ets/pages/Compose.ets(67:9)", "entry");
            Button.fontSize(15);
            Button.fontColor('#6F7689');
            Button.backgroundColor(Color.Transparent);
            Button.onClick(() => this.getUIContext().getRouter().back());
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/Compose.ets(72:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('写邮件');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(73:9)", "entry");
            Text.fontSize(19);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor('#20283D');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/Compose.ets(74:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel(this.isSending ? '发送中' : '发送');
            Button.debugLine("entry/src/main/ets/pages/Compose.ets(75:9)", "entry");
            Button.fontSize(15);
            Button.fontColor('#FFFFFF');
            Button.backgroundColor('#3157D5');
            Button.height(38);
            Button.enabled(!this.isSending);
            Button.onClick(() => this.send());
        }, Button);
        Button.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Scroll.create();
            Scroll.debugLine("entry/src/main/ets/pages/Compose.ets(87:7)", "entry");
            Scroll.layoutWeight(1);
        }, Scroll);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 0 });
            Column.debugLine("entry/src/main/ets/pages/Compose.ets(88:9)", "entry");
            Column.width('100%');
            Column.padding({ left: 20, right: 20 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Compose.ets(89:11)", "entry");
            Row.height(58);
            Row.width('100%');
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('发件人');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(90:13)", "entry");
            Text.width(66);
            Text.fontSize(14);
            Text.fontColor('#7A8195');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Scroll.create();
            Scroll.debugLine("entry/src/main/ets/pages/Compose.ets(91:13)", "entry");
            Scroll.layoutWeight(1);
            Scroll.scrollable(ScrollDirection.Horizontal);
            Scroll.scrollBar(BarState.Off);
        }, Scroll);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: 8 });
            Row.debugLine("entry/src/main/ets/pages/Compose.ets(92:15)", "entry");
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const account = _item;
                this.observeComponentCreation2((elmtId, isInitialRender) => {
                    Button.createWithLabel(account.email);
                    Button.debugLine("entry/src/main/ets/pages/Compose.ets(94:19)", "entry");
                    Button.height(34);
                    Button.fontSize(13);
                    Button.fontColor(this.selectedAccountId === account.id ? '#FFFFFF' : '#596078');
                    Button.backgroundColor(this.selectedAccountId === account.id ? account.color : '#F0F2F7');
                    Button.borderRadius(17);
                    Button.onClick(() => this.selectedAccountId = account.id);
                }, Button);
                Button.pop();
            };
            this.forEachUpdateFunction(elmtId, this.accounts, forEachItemGenFunction, (account: EmailAccount) => account.id, false, false);
        }, ForEach);
        ForEach.pop();
        Row.pop();
        Scroll.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Divider.create();
            Divider.debugLine("entry/src/main/ets/pages/Compose.ets(111:11)", "entry");
            Divider.color('#ECEEF3');
        }, Divider);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Compose.ets(113:11)", "entry");
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('收件人');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(114:13)", "entry");
            Text.width(66);
            Text.fontSize(14);
            Text.fontColor('#7A8195');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TextInput.create({ placeholder: 'name@example.com', text: this.to });
            TextInput.debugLine("entry/src/main/ets/pages/Compose.ets(115:13)", "entry");
            TextInput.layoutWeight(1);
            TextInput.height(54);
            TextInput.fontSize(15);
            TextInput.backgroundColor(Color.Transparent);
            TextInput.onChange((value: string) => this.to = value);
        }, TextInput);
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Divider.create();
            Divider.debugLine("entry/src/main/ets/pages/Compose.ets(123:11)", "entry");
            Divider.color('#ECEEF3');
        }, Divider);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Compose.ets(125:11)", "entry");
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('抄送');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(126:13)", "entry");
            Text.width(66);
            Text.fontSize(14);
            Text.fontColor('#7A8195');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TextInput.create({ placeholder: '可选', text: this.cc });
            TextInput.debugLine("entry/src/main/ets/pages/Compose.ets(127:13)", "entry");
            TextInput.layoutWeight(1);
            TextInput.height(54);
            TextInput.fontSize(15);
            TextInput.backgroundColor(Color.Transparent);
            TextInput.onChange((value: string) => this.cc = value);
        }, TextInput);
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Divider.create();
            Divider.debugLine("entry/src/main/ets/pages/Compose.ets(135:11)", "entry");
            Divider.color('#ECEEF3');
        }, Divider);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/Compose.ets(137:11)", "entry");
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('主题');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(138:13)", "entry");
            Text.width(66);
            Text.fontSize(14);
            Text.fontColor('#7A8195');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TextInput.create({ placeholder: '邮件主题', text: this.subject });
            TextInput.debugLine("entry/src/main/ets/pages/Compose.ets(139:13)", "entry");
            TextInput.layoutWeight(1);
            TextInput.height(54);
            TextInput.fontSize(15);
            TextInput.backgroundColor(Color.Transparent);
            TextInput.onChange((value: string) => this.subject = value);
        }, TextInput);
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Divider.create();
            Divider.debugLine("entry/src/main/ets/pages/Compose.ets(147:11)", "entry");
            Divider.color('#ECEEF3');
        }, Divider);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TextArea.create({ placeholder: '输入邮件正文…', text: this.body });
            TextArea.debugLine("entry/src/main/ets/pages/Compose.ets(149:11)", "entry");
            TextArea.width('100%');
            TextArea.height(360);
            TextArea.fontSize(16);
            TextArea.lineHeight(25);
            TextArea.backgroundColor(Color.Transparent);
            TextArea.padding({ top: 18 });
            TextArea.onChange((value: string) => this.body = value);
        }, TextArea);
        Column.pop();
        Scroll.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create({ space: 24 });
            Row.debugLine("entry/src/main/ets/pages/Compose.ets(163:7)", "entry");
            Row.width('100%');
            Row.height(58);
            Row.padding({ left: 24, right: 24 });
            Row.backgroundColor('#F8F9FC');
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('⌕');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(164:9)", "entry");
            Text.fontSize(24);
            Text.fontColor('#636B80');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('▧');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(165:9)", "entry");
            Text.fontSize(23);
            Text.fontColor('#636B80');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('A');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(166:9)", "entry");
            Text.fontSize(20);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor('#636B80');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/Compose.ets(167:9)", "entry");
        }, Blank);
        Blank.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('⋯');
            Text.debugLine("entry/src/main/ets/pages/Compose.ets(168:9)", "entry");
            Text.fontSize(25);
            Text.fontColor('#636B80');
        }, Text);
        Text.pop();
        Row.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "Compose";
    }
}
registerNamedRoute(() => new Compose(undefined, {}), "", { bundleName: "com.mailhelper.app", moduleName: "entry", pagePath: "pages/Compose", pageFullPath: "entry/src/main/ets/pages/Compose", integratedHsp: "false", moduleType: "followWithHap" });
