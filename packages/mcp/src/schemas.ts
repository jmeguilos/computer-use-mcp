import * as z from "zod/v4";
import { ToolErrorSchema } from "./errors.js";

export const OpaqueIdSchema = z.string().min(8).max(256);
const TimestampSchema = z.string().datetime({ offset: true });
const TimeoutSchema = z.number().int().min(100).max(30_000).default(10_000);
const ActionTimeoutSchema = z.number().int().min(100).max(30_000).default(30_000);

export const EmptyInputSchema = z.object({}).strict();

export const ElementSelectorSchema = z
  .object({
    kind: z.literal("element"),
    element_id: OpaqueIdSchema.describe("Element identifier issued by the current frame")
  })
  .strict();

export const PointSelectorSchema = z
  .object({
    kind: z.literal("point"),
    x: z.number().finite().min(0).describe("X coordinate in current-frame image pixels"),
    y: z.number().finite().min(0).describe("Y coordinate in current-frame image pixels")
  })
  .strict();

export const SelectorSchema = z.discriminatedUnion("kind", [
  ElementSelectorSchema,
  PointSelectorSchema
]);

const ActionContextShape = {
  grant_id: OpaqueIdSchema.describe("Opaque authority for the explicitly granted window or display"),
  frame_id: OpaqueIdSchema.describe("Current frame used to derive all selectors and coordinates"),
  intent: z.string().trim().min(1).max(300).describe("Human-readable purpose of this action"),
  approval_request_id: z
    .string()
    .min(16)
    .max(512)
    .optional()
    .describe("One-shot approval request identifier for an exact retry"),
  timeout_ms: ActionTimeoutSchema
};

export const GetStatusInputSchema = EmptyInputSchema;

export const ListDisplaysInputSchema = z
  .object({ include_mirrored: z.boolean().default(true) })
  .strict();

export const ListAppsInputSchema = z
  .object({ running_only: z.boolean().default(true) })
  .strict();

export const AppSelectorSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("bundle_id"), value: z.string().min(1).max(512) }).strict(),
  z.object({ kind: z.literal("name"), value: z.string().min(1).max(512) }).strict(),
  z.object({ kind: z.literal("path"), value: z.string().startsWith("/").max(4_096) }).strict()
]);

export const AccessTargetInputSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("window"),
      app: AppSelectorSchema,
      window_hint: z.string().trim().min(1).max(500).optional(),
      launch_if_needed: z.boolean().default(false)
    })
    .strict(),
  z
    .object({
      kind: z.literal("display"),
      display_id: OpaqueIdSchema
    })
    .strict()
]);

export const CapabilitySchema = z.enum(["observe", "interact", "clipboard_write"]);

export const RequestAccessInputSchema = z
  .object({
    target: AccessTargetInputSchema,
    reason: z.string().trim().min(1).max(500),
    capabilities: z.array(CapabilitySchema).min(1).max(3).default(["observe", "interact"]),
    timeout_ms: z.number().int().min(100).max(300_000).default(120_000)
  })
  .strict()
  .superRefine((request, ctx) => {
    const capabilities = new Set(request.capabilities);
    if (capabilities.size !== request.capabilities.length) {
      ctx.addIssue({
        code: "custom",
        path: ["capabilities"],
        message: "Requested capabilities must be unique."
      });
    }
    if (capabilities.has("interact") && !capabilities.has("observe")) {
      ctx.addIssue({
        code: "custom",
        path: ["capabilities"],
        message: "The interact capability requires observe because every action is frame-bound."
      });
    }
    if (
      capabilities.has("clipboard_write") &&
      (!capabilities.has("observe") || !capabilities.has("interact"))
    ) {
      ctx.addIssue({
        code: "custom",
        path: ["capabilities"],
        message: "The clipboard_write capability requires both observe and interact."
      });
    }
  });

export const ReleaseAccessInputSchema = z
  .object({
    grant_id: OpaqueIdSchema,
    timeout_ms: TimeoutSchema
  })
  .strict();

export const GetStateInputSchema = z
  .object({
    grant_id: OpaqueIdSchema,
    since_frame_id: OpaqueIdSchema.optional(),
    screenshot: z.enum(["inline", "resource", "none"]).default("inline"),
    max_width_px: z.number().int().min(320).max(4_096).default(1_600),
    include_accessibility: z.boolean().default(true),
    max_accessibility_chars: z.number().int().min(1_000).max(200_000).default(50_000),
    timeout_ms: z.number().int().min(100).max(30_000).default(20_000)
  })
  .strict();

export const ClickInputSchema = z
  .object({
    selector: SelectorSchema,
    mouse_button: z.enum(["left", "right", "middle"]).default("left"),
    click_count: z.number().int().min(1).max(3).default(1),
    ...ActionContextShape
  })
  .strict();

export const DragInputSchema = z
  .object({
    from: PointSelectorSchema,
    to: PointSelectorSchema,
    duration_ms: z.number().int().min(0).max(5_000).default(500),
    ...ActionContextShape
  })
  .strict();

export const ScrollInputSchema = z
  .object({
    selector: SelectorSchema.optional(),
    direction: z.enum(["up", "down", "left", "right"]),
    amount: z.number().positive().max(100).default(1),
    unit: z.enum(["lines", "pages"]).default("pages"),
    ...ActionContextShape
  })
  .strict();

export const PressKeyInputSchema = z
  .object({
    key: z.string().min(1).max(64),
    modifiers: z
      .array(z.enum(["command", "control", "option", "shift", "function"]))
      .max(5)
      .default([]),
    ...ActionContextShape
  })
  .strict();

export const TypeTextInputSchema = z
  .object({
    text: z.string().max(100_000),
    interval_ms: z.number().int().min(0).max(1_000).default(0),
    ...ActionContextShape
  })
  .strict();

export const PasteInputSchema = z
  .object({
    text: z.string().max(1_000_000),
    format: z.literal("text").default("text"),
    ...ActionContextShape
  })
  .strict();

export const SetValueInputSchema = z
  .object({
    selector: ElementSelectorSchema,
    value: z.string().max(1_000_000),
    ...ActionContextShape
  })
  .strict();

export const SelectTextInputSchema = z
  .object({
    selector: ElementSelectorSchema,
    text: z.string().max(100_000),
    prefix: z.string().max(1_000).optional(),
    suffix: z.string().max(1_000).optional(),
    selection_type: z.enum(["text", "cursor_before", "cursor_after"]).default("text"),
    ...ActionContextShape
  })
  .strict();

export const SecondaryActionInputSchema = z
  .object({
    selector: ElementSelectorSchema,
    action: z.string().trim().min(1).max(256),
    ...ActionContextShape
  })
  .strict();

const PermissionStateSchema = z.enum(["authorized", "denied", "not_determined", "restricted"]);

const GrantSummarySchema = z
  .object({
    grant_id: OpaqueIdSchema,
    target_kind: z.enum(["window", "display"]),
    idle_expires_at: TimestampSchema
  })
  .strict();

const StatusSuccessSchema = z
  .object({
    ok: z.literal(true),
    status: z.enum(["ready", "degraded", "permission_required", "unavailable"]),
    server_version: z.string().min(1),
    native_version: z.string().min(1),
    platform: z.literal("macos"),
    permissions: z
      .object({
        accessibility: PermissionStateSchema,
        screen_recording: PermissionStateSchema
      })
      .strict(),
    active_grants: z.array(GrantSummarySchema),
    pending_approvals: z.number().int().min(0)
  })
  .strict();

export const RectSchema = z
  .object({
    x: z.number().finite(),
    y: z.number().finite(),
    width: z.number().finite().nonnegative(),
    height: z.number().finite().nonnegative()
  })
  .strict();

export const DisplaySchema = z
  .object({
    display_id: OpaqueIdSchema,
    name: z.string().min(1).max(512),
    is_main: z.boolean(),
    is_mirrored: z.boolean(),
    frame_points: RectSchema,
    pixel_width: z.number().int().positive(),
    pixel_height: z.number().int().positive(),
    scale_factor: z.number().positive()
  })
  .strict();

const ListDisplaysSuccessSchema = z
  .object({ ok: z.literal(true), displays: z.array(DisplaySchema) })
  .strict();

const AppSchema = z
  .object({
    bundle_id: z.string().min(1).max(512),
    name: z.string().min(1).max(512),
    is_running: z.boolean(),
    pid: z.number().int().positive().optional(),
    window_count: z.number().int().min(0),
    grantable: z.boolean()
  })
  .strict();

const ListAppsSuccessSchema = z.object({ ok: z.literal(true), apps: z.array(AppSchema) }).strict();

const WindowTargetMetadataSchema = z
  .object({
    kind: z.literal("window"),
    app: z
      .object({
        bundle_id: z.string().min(1).max(512),
        name: z.string().min(1).max(512),
        pid: z.number().int().positive()
      })
      .strict(),
    title: z.string().max(2_000).optional(),
    bounds_points: RectSchema,
    display_id: OpaqueIdSchema
  })
  .strict();

const DisplayTargetMetadataSchema = z
  .object({
    kind: z.literal("display"),
    display: DisplaySchema
  })
  .strict();

export const TargetMetadataSchema = z.discriminatedUnion("kind", [
  WindowTargetMetadataSchema,
  DisplayTargetMetadataSchema
]);

const AccessGrantedSchema = z
  .object({
    ok: z.literal(true),
    status: z.literal("granted"),
    grant_id: OpaqueIdSchema,
    target: TargetMetadataSchema,
    capabilities: z.array(CapabilitySchema),
    idle_expires_at: TimestampSchema,
    session_only: z.boolean()
  })
  .strict();

const AccessNotGrantedSchema = z
  .object({
    ok: z.literal(true),
    status: z.enum(["denied", "pending", "permission_required"]),
    message: z.string().min(1).max(2_000)
  })
  .strict();

const ReleaseSuccessSchema = z
  .object({
    ok: z.literal(true),
    status: z.enum(["released", "not_found"]),
    grant_id: OpaqueIdSchema
  })
  .strict();

export const AffineTransformSchema = z
  .object({
    a: z.number().finite(),
    b: z.number().finite(),
    c: z.number().finite(),
    d: z.number().finite(),
    tx: z.number().finite(),
    ty: z.number().finite()
  })
  .strict();

const CoordinateSpaceSchema = z
  .object({
    width_px: z.number().int().positive(),
    height_px: z.number().int().positive(),
    global_bounds_points: RectSchema,
    image_to_global: AffineTransformSchema,
    global_to_image: AffineTransformSchema
  })
  .strict();

const AccessibilityTextSchema = z.string().max(32_768);

export const AccessibilityNodeSchema = z
  .object({
    element_id: OpaqueIdSchema.describe("Frame-bound identifier accepted by element actions"),
    parent_element_id: OpaqueIdSchema.optional(),
    child_element_ids: z.array(OpaqueIdSchema).max(1_200),
    depth: z.number().int().min(0).max(64),
    role: z.string().min(1).max(512),
    subrole: AccessibilityTextSchema.optional(),
    title: AccessibilityTextSchema.optional(),
    label: AccessibilityTextSchema.optional(),
    value: AccessibilityTextSchema.optional(),
    frame_points: RectSchema.optional(),
    enabled: z.boolean().optional(),
    focused: z.boolean(),
    selected: z.boolean().optional(),
    secure: z.boolean(),
    actions: z.array(z.string().min(1).max(512)).max(64)
  })
  .strict()
  .superRefine((node, ctx) => {
    if (node.parent_element_id === node.element_id) {
      ctx.addIssue({
        code: "custom",
        path: ["parent_element_id"],
        message: "An accessibility node cannot be its own parent."
      });
    }
    if (node.secure && node.value !== undefined) {
      ctx.addIssue({
        code: "custom",
        path: ["value"],
        message: "A secure accessibility node must not expose its value."
      });
    }
    const children = new Set<string>();
    node.child_element_ids.forEach((childID, index) => {
      if (childID === node.element_id) {
        ctx.addIssue({
          code: "custom",
          path: ["child_element_ids", index],
          message: "An accessibility node cannot be its own child."
        });
      }
      if (children.has(childID)) {
        ctx.addIssue({
          code: "custom",
          path: ["child_element_ids", index],
          message: "Accessibility child identifiers must be unique."
        });
      }
      children.add(childID);
    });
  });

const AccessibilityFullStateSchema = z
  .object({
    mode: z.literal("full"),
    nodes: z.array(AccessibilityNodeSchema).max(1_200),
    truncated: z.boolean(),
    reset_reason: z.string().min(1).max(1_000).regex(/\S/u).optional()
  })
  .strict();

const AccessibilityDiffStateSchema = z
  .object({
    mode: z.literal("diff"),
    base_frame_id: OpaqueIdSchema,
    upserted_nodes: z.array(AccessibilityNodeSchema).max(1_200),
    removed_element_ids: z.array(OpaqueIdSchema).max(1_200),
    truncated: z.literal(false)
  })
  .strict();

export const AccessibilityStateSchema = z
  .discriminatedUnion("mode", [AccessibilityFullStateSchema, AccessibilityDiffStateSchema])
  .superRefine((state, ctx) => {
    if (state.mode === "diff") {
      if (state.upserted_nodes.length + state.removed_element_ids.length > 1_200) {
        ctx.addIssue({
          code: "custom",
          path: [],
          message: "An accessibility diff may contain at most 1200 total changes."
        });
      }

      const upsertedIDs = state.upserted_nodes.map(node => node.element_id);
      addDuplicateIdentifierIssues(upsertedIDs, ["upserted_nodes"], ctx);
      addDuplicateIdentifierIssues(state.removed_element_ids, ["removed_element_ids"], ctx);
      addOrderingIssue(upsertedIDs, ["upserted_nodes"], ctx);
      addOrderingIssue(state.removed_element_ids, ["removed_element_ids"], ctx);

      const removed = new Set(state.removed_element_ids);
      upsertedIDs.forEach((elementID, index) => {
        if (removed.has(elementID)) {
          ctx.addIssue({
            code: "custom",
            path: ["upserted_nodes", index, "element_id"],
            message: "A diff cannot both upsert and remove the same accessibility element."
          });
        }
      });
      return;
    }

    const indexed = new Map<string, { index: number; node: z.infer<typeof AccessibilityNodeSchema> }>();
    state.nodes.forEach((node, index) => {
      if (indexed.has(node.element_id)) {
        ctx.addIssue({
          code: "custom",
          path: ["nodes", index, "element_id"],
          message: "Accessibility element identifiers must be unique."
        });
      } else {
        indexed.set(node.element_id, { index, node });
      }
    });

    state.nodes.forEach((node, index) => {
      if (node.parent_element_id === undefined) {
        if (node.depth !== 0) {
          ctx.addIssue({
            code: "custom",
            path: ["nodes", index, "depth"],
            message: "A root accessibility node must have depth zero."
          });
        }
      } else {
        const parent = indexed.get(node.parent_element_id);
        if (parent === undefined) {
          ctx.addIssue({
            code: "custom",
            path: ["nodes", index, "parent_element_id"],
            message: "A full accessibility tree cannot contain a dangling parent identifier."
          });
        } else {
          if (parent.index >= index) {
            ctx.addIssue({
              code: "custom",
              path: ["nodes", index, "parent_element_id"],
              message: "Full accessibility nodes must be in deterministic parent-first order."
            });
          }
          if (node.depth !== parent.node.depth + 1) {
            ctx.addIssue({
              code: "custom",
              path: ["nodes", index, "depth"],
              message: "Accessibility node depth must be exactly one greater than its parent."
            });
          }
          if (!parent.node.child_element_ids.includes(node.element_id)) {
            ctx.addIssue({
              code: "custom",
              path: ["nodes", index, "parent_element_id"],
              message: "Accessibility parent and child links must be symmetric."
            });
          }
        }
      }

      node.child_element_ids.forEach((childID, childIndex) => {
        const child = indexed.get(childID);
        if (child === undefined) {
          ctx.addIssue({
            code: "custom",
            path: ["nodes", index, "child_element_ids", childIndex],
            message: "A full accessibility tree cannot contain a dangling child identifier."
          });
        } else if (child.node.parent_element_id !== node.element_id) {
          ctx.addIssue({
            code: "custom",
            path: ["nodes", index, "child_element_ids", childIndex],
            message: "Accessibility parent and child links must be symmetric."
          });
        }
      });
    });
  });

function addDuplicateIdentifierIssues(
  identifiers: readonly string[],
  path: readonly (string | number)[],
  ctx: z.core.$RefinementCtx<unknown>
): void {
  const seen = new Set<string>();
  identifiers.forEach((identifier, index) => {
    if (seen.has(identifier)) {
      ctx.addIssue({
        code: "custom",
        path: [...path, index],
        message: "Accessibility diff identifiers must be unique."
      });
    }
    seen.add(identifier);
  });
}

function addOrderingIssue(
  identifiers: readonly string[],
  path: readonly (string | number)[],
  ctx: z.core.$RefinementCtx<unknown>
): void {
  for (let index = 1; index < identifiers.length; index += 1) {
    const previous = identifiers[index - 1];
    const current = identifiers[index];
    if (previous !== undefined && current !== undefined && previous > current) {
      ctx.addIssue({
        code: "custom",
        path: [...path, index],
        message: "Accessibility diff entries must be sorted by element identifier."
      });
      return;
    }
  }
}

export const NativeScreenshotSchema = z
  .object({
    mime_type: z.literal("image/png"),
    data: z.string().min(1),
    width: z.number().int().positive(),
    height: z.number().int().positive(),
    sha256: z.string().regex(/^[a-f0-9]{64}$/),
    transform: CoordinateSpaceSchema
  })
  .strict();

export const NativeStateSuccessSchema = z
  .object({
    status: z.literal("completed"),
    grant_id: OpaqueIdSchema,
    target: TargetMetadataSchema,
    frame_id: OpaqueIdSchema,
    captured_at: TimestampSchema,
    coordinate_space: CoordinateSpaceSchema,
    accessibility: AccessibilityStateSchema.optional(),
    screenshot: NativeScreenshotSchema.optional()
  })
  .strict();

const ImageMetadataSchema = z
  .object({
    delivery: z.enum(["inline", "resource"]),
    mime_type: z.literal("image/png"),
    width: z.number().int().positive(),
    height: z.number().int().positive(),
    sha256: z.string().regex(/^[a-f0-9]{64}$/),
    resource_uri: z.string().url().optional(),
    expires_at: TimestampSchema.optional()
  })
  .strict();

const StateSuccessSchema = z
  .object({
    ok: z.literal(true),
    status: z.literal("completed"),
    grant_id: OpaqueIdSchema,
    target: TargetMetadataSchema,
    frame_id: OpaqueIdSchema,
    captured_at: TimestampSchema,
    coordinate_space: CoordinateSpaceSchema,
    accessibility: AccessibilityStateSchema.optional(),
    image: ImageMetadataSchema.optional()
  })
  .strict();

export const ActionCompletedSchema = z
  .object({
    ok: z.literal(true),
    status: z.literal("completed"),
    action_id: OpaqueIdSchema,
    grant_id: OpaqueIdSchema,
    target: TargetMetadataSchema,
    completed_at: TimestampSchema
  })
  .strict();

export const ApprovalRequiredSchema = z
  .object({
    ok: z.literal(true),
    status: z.literal("approval_required"),
    approval_request_id: z.string().min(16).max(512),
    message: z.string().min(1).max(2_000),
    expires_at: TimestampSchema
  })
  .strict();

export const ActionDeniedSchema = z
  .object({
    ok: z.literal(true),
    status: z.literal("denied"),
    reason: z.string().min(1).max(2_000)
  })
  .strict();

export const ActionSuccessSchema = z.discriminatedUnion("status", [
  ActionCompletedSchema,
  ApprovalRequiredSchema,
  ActionDeniedSchema
]);

export const StatusOutputSchema = z.union([StatusSuccessSchema, ToolErrorSchema]);
export const ListDisplaysOutputSchema = z.union([ListDisplaysSuccessSchema, ToolErrorSchema]);
export const ListAppsOutputSchema = z.union([ListAppsSuccessSchema, ToolErrorSchema]);
export const RequestAccessOutputSchema = z.union([
  AccessGrantedSchema,
  AccessNotGrantedSchema,
  ToolErrorSchema
]);
export const ReleaseAccessOutputSchema = z.union([ReleaseSuccessSchema, ToolErrorSchema]);
export const GetStateOutputSchema = z.union([StateSuccessSchema, ToolErrorSchema]);
export const ActionOutputSchema = z.union([ActionSuccessSchema, ToolErrorSchema]);

export type NativeStateSuccess = z.infer<typeof NativeStateSuccessSchema>;
export type ActionOutput = z.infer<typeof ActionOutputSchema>;
export type ToolOutput =
  | z.infer<typeof StatusOutputSchema>
  | z.infer<typeof ListDisplaysOutputSchema>
  | z.infer<typeof ListAppsOutputSchema>
  | z.infer<typeof RequestAccessOutputSchema>
  | z.infer<typeof ReleaseAccessOutputSchema>
  | z.infer<typeof GetStateOutputSchema>
  | ActionOutput;
