import { PendingMailOperation } from '../model/MailServerModels';

// Durable queue boundary used by the sync engine. Operations are removed only
// after the remote server confirms them, so app restarts cannot lose changes.
export interface PendingOperationStore {
  listPendingOperations(accountId: string): Promise<PendingMailOperation[]>;
  acknowledgePendingOperation(operationId: string): Promise<void>;
  recordPendingOperationFailure(operationId: string): Promise<void>;
}
