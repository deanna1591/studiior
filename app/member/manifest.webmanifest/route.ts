import { buildManifest } from "@/lib/manifest";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET() {
  const res = await buildManifest("member");
  return res ?? new Response("Not found", { status: 404 });
}
