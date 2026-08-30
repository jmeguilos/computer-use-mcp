import { ComputerUseError } from "./errors.js";

export function snakeToCamel(value: string): string {
  return value.replace(/_([a-z])/g, (_match, letter: string) => letter.toUpperCase());
}

export function camelToSnake(value: string): string {
  return value.replace(/[A-Z]/g, letter => `_${letter.toLowerCase()}`);
}

export function mapKeysDeep(value: unknown, keyMapper: (key: string) => string): unknown {
  if (Array.isArray(value)) return value.map(item => mapKeysDeep(item, keyMapper));
  if (value === null || typeof value !== "object") return value;

  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [keyMapper(key), mapKeysDeep(item, keyMapper)])
  );
}

export function toNativeParams(value: unknown): unknown {
  return mapKeysDeep(value, snakeToCamel);
}

export function fromNativeResult(value: unknown): unknown {
  return mapKeysDeep(value, camelToSnake);
}

export function asRecord(value: unknown): Record<string, unknown> {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new ComputerUseError("BRIDGE_PROTOCOL_ERROR", "The native bridge returned a non-object result.");
  }
  return value as Record<string, unknown>;
}

export function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => `${JSON.stringify(key)}:${stableJson(item)}`)
      .join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

export function withoutApprovalRequest<T extends Record<string, unknown>>(value: T): Record<string, unknown> {
  const { approval_request_id: _ignored, ...rest } = value;
  return rest;
}
