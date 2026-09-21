import { describe, expect, it } from '@ohos/hypium';
import { EmailProviderType } from '../main/ets/model/MailModels';
import { findProvider } from '../main/ets/model/ProviderConfig';

export default function providerConfigTest(): void {
  describe('ProviderConfig', () => {
    it('uses secure QQ endpoints', 0, () => {
      const provider = findProvider(EmailProviderType.QQ);
      expect(provider.incoming?.host).assertEqual('imap.qq.com');
      expect(provider.incoming?.port).assertEqual(993);
      expect(provider.outgoing?.port).assertEqual(465);
    });

    it('uses secure 163 endpoints', 0, () => {
      const provider = findProvider(EmailProviderType.NETEASE_163);
      expect(provider.incoming?.host).assertEqual('imap.163.com');
      expect(provider.outgoing?.host).assertEqual('smtp.163.com');
    });
  });
}

