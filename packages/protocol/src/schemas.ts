import * as z from "zod/v4";

import {
  ALL_NATIVE_METHODS,
  NATIVE_CAPABILITIES,
  NATIVE_HANDSHAKE_METHOD,
  NATIVE_METHODS,
  PROTOCOL_VERSION,
  PUBLIC_CAPABILITIES
} from "./constants.js";

export const OpaqueIdSchema = z.string().min(8).max(512);
export const RequestIdSchema = z.string().min(1).max(256);
export const ConnectionIdSchema = z.string().uuid();
export const ConnectionTokenSchema = z.string().min(43).max(512);

export const ProtocolVersionSchema = z.object({
  major: z.literal(PROTOCOL_VERSION.major),
  minor: z.number().int().nonnegative()
}).strict();

export const CurrentProtocolVersionSchema = z.object({
  major: z.literal(PROTOCOL_VERSION.major),
  minor: z.literal(PROTOCOL_VERSION.minor)
}).strict();

export const CapabilitySchema = z.enum(PUBLIC_CAPABILITIES);
export const PublicCapabilitySchema = CapabilitySchema;
export const CapabilitiesSchema = z.array(CapabilitySchema)
  .min(1)
  .max(PUBLIC_CAPABILITIES.length)
  .superRefine((items, context) => {
    const capabilities = new Set(items);
    if (capabilities.size !== items.length) {
      context.addIssue({
        code: "custom",
        message: "Public capabilities must be unique"
      });
    }
    if (capabilities.has("interact") && !capabilities.has("observe")) {
      context.addIssue({
        code: "custom",
        message: "interact requires observe"
      });
    }
    if (
      capabilities.has("clipboard_write") &&
      (!capabilities.has("observe") || !capabilities.has("interact"))
    ) {
      context.addIssue({
        code: "custom",
        message: "clipboard_write requires observe and interact"
      });
    }
  });

export const NativeCapabilitySchema = z.enum(NATIVE_CAPABILITIES);
export const NativeCapabilitiesSchema = z.array(NativeCapabilitySchema)
  .max(NATIVE_CAPABILITIES.length)
  .transform((items) => [...new Set(items)]);

export const NativeMethodSchema = z.enum(NATIVE_METHODS);
export const AnyNativeMethodSchema = z.enum(ALL_NATIVE_METHODS);

export const AppSelectorSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("bundle_id"),
    value: z.string().min(1).max(512)
  }).strict(),
  z.object({
    kind: z.literal("name"),
    value: z.string().min(1).max(512)
  }).strict(),
  z.object({
    kind: z.literal("path"),
    value: z.string().startsWith("/").max(4_096)
  }).strict()
]);

export const WindowTargetSchema = z.object({
  kind: z.literal("window"),
  app: AppSelectorSchema,
  window_hint: z.string().trim().min(1).max(500).optional(),
  launch_if_needed: z.boolean().default(false)
}).strict();

export const DisplayTargetSchema = z.object({
  kind: z.literal("display"),
  display_id: OpaqueIdSchema
}).strict();

export const AccessTargetSchema = z.discriminatedUnion("kind", [WindowTargetSchema, DisplayTargetSchema]);

/** Native affine convention: x' = a*x + c*y + tx; y' = b*x + d*y + ty. */
export const AffineTransformSchema = z.object({
  a: z.number(),
  b: z.number(),
  c: z.number(),
  d: z.number(),
  tx: z.number(),
  ty: z.number()
}).strict();

type AffineTransform = z.infer<typeof AffineTransformSchema>;

function compose(left: AffineTransform, right: AffineTransform): AffineTransform {
  return {
    a: left.a * right.a + left.c * right.b,
    b: left.b * right.a + left.d * right.b,
    c: left.a * right.c + left.c * right.d,
    d: left.b * right.c + left.d * right.d,
    tx: left.a * right.tx + left.c * right.ty + left.tx,
    ty: left.b * right.tx + left.d * right.ty + left.ty
  };
}

function approximatelyEqual(left: number, right: number): boolean {
  const scale = Math.max(1, Math.abs(left), Math.abs(right));
  return Math.abs(left - right) <= 1e-9 * scale;
}

function isIdentity(value: AffineTransform): boolean {
  return approximatelyEqual(value.a, 1) &&
    approximatelyEqual(value.b, 0) &&
    approximatelyEqual(value.c, 0) &&
    approximatelyEqual(value.d, 1) &&
    approximatelyEqual(value.tx, 0) &&
    approximatelyEqual(value.ty, 0);
}

export const RectSchema = z.object({
  x: z.number(),
  y: z.number(),
  width: z.number().positive(),
  height: z.number().positive()
}).strict();

export const CoordinateTransformSchema = z.object({
  widthPx: z.number().int().positive(),
  heightPx: z.number().int().positive(),
  globalBoundsPoints: RectSchema,
  imageToGlobal: AffineTransformSchema,
  globalToImage: AffineTransformSchema
}).strict().superRefine((value, context) => {
  const forwardThenInverse = compose(value.globalToImage, value.imageToGlobal);
  const inverseThenForward = compose(value.imageToGlobal, value.globalToImage);
  if (!isIdentity(forwardThenInverse) || !isIdentity(inverseThenForward)) {
    context.addIssue({
      code: "custom",
      path: ["globalToImage"],
      message: "imageToGlobal and globalToImage must be inverse affine transforms"
    });
  }
});

/** Stable MCP-facing errors. Native errors are mapped before reaching clients. */
export const ErrorCodeSchema = z.enum([
  "INVALID_REQUEST",
  "PERMISSION_REQUIRED",
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

export const WireErrorSchema = z.object({
  code: z.string().min(1).max(128),
  message: z.string().min(1).max(4_000),
  retryable: z.boolean(),
  details: z.unknown().optional()
}).strict();
export const BridgeErrorSchema = WireErrorSchema;

export const PeerIdentitySchema = z.object({
  uid: z.number().int().min(0).max(4_294_967_295),
  pid: z.number().int().min(2).max(2_147_483_647),
  name: z.string().min(1).max(256),
  instanceId: z.string().min(1).max(512)
}).strict();

export const HelloRequestSchema = z.object({
  protocol: ProtocolVersionSchema,
  id: RequestIdSchema,
  method: z.literal(NATIVE_HANDSHAKE_METHOD),
  auth: z.object({ token: ConnectionTokenSchema }).strict(),
  client: PeerIdentitySchema,
  capabilities: NativeCapabilitiesSchema,
  nonce: z.string().min(22).max(512),
  params: z.record(z.string(), z.unknown()).optional()
}).strict();

const AuthenticatedRequestBaseSchema = z.object({
  protocol: ProtocolVersionSchema,
  id: RequestIdSchema,
  connectionId: ConnectionIdSchema,
  connectionToken: ConnectionTokenSchema,
  deadlineUnixMs: z.number().int().positive(),
  params: z.record(z.string(), z.unknown())
}).strict();

export const CancelRequestSchema = AuthenticatedRequestBaseSchema.extend({
  method: z.literal("cancel"),
  params: z.object({ requestId: RequestIdSchema }).strict()
}).strict();

export const AuthenticatedRequestSchema = AuthenticatedRequestBaseSchema.extend({
  method: NativeMethodSchema
}).strict().superRefine((value, context) => {
  if (value.method === "cancel") {
    const parsed = z.object({ requestId: RequestIdSchema }).strict().safeParse(value.params);
    if (!parsed.success) {
      context.addIssue({
        code: "custom",
        path: ["params"],
        message: "cancel params must contain only requestId"
      });
    }
  }
});

export const BridgeRequestSchema = z.union([HelloRequestSchema, AuthenticatedRequestSchema]);

export const HelloResultSchema = z.object({
  connectionId: ConnectionIdSchema,
  connectionToken: ConnectionTokenSchema,
  acceptedCapabilities: z.array(NativeCapabilitySchema),
  idleExpiresAt: z.string().datetime({ offset: true })
}).strict();

export const BridgeResponseSchema = z.discriminatedUnion("ok", [
  z.object({
    protocol: ProtocolVersionSchema,
    id: RequestIdSchema,
    ok: z.literal(true),
    result: z.unknown()
  }).strict(),
  z.object({
    protocol: ProtocolVersionSchema,
    id: RequestIdSchema,
    ok: z.literal(false),
    error: WireErrorSchema
  }).strict()
]);

export type Capability = z.infer<typeof CapabilitySchema>;
export type AppSelector = z.infer<typeof AppSelectorSchema>;
export type AccessTarget = z.infer<typeof AccessTargetSchema>;
export type CoordinateTransform = z.infer<typeof CoordinateTransformSchema>;
export type ErrorCode = z.infer<typeof ErrorCodeSchema>;
export type BridgeError = z.infer<typeof BridgeErrorSchema>;
export type BridgeRequest = z.infer<typeof BridgeRequestSchema>;
export type BridgeResponse = z.infer<typeof BridgeResponseSchema>;
