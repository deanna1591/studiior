"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Field, inputClass } from "@/components/ui";
import {
  browserTimeZone, countryOptions, currencyOptions, currencyForCountry,
  timezoneOptions, utcOffset,
} from "@/lib/locale";

/**
 * Timezone, country and currency — the three fields that were free text.
 *
 * Timezone is the one that matters. An IANA identifier is not a label a person
 * can proofread, and a wrong one does not fail: it silently shifts every class
 * in the studio, and keeps shifting them, because occurrences are materialised
 * against it. So the value can only ever come from an option in the list, never
 * from what someone typed. The search box filters; it is not the field.
 *
 * Used by both the provisioning form and the wizard's identity step, so the two
 * cannot drift apart.
 */
export default function StudioLocaleFields({
  timezone, country, currency, disabled,
}: {
  timezone?: string; country?: string; currency?: string; disabled?: boolean;
}) {
  const zones = useMemo(() => timezoneOptions(), []);
  const countries = useMemo(() => countryOptions(), []);
  const currencies = useMemo(() => currencyOptions(), []);

  const [tz, setTz] = useState(timezone ?? "");
  const [ctry, setCtry] = useState(country ?? "");
  const [cur, setCur] = useState(currency ?? "");
  const [q, setQ] = useState("");

  // Everything here is locale- and clock-dependent, and this component is
  // server-rendered before it is hydrated. On the server browserTimeZone() is
  // the *server's* zone and the offsets are computed against the server's
  // clock, so rendering the real list on both sides produces text that does not
  // match and React throws out the server HTML. Nothing locale-dependent is
  // rendered until mount; before that the field holds exactly the value it was
  // given, which both sides agree on.
  const selectRef = useRef<HTMLSelectElement>(null);
  const [mounted, setMounted] = useState(false);
  useEffect(() => {
    setMounted(true);
    // A studio being provisioned has no timezone yet; the operator's own is a
    // better guess than the top of an alphabetical list.
    if (!timezone) setTz((current) => current || browserTimeZone());
  }, [timezone]);

  // A six-row window over 418 zones opens at the top, so the selected option is
  // off-screen and the operator sees Abidjan rather than their own city. On a
  // field where the whole risk is picking the wrong one, it has to show which
  // one is picked.
  useEffect(() => {
    if (!mounted) return;
    const el = selectRef.current;
    if (!el || el.selectedIndex < 0 || el.options.length === 0) return;
    // option.offsetTop is not meaningful inside a select — it reports relative
    // to the wrong box and lands hundreds of rows away. Row height from the
    // scroll extent is reliable.
    const rowHeight = el.scrollHeight / el.options.length;
    el.scrollTop = Math.max(
      0,
      (el.selectedIndex + 0.5) * rowHeight - el.clientHeight / 2,
    );
  }, [mounted, tz, q]);

  const filtered = useMemo(() => {
    if (!mounted) return tz ? [{ value: tz, label: tz }] : [];
    const needle = q.trim().toLowerCase();
    const matches = needle
      ? zones.filter((z) => z.label.toLowerCase().includes(needle))
      : zones;
    // The selected zone stays in the list even when it does not match the
    // search, so filtering can never silently change the value.
    return matches.some((z) => z.value === tz)
      ? matches
      : [...zones.filter((z) => z.value === tz), ...matches];
  }, [q, zones, tz, mounted]);

  function pickCountry(next: string) {
    setCtry(next);
    const suggested = currencyForCountry(next);
    // Defaulted, not forced: a Prague studio may well price in EUR.
    if (suggested) setCur(suggested);
  }

  return (
    <>
      <Field label="Timezone">
        <input
          type="search"
          disabled={disabled || !mounted}
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Search cities or regions — Prague, London, GMT…"
          className={`${inputClass} mb-2`}
          aria-label="Filter timezones"
        />
        <select
          ref={selectRef}
          name="timezone"
          required
          value={tz}
          onChange={(e) => setTz(e.target.value)}
          size={6}
          disabled={disabled}
          className={`${inputClass} h-auto font-mono text-xs`}
        >
          {filtered.map((z) => (
            <option key={z.value} value={z.value}>{z.label}</option>
          ))}
        </select>
        <p className="mt-1 text-xs text-stone-500">
          {mounted ? (
            <>
              {filtered.length} of {zones.length} zones.{" "}
              <span className="font-medium text-stone-700">
                {tz} is UTC{utcOffset(tz)} right now.
              </span>{" "}
            </>
          ) : null}
          Class times are stored in UTC and shown in this zone, so a 7am class
          stays 7am across daylight saving.
        </p>
      </Field>

      <div className="grid grid-cols-2 gap-3">
        <Field label="Country">
          <select
            name="country"
            value={ctry}
            onChange={(e) => pickCountry(e.target.value)}
            disabled={disabled}
            className={inputClass}
          >
            <option value="">Not set</option>
            {(mounted ? countries : ctry ? [{ value: ctry, label: ctry }] : []).map((c) => (
              <option key={c.value} value={c.value}>{c.label}</option>
            ))}
          </select>
        </Field>
        <Field label="Currency">
          <select
            name="currency"
            required
            value={cur}
            onChange={(e) => setCur(e.target.value)}
            disabled={disabled}
            className={inputClass}
          >
            <option value="" disabled>Choose a currency</option>
            {(mounted ? currencies : cur ? [{ value: cur, label: cur }] : []).map((c) => (
              <option key={c.value} value={c.value}>{c.label}</option>
            ))}
          </select>
        </Field>
      </div>
      <p className="-mt-2 text-xs text-stone-500">
        Choosing a country suggests its currency; change it if the studio prices
        in something else. Every price is stored in this currency and changing it
        later converts nothing.
      </p>
    </>
  );
}
