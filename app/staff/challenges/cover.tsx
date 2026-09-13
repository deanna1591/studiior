"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import FocalPicker from "@/components/focal-picker";
import { uploadChallengeCover, saveChallengeCoverFocus, type CoverState } from "./actions";

function Btn({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : children}</button>;
}

/**
 * The challenge cover, on the edit surface. Upload replaces the picture and
 * recentres the focal point; the picker then anchors what survives the crop, on
 * a preview at the shape the member's phone will actually crop it to — the same
 * treatment class-type and login photos got in 116, because object-fit: cover on
 * a phone keeps about a sixth of a wide picture.
 */
export default function ChallengeCover({ challengeId, coverUrl, focusX, focusY }: {
  challengeId: string; coverUrl: string | null; focusX: number; focusY: number;
}) {
  const [upState, upload] = useFormState<CoverState, FormData>(uploadChallengeCover, null);
  const [foState, saveFocus] = useFormState<CoverState, FormData>(saveChallengeCoverFocus, null);

  return (
    <div className="s-card p-4">
      {upState && <Notice kind={upState.ok ? "ok" : "error"}>{upState.message}</Notice>}

      {coverUrl && (
        <form action={saveFocus} className="mb-4">
          {foState && <Notice kind={foState.ok ? "ok" : "error"}>{foState.message}</Notice>}
          <input type="hidden" name="challenge_id" value={challengeId} />
          <FocalPicker
            src={coverUrl}
            nameX="focus_x" nameY="focus_y" x={focusX} y={focusY}
            ratio={{ w: 686, h: 344 }}
            label="What stays in frame on a phone"
          />
          <div className="mt-3"><Btn>Save focal point</Btn></div>
        </form>
      )}

      <form action={upload}>
        <input type="hidden" name="challenge_id" value={challengeId} />
        <label className="block text-[12px] font-semibold text-ink-2 mb-1">
          {coverUrl ? "Replace the cover" : "Add a cover photo"}
        </label>
        <input name="cover" type="file" accept="image/png,image/jpeg,image/webp"
               className="block w-full text-[13px] text-ink-2 file:mr-3 file:rounded-full file:border-0 file:bg-paper file:px-3 file:py-1.5 file:text-[13px]" />
        <div className="mt-3"><Btn>Upload</Btn></div>
        <p className="mt-1 text-[11px] text-ink-3">
          JPEG, PNG or WebP, up to 2 MB. No photo falls back to your studio accent.
        </p>
      </form>
    </div>
  );
}
