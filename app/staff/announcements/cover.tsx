"use client";

import { useFormState, useFormStatus } from "react-dom";
import FocalPicker from "@/components/focal-picker";
import { uploadAnnouncementCover, saveAnnouncementCoverFocus, type CoverState } from "./actions";
import { Notice } from "@/components/ui";

function Btn({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return <button className="rounded-full border border-line-2 bg-surface px-3.5 py-1.5 text-[13px] font-medium text-ink disabled:opacity-50" disabled={pending}>{pending ? "…" : label}</button>;
}

export default function AnnouncementCover({ id, imageUrl, focusX, focusY }: {
  id: string; imageUrl: string | null; focusX: number; focusY: number;
}) {
  const [up, upAction] = useFormState<CoverState, FormData>(uploadAnnouncementCover, null);
  const [fx, fxAction] = useFormState<CoverState, FormData>(saveAnnouncementCoverFocus, null);

  return (
    <div className="max-w-md">
      {up && <Notice kind={up.ok ? "ok" : "error"}>{up.message}</Notice>}
      {imageUrl && (
        <form action={fxAction} className="mb-3">
          {fx && <Notice kind={fx.ok ? "ok" : "error"}>{fx.message}</Notice>}
          <input type="hidden" name="announcement_id" value={id} />
          <FocalPicker src={imageUrl} nameX="focus_x" nameY="focus_y" x={focusX} y={focusY}
                       ratio={{ w: 686, h: 256 }} label="Where should it crop?"
                       note="Drag the point to the part that matters." />
          <div className="mt-2"><Btn label="Save focal point" /></div>
        </form>
      )}
      <form action={upAction}>
        <input type="hidden" name="announcement_id" value={id} />
        <input name="cover" type="file" accept="image/png,image/jpeg,image/webp"
               className="mb-2 block w-full text-[13px] file:mr-3 file:rounded file:border-0 file:bg-ink file:px-3 file:py-1.5 file:text-[13px] file:text-surface" />
        <Btn label={imageUrl ? "Replace photo" : "Upload a photo"} />
      </form>
    </div>
  );
}
