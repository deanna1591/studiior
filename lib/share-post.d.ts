export declare const SHARE_FALLBACK_TOAST: string;
export type ShareMode = "share" | "fallback";
export type ShareOutcome = "shared" | "cancelled" | "fallback";
export declare function pickShareMode(
  nav: { canShare?: (data: { files?: File[] }) => boolean; share?: (data: unknown) => Promise<void> } | null | undefined,
  file: File | null,
): ShareMode;
export declare function sharePost(opts: { blob: Blob; filename: string; caption: string }): Promise<ShareOutcome>;
