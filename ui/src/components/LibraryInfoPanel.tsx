import { useMemo } from "react";
import { createParser, Renderer } from "@openuidev/react-lang";
import { library } from "../lib/library-info";
import type { WallPackage } from "../generated/types";
import { Card, CardContent } from "./ui/card";

export function libraryInfoProgram(packages: WallPackage[], selected?: WallPackage) {
  // JSON string literals keep local titles/paths as data, never Lang expressions.
  const args = [packages.length, packages.filter(item => !item.previewPath).length,
    selected?.title ?? "", selected?.path ?? ""].map(value => JSON.stringify(value));
  return `root = LibraryInfo(${args.join(", ")})`;
}

export function LibraryInfoPanel({ packages, selected }: { packages: WallPackage[]; selected?: WallPackage }) {
  const response = libraryInfoProgram(packages, selected);
  const valid = useMemo(() => {
    const result = createParser(library.toJSONSchema(), "LibraryInfo").parse(response);
    return result.meta.errors.length === 0 && result.meta.unresolved.length === 0;
  }, [response]);
  return <section aria-label="로컬 라이브러리 정보" className="mt-6">
    <Card><CardContent className="space-y-3 p-5">
      <h2 className="font-semibold">로컬 라이브러리 정보</h2>
      <p className="text-xs text-muted-foreground">로컬 파일 정보 · OpenUI 렌더러 · AI 생성 아님</p>
      {valid ? <Renderer response={response} library={library} isStreaming={false} />
        : <p role="alert">라이브러리 정보 형식을 해석하지 못했습니다.</p>}
    </CardContent></Card>
  </section>;
}
