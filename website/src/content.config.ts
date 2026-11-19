import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

const guides = defineCollection({
  loader: glob({ base: "./src/content/guides", pattern: "**/*.md" }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    /** Path under public/, 1200×630. */
    cover: z.string(),
    /** Lower comes first on the guides page. */
    order: z.number(),
    /** Which group it sits in on /guides. */
    audience: z.enum(["everyone", "developers"]),
    /** The one guide shown wide at the top of its group. */
    featured: z.boolean().default(false),
    readingMinutes: z.number(),
    /** Two to four one-sentence takeaways shown at the top. `code` is allowed. */
    tldr: z.array(z.string()).min(2).max(4),
    updated: z.coerce.date(),
  }),
});

export const collections = { guides };
