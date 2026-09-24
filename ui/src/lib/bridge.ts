import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { configure, createTauriEngine } from "@rustra/tauri";
import { scanLibrary, subscribeEvent } from "../generated/tauri";
import { onRustraEvent } from "../generated/events";
import type { RustraEventPayloads } from "../generated/events";

// Explicit Tauri module transport: no window globals or service credentials.
configure(createTauriEngine({ invoke: (command, args) => {
  if (args === undefined) return invoke(command);
  if (args === null || typeof args !== "object" || Array.isArray(args)) {
    throw new TypeError("rustra Tauri arguments must be an object");
  }
  return invoke(command, { ...args });
} }));
export { scanLibrary };
export type { WallPackage } from "../generated/types";
export function onDownloadProgress(callback: (payload: RustraEventPayloads["download-progress"]) => void) {
  return onRustraEvent((name, listener) => subscribeEvent(name, listener, listen), "download-progress", callback);
}
