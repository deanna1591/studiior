import { createClient } from "@/lib/supabase/server";

// The instructor's whole month as one .ics — scheduled, published classes only
// (Decision 25). The studio is resolved from the caller's own instructor record
// rather than trusted from the URL.
export async function GET(_req: Request, { params }: { params: { month: string } }) {
  const supabase = createClient();

  const { data: me, error: meErr } = await supabase.rpc("my_instructor");
  if (meErr || !me) return new Response("Not signed in as an instructor", { status: 401 });
  const studioId = (me as { studio_id?: string }).studio_id;
  if (!studioId) return new Response("No studio", { status: 401 });

  const { data, error } = await supabase.rpc("instructor_month_ics", {
    p_studio_id: studioId,
    p_month: params.month,
  });
  if (error) return new Response(error.message, { status: error.code === "PT403" ? 403 : 400 });

  return new Response(data as string, {
    headers: {
      "content-type": "text/calendar; charset=utf-8",
      "content-disposition": `attachment; filename="schedule-${params.month}.ics"`,
    },
  });
}
