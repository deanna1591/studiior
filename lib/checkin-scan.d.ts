/** Decision 68 amendment — extract the check-in token from a scanned printed
 *  studio QR, accepting ONLY this studio's member-host URL (host must match). */
export function slugFromCheckinUrl(raw: string, host: string): string | null;
