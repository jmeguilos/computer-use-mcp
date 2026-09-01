import { describe, expect, it } from "vitest";
import {
  AccessibilityStateSchema,
  ActionOutputSchema,
  ClickInputSchema,
  DragInputSchema,
  GetStateInputSchema,
  GetStateOutputSchema,
  GetStatusInputSchema,
  ListAppsOutputSchema,
  ListAppsInputSchema,
  ListDisplaysInputSchema,
  ListDisplaysOutputSchema,
  PasteInputSchema,
  PUBLIC_NAMED_KEYS,
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
  TypeTextInputSchema
} from "../src/schemas.js";

const accessibilityRoot = {
  element_id: "element-0",
  child_element_ids: ["element-1"],
  depth: 0,
  role: "AXWindow",
  title: "Document",
  frame_points: { x: -100, y: 20, width: 800, height: 600 },
  focused: true,
  secure: false,
  actions: []
};

const accessibilityChild = {
  element_id: "element-1",
  parent_element_id: "element-0",
  child_element_ids: [],
  depth: 1,
  role: "AXButton",
  label: "Save",
  frame_points: { x: 20, y: 30, width: 80, height: 30 },
  enabled: true,
  focused: false,
  selected: false,
  secure: false,
  actions: ["AXPress"]
};

describe("public schemas", () => {
  it("does not pretend to inventory non-running applications", () => {
    expect(ListAppsInputSchema.parse({})).toEqual({ running_only: true });
    expect(ListAppsInputSchema.parse({ running_only: true })).toEqual({ running_only: true });
    expect(() => ListAppsInputSchema.parse({ running_only: false })).toThrow();
  });

  it("covers every discovery and lifecycle input contract", () => {
    expect(GetStatusInputSchema.parse({})).toEqual({});
    expect(() => GetStatusInputSchema.parse({ unexpected: true })).toThrow();
    expect(ListDisplaysInputSchema.parse({})).toEqual({ include_mirrored: true });
    expect(ReleaseAccessInputSchema.parse({ grant_id: "grant-123456" })).toMatchObject({
      timeout_ms: 10_000
    });
    expect(
      GetStateInputSchema.parse({ grant_id: "grant-123456" })
    ).toMatchObject({
      screenshot: "inline",
      max_width_px: 1_600,
      include_accessibility: true,
      max_accessibility_chars: 50_000,
      timeout_ms: 20_000
    });
    expect(() =>
      GetStateInputSchema.parse({ grant_id: "grant-123456", screenshot: "jpeg" })
    ).toThrow();
  });

  it("covers every frame-bound action input contract", () => {
    const context = {
      grant_id: "grant-123456",
      frame_id: "frame-123456",
      intent: "Exercise the visible fixture control"
    } as const;
    const point = { kind: "point", x: 10, y: 20 } as const;
    const element = { kind: "element", element_id: "element-123456" } as const;
    const cases = [
      [ClickInputSchema, { ...context, selector: point }],
      [DragInputSchema, { ...context, from: point, to: { ...point, x: 30 } }],
      [ScrollInputSchema, { ...context, selector: point, direction: "down" }],
      [PressKeyInputSchema, { ...context, key: "return" }],
      [TypeTextInputSchema, { ...context, text: "fixture" }],
      [PasteInputSchema, { ...context, text: "fixture" }],
      [SetValueInputSchema, { ...context, selector: element, value: "fixture" }],
      [SelectTextInputSchema, { ...context, selector: element, text: "fixture" }],
      [SecondaryActionInputSchema, { ...context, selector: element, action: "AXPress" }]
    ] as const;

    for (const [schema, value] of cases) {
      expect(schema.safeParse(value).success).toBe(true);
      const { frame_id: _frameID, ...withoutFrame } = value;
      expect(schema.safeParse(withoutFrame).success).toBe(false);
    }
  });

  it("advertises only named and ANSI keys the native host can map", () => {
    const context = {
      grant_id: "grant-123456",
      frame_id: "frame-123456",
      intent: "Exercise a documented keyboard key"
    } as const;

    for (const key of PUBLIC_NAMED_KEYS) {
      expect(PressKeyInputSchema.safeParse({ ...context, key }).success, key).toBe(true);
    }
    for (const key of ["a", "z", "0", "=", "[", "\\", "'", "/"]) {
      expect(PressKeyInputSchema.safeParse({ ...context, key }).success, key).toBe(true);
    }
    for (const key of ["f21", "volume_up", "page up", " ", "😀", "ab", "ENTER", "A"]) {
      expect(PressKeyInputSchema.safeParse({ ...context, key }).success, key).toBe(false);
    }
  });

  it("covers every public output success and error union", () => {
    const timestamp = "2026-08-30T08:00:00.000Z";
    const error = {
      ok: false,
      error: {
        code: "ACCESS_DENIED",
        message: "Denied by native policy",
        retryable: false
      }
    } as const;
    const outputSchemas = [
      StatusOutputSchema,
      ListDisplaysOutputSchema,
      ListAppsOutputSchema,
      RequestAccessOutputSchema,
      ReleaseAccessOutputSchema,
      GetStateOutputSchema,
      ActionOutputSchema
    ] as const;
    for (const schema of outputSchemas) expect(schema.parse(error)).toEqual(error);

    expect(StatusOutputSchema.parse({
      ok: true,
      status: "ready",
      server_version: "0.1.0-alpha.1",
      native_version: "0.1.0-alpha.1",
      platform: "macos",
      app_control_enabled: true,
      action_authorization: "grant_scoped",
      permissions: { accessibility: "authorized", screen_recording: "authorized" },
      active_grants: [],
      pending_approvals: 0
    }).ok).toBe(true);
    expect(ListDisplaysOutputSchema.parse({ ok: true, displays: [] })).toEqual({
      ok: true,
      displays: []
    });
    expect(ListAppsOutputSchema.parse({ ok: true, apps: [] })).toEqual({ ok: true, apps: [] });
    expect(RequestAccessOutputSchema.parse({
      ok: true,
      status: "denied",
      message: "Not approved"
    }).status).toBe("denied");
    const grantedAccess = {
      ok: true,
      status: "granted",
      grant_id: "grant-123456",
      target: {
        kind: "display",
        display: {
          display_id: "display-123456",
          name: "Main display",
          is_main: true,
          is_mirrored: false,
          frame_points: { x: 0, y: 0, width: 1_440, height: 900 },
          pixel_width: 2_880,
          pixel_height: 1_800,
          scale_factor: 2
        }
      },
      capabilities: ["observe"],
      idle_expires_at: timestamp,
      session_only: true
    } as const;
    expect(RequestAccessOutputSchema.parse(grantedAccess).status).toBe("granted");
    expect(() =>
      RequestAccessOutputSchema.parse({
        ...grantedAccess,
        capabilities: ["observe", "observe"]
      })
    ).toThrow(/must be unique/u);
    expect(() =>
      RequestAccessOutputSchema.parse({
        ...grantedAccess,
        capabilities: ["interact"]
      })
    ).toThrow(/requires observe/u);
    expect(ReleaseAccessOutputSchema.parse({
      ok: true,
      status: "released",
      grant_id: "grant-123456"
    }).status).toBe("released");
    expect(ActionOutputSchema.parse({
      ok: true,
      status: "completed",
      action_id: "action-123456",
      grant_id: "grant-123456",
      target: {
        kind: "window",
        app: { bundle_id: "com.example.fixture", name: "Fixture", pid: 4242 },
        title: "Primary",
        bounds_points: { x: 10, y: 20, width: 720, height: 520 },
        display_id: "display-123456"
      },
      completed_at: timestamp
    }).status).toBe("completed");
    expect(ActionOutputSchema.parse({
      ok: true,
      status: "approval_required",
      approval_request_id: "approval-request-123456",
      message: "Approve one exact action",
      expires_at: timestamp
    }).status).toBe("approval_required");
    expect(ActionOutputSchema.parse({
      ok: true,
      status: "denied",
      reason: "User denied"
    }).status).toBe("denied");
  });

  it("accepts only the discriminated window/display access targets", () => {
    expect(
      RequestAccessInputSchema.parse({
        target: {
          kind: "window",
          app: { kind: "bundle_id", value: "com.apple.TextEdit" },
          launch_if_needed: false
        },
        reason: "Edit the document"
      }).target.kind
    ).toBe("window");
    expect(
      RequestAccessInputSchema.parse({
        target: { kind: "display", display_id: "display-123456" },
        reason: "Observe the full display"
      }).target.kind
    ).toBe("display");
    expect(() =>
      RequestAccessInputSchema.parse({
        target: { kind: "window", window_id: "not-public" },
        reason: "Invalid"
      })
    ).toThrow();
    for (const app of [
      { kind: "name", value: "TextEdit" },
      { kind: "path", value: "/System/Applications/TextEdit.app" }
    ] as const) {
      expect(() =>
        RequestAccessInputSchema.parse({
          target: { kind: "window", app, launch_if_needed: true },
          reason: "Launch an ambiguously selected application"
        })
      ).toThrow(/bundle_id/u);
      expect(
        RequestAccessInputSchema.parse({
          target: { kind: "window", app, launch_if_needed: false },
          reason: "Select an already running application"
        }).target.kind
      ).toBe("window");
    }
    expect(
      RequestAccessInputSchema.parse({
        target: {
          kind: "window",
          app: { kind: "bundle_id", value: "com.apple.TextEdit" },
          launch_if_needed: true
        },
        reason: "Launch TextEdit when needed"
      }).target.kind
    ).toBe("window");
  });

  it("enforces coherent frame-bound access capabilities", () => {
    const request = {
      target: { kind: "display", display_id: "display-123456" },
      reason: "Control the selected display"
    } as const;
    expect(RequestAccessInputSchema.parse(request)).toMatchObject({
      capabilities: ["observe", "interact"],
      timeout_ms: 120_000
    });
    expect(() =>
      RequestAccessInputSchema.parse({ ...request, capabilities: ["interact"] })
    ).toThrow(/requires observe/u);
    expect(() =>
      RequestAccessInputSchema.parse({ ...request, capabilities: ["observe", "clipboard_write"] })
    ).toThrow(/requires both observe and interact/u);
    expect(() =>
      RequestAccessInputSchema.parse({ ...request, capabilities: ["observe", "observe"] })
    ).toThrow(/must be unique/u);
    expect(
      RequestAccessInputSchema.parse({
        ...request,
        capabilities: ["observe", "interact", "clipboard_write"],
        timeout_ms: 300_000
      }).capabilities
    ).toEqual(["observe", "interact", "clipboard_write"]);
    expect(() =>
      RequestAccessInputSchema.parse({ ...request, timeout_ms: 300_001 })
    ).toThrow();
  });

  it("requires grant, current frame, and intent on actions", () => {
    expect(() =>
      ClickInputSchema.parse({ selector: { kind: "point", x: 1, y: 2 } })
    ).toThrow();
    expect(
      ClickInputSchema.parse({
        grant_id: "grant-123456",
        frame_id: "frame-123456",
        intent: "Click the visible Save button",
        selector: { kind: "point", x: 1, y: 2 }
      })
    ).toMatchObject({ timeout_ms: 30_000, mouse_button: "left", click_count: 1 });
  });

  it("keeps paste text-only and frame-bound", () => {
    const paste = {
      grant_id: "grant-123456",
      frame_id: "frame-123456",
      intent: "Paste the approved plain text into the visible field",
      text: "hello"
    } as const;
    expect(PasteInputSchema.parse(paste)).toMatchObject({
      format: "text",
      timeout_ms: 30_000
    });
    expect(() => PasteInputSchema.parse({ ...paste, format: "markdown" })).toThrow();
    expect(() => PasteInputSchema.parse({ ...paste, format: "html" })).toThrow();
  });

  it("accepts a bounded structured accessibility tree and rejects text or insecure secrets", () => {
    const parsed = AccessibilityStateSchema.parse({
      mode: "full",
      nodes: [accessibilityRoot, accessibilityChild],
      truncated: false
    });
    expect(parsed.mode === "full" && parsed.nodes[1]).toMatchObject({
      element_id: "element-1",
      role: "AXButton",
      actions: ["AXPress"]
    });

    expect(() =>
      AccessibilityStateSchema.parse({
        mode: "full",
        text: "element_id=element-1\trole=AXButton",
        truncated: false
      })
    ).toThrow();
    expect(() =>
      AccessibilityStateSchema.parse({
        mode: "full",
        nodes: [
          {
            ...accessibilityRoot,
            child_element_ids: [],
            role: "AXSecureTextField",
            secure: true,
            value: "must never be exposed"
          }
        ],
        truncated: false
      })
    ).toThrow();
  });

  it("enforces full-tree hierarchy and deterministic diff invariants", () => {
    expect(() =>
      AccessibilityStateSchema.parse({
        mode: "full",
        nodes: [accessibilityRoot, { ...accessibilityChild, parent_element_id: "element-9" }],
        truncated: false
      })
    ).toThrow();
    expect(() =>
      AccessibilityStateSchema.parse({
        mode: "full",
        nodes: [accessibilityRoot, accessibilityChild, accessibilityChild],
        truncated: false
      })
    ).toThrow();

    expect(
      AccessibilityStateSchema.parse({
        mode: "diff",
        base_frame_id: "frame-base-123456",
        upserted_nodes: [
          {
            ...accessibilityChild,
            element_id: "element-2",
            parent_element_id: "element-0"
          }
        ],
        removed_element_ids: ["element-1"],
        truncated: false
      })
    ).toMatchObject({ mode: "diff", base_frame_id: "frame-base-123456" });

    expect(() =>
      AccessibilityStateSchema.parse({
        mode: "diff",
        base_frame_id: "frame-base-123456",
        upserted_nodes: [],
        removed_element_ids: ["element-9", "element-1"],
        truncated: false
      })
    ).toThrow();
    expect(() =>
      AccessibilityStateSchema.parse({
        mode: "diff",
        base_frame_id: "frame-base-123456",
        upserted_nodes: [accessibilityChild],
        removed_element_ids: ["element-1"],
        truncated: false
      })
    ).toThrow();
  });

  it("preserves negative global origins and exact inverse transforms", () => {
    const parsed = GetStateOutputSchema.parse({
      ok: true,
      status: "completed",
      grant_id: "grant-123456",
      frame_id: "frame-123456",
      captured_at: "2026-08-29T20:00:00.000Z",
      target: {
        kind: "display",
        display: {
          display_id: "display-123456",
          name: "External",
          is_main: false,
          is_mirrored: false,
          frame_points: { x: -1920, y: 0, width: 1920, height: 1080 },
          pixel_width: 3840,
          pixel_height: 2160,
          scale_factor: 2
        }
      },
      coordinate_space: {
        width_px: 3840,
        height_px: 2160,
        global_bounds_points: { x: -1920, y: 0, width: 1920, height: 1080 },
        image_to_global: { a: 0.5, b: 0, c: 0, d: 0.5, tx: -1920, ty: 0 },
        global_to_image: { a: 2, b: 0, c: 0, d: 2, tx: 3840, ty: 0 }
      },
      accessibility: {
        mode: "full",
        nodes: [],
        truncated: false,
        reset_reason: "target_has_no_accessibility_tree"
      }
    });
    expect(parsed.ok && parsed.coordinate_space.global_bounds_points.x).toBe(-1920);
  });
});
