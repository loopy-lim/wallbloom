// ── rustra generated ────────────────────────────────────────
// File:   types.ts
// Source: schema.json (single source of truth for this file)
// Regen:  rustra codegen --config rustra.json
// Stage:  rust-probe schema → ts renderer
// DO NOT EDIT — changes will be overwritten and fail codegen --check.
// ────────────────────────────────────────────────────────────

export type { EngineClient, RustraError } from '@rustra/types';
export { RustraCommandError } from '@rustra/types';

export type WallPackage = {
  id: string;
  title: string;
  path: string;
  previewPath?: string | null;
  packageType: string;
};

export type ScanLibraryInput = Record<string, unknown>;

export type Array_of_WallPackage = WallPackage[];
