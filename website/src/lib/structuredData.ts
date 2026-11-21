/*
 * schema.org JSON-LD for search engines and AI assistants. Rendered by StructuredData.astro.
 * Only describe what the page itself shows: nothing here may claim more than the visible copy.
 */
import { releases } from "../data/changelog";
import { site } from "../site.config";

const SITE = "https://getfurl.app";
const ORG_ID = `${SITE}/#organization`;
const SITE_ID = `${SITE}/#website`;
const APP_ID = `${SITE}/#app`;

type Thing = Record<string, unknown>;

const latest = releases[0];

export function siteGraph(): Thing[] {
  return [
    {
      "@type": "Organization",
      "@id": ORG_ID,
      name: "Furl",
      url: `${SITE}/`,
      logo: `${SITE}/favicon.svg`,
      sameAs: [site.githubUrl],
    },
    {
      "@type": "WebSite",
      "@id": SITE_ID,
      name: "Furl",
      url: `${SITE}/`,
      inLanguage: "en",
      publisher: { "@id": ORG_ID },
    },
    {
      "@type": "SoftwareApplication",
      "@id": APP_ID,
      name: "Furl",
      description:
        "Furl is a free, open-source macOS app that frees disk space. It finds caches, merged git worktrees, app leftovers, duplicates, large files and leftover dev servers, explains why each one is safe, and uses the Trash by default so it can be undone. Files, file names and paths never leave the Mac.",
      url: `${SITE}/`,
      applicationCategory: "UtilitiesApplication",
      operatingSystem: "macOS 14 or later",
      softwareVersion: latest.version,
      releaseNotes: `${SITE}/changelog/#${latest.version}`,
      downloadUrl: site.downloadUrl,
      installUrl: `${SITE}/install/`,
      license: "https://opensource.org/licenses/MIT",
      isAccessibleForFree: true,
      codeRepository: site.githubUrl,
      screenshot: `${SITE}/og-site.png`,
      featureList: [
        "Caches and junk: node_modules, Xcode DerivedData, package manager caches, logs, old installers",
        "Merged and squash-merged git worktrees",
        "Uninstall apps with their leftover ~/Library data",
        "Space Map of any folder or disk",
        "Duplicate files by content",
        "Smart Review: on-device AI labels likely useless files",
        "Large files",
        "Lossless Compress and opt-in lossy Shrink for photos, videos and PDFs",
        "Processes & Sessions: stop dev servers AI coding agents left running",
        "Snapshots of folder sizes over time",
        "Undo for anything moved to the Trash",
        "Automatic updates",
      ],
      offers: {
        "@type": "Offer",
        price: "0",
        priceCurrency: "USD",
        description: "Pay what you like, including $0. Every feature is free.",
        url: `${SITE}/#pricing`,
      },
      author: { "@id": ORG_ID },
      publisher: { "@id": ORG_ID },
    },
  ];
}

export function breadcrumbs(items: { name: string; path: string }[]): Thing {
  return {
    "@type": "BreadcrumbList",
    itemListElement: items.map((item, i) => ({
      "@type": "ListItem",
      position: i + 1,
      name: item.name,
      item: `${SITE}${item.path}`,
    })),
  };
}

export function guideArticle(guide: {
  id: string;
  title: string;
  description: string;
  cover: string;
  updated: Date;
  readingMinutes: number;
}): Thing {
  const url = `${SITE}/guides/${guide.id}/`;
  return {
    "@type": "TechArticle",
    "@id": `${url}#article`,
    headline: guide.title,
    description: guide.description,
    url,
    mainEntityOfPage: url,
    image: `${SITE}${guide.cover}`,
    dateModified: guide.updated.toISOString().slice(0, 10),
    timeRequired: `PT${guide.readingMinutes}M`,
    inLanguage: "en",
    author: { "@id": ORG_ID },
    publisher: { "@id": ORG_ID },
    about: { "@id": APP_ID },
  };
}

/** The install page's visible steps (macOS 15 Sequoia and later), as a HowTo. */
export function installHowTo(): Thing {
  const url = `${SITE}/install/`;
  const steps = [
    ["Open Furl once", "Drag Furl to Applications and double-click it. When macOS shows “Furl” Not Opened, click Done."],
    ["Go to Privacy & Security", "Open System Settings from the Apple menu and choose Privacy & Security in the sidebar."],
    ["Click Open Anyway", "Scroll down to Security. Next to “Furl” was blocked to protect your Mac, click Open Anyway."],
    ["Confirm", "Click Open Anyway again, then enter your Mac password or use Touch ID. macOS remembers your choice for this version."],
  ];
  return {
    "@type": "HowTo",
    "@id": `${url}#howto`,
    name: "Opening Furl the first time",
    description:
      "Furl isn't notarized by Apple yet, so the first time you open it macOS asks you to approve it in System Settings. It takes about a minute, once per version.",
    url,
    totalTime: "PT1M",
    step: steps.map(([name, text], i) => ({
      "@type": "HowToStep",
      position: i + 1,
      name,
      text,
      url: `${url}#panel-sequoia`,
    })),
  };
}
