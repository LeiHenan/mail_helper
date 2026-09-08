import { AccountSyncState, PendingMailOperation, SyncPhase } from '../model/MailServerModels';
import { PendingOperationStore } from '../data/PendingOperationStore';
import { MailBackend } from './MailBackendContract';

export interface SyncStateListener {
  onStateChanged(state: AccountSyncState): void;
}

export class SyncCoordinator {
  private states: Map<string, AccountSyncState> = new Map<string, AccountSyncState>();
  private listeners: SyncStateListener[] = [];

  constructor(private operationStore: PendingOperationStore) {
  }

  addListener(listener: SyncStateListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: SyncStateListener): void {
    this.listeners = this.listeners.filter((item: SyncStateListener) => item !== listener);
  }

  getState(accountId: string): AccountSyncState {
    return this.states.get(accountId) ?? new AccountSyncState(accountId);
  }

  async synchronize(accountId: string, backend: MailBackend): Promise<void> {
    try {
      this.update(accountId, SyncPhase.CONNECTING, 0.1);
      this.update(accountId, SyncPhase.OPERATIONS, 0.25);
      const queued: PendingMailOperation[] = await this.operationStore.listPendingOperations(accountId);
      for (let index: number = 0; index < queued.length; index++) {
        try {
          await backend.execute(queued[index]);
          await this.operationStore.acknowledgePendingOperation(queued[index].id);
        } catch (error) {
          await this.operationStore.recordPendingOperationFailure(queued[index].id);
          throw error;
        }
      }
      this.update(accountId, SyncPhase.FOLDERS, 0.45);
      await backend.fetchFolders();
      this.update(accountId, SyncPhase.MESSAGES, 0.7);
      await backend.fetchMessages('INBOX', '', 50);
      const completed: AccountSyncState = new AccountSyncState(accountId, SyncPhase.COMPLETE, 1,
        Date.now(), '');
      this.states.set(accountId, completed);
      this.notify(completed);
    } catch (error) {
      const failed: AccountSyncState = new AccountSyncState(accountId, SyncPhase.FAILED, 0,
        this.getState(accountId).lastSuccessAt, `${error}`);
      this.states.set(accountId, failed);
      this.notify(failed);
      throw error;
    }
  }

  private update(accountId: string, phase: SyncPhase, progress: number): void {
    const current: AccountSyncState = this.getState(accountId);
    const state: AccountSyncState = new AccountSyncState(accountId, phase, progress,
      current.lastSuccessAt, '');
    this.states.set(accountId, state);
    this.notify(state);
  }

  private notify(state: AccountSyncState): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onStateChanged(state);
    }
  }
}
