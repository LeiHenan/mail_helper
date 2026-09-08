if (!("finalizeConstruction" in ViewPU.prototype)) {
    Reflect.set(ViewPU.prototype, "finalizeConstruction", () => { });
}
interface AddAccount_Params {
    repository?: MockMailRepository;
    selectedProvider?: EmailProviderType;
    displayName?: string;
    email?: string;
    secret?: string;
    isConnecting?: boolean;
}
import { MockMailRepository } from "@bundle:com.mailhelper.app/entry/ets/data/MockMailRepository";
import { AuthType, EmailAccount, EmailProviderType } from "@bundle:com.mailhelper.app/entry/ets/model/MailModels";
import { EMAIL_PROVIDERS, findProvider } from "@bundle:com.mailhelper.app/entry/ets/model/ProviderConfig";
import type { EmailProviderConfig } from "@bundle:com.mailhelper.app/entry/ets/model/ProviderConfig";
class AddAccount extends ViewPU {
    constructor(parent, params, __localStorage, elmtId = -1, paramsLambda = undefined, extraInfo) {
        super(parent, __localStorage, elmtId, extraInfo);
        if (typeof paramsLambda === "function") {
            this.paramsGenerator_ = paramsLambda;
        }
        this.repository = MockMailRepository.shared();
        this.__selectedProvider = new ObservedPropertySimplePU(EmailProviderType.QQ, this, "selectedProvider");
        this.__displayName = new ObservedPropertySimplePU('', this, "displayName");
        this.__email = new ObservedPropertySimplePU('', this, "email");
        this.__secret = new ObservedPropertySimplePU('', this, "secret");
        this.__isConnecting = new ObservedPropertySimplePU(false, this, "isConnecting");
        this.setInitiallyProvidedValue(params);
        this.finalizeConstruction();
    }
    setInitiallyProvidedValue(params: AddAccount_Params) {
        if (params.repository !== undefined) {
            this.repository = params.repository;
        }
        if (params.selectedProvider !== undefined) {
            this.selectedProvider = params.selectedProvider;
        }
        if (params.displayName !== undefined) {
            this.displayName = params.displayName;
        }
        if (params.email !== undefined) {
            this.email = params.email;
        }
        if (params.secret !== undefined) {
            this.secret = params.secret;
        }
        if (params.isConnecting !== undefined) {
            this.isConnecting = params.isConnecting;
        }
    }
    updateStateVars(params: AddAccount_Params) {
    }
    purgeVariableDependenciesOnElmtId(rmElmtId) {
        this.__selectedProvider.purgeDependencyOnElmtId(rmElmtId);
        this.__displayName.purgeDependencyOnElmtId(rmElmtId);
        this.__email.purgeDependencyOnElmtId(rmElmtId);
        this.__secret.purgeDependencyOnElmtId(rmElmtId);
        this.__isConnecting.purgeDependencyOnElmtId(rmElmtId);
    }
    aboutToBeDeleted() {
        this.__selectedProvider.aboutToBeDeleted();
        this.__displayName.aboutToBeDeleted();
        this.__email.aboutToBeDeleted();
        this.__secret.aboutToBeDeleted();
        this.__isConnecting.aboutToBeDeleted();
        SubscriberManager.Get().delete(this.id__());
        this.aboutToBeDeletedInternal();
    }
    private repository: MockMailRepository;
    private __selectedProvider: ObservedPropertySimplePU<EmailProviderType>;
    get selectedProvider() {
        return this.__selectedProvider.get();
    }
    set selectedProvider(newValue: EmailProviderType) {
        this.__selectedProvider.set(newValue);
    }
    private __displayName: ObservedPropertySimplePU<string>;
    get displayName() {
        return this.__displayName.get();
    }
    set displayName(newValue: string) {
        this.__displayName.set(newValue);
    }
    private __email: ObservedPropertySimplePU<string>;
    get email() {
        return this.__email.get();
    }
    set email(newValue: string) {
        this.__email.set(newValue);
    }
    private __secret: ObservedPropertySimplePU<string>;
    get secret() {
        return this.__secret.get();
    }
    set secret(newValue: string) {
        this.__secret.set(newValue);
    }
    private __isConnecting: ObservedPropertySimplePU<boolean>;
    get isConnecting() {
        return this.__isConnecting.get();
    }
    set isConnecting(newValue: boolean) {
        this.__isConnecting.set(newValue);
    }
    private async connect(): Promise<void> {
        const provider: EmailProviderConfig = findProvider(this.selectedProvider);
        if (this.email.trim().length === 0 || !this.email.includes('@')) {
            this.showToast('请输入有效的邮箱地址');
            return;
        }
        if (provider.authType === AuthType.AUTHORIZATION_CODE && this.secret.length === 0) {
            this.showToast('请输入邮箱授权码');
            return;
        }
        this.isConnecting = true;
        const name: string = this.displayName.trim().length > 0 ? this.displayName : provider.name;
        const account: EmailAccount = new EmailAccount(`account_${Date.now()}`, this.email.trim(), name, provider.type, provider.color);
        await this.repository.addAccount(account, this.secret);
        this.isConnecting = false;
        this.showToast('邮箱账户已添加');
        this.getUIContext().getRouter().back();
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
            Column.debugLine("entry/src/main/ets/pages/AddAccount.ets(43:5)", "entry");
            Column.width('100%');
            Column.height('100%');
            Column.backgroundColor('#F8F9FC');
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Row.create();
            Row.debugLine("entry/src/main/ets/pages/AddAccount.ets(44:7)", "entry");
            Row.width('100%');
            Row.padding({ left: 8, right: 18, top: 12, bottom: 8 });
        }, Row);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel('‹');
            Button.debugLine("entry/src/main/ets/pages/AddAccount.ets(45:9)", "entry");
            Button.width(42);
            Button.height(42);
            Button.fontSize(30);
            Button.fontColor('#263047');
            Button.backgroundColor(Color.Transparent);
            Button.onClick(() => this.getUIContext().getRouter().back());
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('添加邮箱');
            Text.debugLine("entry/src/main/ets/pages/AddAccount.ets(49:9)", "entry");
            Text.fontSize(22);
            Text.fontWeight(FontWeight.Bold);
            Text.fontColor('#20283D');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Blank.create();
            Blank.debugLine("entry/src/main/ets/pages/AddAccount.ets(50:9)", "entry");
        }, Blank);
        Blank.pop();
        Row.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Scroll.create();
            Scroll.debugLine("entry/src/main/ets/pages/AddAccount.ets(55:7)", "entry");
            Scroll.layoutWeight(1);
            Scroll.scrollBar(BarState.Off);
        }, Scroll);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 18 });
            Column.debugLine("entry/src/main/ets/pages/AddAccount.ets(56:9)", "entry");
            Column.width('100%');
            Column.padding({ left: 20, right: 20, top: 10, bottom: 30 });
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('选择邮箱服务商');
            Text.debugLine("entry/src/main/ets/pages/AddAccount.ets(57:11)", "entry");
            Text.width('100%');
            Text.fontSize(15);
            Text.fontWeight(FontWeight.Medium);
            Text.fontColor('#596078');
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Grid.create();
            Grid.debugLine("entry/src/main/ets/pages/AddAccount.ets(60:11)", "entry");
            Grid.columnsTemplate('1fr 1fr');
            Grid.rowsGap(12);
            Grid.columnsGap(12);
            Grid.height(220);
        }, Grid);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            ForEach.create();
            const forEachItemGenFunction = _item => {
                const provider = _item;
                {
                    const itemCreation2 = (elmtId, isInitialRender) => {
                        GridItem.create(() => { }, false);
                        GridItem.debugLine("entry/src/main/ets/pages/AddAccount.ets(62:15)", "entry");
                    };
                    const observedDeepRender = () => {
                        this.observeComponentCreation2(itemCreation2, GridItem);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Column.create({ space: 9 });
                            Column.debugLine("entry/src/main/ets/pages/AddAccount.ets(63:17)", "entry");
                            Column.width('100%');
                            Column.height(104);
                            Column.justifyContent(FlexAlign.Center);
                            Column.backgroundColor(this.selectedProvider === provider.type ? '#E9EEFF' : '#FFFFFF');
                            Column.border({ width: this.selectedProvider === provider.type ? 2 : 1,
                                color: this.selectedProvider === provider.type ? '#3157D5' : '#EAECF2' });
                            Column.borderRadius(16);
                            Column.onClick(() => this.selectedProvider = provider.type);
                        }, Column);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Stack.create();
                            Stack.debugLine("entry/src/main/ets/pages/AddAccount.ets(64:19)", "entry");
                        }, Stack);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Circle.create();
                            Circle.debugLine("entry/src/main/ets/pages/AddAccount.ets(65:21)", "entry");
                            Circle.width(46);
                            Circle.height(46);
                            Circle.fill(provider.color);
                        }, Circle);
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Text.create(provider.shortName);
                            Text.debugLine("entry/src/main/ets/pages/AddAccount.ets(66:21)", "entry");
                            Text.fontSize(16);
                            Text.fontWeight(FontWeight.Bold);
                            Text.fontColor('#FFFFFF');
                        }, Text);
                        Text.pop();
                        Stack.pop();
                        this.observeComponentCreation2((elmtId, isInitialRender) => {
                            Text.create(provider.name);
                            Text.debugLine("entry/src/main/ets/pages/AddAccount.ets(68:19)", "entry");
                            Text.fontSize(14);
                            Text.fontColor('#30384E');
                        }, Text);
                        Text.pop();
                        Column.pop();
                        GridItem.pop();
                    };
                    observedDeepRender();
                }
            };
            this.forEachUpdateFunction(elmtId, EMAIL_PROVIDERS, forEachItemGenFunction, (provider: EmailProviderConfig) => provider.type, false, false);
        }, ForEach);
        ForEach.pop();
        Grid.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Column.create({ space: 12 });
            Column.debugLine("entry/src/main/ets/pages/AddAccount.ets(86:11)", "entry");
        }, Column);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TextInput.create({ placeholder: '账户名称，例如：工作邮箱', text: this.displayName });
            TextInput.debugLine("entry/src/main/ets/pages/AddAccount.ets(87:13)", "entry");
            TextInput.height(52);
            TextInput.fontSize(15);
            TextInput.backgroundColor('#F4F5F8');
            TextInput.borderRadius(13);
            TextInput.onChange((value: string) => this.displayName = value);
        }, TextInput);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            TextInput.create({ placeholder: '邮箱地址', text: this.email });
            TextInput.debugLine("entry/src/main/ets/pages/AddAccount.ets(91:13)", "entry");
            TextInput.height(52);
            TextInput.fontSize(15);
            TextInput.backgroundColor('#F4F5F8');
            TextInput.borderRadius(13);
            TextInput.type(InputType.Email);
            TextInput.onChange((value: string) => this.email = value);
        }, TextInput);
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            If.create();
            if (findProvider(this.selectedProvider).authType === AuthType.AUTHORIZATION_CODE) {
                this.ifElseBranchUpdateFunction(0, () => {
                    this.observeComponentCreation2((elmtId, isInitialRender) => {
                        TextInput.create({ placeholder: '邮箱授权码（不是登录密码）', text: this.secret });
                        TextInput.debugLine("entry/src/main/ets/pages/AddAccount.ets(97:15)", "entry");
                        TextInput.height(52);
                        TextInput.fontSize(15);
                        TextInput.backgroundColor('#F4F5F8');
                        TextInput.borderRadius(13);
                        TextInput.type(InputType.Password);
                        TextInput.onChange((value: string) => this.secret = value);
                    }, TextInput);
                });
            }
            else {
                this.ifElseBranchUpdateFunction(1, () => {
                });
            }
        }, If);
        If.pop();
        Column.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create(findProvider(this.selectedProvider).helpText);
            Text.debugLine("entry/src/main/ets/pages/AddAccount.ets(104:11)", "entry");
            Text.width('100%');
            Text.fontSize(13);
            Text.lineHeight(20);
            Text.fontColor('#7C8498');
            Text.padding(14);
            Text.backgroundColor('#EFF2F9');
            Text.borderRadius(12);
        }, Text);
        Text.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Button.createWithLabel(findProvider(this.selectedProvider).authType === AuthType.OAUTH_PKCE ?
                '使用 OAuth 安全登录' : (this.isConnecting ? '正在连接…' : '连接邮箱'));
            Button.debugLine("entry/src/main/ets/pages/AddAccount.ets(113:11)", "entry");
            Button.width('100%');
            Button.height(52);
            Button.fontSize(16);
            Button.fontWeight(FontWeight.Medium);
            Button.fontColor('#FFFFFF');
            Button.backgroundColor(findProvider(this.selectedProvider).color);
            Button.enabled(!this.isConnecting);
            Button.onClick(() => this.connect());
        }, Button);
        Button.pop();
        this.observeComponentCreation2((elmtId, isInitialRender) => {
            Text.create('继续即表示你允许邮箱助手同步邮件。凭证应由 HUKS 加密保存，OAuth Token 由服务端安全交换。');
            Text.debugLine("entry/src/main/ets/pages/AddAccount.ets(124:11)", "entry");
            Text.fontSize(12);
            Text.lineHeight(18);
            Text.fontColor('#9298A9');
            Text.textAlign(TextAlign.Center);
        }, Text);
        Text.pop();
        Column.pop();
        Scroll.pop();
        Column.pop();
    }
    rerender() {
        this.updateDirtyElements();
    }
    static getEntryName(): string {
        return "AddAccount";
    }
}
registerNamedRoute(() => new AddAccount(undefined, {}), "", { bundleName: "com.mailhelper.app", moduleName: "entry", pagePath: "pages/AddAccount", pageFullPath: "entry/src/main/ets/pages/AddAccount", integratedHsp: "false", moduleType: "followWithHap" });
