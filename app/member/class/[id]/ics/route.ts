import { createClient } from "@/lib/supabase/server";

// Add-to-calendar for a member's own booked class. The .ics builder lives in
// SQL (member_class_ics is guarded to the booking's owner); this route only
// wraps it as a downloadable text/calendar file so the phone hands it to the
// calendar app.
export async function GET(_req: Request, { params }: { params: { id: string } }) {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("member_class_ics", { p_occurrence_id: params.id });
  if (error) return new Response(error.message, { status: error.code === "PT403" ? 403 : 404 });
  if (!data) return new Response("No booking for that class", { status: 404 });

  return new Response(data as string, {
    headers: {
      "content-type": "text/calendar; charset=utf-8",
      "content-disposition": `attachment; filename="class-${params.id}.ics"`,
    },
  });
}
