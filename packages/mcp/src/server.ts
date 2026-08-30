import { createHash } from "node:crypto";
import {
  McpServer,
  CLIENT_CAPABILITIES_META_KEY,
  ResourceNotFoundError,
  ResourceTemplate,
  acceptedContent,
  inputRequired,
  inputResponse,
  type CallToolResult,
  type InputRequiredResult,
  type ServerContext,
  type ToolAnnotations
} from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import { ApprovalRegistry } from "./approval-registry.js";
import { createDefaultNativeBridge } from "./bridge/index.js";
import type { NativeBridge, NativeMethod } from "./bridge/protocol.js";
import { ComputerUseError, NativeApprovalRequiredError, errorResult } from "./errors.js";
import { FrameStore } from "./frame-store.js";
import { RequestStateCodec, type ApprovalRequestState } from "./request-state.js";
import {
  ActionOutputSchema,
  ActionSuccessSchema,
  ClickInputSchema,
  DragInputSchema,
  EmptyInputSchema,
  GetStateInputSchema,
  GetStateOutputSchema,
  ListAppsInputSchema,
  ListAppsOutputSchema,
  ListDisplaysInputSchema,
  ListDisplaysOutputSchema,
  NativeStateSuccessSchema,
  PasteInputSchema,
  PressKeyInputSchema,
  ReleaseAccessInputSchema,
  ReleaseAccessOutputSchema,
  RequestAccessInputSchema,
  RequestAccessOutputSchema,
  ScrollInputSchema,
  SecondaryActionInputSchema,
  SelectTextInputSchema,
  SetValueInputSchema,
  StatusOutputSchema,
  TypeTextInputSchema,
  type ToolOutput
} from "./schemas.js";
import {
  asRecord,
  fromNativeResult,
  stableJson,
  toNativeParams,
  withoutApprovalRequest
} from "./utils.js";

export const SERVER_NAME = "computer-use-mcp-server";
export const SERVER_VERSION = "0.1.0-alpha.1";
const MAX_INLINE_PNG_BYTES = 5 * 1024 * 1024;
const APPROVAL_RESPONSE_KEY = "risk_approval";

const ConfirmApprovalSchema = z
  .object({ confirm: z.boolean().describe("Approve this exact computer action") })
  .strict();
const ConfirmApprovalRequestedSchema = Object.freeze({
  type: "object" as const,
  properties: {
    confirm: {
      type: "boolean" as const,
      title: "Approve this exact computer action"
    }
  },
  required: ["confirm"]
});

const NativeApprovalResolutionSchema = z
  .object({
    approval_request_id: z.string().min(16).max(512),
    disposition: z.enum(["approved", "denied"]),
    consumed: z.literal(false)
  })
  .strict();

const READ_ONLY_ANNOTATIONS = Object.freeze({
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
}) satisfies ToolAnnotations;

const ACCESS_REQUEST_ANNOTATIONS = Object.freeze({
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false
}) satisfies ToolAnnotations;

const ACCESS_RELEASE_ANNOTATIONS = Object.freeze({
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
}) satisfies ToolAnnotations;

const INTERACTION_ANNOTATIONS = Object.freeze({
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: false,
  openWorldHint: true
}) satisfies ToolAnnotations;

export type ComputerUseMcpServerOptions = {
  bridge?: NativeBridge;
  frameStore?: FrameStore;
  approvalRegistry?: ApprovalRegistry;
  requestStateCodec?: RequestStateCodec;
  era?: "legacy" | "modern";
  approvalMode?: "auto" | "native";
  onDiagnostic?: (message: string, error?: unknown) => void;
};

type ActionArguments =
  | z.infer<typeof ClickInputSchema>
  | z.infer<typeof DragInputSchema>
  | z.infer<typeof ScrollInputSchema>
  | z.infer<typeof PressKeyInputSchema>
  | z.infer<typeof TypeTextInputSchema>
  | z.infer<typeof PasteInputSchema>
  | z.infer<typeof SetValueInputSchema>
  | z.infer<typeof SelectTextInputSchema>
  | z.infer<typeof SecondaryActionInputSchema>;

type RegisteredAction = {
  toolName: string;
  nativeKind: string;
};

class ManagedMcpServer extends McpServer {
  readonly #bridge: NativeBridge;
  #closed = false;

  public constructor(bridge: NativeBridge, options: ConstructorParameters<typeof McpServer>) {
    super(...options);
    this.#bridge = bridge;
  }

  public override async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    try {
      await super.close();
    } finally {
      await this.#bridge.close();
    }
  }
}

export class ComputerUseMcpRuntime {
  public readonly server: McpServer;
  readonly #bridge: NativeBridge;
  readonly #frameStore: FrameStore;
  readonly #approvalRegistry: ApprovalRegistry;
  readonly #requestStateCodec: RequestStateCodec;
  readonly #era: "legacy" | "modern";
  readonly #approvalMode: "auto" | "native";
  readonly #onDiagnostic: (message: string, error?: unknown) => void;
  readonly #resolvedChallenges = new Map<string, number>();

  public constructor(options: ComputerUseMcpServerOptions = {}) {
    this.#bridge = options.bridge ?? createDefaultNativeBridge();
    this.#frameStore = options.frameStore ?? new FrameStore();
    this.#approvalRegistry = options.approvalRegistry ?? new ApprovalRegistry();
    this.#requestStateCodec = options.requestStateCodec ?? new RequestStateCodec();
    this.#era = options.era ?? "legacy";
    this.#approvalMode = options.approvalMode ?? approvalModeFromEnvironment();
    this.#onDiagnostic = options.onDiagnostic ?? (() => undefined);

    this.server = new ManagedMcpServer(this.#bridge, [
      { name: SERVER_NAME, version: SERVER_VERSION },
      {
        instructions:
          "Control only an explicitly granted macOS window or display. Call computer_get_state before every action and use its current grant_id and frame_id. Never reuse selectors or image coordinates across frames. Approval retries must preserve the exact arguments and approval_request_id.",
        inputRequired: {
          maxRounds: 2,
          roundTimeoutMs: 300_000,
          legacyShim: true
        },
        requestState: {
          verify: state => this.#requestStateCodec.verify(state)
        }
      }
    ]);

    this.#registerFrameResource();
    this.#registerTools();
  }

  #registerFrameResource(): void {
    this.server.registerResource(
      "computer_frame",
      new ResourceTemplate("computer-use://frame/{frameId}", { list: undefined }),
      {
        title: "Ephemeral computer-use frame",
        description: "A PNG screenshot from a recently returned computer_get_state frame.",
        mimeType: "image/png",
        cacheHint: { ttlMs: 60_000, cacheScope: "private" }
      },
      async (uri, variables) => {
        const rawFrameId = variables.frameId;
        const frameId = Array.isArray(rawFrameId) ? rawFrameId[0] : rawFrameId;
        if (typeof frameId !== "string") throw new ResourceNotFoundError(uri.href);
        const frame = this.#frameStore.get(decodeURIComponent(frameId));
        if (frame === undefined) throw new ResourceNotFoundError(uri.href);
        return {
          contents: [
            {
              uri: uri.href,
              mimeType: "image/png",
              blob: frame.data
            }
          ]
        };
      }
    );
  }

  #registerTools(): void {
    this.server.registerTool(
      "computer_get_status",
      {
        title: "Get computer-use status",
        description: "Check native host availability, macOS permissions, and active grants.",
        inputSchema: EmptyInputSchema,
        outputSchema: StatusOutputSchema,
        annotations: READ_ONLY_ANNOTATIONS
      },
      async (_args, ctx) =>
        this.#safeResult(StatusOutputSchema, async () => {
          const native = asRecord(await this.#callNative("status", {}, ctx, 10_000));
          return {
            ...native,
            ok: true,
            server_version: SERVER_VERSION,
            pending_approvals: this.#approvalRegistry.pendingCount()
          };
        })
    );

    this.server.registerTool(
      "computer_list_displays",
      {
        title: "List grantable displays",
        description: "List macOS displays and their global point and pixel geometry.",
        inputSchema: ListDisplaysInputSchema,
        outputSchema: ListDisplaysOutputSchema,
        annotations: READ_ONLY_ANNOTATIONS
      },
      async (args, ctx) =>
        this.#safeResult(ListDisplaysOutputSchema, async () => ({
          ...asRecord(await this.#callNative("listDisplays", args, ctx, 10_000)),
          ok: true
        }))
    );

    this.server.registerTool(
      "computer_list_apps",
      {
        title: "List grantable apps",
        description: "List applications whose windows can be selected for explicit access.",
        inputSchema: ListAppsInputSchema,
        outputSchema: ListAppsOutputSchema,
        annotations: READ_ONLY_ANNOTATIONS
      },
      async (args, ctx) =>
        this.#safeResult(ListAppsOutputSchema, async () => ({
          ...asRecord(await this.#callNative("listApps", args, ctx, 10_000)),
          ok: true
        }))
    );

    this.server.registerTool(
      "computer_request_access",
      {
        title: "Request target access",
        description:
          "Ask the user to grant an exact window or a session-only display and return an opaque grant_id.",
        inputSchema: RequestAccessInputSchema,
        outputSchema: RequestAccessOutputSchema,
        annotations: ACCESS_REQUEST_ANNOTATIONS
      },
      async (args, ctx) =>
        this.#safeResult(RequestAccessOutputSchema, async () => {
          const native = asRecord(
            await this.#callNative("requestAccess", args, ctx, args.timeout_ms)
          );
          const output: Record<string, unknown> = {
            ...native,
            ok: true
          };
          if (output["status"] === "granted") {
            const target = asRecord(output["target"]);
            const expectedSessionOnly = target.kind === "display";
            if (output["session_only"] !== expectedSessionOnly) {
              throw this.#protocolError("The native bridge returned inconsistent grant lifetime metadata.");
            }
          }
          return output;
        })
    );

    this.server.registerTool(
      "computer_release_access",
      {
        title: "Release target access",
        description: "Revoke one opaque grant immediately.",
        inputSchema: ReleaseAccessInputSchema,
        outputSchema: ReleaseAccessOutputSchema,
        annotations: ACCESS_RELEASE_ANNOTATIONS
      },
      async (args, ctx) =>
        this.#safeResult(ReleaseAccessOutputSchema, async () => {
          const native = asRecord(
            await this.#callNative("releaseAccess", args, ctx, args.timeout_ms)
          );
          const output: Record<string, unknown> = {
            ...native,
            ok: true
          };
          if (output["grant_id"] !== args.grant_id) {
            throw this.#protocolError("The native bridge released a different grant.");
          }
          return output;
        })
    );

    this.server.registerTool(
      "computer_get_state",
      {
        title: "Get current target state",
        description:
          "Capture a current frame, exact image/global transform, target metadata, and accessibility state for a grant.",
        inputSchema: GetStateInputSchema,
        outputSchema: GetStateOutputSchema,
        annotations: READ_ONLY_ANNOTATIONS
      },
      async (args, ctx) => this.#getState(args, ctx)
    );

    this.#registerAction(
      "computer_click",
      "Click",
      "Click a current-frame element or image point.",
      ClickInputSchema,
      "click",
      INTERACTION_ANNOTATIONS
    );
    this.#registerAction(
      "computer_drag",
      "Drag",
      "Drag between current-frame image points.",
      DragInputSchema,
      "drag",
      INTERACTION_ANNOTATIONS
    );
    this.#registerAction(
      "computer_scroll",
      "Scroll",
      "Scroll the granted target from its current frame.",
      ScrollInputSchema,
      "scroll",
      INTERACTION_ANNOTATIONS
    );
    this.#registerAction(
      "computer_press_key",
      "Press key",
      "Send one key chord to the granted target.",
      PressKeyInputSchema,
      "pressKey",
      INTERACTION_ANNOTATIONS
    );
    this.#registerAction(
      "computer_type_text",
      "Type text",
      "Type literal text into the current target focus.",
      TypeTextInputSchema,
      "typeText",
      INTERACTION_ANNOTATIONS
    );
    this.#registerAction(
      "computer_paste",
      "Paste content",
      "Write approved content through the native paste path.",
      PasteInputSchema,
      "paste",
      INTERACTION_ANNOTATIONS
    );
    this.#registerAction(
      "computer_set_value",
      "Set element value",
      "Set the value of a current-frame accessibility element.",
      SetValueInputSchema,
      "setValue",
      INTERACTION_ANNOTATIONS
    );
    this.#registerAction(
      "computer_select_text",
      "Select text",
      "Select text or place a cursor in a current-frame accessibility element.",
      SelectTextInputSchema,
      "selectText",
      INTERACTION_ANNOTATIONS
    );
    this.#registerAction(
      "computer_perform_secondary_action",
      "Perform secondary action",
      "Invoke a named secondary accessibility action on a current-frame element.",
      SecondaryActionInputSchema,
      "performSecondaryAction",
      INTERACTION_ANNOTATIONS
    );
  }

  #registerAction<Schema extends z.ZodObject>(
    toolName: string,
    title: string,
    description: string,
    schema: Schema,
    nativeKind: string,
    annotations: ToolAnnotations
  ): void {
    this.server.registerTool<typeof ActionOutputSchema, Schema>(
      toolName,
      {
        title,
        description: `${description} Requires the current frame_id and a concise intent.`,
        inputSchema: schema,
        outputSchema: ActionOutputSchema,
        annotations
      },
      (async (args: z.output<Schema>, ctx: ServerContext) =>
        this.#performAction(args as ActionArguments, { toolName, nativeKind }, ctx)) as never
    );
  }

  async #getState(args: z.infer<typeof GetStateInputSchema>, ctx: ServerContext): Promise<CallToolResult> {
    return this.#safeResult(GetStateOutputSchema, async () => {
      const raw = await this.#callNative("getState", args, ctx, args.timeout_ms);
      const parsed = NativeStateSuccessSchema.safeParse(raw);
      if (!parsed.success) throw this.#protocolError("The native bridge returned invalid state data.");
      const state = parsed.data;
      if (state.grant_id !== args.grant_id) {
        throw this.#protocolError("The native bridge returned state for a different grant.");
      }
      this.#validateCoordinateSpace(state.coordinate_space);
      this.#validateAccessibilityState(state, args);

      const output: Record<string, unknown> = {
        ok: true,
        status: "completed",
        grant_id: state.grant_id,
        target: state.target,
        frame_id: state.frame_id,
        captured_at: state.captured_at,
        coordinate_space: state.coordinate_space,
        ...(state.accessibility === undefined ? {} : { accessibility: state.accessibility })
      };

      let extraContent: CallToolResult["content"] = [];
      if (args.screenshot !== "none") {
        if (state.screenshot === undefined) {
          throw this.#protocolError("The native bridge omitted the requested PNG screenshot.");
        }
        this.#validateScreenshot(state);
        if (args.screenshot === "inline") {
          output.image = {
            delivery: "inline",
            mime_type: "image/png",
            width: state.screenshot.width,
            height: state.screenshot.height,
            sha256: state.screenshot.sha256
          };
          extraContent = [
            { type: "image", data: state.screenshot.data, mimeType: "image/png" }
          ];
        } else {
          const stored = this.#frameStore.put({
            frameId: state.frame_id,
            data: state.screenshot.data,
            mimeType: "image/png",
            width: state.screenshot.width,
            height: state.screenshot.height,
            sha256: state.screenshot.sha256
          });
          const resourceUri = this.#frameStore.uri(state.frame_id);
          output.image = {
            delivery: "resource",
            mime_type: "image/png",
            width: stored.width,
            height: stored.height,
            sha256: stored.sha256,
            resource_uri: resourceUri,
            expires_at: stored.expiresAt
          };
          extraContent = [
            {
              type: "resource_link",
              name: `frame-${state.frame_id}`,
              uri: resourceUri,
              mimeType: "image/png",
              description: "Ephemeral current-frame PNG; read before its expires_at value."
            }
          ];
        }
      }

      return { output, extraContent };
    });
  }

  async #performAction(
    args: ActionArguments,
    action: RegisteredAction,
    ctx: ServerContext
  ): Promise<CallToolResult | InputRequiredResult> {
    try {
      const recordArgs = args as Record<string, unknown>;
      const canonicalArguments = stableJson(withoutApprovalRequest(recordArgs));
      const state = ctx.mcpReq.requestState<ApprovalRequestState>();

      if (state !== undefined) {
        this.#requestStateCodec.assertBound(state, {
          toolName: action.toolName,
          canonicalArguments,
          grantId: args.grant_id,
          frameId: args.frame_id
        });
        if (
          args.approval_request_id !== undefined &&
          args.approval_request_id !== state.approval_request_id
        ) {
          throw new ComputerUseError(
            "APPROVAL_MISMATCH",
            "The input approval_request_id does not match the verified elicitation state."
          );
        }
        return this.#continueElicitedAction(args, action, state, ctx);
      }

      this.#approvalRegistry.assertRetry(action.toolName, recordArgs);
      const supportsForm = this.#supportsModernFormElicitation(ctx);
      const result = await this.#callAction(args, action.nativeKind, ctx, supportsForm ? "elicitation" : "native");
      if (result.status !== "approval_required") {
        this.#approvalRegistry.consume(args.approval_request_id);
        return this.#result(ActionOutputSchema.parse(result));
      }

      this.#approvalRegistry.remember(
        action.toolName,
        recordArgs,
        result.approval_request_id,
        result.expires_at
      );
      if (!supportsForm) return this.#result(ActionOutputSchema.parse(result));

      const requestState = this.#requestStateCodec.mint({
        tool_name: action.toolName,
        canonical_arguments: canonicalArguments,
        grant_id: args.grant_id,
        frame_id: args.frame_id,
        approval_request_id: result.approval_request_id,
        expires_at: result.expires_at
      });
      return this.#approvalInputRequired(result.message, requestState);
    } catch (error) {
      this.#onDiagnostic(`Tool ${action.toolName} failed.`, error);
      return this.#error(error);
    }
  }

  async #continueElicitedAction(
    args: ActionArguments,
    action: RegisteredAction,
    state: ApprovalRequestState,
    ctx: ServerContext
  ): Promise<CallToolResult | InputRequiredResult> {
    const response = inputResponse(ctx.mcpReq.inputResponses, APPROVAL_RESPONSE_KEY);
    if (response.kind === "missing") {
      return this.#approvalInputRequired(
        "Approve this exact computer action to continue.",
        this.#requestStateCodec.mint({
          tool_name: state.tool_name,
          canonical_arguments: state.canonical_arguments,
          grant_id: state.grant_id,
          frame_id: state.frame_id,
          approval_request_id: state.approval_request_id,
          expires_at: state.expires_at
        })
      );
    }

    if (response.kind !== "elicit") {
      throw new ComputerUseError("APPROVAL_MISMATCH", "The approval response has the wrong kind.");
    }

    if (response.action === "decline" || response.action === "cancel") {
      await this.#resolveRiskChallenge(
        state.approval_request_id,
        false,
        state.expires_at,
        ctx
      );
      this.#approvalRegistry.consume(state.approval_request_id);
      return this.#result({
        ok: true,
        status: "denied",
        reason: response.action === "decline" ? "The user declined the action." : "The user cancelled approval."
      });
    }

    const content = acceptedContent(
      ctx.mcpReq.inputResponses,
      APPROVAL_RESPONSE_KEY,
      ConfirmApprovalSchema
    );
    if (content === undefined) {
      return this.#approvalInputRequired(
        "A valid confirmation is required for this exact computer action.",
        this.#requestStateCodec.mint({
          tool_name: state.tool_name,
          canonical_arguments: state.canonical_arguments,
          grant_id: state.grant_id,
          frame_id: state.frame_id,
          approval_request_id: state.approval_request_id,
          expires_at: state.expires_at
        })
      );
    }
    if (!content.confirm) {
      await this.#resolveRiskChallenge(
        state.approval_request_id,
        false,
        state.expires_at,
        ctx
      );
      this.#approvalRegistry.consume(state.approval_request_id);
      return this.#result({ ok: true, status: "denied", reason: "The user denied the action." });
    }

    await this.#resolveRiskChallenge(
      state.approval_request_id,
      true,
      state.expires_at,
      ctx
    );
    const retryArgs = {
      ...(args as Record<string, unknown>),
      approval_request_id: state.approval_request_id
    } as ActionArguments;
    this.#approvalRegistry.assertRetry(action.toolName, retryArgs as Record<string, unknown>);
    const result = await this.#callAction(retryArgs, action.nativeKind, ctx, "elicitation");
    if (result.status === "approval_required") {
      throw this.#protocolError("The native bridge repeated a resolved risk challenge.");
    }
    this.#approvalRegistry.consume(state.approval_request_id);
    return this.#result(ActionOutputSchema.parse(result));
  }

  async #resolveRiskChallenge(
    approvalRequestId: string,
    approved: boolean,
    expiresAt: string,
    ctx: ServerContext
  ): Promise<void> {
    const now = Date.now();
    for (const [requestId, expiry] of this.#resolvedChallenges) {
      if (expiry <= now) this.#resolvedChallenges.delete(requestId);
    }
    if (this.#resolvedChallenges.has(approvalRequestId)) {
      throw new ComputerUseError("APPROVAL_USED", "The approval request has already been resolved.");
    }
    this.#resolvedChallenges.set(approvalRequestId, Date.parse(expiresAt));
    const raw = await this.#callNative(
      "approveRisk",
      { approval_request_id: approvalRequestId, approved },
      ctx,
      10_000
    );
    const parsed = NativeApprovalResolutionSchema.safeParse(raw);
    if (!parsed.success || parsed.data.approval_request_id !== approvalRequestId) {
      throw this.#protocolError("The native bridge returned an invalid approval resolution.");
    }
    if (approved && parsed.data.disposition === "denied") {
      throw new ComputerUseError("ACCESS_DENIED", "The native host denied the approved action.");
    }
  }

  async #callAction(
    args: ActionArguments,
    nativeKind: string,
    ctx: ServerContext,
    approvalMode: "elicitation" | "native"
  ): Promise<z.infer<typeof ActionSuccessSchema>> {
    const nativeParams = {
      ...(args as Record<string, unknown>),
      kind: nativeKind,
      approval_mode: approvalMode
    };
    let raw: Record<string, unknown>;
    try {
      raw = asRecord(await this.#callNative("action", nativeParams, ctx, args.timeout_ms));
    } catch (error) {
      if (!(error instanceof NativeApprovalRequiredError)) throw error;
      if (error.details.approvalMode !== approvalMode) {
        throw this.#protocolError("The native bridge returned a challenge for the wrong approval mode.");
      }
      return ActionSuccessSchema.parse({
        ok: true,
        status: "approval_required",
        approval_request_id: error.details.approvalRequestId,
        message: error.message,
        expires_at: error.details.expiresAt
      });
    }
    const output: Record<string, unknown> = { ...raw, ok: true };
    if (output["status"] === "completed" && output["grant_id"] !== args.grant_id) {
      throw this.#protocolError("The native bridge completed an action for a different grant.");
    }
    const parsed = ActionSuccessSchema.safeParse(output);
    if (!parsed.success) {
      throw this.#protocolError("The native bridge returned an invalid action result.");
    }
    return parsed.data;
  }

  #approvalInputRequired(message: string, requestState: string): InputRequiredResult {
    return inputRequired({
      inputRequests: {
        [APPROVAL_RESPONSE_KEY]: inputRequired.elicit({
          message,
          requestedSchema: ConfirmApprovalRequestedSchema
        })
      },
      requestState
    });
  }

  #supportsModernFormElicitation(ctx: ServerContext): boolean {
    if (this.#approvalMode === "native") return false;
    // Modern requests always carry the negotiated per-request envelope;
    // legacy initialize-era requests never do, even when they advertise the
    // older push-elicitation capability.
    if (ctx.mcpReq.envelope === undefined) return false;
    const capabilities =
      ((ctx.mcpReq.envelope as Record<string, unknown>)[CLIENT_CAPABILITIES_META_KEY] as
        | { elicitation?: unknown }
        | undefined) ??
      (this.server.server.getClientCapabilities() as
        | { elicitation?: unknown }
        | undefined);
    if (capabilities?.elicitation === undefined) return false;
    if (
      capabilities.elicitation === null ||
      typeof capabilities.elicitation !== "object" ||
      Array.isArray(capabilities.elicitation)
    ) {
      return false;
    }
    const elicitation = capabilities.elicitation as Record<string, unknown>;
    if (Object.hasOwn(elicitation, "form")) return elicitation.form !== undefined;
    return !Object.hasOwn(elicitation, "url");
  }

  async #callNative(
    method: NativeMethod,
    params: unknown,
    ctx: ServerContext,
    timeoutMs: number
  ): Promise<unknown> {
    const raw = await this.#bridge.call(method, toNativeParams(params), {
      signal: ctx.mcpReq.signal,
      timeoutMs
    });
    return fromNativeResult(raw);
  }

  async #safeResult<Schema extends z.ZodType>(
    schema: Schema,
    operation: () => Promise<unknown>
  ): Promise<CallToolResult> {
    try {
      const produced = await operation();
      if (
        produced !== null &&
        typeof produced === "object" &&
        Object.hasOwn(produced, "output") &&
        Object.hasOwn(produced, "extraContent")
      ) {
        const composite = produced as {
          output: unknown;
          extraContent: CallToolResult["content"];
        };
        const output = schema.parse(composite.output) as ToolOutput;
        return this.#result(output, composite.extraContent);
      }
      const output = schema.parse(produced) as ToolOutput;
      return this.#result(output);
    } catch (error) {
      this.#onDiagnostic("Computer-use tool failed.", error);
      return this.#error(error);
    }
  }

  #result(output: ToolOutput, extraContent: CallToolResult["content"] = []): CallToolResult {
    return {
      content: [{ type: "text", text: JSON.stringify(output) }, ...extraContent],
      structuredContent: output as Record<string, unknown>
    };
  }

  #error(error: unknown): CallToolResult {
    const output = errorResult(error);
    return {
      isError: true,
      content: [{ type: "text", text: JSON.stringify(output) }],
      structuredContent: output
    };
  }

  #validateScreenshot(state: z.infer<typeof NativeStateSuccessSchema>): void {
    const screenshot = state.screenshot;
    if (screenshot === undefined) throw this.#protocolError("The screenshot is missing.");
    if (stableJson(screenshot.transform) !== stableJson(state.coordinate_space)) {
      throw this.#protocolError("The screenshot transform does not match its frame coordinate space.");
    }
    if (
      screenshot.width !== state.coordinate_space.width_px ||
      screenshot.height !== state.coordinate_space.height_px
    ) {
      throw this.#protocolError("The screenshot dimensions do not match its coordinate space.");
    }

    const normalized = screenshot.data.replace(/=+$/u, "");
    if (!/^[A-Za-z0-9+/]+={0,2}$/u.test(screenshot.data)) {
      throw this.#protocolError("The native bridge returned malformed screenshot base64.");
    }
    const decoded = Buffer.from(screenshot.data, "base64");
    if (decoded.toString("base64").replace(/=+$/u, "") !== normalized) {
      throw this.#protocolError("The native bridge returned non-canonical screenshot base64.");
    }
    if (decoded.byteLength > MAX_INLINE_PNG_BYTES) {
      throw new ComputerUseError(
        "SCREEN_CAPTURE_FAILED",
        `The decoded PNG exceeds the ${MAX_INLINE_PNG_BYTES}-byte limit.`,
        { remediation: "Request a smaller max_width_px value." }
      );
    }
    const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
    if (
      decoded.byteLength < 24 ||
      !decoded.subarray(0, 8).equals(pngSignature) ||
      decoded.subarray(12, 16).toString("ascii") !== "IHDR"
    ) {
      throw this.#protocolError("The screenshot is not a PNG image.");
    }
    if (
      decoded.readUInt32BE(16) !== screenshot.width ||
      decoded.readUInt32BE(20) !== screenshot.height
    ) {
      throw this.#protocolError("The PNG header dimensions do not match screenshot metadata.");
    }
    if (createHash("sha256").update(decoded).digest("hex") !== screenshot.sha256) {
      throw this.#protocolError("The screenshot SHA-256 does not match its bytes.");
    }
  }

  #validateCoordinateSpace(space: z.infer<typeof NativeStateSuccessSchema>["coordinate_space"]): void {
    const forward = space.image_to_global;
    const inverse = space.global_to_image;
    const tolerance = 1e-7;
    const values = [
      forward.a * inverse.a + forward.c * inverse.b,
      forward.b * inverse.a + forward.d * inverse.b,
      forward.a * inverse.c + forward.c * inverse.d,
      forward.b * inverse.c + forward.d * inverse.d,
      forward.a * inverse.tx + forward.c * inverse.ty + forward.tx,
      forward.b * inverse.tx + forward.d * inverse.ty + forward.ty
    ];
    const expected = [1, 0, 0, 1, 0, 0];
    if (values.some((value, index) => Math.abs(value - (expected[index] ?? 0)) > tolerance)) {
      throw this.#protocolError("The image/global coordinate matrices are not exact inverses.");
    }
  }

  #validateAccessibilityState(
    state: z.infer<typeof NativeStateSuccessSchema>,
    args: z.infer<typeof GetStateInputSchema>
  ): void {
    const accessibility = state.accessibility;
    if (!args.include_accessibility) {
      if (accessibility !== undefined) {
        throw this.#protocolError("The native bridge returned unrequested accessibility state.");
      }
      return;
    }
    if (accessibility === undefined) {
      throw this.#protocolError("The native bridge omitted requested accessibility state.");
    }

    if (state.target.kind === "display") {
      if (
        accessibility.mode !== "full" ||
        accessibility.nodes.length !== 0 ||
        accessibility.truncated ||
        accessibility.reset_reason === undefined
      ) {
        throw this.#protocolError(
          "Display state must return an explicit empty, non-truncated full accessibility result."
        );
      }
    } else if (accessibility.mode === "diff") {
      if (args.since_frame_id === undefined) {
        throw this.#protocolError("An accessibility diff requires since_frame_id.");
      }
      if (accessibility.base_frame_id !== args.since_frame_id) {
        throw this.#protocolError("The accessibility diff does not match since_frame_id.");
      }
      if (accessibility.base_frame_id === state.frame_id) {
        throw this.#protocolError("An accessibility diff cannot use its current frame as its base.");
      }
    } else if (args.since_frame_id !== undefined && accessibility.reset_reason === undefined) {
      throw this.#protocolError(
        "A full accessibility snapshot replacing a requested diff must include reset_reason."
      );
    }

    const nodes =
      accessibility.mode === "full" ? accessibility.nodes : accessibility.upserted_nodes;
    const textCharacters = nodes.reduce((total, node) => {
      const fields = [node.role, node.subrole, node.title, node.label, node.value];
      return (
        total +
        fields.reduce<number>((subtotal, field) => subtotal + (field?.length ?? 0), 0) +
        node.actions.reduce((subtotal, action) => subtotal + action.length, 0)
      );
    }, 0);
    if (textCharacters > args.max_accessibility_chars) {
      throw this.#protocolError(
        "The accessibility state exceeds the requested max_accessibility_chars bound."
      );
    }
  }

  #protocolError(message: string): ComputerUseError {
    return new ComputerUseError("BRIDGE_PROTOCOL_ERROR", message, {
      retryable: false,
      remediation: "Update ComputerUseMCPHost and the MCP package to compatible versions."
    });
  }
}

function approvalModeFromEnvironment(): "auto" | "native" {
  const configured = process.env.COMPUTER_USE_MCP_APPROVAL_MODE;
  if (configured === undefined || configured === "" || configured === "auto") return "auto";
  if (configured === "native") return "native";
  throw new Error("COMPUTER_USE_MCP_APPROVAL_MODE must be either auto or native.");
}

export function createComputerUseMcpServer(
  options: ComputerUseMcpServerOptions = {}
): McpServer {
  return new ComputerUseMcpRuntime(options).server;
}
