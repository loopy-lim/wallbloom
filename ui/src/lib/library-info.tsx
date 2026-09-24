import { createLibrary, defineComponent } from "@openuidev/react-lang";
import { z } from "zod/v4";

const LibraryInfo = defineComponent({
  name: "LibraryInfo",
  description: "Local wallpaper inventory and the last successfully selected package, not an AI recommendation.",
  props: z.object({
    count: z.number(),
    missingPreviews: z.number(),
    title: z.string(),
    path: z.string(),
  }),
  component: ({ props }) => <div className="space-y-2 text-sm text-muted-foreground">
    <p>사용 가능한 배경화면: {props.count}개 · 미리보기 없는 항목: {props.missingPreviews}개</p>
    {props.missingPreviews > 0 && <p>미리보기가 없어도 선택할 수 있습니다. 패키지 폴더에 preview.png를 추가한 뒤 새로고침하세요.</p>}
    {props.title ? <dl><dt className="font-medium text-foreground">마지막 선택: {props.title}</dt><dd className="break-all">{props.path}</dd></dl>
      : <p>배경화면을 선택하면 저장 위치를 확인할 수 있습니다.</p>}
  </div>,
});

export const library = createLibrary({ root: "LibraryInfo", components: [LibraryInfo] });
