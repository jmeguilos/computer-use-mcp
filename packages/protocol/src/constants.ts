export const PACKAGE_VERSION = "0.1.0-alpha.1" as const;

/** Native helper/host protocol. Minor versions are backward-compatible. */
export const PROTOCOL_VERSION = Object.freeze({ major: 2, minor: 0 }) as Readonly<{
  major: 2;
  minor: 0;
}>;

export const MAX_WIRE_LINE_BYTES = 8 * 1024 * 1024;
export const MAX_INLINE_PNG_BYTES = 5 * 1024 * 1024;
export const FRAME_RESOURCE_TTL_MS = 60_000;
export const GRANT_IDLE_TIMEOUT_MS = 15 * 60_000;
export const AUDIT_RETENTION_MS = 7 * 24 * 60 * 60_000;

export const PUBLIC_CAPABILITIES = ["observe", "interact", "clipboard_write"] as const;
export type PublicCapability = (typeof PUBLIC_CAPABILITIES)[number];

export const NATIVE_CAPABILITIES = [
  "inventory.read",
  "window.capture",
  "display.capture",
  "accessibility.read",
  "accessibility.action",
  "input.synthetic",
  "indicator.control",
  "risk.approve",
  "session.stop"
] as const;
export type NativeCapability = (typeof NATIVE_CAPABILITIES)[number];

export const NATIVE_HANDSHAKE_METHOD = "hello" as const;

/** Methods accepted after the authenticated hello. EOF is the disconnect signal. */
export const NATIVE_METHODS = [
  "status",
  "listDisplays",
  "listApps",
  "requestAccess",
  "releaseAccess",
  "getState",
  "action",
  "approveRisk",
  "stop",
  "cancel"
] as const;
export type NativeMethod = (typeof NATIVE_METHODS)[number];

export const ALL_NATIVE_METHODS = [NATIVE_HANDSHAKE_METHOD, ...NATIVE_METHODS] as const;
export type AnyNativeMethod = (typeof ALL_NATIVE_METHODS)[number];

export const TOOL_NAMES = [
  "computer_get_status",
  "computer_list_apps",
  "computer_list_displays",
  "computer_request_access",
  "computer_release_access",
  "computer_get_state",
  "computer_click",
  "computer_drag",
  "computer_scroll",
  "computer_press_key",
  "computer_type_text",
  "computer_paste",
  "computer_set_value",
  "computer_select_text",
  "computer_perform_secondary_action"
] as const;

export type ToolName = (typeof TOOL_NAMES)[number];

export const INSPECTION_TOOL_NAMES = [
  "computer_get_status",
  "computer_list_apps",
  "computer_list_displays",
  "computer_get_state"
] as const satisfies readonly ToolName[];

export const ACTION_TOOL_NAMES = [
  "computer_click",
  "computer_drag",
  "computer_scroll",
  "computer_press_key",
  "computer_type_text",
  "computer_paste",
  "computer_set_value",
  "computer_select_text",
  "computer_perform_secondary_action"
] as const satisfies readonly ToolName[];

export type ToolAnnotationContract = Readonly<{
  readOnlyHint: boolean;
  destructiveHint: boolean;
  idempotentHint: boolean;
  openWorldHint: boolean;
}>;

const inspect: ToolAnnotationContract = Object.freeze({
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
});

const grant: ToolAnnotationContract = Object.freeze({
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false
});

const release: ToolAnnotationContract = Object.freeze({
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
});

const input: ToolAnnotationContract = Object.freeze({
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: false,
  openWorldHint: true
});

export const TOOL_ANNOTATIONS: Readonly<Record<ToolName, ToolAnnotationContract>> = Object.freeze({
  computer_get_status: inspect,
  computer_list_apps: inspect,
  computer_list_displays: inspect,
  computer_request_access: grant,
  computer_release_access: release,
  computer_get_state: inspect,
  computer_click: input,
  computer_drag: input,
  computer_scroll: input,
  computer_press_key: input,
  computer_type_text: input,
  computer_paste: input,
  computer_set_value: input,
  computer_select_text: input,
  computer_perform_secondary_action: input
});
