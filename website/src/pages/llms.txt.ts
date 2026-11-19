import type { APIRoute } from "astro";
import { guideUrl, header, optional, pages, sortedGuides, textResponse } from "../lib/llms";

// /llms.txt: a short index of the site for AI assistants (llmstxt.org). /llms-full.txt has the guides in full.
export const GET: APIRoute = async () => {
  const guides = (await sortedGuides())
    .map((g) => `- [${g.data.title}](${guideUrl(g.id)}): ${g.data.description}`)
    .join("\n");
  return textResponse(`${header}\n${pages}\n## Guides\n\n${guides}\n\n${optional}`);
};
