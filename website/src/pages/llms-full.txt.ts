import type { APIRoute } from "astro";
import { guideUrl, header, pages, sortedGuides, textResponse } from "../lib/llms";

// /llms-full.txt: /llms.txt plus every guide's full Markdown, for assistants that want it in one fetch.
export const GET: APIRoute = async () => {
  const guides = (await sortedGuides())
    .map((g) => `## ${g.data.title}\n\nSource: ${guideUrl(g.id)}\n\n${g.data.description}\n\n${(g.body ?? "").trim()}`)
    .join("\n\n---\n\n");
  return textResponse(`${header}\n${pages}\n---\n\n${guides}\n`);
};
