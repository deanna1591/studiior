"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonQuietClass } from "@/components/ui";
import ShrinkImageInput from "@/components/shrink-image-input";
import {
  savePrivateSettings, savePrivateType, togglePrivateType, saveTeachesPrivates,
  uploadGiftCardImage, removeGiftCardImage, type PrivState,
} from "./private-actions";

function Save({ label = "Save" }: { label?: string }) {
  const { pending } = useFormStatus();
  return <button className={buttonQuietClass} disabled={pending}>{pending ? "Saving…" : label}</button>;
}

export type PrivateType = {
  id: string; name: string; price_cents: number; people: number; duration_min: number;
  coach_pay_cents: number; active: boolean;
};
export type Coach = { id: string; display_name: string; teaches_privates: boolean };

const input = "mt-1 w-full rounded border border-line bg-surface px-3 py-2 text-[13px] text-ink";

/**
 * Decision 116: private sessions. On or off, the lead time and the buffer, up to
 * three session types, and which coaches teach privates. Off by default.
 */
export default function PrivateSessionsPanel({
  enabled, leadHours, bufferMin, types, coaches, currency,
}: {
  enabled: boolean; leadHours: number; bufferMin: number;
  types: PrivateType[]; coaches: Coach[]; currency: string;
}) {
  const [st, act] = useFormState<PrivState, FormData>(savePrivateSettings, null);
  const [cst, cact] = useFormState<PrivState, FormData>(saveTeachesPrivates, null);
  const activeCount = types.filter((t) => t.active).length;
  return (
    <div className="max-w-2xl space-y-4">
      <form action={act} className="rounded border border-line bg-surface px-3.5 py-3">
        {st && <Notice kind={st.ok ? "ok" : "error"}>{st.message}</Notice>}
        <label className="flex items-start gap-2.5 text-[13px] leading-[19px] text-ink">
          <input type="checkbox" name="private_sessions_enabled" defaultChecked={enabled} className="mt-0.5" />
          <span>
            <span className="font-medium">Offer private sessions</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">
              Members book a 1:1, Duo or Trio in the free gaps of your timetable: inside your
              opening hours, with the room free for the session plus the buffer either side, and a
              coach available. A private is hidden from everyone else.
            </span>
          </span>
        </label>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="block text-[13px] text-ink">
            <span className="font-medium">Book at least (hours ahead)</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">Also the free-cancel and move cut-off.</span>
            <input name="private_lead_time_hours" type="number" min={0} max={336} defaultValue={leadHours} className={input} />
          </label>
          <label className="block text-[13px] text-ink">
            <span className="font-medium">Buffer (minutes)</span>
            <span className="block text-[12px] leading-[18px] text-ink-3">Kept free before and after, for the room.</span>
            <input name="private_buffer_minutes" type="number" min={0} max={120} defaultValue={bufferMin} className={input} />
          </label>
        </div>
        <div className="mt-3"><Save /></div>
      </form>

      <div className="rounded border border-line bg-surface px-3.5 py-3">
        <p className="text-[13px] font-medium text-ink">Session types</p>
        <p className="text-[12px] leading-[18px] text-ink-3">
          Up to three. Prices in {currency}. Coach pay is the flat amount the coach earns for the session.
        </p>
        <div className="mt-3 space-y-3">
          {types.map((t) => <TypeRow key={t.id} t={t} />)}
          {activeCount < 3 && <TypeRow t={null} />}
        </div>
      </div>

      <form action={cact} className="rounded border border-line bg-surface px-3.5 py-3">
        {cst && <Notice kind={cst.ok ? "ok" : "error"}>{cst.message}</Notice>}
        <p className="text-[13px] font-medium text-ink">Coaches who teach privates</p>
        {coaches.length === 0 ? (
          <p className="mt-1 text-[12px] text-ink-3">No active coaches yet.</p>
        ) : (
          <div className="mt-2 grid gap-1.5 sm:grid-cols-2">
            {coaches.map((c) => (
              <label key={c.id} className="flex items-center gap-2 text-[13px] text-ink">
                <input type="checkbox" name="teaches" value={c.id} defaultChecked={c.teaches_privates} />
                {c.display_name}
              </label>
            ))}
          </div>
        )}
        <div className="mt-3"><Save /></div>
      </form>
    </div>
  );
}

function TypeRow({ t }: { t: PrivateType | null }) {
  const [st, act] = useFormState<PrivState, FormData>(savePrivateType, null);
  const [tst, tact] = useFormState<PrivState, FormData>(togglePrivateType, null);
  const muted = t && !t.active;
  return (
    <div className={"rounded border border-line px-3 py-2.5 " + (muted ? "bg-paper" : "")}>
      {st && <Notice kind={st.ok ? "ok" : "error"}>{st.message}</Notice>}
      {tst && !tst.ok && <Notice kind="error">{tst.message}</Notice>}
      <form action={act} className="grid gap-2 sm:grid-cols-6">
        {t && <input type="hidden" name="id" value={t.id} />}
        <label className="block text-[12px] text-ink sm:col-span-2">Name
          <input name="name" defaultValue={t?.name ?? ""} placeholder={t ? "" : "e.g. Private 1:1"} required className={input} />
        </label>
        <label className="block text-[12px] text-ink">People
          <select name="people" defaultValue={t?.people ?? 1} className={input}>
            <option value={1}>1</option><option value={2}>2</option><option value={3}>3</option>
          </select>
        </label>
        <label className="block text-[12px] text-ink">Minutes
          <input name="duration_min" type="number" min={10} max={240} defaultValue={t?.duration_min ?? 50} className={input} />
        </label>
        <label className="block text-[12px] text-ink">Price
          <input name="price" inputMode="decimal" defaultValue={t ? t.price_cents / 100 : ""} required className={input} />
        </label>
        <label className="block text-[12px] text-ink">Coach pay
          <input name="coach_pay" inputMode="decimal" defaultValue={t ? t.coach_pay_cents / 100 : ""} required className={input} />
        </label>
        <div className="flex items-end gap-3 sm:col-span-6">
          <Save label={t ? "Save" : "Add session type"} />
        </div>
      </form>
      {t && (
        <form action={tact} className="mt-2">
          <input type="hidden" name="id" value={t.id} />
          <input type="hidden" name="active" value={t.active ? "false" : "true"} />
          <button className="text-[12px] text-ink-2 underline">{t.active ? "Stop offering this" : "Offer this again"}</button>
        </form>
      )}
    </div>
  );
}

/** Decision 110(a): the gift card image (PNG or JPG; shrunk in the browser). */
export function GiftCardImagePanel({ imageUrl }: { imageUrl: string | null }) {
  const [st, act] = useFormState<PrivState, FormData>(uploadGiftCardImage, null);
  const [rst, ract] = useFormState<PrivState, FormData>(removeGiftCardImage, null);
  return (
    <div className="mt-4 max-w-2xl rounded border border-line bg-surface px-3.5 py-3">
      {(st || rst) && <Notice kind={(st ?? rst)!.ok ? "ok" : "error"}>{(st ?? rst)!.message}</Notice>}
      <p className="text-[13px] font-medium text-ink">Gift card image</p>
      <p className="text-[12px] leading-[18px] text-ink-3">
        The recipient&apos;s email shows the card with the amount and the code on it. A wide image works
        best (about 1200 by 750). Without one, the card is drawn in your studio colour.
      </p>
      {imageUrl && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={imageUrl} alt="Gift card image" width={300} height={188}
             className="mt-2 h-[94px] w-[150px] rounded object-cover" />
      )}
      <form action={act} className="mt-2 flex flex-wrap items-center gap-3">
        <ShrinkImageInput name="gift_card_image" accept="image/png,image/jpeg" maxPx={1280} />
        <Save label="Upload" />
      </form>
      {imageUrl && (
        <form action={ract} className="mt-2">
          <button className="text-[12px] text-ink-2 underline">Remove and use the default card</button>
        </form>
      )}
    </div>
  );
}
