import { Context } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { util } from '@kit.ArkTS';
import { describeError, errorCode } from '../service/ErrorFormatter';

const KEY_ALIAS: string = 'mail_helper_credential_master_v1';
const PREFERENCES_NAME: string = 'mail_helper_credentials';

export interface CredentialVault {
  save(accountId: string, secret: string): Promise<string>;
  read(reference: string): Promise<string>;
  remove(reference: string): Promise<void>;
}

export class HuksCredentialVault implements CredentialVault {
  private storage: preferences.Preferences;
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  constructor(context: Context) {
    this.storage = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
  }

  private keyProperties(): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_CBC },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_PKCS7 }
    ];
  }

  private operationProperties(purpose: huks.HuksKeyPurpose, iv: Uint8Array): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_CBC },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_PKCS7 },
      { tag: huks.HuksTag.HUKS_TAG_IV, value: iv }
    ];
  }

  private async ensureKey(): Promise<void> {
    let exists: boolean = false;
    try {
      exists = await huks.isKeyItemExist(KEY_ALIAS, { properties: [] });
    } catch (error) {
      if (errorCode(error) !== 12000011) {
        throw new Error(`检查安全密钥失败：${describeError(error)}`);
      }
    }
    if (!exists) {
      await huks.generateKeyItem(KEY_ALIAS, { properties: this.keyProperties() });
    }
  }

  private async recreateKey(): Promise<void> {
    try {
      await huks.deleteKeyItem(KEY_ALIAS, { properties: [] });
    } catch (error) {
      if (errorCode(error) !== 12000011) {
        throw new Error(`重置安全密钥失败：${describeError(error)}`);
      }
    }
    await huks.generateKeyItem(KEY_ALIAS, { properties: this.keyProperties() });
  }

  private async crypt(data: Uint8Array, purpose: huks.HuksKeyPurpose, iv: Uint8Array): Promise<Uint8Array> {
    await this.ensureKey();
    return this.cryptSession(data, purpose, iv, true);
  }

  private async cryptSession(data: Uint8Array, purpose: huks.HuksKeyPurpose, iv: Uint8Array,
    allowMissingKeyRetry: boolean): Promise<Uint8Array> {
    const properties: huks.HuksParam[] = this.operationProperties(purpose, iv);
    let session: huks.HuksSessionHandle | undefined = undefined;
    try {
      session = await huks.initSession(KEY_ALIAS, { properties: properties });
      const updated: huks.HuksReturnResult | null = await huks.updateSession(session.handle,
        { properties: properties, inData: data });
      const finished: huks.HuksReturnResult | null = await huks.finishSession(session.handle,
        { properties: properties, inData: new Uint8Array(0) });
      const updatedData: Uint8Array = updated?.outData ?? new Uint8Array(0);
      const finishedData: Uint8Array = finished?.outData ?? new Uint8Array(0);
      const output: Uint8Array = new Uint8Array(updatedData.length + finishedData.length);
      output.set(updatedData, 0);
      output.set(finishedData, updatedData.length);
      if (output.length === 0) {
        throw new Error('安全凭据处理没有返回数据');
      }
      return output;
    } catch (error) {
      if (session) {
        await huks.abortSession(session.handle, { properties: properties }).catch(() => {});
      }
      if (allowMissingKeyRetry && errorCode(error) === 12000011) {
        await this.recreateKey();
        return this.cryptSession(data, purpose, iv, false);
      }
      throw new Error(describeError(error));
    }
  }

  async save(accountId: string, secret: string): Promise<string> {
    const reference: string = `credential_${accountId}`;
    const iv: Uint8Array = cryptoFramework.createRandom().generateRandomSync(16).data;
    const encrypted: Uint8Array = await this.crypt(this.encoder.encodeInto(secret),
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, iv);
    const stored: Uint8Array = new Uint8Array(iv.length + encrypted.length);
    stored.set(iv, 0);
    stored.set(encrypted, iv.length);
    await this.storage.put(reference, stored);
    await this.storage.flush();
    return reference;
  }

  async read(reference: string): Promise<string> {
    const value: preferences.ValueType = await this.storage.get(reference, new Uint8Array(0));
    if (!(value instanceof Uint8Array) || value.length <= 16) {
      return '';
    }
    const iv: Uint8Array = value.slice(0, 16);
    const encrypted: Uint8Array = value.slice(16);
    const clear: Uint8Array = await this.crypt(encrypted,
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, iv);
    return this.decoder.decode(clear);
  }

  async remove(reference: string): Promise<void> {
    await this.storage.delete(reference);
    await this.storage.flush();
  }
}

export class MemoryCredentialVault implements CredentialVault {
  private secrets: Map<string, string> = new Map<string, string>();

  async save(accountId: string, secret: string): Promise<string> {
    const reference: string = `credential_${accountId}`;
    this.secrets.set(reference, secret);
    return reference;
  }

  async read(reference: string): Promise<string> {
    return this.secrets.get(reference) ?? '';
  }

  async remove(reference: string): Promise<void> {
    this.secrets.delete(reference);
  }
}
