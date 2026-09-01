import { ComputerUseError } from "./errors.js";
import { stableJson, withoutApprovalRequest } from "./utils.js";

type PendingApproval = {
  toolName: string;
  canonicalArguments: string;
  grantId: string | undefined;
  expiresAtMs: number;
  consumed: boolean;
};

export class ApprovalRegistry {
  readonly #approvals = new Map<string, PendingApproval>();
  readonly #now: () => number;

  public constructor(now: () => number = Date.now) {
    this.#now = now;
  }

  public remember(
    toolName: string,
    argumentsWithDefaults: Record<string, unknown>,
    token: string,
    expiresAt: string
  ): void {
    const expiresAtMs = Date.parse(expiresAt);
    if (!Number.isFinite(expiresAtMs) || expiresAtMs <= this.#now()) {
      throw new ComputerUseError("BRIDGE_PROTOCOL_ERROR", "The native bridge issued an invalid approval expiry.");
    }
    this.#approvals.set(token, {
      toolName,
      canonicalArguments: stableJson(withoutApprovalRequest(argumentsWithDefaults)),
      grantId:
        typeof argumentsWithDefaults.grant_id === "string"
          ? argumentsWithDefaults.grant_id
          : undefined,
      expiresAtMs,
      consumed: false
    });
  }

  public assertRetry(toolName: string, argumentsWithDefaults: Record<string, unknown>): void {
    const requestId = argumentsWithDefaults.approval_request_id;
    if (requestId === undefined) return;
    if (typeof requestId !== "string") {
      throw new ComputerUseError("APPROVAL_MISMATCH", "The approval request identifier is malformed.");
    }

    const pending = this.#approvals.get(requestId);
    if (pending === undefined || pending.expiresAtMs <= this.#now()) {
      this.#approvals.delete(requestId);
      throw new ComputerUseError("APPROVAL_EXPIRED", "The approval request is unknown or expired.", {
        retryable: true,
        remediation: "Retry the action without approval_request_id to request a fresh approval."
      });
    }
    if (pending.consumed) {
      throw new ComputerUseError("APPROVAL_USED", "The approval request has already been consumed.");
    }

    const canonical = stableJson(withoutApprovalRequest(argumentsWithDefaults));
    if (pending.toolName !== toolName || pending.canonicalArguments !== canonical) {
      throw new ComputerUseError(
        "APPROVAL_MISMATCH",
        "The approval request is bound to different action arguments.",
        { remediation: "Retry the originally approved action exactly, or request a new approval." }
      );
    }
  }

  public consume(requestId: string | undefined): void {
    if (requestId === undefined) return;
    const approval = this.#approvals.get(requestId);
    if (approval !== undefined) approval.consumed = true;
  }

  public pendingCount(): number {
    this.#prune();
    return [...this.#approvals.values()].filter(value => !value.consumed).length;
  }

  public revokeGrant(grantId: string): void {
    for (const [token, approval] of this.#approvals) {
      if (approval.grantId === grantId) this.#approvals.delete(token);
    }
  }

  public retainGrants(activeGrantIds: ReadonlySet<string>): void {
    for (const [token, approval] of this.#approvals) {
      if (approval.grantId !== undefined && !activeGrantIds.has(approval.grantId)) {
        this.#approvals.delete(token);
      }
    }
  }

  #prune(): void {
    const now = this.#now();
    for (const [token, approval] of this.#approvals) {
      if (approval.expiresAtMs <= now) this.#approvals.delete(token);
    }
  }
}
