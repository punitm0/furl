import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Setup files run outside per-test storage isolation, so this is safe to run for every file.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

// Tests share one UTC day, so lift the public growth ceilings out of the way; the ceiling tests set their own.
await env.DB.prepare("UPDATE public_ceilings SET value = ?1").bind(Number.MAX_SAFE_INTEGER).run();
