import { describe, expect, it } from '@ohos/hypium';
import { EmailProviderType } from '../main/ets/model/MailModels';
import { findProvider } from '../main/ets/model/ProviderConfig';

export default function providerConfigTest(): void {
  describe('ProviderConfig', () => {
    it('uses secure QQ endpoints', 0, () => {
      const provider = findProvider(EmailProviderType.QQ);
      expect(provider.imap?.host).assertEqual('imap.qq.com');
      expect(provider.imap?.port).assertEqual(993);
      expect(provider.smtp?.port).assertEqual(465);
    });

    it('uses secure 163 endpoints', 0, () => {
      const provider = findProvider(EmailProviderType.NETEASE_163);
      expect(provider.imap?.host).assertEqual('imap.163.com');
      expect(provider.smtp?.host).assertEqual('smtp.163.com');
    });
  });
}

