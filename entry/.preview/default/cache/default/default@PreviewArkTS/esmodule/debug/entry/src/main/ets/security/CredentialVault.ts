// UI and repositories only keep a reference. Production builds should back this
// interface with HUKS and never persist the raw authorization code or OAuth token.
export interface CredentialVault {
    save(accountId: string, secret: string): Promise<string>;
    read(reference: string): Promise<string>;
    remove(reference: string): Promise<void>;
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
