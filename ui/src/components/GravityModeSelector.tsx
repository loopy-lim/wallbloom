import { Button } from "@/components/ui/button";

export const GRAVITY_MODES = [
  { value: "cover", label: "화면 채움 (cover)" },
  { value: "contain", label: "전체 보기 (contain)" },
  { value: "stretch", label: "늘리기 (stretch)" },
] as const;

export type GravityMode = (typeof GRAVITY_MODES)[number]["value"];

export function isGravityMode(value: unknown): value is GravityMode {
  return typeof value === "string" && GRAVITY_MODES.some(mode => mode.value === value);
}

export function gravityLabel(mode: GravityMode): string {
  return GRAVITY_MODES.find(item => item.value === mode)?.label ?? mode;
}

export function GravityModeSelector({ mode, disabled, onChange }: {
  mode: GravityMode;
  disabled?: boolean;
  onChange: (mode: GravityMode) => void;
}) {
  return <div role="group" aria-label="화면 맞춤 모드" className="flex flex-wrap items-center gap-2">
    <span className="text-sm font-medium text-slate-300">화면 맞춤</span>
    {GRAVITY_MODES.map(item => (
      <Button key={item.value} size="sm" variant={mode === item.value ? "default" : "outline"}
        aria-pressed={mode === item.value} disabled={disabled}
        onClick={() => onChange(item.value)}>{item.label}</Button>
    ))}
  </div>;
}
