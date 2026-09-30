// Types for the plain-ESM lib/flex-copy.mjs.

/** The standalone-flex warning, or "" when standbyText is falsy (standby pay 0). */
export function standaloneFlexSentence(standbyText: string | null | undefined, count?: number): string;

/** The opening-hours warning (Decision 44), or "" when hoursText is falsy (unset). */
export function outsideHoursSentence(hoursText: string | null | undefined, plural?: boolean): string;
