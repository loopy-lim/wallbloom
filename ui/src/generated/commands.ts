// ── rustra generated ────────────────────────────────────────
// File:   commands.ts
// Source: schema.json (single source of truth for this file)
// Regen:  rustra codegen --config rustra.json
// Stage:  rust-probe schema → ts renderer
// DO NOT EDIT — changes will be overwritten and fail codegen --check.
// ────────────────────────────────────────────────────────────

import type { Array_of_WallPackage, ScanLibraryInput } from './types.js';
import { invokeGenerated } from '@rustra/types';
import type { InvokeOptions } from '@rustra/types';

export function scanLibrary(input: ScanLibraryInput, options?: InvokeOptions): Promise<Array_of_WallPackage> {
  return invokeGenerated<Array_of_WallPackage>(1, 'scanLibrary', input, options);
}
scanLibrary.commandId = 'scanLibrary';
