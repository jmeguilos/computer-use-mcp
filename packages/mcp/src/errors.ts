import * as z from "zod/v4";

export const ToolErrorCodeSchema = z.enum([
  "INVALID_REQUEST",
  "PERMISSION_REQUIRED",
  "APP_CONTROL_DISABLED",
  "ACCESS_DENIED",
  "APP_NOT_RUNNING",
  "WINDOW_NOT_GRANTED",
  "WINDOW_CLOSED",
  "STALE_FRAME",
  "ELEMENT_NOT_FOUND",
  "ELEMENT_NOT_ACTIONABLE",
  "FOCUS_FAILED",
  "SCREEN_CAPTURE_FAILED",
  "ACTION_TIMEOUT",
  "CANCELLED",
  "APPROVAL_EXPIRED",
  "APPROVAL_USED",
  "APPROVAL_MISMATCH",
  "BUSY",
  "UNSUPPORTED",
  "BRIDGE_UNAVAILABLE",
  "BRIDGE_PROTOCOL_ERROR",
  "INTERNAL_ERROR"
]);

export type ToolErrorCode = z.infer<typeof ToolErrorCodeSchema>;

export const ToolErrorSchema = z
  .object({
    ok: z.literal(false),
    error: z
      .object({
        code: ToolErrorCodeSchema,
        message: z.string().min(1).max(2_000),
        retryable: z.boolean(),
        remediation: z.string().min(1).max(2_000).optional()
      })
      .strict()
  })
  .strict();

export type ToolError = z.infer<typeof ToolErrorSchema>;

export type NativeApprovalRequiredDetails = {
  approvalRequestId: string;
  riskTier: string;
  expiresAt: string;
  approvalMode: "elicitation" | "native";
};

export class NativeApprovalRequiredError extends Error {
  public readonly details: NativeApprovalRequiredDetails;

  public constructor(message: string, details: NativeApprovalRequiredDetails) {
    super(message);
    this.name = "NativeApprovalRequiredError";
    this.details = details;
  }
}

export class ComputerUseError extends Error {
  public readonly code: ToolErrorCode;
  public readonly retryable: boolean;
  public readonly remediation: string | undefined;

  public constructor(
    code: ToolErrorCode,
    message: string,
    options: { retryable?: boolean; remediation?: string; cause?: unknown } = {}
  ) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = "ComputerUseError";
    this.code = code;
    this.retryable = options.retryable ?? false;
    this.remediation = options.remediation;
  }
}

export function errorResult(error: unknown): ToolError {
  if (error instanceof ComputerUseError) {
    return {
      ok: false,
      error: {
        code: error.code,
        message: error.message,
        retryable: error.retryable,
        ...(error.remediation === undefined ? {} : { remediation: error.remediation })
      }
    };
  }

  if (error instanceof Error && error.name === "AbortError") {
    return {
      ok: false,
      error: {
        code: "CANCELLED",
        message: "The computer-use operation was cancelled.",
        retryable: true,
        remediation: "Refresh the target window state before retrying."
      }
    };
  }

  return {
    ok: false,
    error: {
      code: "INTERNAL_ERROR",
      message: "The computer-use operation failed unexpectedly.",
      retryable: false,
      remediation: "Run computer-use-mcp doctor and inspect stderr diagnostics."
    }
  };
}
