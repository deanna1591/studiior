export const DEFAULT_LOGIN_TAGLINE: string;
export function loginTagline(custom: string | null | undefined): string;
export function installWelcome(studioName: string, custom: string | null | undefined): string;
export function shortName(studioName: string): string;
export function iconVersion(logoUrl: string | null | undefined): string;

export type ManifestIcon = { src: string; sizes: string; type: string; purpose: string };
export type Manifest = {
  id: string;
  name: string;
  short_name: string;
  start_url: string;
  scope: string;
  display: string;
  background_color: string;
  theme_color: string;
  icons: ManifestIcon[];
};
export function manifestObject(
  input: { slug: string; name: string; themeColor: string; backgroundColor: string; iconV: string },
  which: "member" | "instructor",
): Manifest;
