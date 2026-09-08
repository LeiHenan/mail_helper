import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http, socket } from '@kit.NetworkKit';
import { OAuthClientConfig, oauthClientConfig } from '../config/OAuthClientConfig';
import { EmailProviderType } from '../model/MailModels';
import { describeError } from './ErrorFormatter';

interface OAuthProviderSettings {
  authorizationEndpoint: string;
  tokenEndpoint: string;
  scope: string;
  redirectHost: string;
}

interface OAuthTokenResponse {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
  token_type?: string;
  error?: string;
  error_description?: string;
}

class OAuthCallbackResult {
  code: string;
  state: string;
  error: string;
  errorDescription: string;

  constructor(code: string, state: string, error: string, errorDescription: string) {
    this.code = code;
    this.state = state;
    this.error = error;
    this.errorDescription = errorDescription;
  }
}

export class OAuthCredential {
  version: number;
  provider: EmailProviderType;
  clientId: string;
  clientSecret: string;
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  tokenEndpoint: string;
  scope: string;

  constructor(provider: EmailProviderType, clientId: string, clientSecret: string, accessToken: string,
    refreshToken: string, expiresAt: number, tokenEndpoint: string, scope: string) {
    this.version = 1;
    this.provider = provider;
    this.clientId = clientId;
    this.clientSecret = clientSecret;
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.expiresAt = expiresAt;
    this.tokenEndpoint = tokenEndpoint;
    this.scope = scope;
  }
}

export class OAuthResolvedCredential {
  accessToken: string;
  serializedCredential: string;
  wasRefreshed: boolean;

  constructor(accessToken: string, serializedCredential: string, wasRefreshed: boolean) {
    this.accessToken = accessToken;
    this.serializedCredential = serializedCredential;
    this.wasRefreshed = wasRefreshed;
  }
}

export class OAuthService {
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');
  private base64: util.Base64Helper = new util.Base64Helper();

  async authorize(context: common.UIAbilityContext, provider: EmailProviderType, email: string): Promise<string> {
    const configuration: OAuthProviderSettings = this.configuration(provider);
    const client: OAuthClientConfig = oauthClientConfig(provider);
    const clientId: string = client.clientId.trim();
    const clientSecret: string = client.clientSecret.trim();
    if (clientId.length === 0) {
      throw new Error(provider === EmailProviderType.OUTLOOK ?
        '应用尚未配置 Microsoft OAuth Client ID' : '应用尚未配置 OAuth Client ID');
    }
    const verifier: string = this.randomBase64Url(64);
    const state: string = this.randomBase64Url(32);
    const challenge: string = await this.sha256Base64Url(verifier);
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    await server.listen({ address: '127.0.0.1', family: 1, port: 0 });
    const localAddress: socket.NetAddress = await server.getLocalAddress();
    const port: number = localAddress.port ?? 0;
    if (port <= 0) {
      await server.close();
      throw new Error('无法创建 OAuth 本机回调端口');
    }
    const redirectUri: string = `http://${configuration.redirectHost}:${port}/oauth/callback`;
    const callback: Promise<OAuthCallbackResult> = this.waitForCallback(server);
    const authorizationUrl: string = this.authorizationUrl(provider, configuration,
      clientId, email.trim(), redirectUri, state, challenge);
    try {
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: authorizationUrl });
      const callbackResult: OAuthCallbackResult = await callback;
      await this.returnToApplication(context);
      if (callbackResult.error.length > 0) {
        throw new Error(callbackResult.errorDescription.length > 0 ? callbackResult.errorDescription :
          `OAuth 授权失败：${callbackResult.error}`);
      }
      if (callbackResult.state !== state) {
        throw new Error('OAuth 回调校验失败，请重新登录');
      }
      if (callbackResult.code.length === 0) {
        throw new Error('OAuth 服务没有返回授权码');
      }
      const tokenParameters: string[][] = [
        ['client_id', clientId],
        ['code', callbackResult.code],
        ['code_verifier', verifier],
        ['redirect_uri', redirectUri],
        ['grant_type', 'authorization_code']
      ];
      if (provider === EmailProviderType.GMAIL && clientSecret.trim().length > 0) {
        tokenParameters.push(['client_secret', clientSecret.trim()]);
      }
      const token: OAuthTokenResponse = await this.requestToken(configuration.tokenEndpoint,
        this.form(tokenParameters));
      const accessToken: string = token.access_token ?? '';
      if (accessToken.length === 0) {
        throw new Error(this.tokenError(token, 'OAuth 服务没有返回访问令牌'));
      }
      const expiresIn: number = token.expires_in ?? 3600;
      const credential: OAuthCredential = new OAuthCredential(provider, clientId, '',
        accessToken, token.refresh_token ?? '', Date.now() + Math.max(60, expiresIn) * 1000,
        configuration.tokenEndpoint, token.scope ?? configuration.scope);
      return JSON.stringify(credential);
    } finally {
      try {
        await server.close();
      } catch (_error) {
      }
    }
  }

  async resolveAccessToken(provider: EmailProviderType, serializedCredential: string):
    Promise<OAuthResolvedCredential> {
    const credential: OAuthCredential = this.parseCredential(serializedCredential);
    if (credential.provider !== provider) {
      throw new Error('OAuth 凭据与邮箱服务商不匹配，请重新登录');
    }
    if (credential.expiresAt > Date.now() + 5 * 60 * 1000 && credential.accessToken.length > 0) {
      return new OAuthResolvedCredential(credential.accessToken, serializedCredential, false);
    }
    if (credential.refreshToken.length === 0) {
      throw new Error('OAuth 登录已过期且没有刷新令牌，请删除账户后重新登录');
    }
    const configuration: OAuthProviderSettings = this.configuration(provider);
    const configuredClient: OAuthClientConfig = oauthClientConfig(provider);
    const clientId: string = configuredClient.clientId.trim().length > 0 ?
      configuredClient.clientId.trim() : credential.clientId;
    const refreshParameters: string[][] = [
      ['client_id', clientId],
      ['refresh_token', credential.refreshToken],
      ['grant_type', 'refresh_token'],
      ['scope', credential.scope.length > 0 ? credential.scope : configuration.scope]
    ];
    const clientSecret: string = configuredClient.clientSecret.trim().length > 0 ?
      configuredClient.clientSecret.trim() : credential.clientSecret;
    if (provider === EmailProviderType.GMAIL && clientSecret.length > 0) {
      refreshParameters.push(['client_secret', clientSecret]);
    }
    const token: OAuthTokenResponse = await this.requestToken(credential.tokenEndpoint.length > 0 ?
      credential.tokenEndpoint : configuration.tokenEndpoint, this.form(refreshParameters));
    const accessToken: string = token.access_token ?? '';
    if (accessToken.length === 0) {
      throw new Error(this.tokenError(token, 'OAuth 令牌刷新失败，请重新登录'));
    }
    credential.accessToken = accessToken;
    credential.refreshToken = token.refresh_token ?? credential.refreshToken;
    credential.expiresAt = Date.now() + Math.max(60, token.expires_in ?? 3600) * 1000;
    credential.scope = token.scope ?? credential.scope;
    const serialized: string = JSON.stringify(credential);
    return new OAuthResolvedCredential(accessToken, serialized, true);
  }

  private configuration(provider: EmailProviderType): OAuthProviderSettings {
    if (provider === EmailProviderType.GMAIL) {
      return {
        authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
        tokenEndpoint: 'https://oauth2.googleapis.com/token',
        scope: 'openid email https://mail.google.com/',
        redirectHost: '127.0.0.1'
      };
    }
    if (provider === EmailProviderType.OUTLOOK) {
      return {
        authorizationEndpoint: 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
        tokenEndpoint: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
        scope: 'offline_access openid email https://outlook.office.com/IMAP.AccessAsUser.All ' +
          'https://outlook.office.com/SMTP.Send',
        redirectHost: 'localhost'
      };
    }
    throw new Error('当前邮箱服务商不支持 OAuth 登录');
  }

  private authorizationUrl(provider: EmailProviderType, configuration: OAuthProviderSettings,
    clientId: string, email: string, redirectUri: string, state: string, challenge: string): string {
    const parameters: string[][] = [
      ['client_id', clientId],
      ['redirect_uri', redirectUri],
      ['response_type', 'code'],
      ['scope', configuration.scope],
      ['state', state],
      ['code_challenge', challenge],
      ['code_challenge_method', 'S256'],
      ['login_hint', email]
    ];
    if (provider === EmailProviderType.GMAIL) {
      parameters.push(['access_type', 'offline']);
      parameters.push(['prompt', 'consent']);
    } else {
      parameters.push(['response_mode', 'query']);
    }
    return `${configuration.authorizationEndpoint}?${this.form(parameters)}`;
  }

  private waitForCallback(server: socket.TCPSocketServer): Promise<OAuthCallbackResult> {
    return new Promise<OAuthCallbackResult>((resolve, reject) => {
      let completed: boolean = false;
      const timeoutId: number = setTimeout(() => {
        if (completed) return;
        completed = true;
        reject(new Error('OAuth 登录等待超时，请重新尝试'));
      }, 5 * 60 * 1000);
      server.on('error', (error: Error) => {
        if (completed) return;
        completed = true;
        clearTimeout(timeoutId);
        reject(new Error(`OAuth 回调服务异常：${error.message}`));
      });
      server.on('connect', (connection: socket.TCPSocketConnection) => {
        connection.on('message', (messageInfo: socket.SocketMessageInfo) => {
          if (completed) return;
          const request: string = this.decoder.decode(new Uint8Array(messageInfo.message));
          const result: OAuthCallbackResult = this.parseCallbackRequest(request);
          const validRequest: boolean = request.startsWith('GET /oauth/callback?') ||
            request.startsWith('GET /oauth/callback ');
          const success: boolean = validRequest && result.code.length > 0 && result.error.length === 0;
          const pageTitle: string = success ? '授权成功' : '授权未完成';
          const pageText: string = success ? '授权成功，正在自动返回邮箱助手。' :
            '授权未完成，请返回邮箱助手重试。';
          const returnUri: string = 'mailhelper://oauth/complete';
          const body: string = '<!doctype html><html><head><meta charset="utf-8">' +
            '<meta name="viewport" content="width=device-width,initial-scale=1">' +
            `<title>${pageTitle}</title>` +
            '</head><body style="font-family:sans-serif;padding:32px">' +
            `<h2>${pageTitle}</h2><p>${pageText}</p>` + (success ?
              `<p><a href="${returnUri}" style="display:inline-block;text-decoration:none;padding:12px 20px;` +
              'background:#0866c6;color:#fff;font-size:16px;border-radius:24px">返回邮箱助手</a></p>' : '') +
            '</body></html>';
          const response: string = success ?
            `HTTP/1.1 302 Found\r\nLocation: ${returnUri}\r\n` +
              'Cache-Control: no-store\r\nContent-Type: text/html; charset=utf-8\r\n' +
              `Content-Length: ${this.encoder.encodeInto(body).length}\r\nConnection: close\r\n\r\n${body}` :
            'HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nContent-Type: text/html; charset=utf-8\r\n' +
              `Content-Length: ${this.encoder.encodeInto(body).length}\r\nConnection: close\r\n\r\n${body}`;
          connection.send({ data: response, encoding: 'UTF-8' }).then(() => {
            connection.close();
            if (!validRequest || completed) return;
            completed = true;
            clearTimeout(timeoutId);
            resolve(result);
          }).catch(() => connection.close());
          if (!validRequest) return;
        });
      });
    });
  }

  private parseCallbackRequest(request: string): OAuthCallbackResult {
    const firstLine: string = request.split('\r\n')[0] ?? '';
    const target: string = firstLine.split(' ')[1] ?? '';
    const queryIndex: number = target.indexOf('?');
    const query: string = queryIndex >= 0 ? target.substring(queryIndex + 1) : '';
    return new OAuthCallbackResult(this.queryValue(query, 'code'), this.queryValue(query, 'state'),
      this.queryValue(query, 'error'), this.queryValue(query, 'error_description'));
  }

  private queryValue(query: string, key: string): string {
    const pairs: string[] = query.split('&');
    for (let index: number = 0; index < pairs.length; index++) {
      const separator: number = pairs[index].indexOf('=');
      const rawKey: string = separator >= 0 ? pairs[index].substring(0, separator) : pairs[index];
      if (decodeURIComponent(rawKey.replace(/\+/g, ' ')) === key) {
        const rawValue: string = separator >= 0 ? pairs[index].substring(separator + 1) : '';
        return decodeURIComponent(rawValue.replace(/\+/g, ' '));
      }
    }
    return '';
  }

  private async requestToken(endpoint: string, body: string): Promise<OAuthTokenResponse> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(endpoint, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/x-www-form-urlencoded' },
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 30000
      });
      const responseText: string = typeof response.result === 'string' ? response.result : '';
      const token: OAuthTokenResponse = JSON.parse(responseText) as OAuthTokenResponse;
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(this.tokenError(token, `OAuth 服务返回 ${response.responseCode}`));
      }
      return token;
    } catch (error) {
      throw new Error(`OAuth 令牌请求失败：${describeError(error)}`);
    } finally {
      request.destroy();
    }
  }

  private parseCredential(serializedCredential: string): OAuthCredential {
    try {
      const parsed: OAuthCredential = JSON.parse(serializedCredential) as OAuthCredential;
      if (!parsed || parsed.version !== 1 || !parsed.provider || !parsed.clientId ||
        !parsed.accessToken || !parsed.tokenEndpoint) {
        throw new Error('凭据格式不完整');
      }
      return new OAuthCredential(parsed.provider, parsed.clientId, parsed.clientSecret ?? '',
        parsed.accessToken, parsed.refreshToken ?? '', parsed.expiresAt ?? 0,
        parsed.tokenEndpoint, parsed.scope ?? '');
    } catch (error) {
      throw new Error(`OAuth 凭据已损坏，请重新登录：${describeError(error)}`);
    }
  }

  private tokenError(token: OAuthTokenResponse, fallback: string): string {
    const detail: string = token.error_description ?? token.error ?? fallback;
    if (detail.toLowerCase().includes('client_secret is missing')) {
      return '应用内置的 Google OAuth Client Secret 无效或缺失';
    }
    return detail;
  }

  private async returnToApplication(context: common.UIAbilityContext): Promise<void> {
    try {
      const mainWindow: window.Window = await context.windowStage.getMainWindow();
      try {
        await mainWindow.restore();
      } catch (_error) {
      }
      await mainWindow.showWindow();
    } catch (_error) {
    }
  }

  private form(parameters: string[][]): string {
    return parameters.map((entry: string[]) =>
      `${encodeURIComponent(entry[0])}=${encodeURIComponent(entry[1])}`).join('&');
  }

  private randomBase64Url(length: number): string {
    const bytes: Uint8Array = cryptoFramework.createRandom().generateRandomSync(length).data;
    return this.base64.encodeToStringSync(bytes, util.Type.BASIC_URL_SAFE).replace(/=+$/g, '');
  }

  private async sha256Base64Url(value: string): Promise<string> {
    const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    await digest.update({ data: this.encoder.encodeInto(value) });
    const result: cryptoFramework.DataBlob = await digest.digest();
    return this.base64.encodeToStringSync(result.data, util.Type.BASIC_URL_SAFE).replace(/=+$/g, '');
  }
}
