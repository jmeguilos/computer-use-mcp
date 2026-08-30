import type { NativeBridge } from "./protocol.js";
import { NativeSocketClient } from "./client.js";
import { BridgeProcessClient, type BridgeProcessClientOptions } from "./process-client.js";

export type DefaultNativeBridgeOptions = BridgeProcessClientOptions & {
  /** Test/source-build escape hatch. Production always uses the signed helper process. */
  devDirectSocket?: boolean;
};

export function createDefaultNativeBridge(options: DefaultNativeBridgeOptions = {}): NativeBridge {
  if (options.devDirectSocket === true) return new NativeSocketClient();
  return new BridgeProcessClient(options);
}

export { NativeSocketClient } from "./client.js";
export { BridgeProcessClient, DEFAULT_BRIDGE_EXECUTABLE } from "./process-client.js";
export type { BridgeCallOptions, NativeBridge, NativeMethod } from "./protocol.js";
export { NATIVE_MAX_LINE_BYTES } from "./protocol.js";
