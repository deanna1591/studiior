import { createClient } from "@/lib/supabase/server";

// Add-to-calendar for one of the instructor's own classes. instructor_class_ics
// is guarded to that class's instructor (or a manager); the .ics carries the
// headcount in its body.
export async function GET(_req: Request, { params }: { params: { id: string } }) {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("instructor_class_ics", { p_occurrence_id: params.id });
  if (error) return new Response(error.message, { status: error.code === "PT403" ? 403 : 404 });

  return new Response(data as string, {
    headers: {
      "content-type": "text/calendar; charset=utf-8",
      "content-disposition": `attachment; filename="class-${params.id}.ics"`,
    },
  });
}
