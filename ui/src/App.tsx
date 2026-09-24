import { useCallback, useEffect, useState } from "react";
import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { scanLibrary, onDownloadProgress, type WallPackage } from "./lib/bridge";
import { LibraryInfoPanel } from "./components/LibraryInfoPanel";
import { GravityModeSelector, gravityLabel, isGravityMode, type GravityMode } from "./components/GravityModeSelector";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";

export default function App() {
  const [packages, setPackages] = useState<WallPackage[]>([]);
  const [selected, setSelected] = useState<WallPackage>();
  const [status, setStatus] = useState("라이브러리를 불러오는 중…");
  const [loading, setLoading] = useState(true);
  const [url, setUrl] = useState("");
  const [downloading, setDownloading] = useState(false);
  const [tab, setTab] = useState<"library" | "registry">("library");
  const [registryUrl, setRegistryUrl] = useState("https://raw.githubusercontent.com/wallbloom/registry/main/index.json");
  const [registry, setRegistry] = useState<Array<{ id: string; title: string; type: string; version: string; download_url: string; sha256: string }>>([]);
  const [registryLoading, setRegistryLoading] = useState(false);
  const [activeState, setActiveState] = useState<{ active: string | null; gravity: GravityMode | null }>({ active: null, gravity: null });
  const [gravityChanging, setGravityChanging] = useState(false);

  const refreshActive = useCallback(async () => {
    try {
      const state = await invoke<{ active: string | null; paused: boolean; gravity: string | null } | null>("read_active");
      setActiveState({ active: state?.active ?? null, gravity: isGravityMode(state?.gravity) ? state.gravity : null });
    } catch { setActiveState({ active: null, gravity: null }); }
  }, []);

  const scan = useCallback(async () => {
    setLoading(true);
    setStatus("라이브러리를 스캔하는 중…");
    try {
      const result = await scanLibrary({});
      setPackages(result);
      await refreshActive();
      setStatus(result.length ? "라이브러리를 불러왔습니다." : "라이브러리가 비어 있습니다. URL로 배경화면을 추가해 보세요.");
    } catch (error) {
      setPackages([]);
      setStatus(`라이브러리 스캔 실패: ${String(error)}`);
    } finally { setLoading(false); }
  }, [refreshActive]);

  useEffect(() => { void scan(); }, [scan]);

  async function select(item: WallPackage) {
    setStatus(`${item.title} 선택 중…`);
    try {
      await invoke("select_wallpaper", { id: item.id });
      setSelected(item);
      // 같은 패키지 재선택은 오버라이드를 유지하고, 다른 패키지 선택은 초기화한다(Rust와 동일 계약).
      setActiveState(prev => ({ active: item.path, gravity: prev.active === item.path ? prev.gravity : null }));
      setStatus(`${item.title}을(를) 선택했습니다.`);
    } catch (error) { setStatus(`선택 실패: ${String(error)}`); }
  }

  const selectedGravity: GravityMode = (() => {
    if (!selected) return "cover";
    // 우선순위: active.json 오버라이드 > wallpkg gravity > cover (WALLPKG_SPEC §2/§3).
    const override = activeState.active === selected.path ? activeState.gravity : null;
    return override ?? (isGravityMode(selected.gravity) ? selected.gravity : "cover");
  })();

  async function changeGravity(mode: GravityMode) {
    if (!selected || gravityChanging) return;
    setGravityChanging(true);
    const previous = selectedGravity;
    try {
      await invoke("set_wallpaper_gravity", { id: selected.id, gravity: mode });
      setActiveState({ active: selected.path, gravity: mode });
      setStatus(`${selected.title} 화면 맞춤을 ${gravityLabel(mode)}(으)로 바꿨습니다.`);
    } catch (error) {
      setActiveState({ active: selected.path, gravity: previous });
      setStatus(`화면 맞춤 변경 실패: ${String(error)}`);
    } finally { setGravityChanging(false); }
  }

  async function download() {
    if (!url.trim() || downloading) return;
    setDownloading(true);
    let unlisten: (() => void) | undefined;
    try {
      unlisten = await onDownloadProgress(payload => {
        const received = (Number(payload.receivedBytes) / 1024 / 1024).toFixed(1);
        const total = payload.totalBytes ? ` / ${(Number(payload.totalBytes) / 1024 / 1024).toFixed(1)} MB` : "";
        setStatus(`다운로드 중: ${received} MB${total}`);
      });
      const id = await invoke<string>("download_wallpaper", { url: url.trim() });
      setUrl("");
      await scan();
      setStatus(`${id} 다운로드 완료`);
    } catch (error) { setStatus(`다운로드 실패: ${String(error)}`); }
    finally { unlisten?.(); setDownloading(false); }
  }

  async function browseRegistry() {
    setRegistryLoading(true);
    try { setRegistry(await invoke("fetch_registry", { indexUrl: registryUrl.trim() })); setStatus("레지스트리 인덱스를 불러왔습니다."); }
    catch (error) { setStatus(`레지스트리 불러오기 실패: ${String(error)}`); }
    finally { setRegistryLoading(false); }
  }

  async function installRegistry(entry: (typeof registry)[number]) {
    try { await invoke("install_registry_entry", { entry }); await scan(); setStatus(`${entry.title} 설치 완료`); }
    catch (error) { setStatus(`레지스트리 설치 실패: ${String(error)}`); }
  }

  return <div className="mx-auto min-h-screen w-full max-w-6xl px-5 py-7 sm:px-8">
    <header className="mb-8 flex flex-wrap items-center justify-between gap-4">
      <div><p className="mb-1 text-xs font-semibold uppercase tracking-[.2em] text-indigo-300">WALLBLOOM</p><h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">배경화면 라이브러리</h1></div>
      <div className="flex gap-2"><Button variant="outline" onClick={() => void invoke("install_web_demo").then(async () => { await scan(); setStatus("마우스 반응형 WebGL 데모를 라이브러리에 설치했습니다. 카드를 선택해 시험하세요."); }).catch(error => setStatus(`데모 설치 실패: ${String(error)}`))}>Web 데모 설치</Button><Button variant="outline" onClick={() => void invoke<string>("import_wallpkg").then(async () => { await scan(); setStatus("wallpkg 아카이브를 가져왔습니다."); }).catch(error => setStatus(`wallpkg 가져오기 실패: ${String(error)}`))}>wallpkg 가져오기</Button><Button variant="outline" onClick={() => void scan()} disabled={loading}>라이브러리 새로고침</Button></div>
    </header>
    <Card className="mb-8 bg-card/70">
      <CardContent className="p-5">
        <h2 className="mb-4 text-lg font-semibold">새 배경화면 다운로드</h2>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
          <div className="min-w-0 flex-1"><label className="mb-2 block text-sm font-medium text-slate-300" htmlFor="download-url">동영상 URL</label>
            <Input id="download-url" type="url" autoComplete="url" placeholder="https://example.com/wallpaper.mp4" value={url} onChange={event => setUrl(event.target.value)} /></div>
          <Button className="h-11 shrink-0" onClick={() => void download()} disabled={!url.trim() || downloading}>{downloading ? "다운로드 중…" : "다운로드"}</Button>
        </div>
      </CardContent>
    </Card>
    <nav className="mb-4 flex gap-2" aria-label="라이브러리 탐색"><Button variant={tab === "library" ? "default" : "outline"} onClick={() => setTab("library")}>내 라이브러리</Button><Button variant={tab === "registry" ? "default" : "outline"} onClick={() => setTab("registry")}>레지스트리</Button></nav>
    {tab === "registry" && <Card className="mb-6"><CardContent className="space-y-3 p-5"><h2 className="font-semibold">GitHub 레지스트리</h2><div className="flex gap-2"><Input aria-label="레지스트리 인덱스 URL" value={registryUrl} onChange={e => setRegistryUrl(e.target.value)} /><Button disabled={registryLoading} onClick={() => void browseRegistry()}>{registryLoading ? "불러오는 중…" : "목록 불러오기"}</Button></div><p className="text-sm text-muted-foreground">읽기 전용 목록입니다. 선택한 패키지만 다운로드하고 SHA-256을 확인합니다. Scene 패키지는 실행 코드를 포함할 수 있습니다.</p><div className="space-y-2">{registry.map(entry => <div key={`${entry.id}-${entry.version}`} className="flex items-center justify-between rounded border border-white/10 p-3"><span>{entry.title} <small className="text-muted-foreground">{entry.type} · {entry.version}</small></span><Button onClick={() => void installRegistry(entry)}>설치</Button></div>)}</div>{registry.length === 0 && <p className="text-sm text-muted-foreground">레지스트리 항목이 없습니다.</p>}</CardContent></Card>}
    <main aria-labelledby="library-heading" hidden={tab !== "library"}>
      <div className="mb-4 flex items-baseline justify-between gap-3"><h2 id="library-heading" className="text-lg font-semibold">내 라이브러리</h2><span className="text-sm text-slate-400" aria-live="polite">{loading ? "" : `${packages.length}개`}</span></div>
      {loading ? <p className="py-8 text-center text-muted-foreground">라이브러리를 불러오는 중…</p> : packages.length === 0 ? <p className="py-8 text-center text-muted-foreground">라이브러리에 배경화면이 없습니다.</p> :
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4" aria-label="배경화면 그리드">
          {packages.map(item => <button key={item.id} type="button" aria-label={`${item.title} 배경화면 선택`} className="group rounded-xl text-left focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring" onClick={() => void select(item)}>
            <Card className="h-full transition-colors group-hover:ring-ring/60"><CardContent className="p-0">
              {item.previewPath ? <img className="aspect-video w-full rounded-t-xl object-cover" src={convertFileSrc(item.previewPath)} alt="" onError={event => { event.currentTarget.hidden = true; }} /> : <div className="aspect-video w-full rounded-t-xl bg-muted" aria-hidden="true" />}
              <div className="flex items-center justify-between gap-2 px-4 py-3"><p className="truncate font-medium">{item.title}</p><span className="rounded-full bg-muted px-2 py-1 text-xs text-muted-foreground">{item.packageType === "web" ? "WEB · 마우스 반응형" : "VIDEO"}</span></div>
            </CardContent></Card>
          </button>)}
        </div>}
      {!loading && <LibraryInfoPanel packages={packages} selected={selected} />}
      {selected && <div className="mt-4 flex flex-col gap-3 rounded-xl border border-white/10 bg-card/50 p-4 sm:flex-row sm:flex-wrap sm:items-center sm:justify-between">
        <GravityModeSelector mode={selectedGravity} disabled={gravityChanging} onChange={mode => void changeGravity(mode)} />
        <Button variant="outline" onClick={() => void invoke("export_wallpkg", { id: selected.id }).then(() => setStatus(`${selected.title}을(를) wallpkg로 내보냈습니다.`)).catch(error => setStatus(`내보내기 실패: ${String(error)}`))}>선택 항목 wallpkg 내보내기</Button>
      </div>}
    </main>
    <aside className="my-6 rounded-xl border border-indigo-400/20 bg-indigo-400/5 p-4 text-sm text-slate-300"><strong className="block text-foreground">Web 배경화면 상호작용</strong><p className="mt-1">Web 배경은 기본적으로 클릭을 통과합니다. 배경에서 직접 상호작용하려면 메뉴 막대의 ‘Web 상호작용 시작’을 사용하고, 종료는 Escape 또는 메뉴 막대에서 할 수 있습니다.</p></aside>
    <footer className="mt-6 min-h-12 border-t border-white/10 pt-4 text-sm text-slate-300"><p role="status" aria-live="polite">{status}</p></footer>
  </div>;
}
