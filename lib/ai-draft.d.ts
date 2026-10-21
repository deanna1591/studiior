type Ctx = Record<string, string | undefined>;
export function buildPrompt(
  ctx: Ctx | null | undefined,
  voice: string | null | undefined,
  currentSubject: string | null | undefined,
  currentBody: string | null | undefined,
  situation: string,
): { system: string; user: string };
export function buildBulkPrompt(
  voice: string | null | undefined,
  currentSubject: string | null | undefined,
  currentBody: string | null | undefined,
  situation: string,
): { system: string; user: string };
export function parseDraft(text: unknown): { subject: string; body: string } | null;
export function parseApiResponse(json: unknown): {
  text: string;
  inputTokens: number | null;
  outputTokens: number | null;
};
