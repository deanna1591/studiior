export function parseFingerprints(text: string): { valid: string[]; invalid: string[] };
export function isPackageId(s: string): boolean;
export function isTeamId(s: string): boolean;
export function assetlinksFor(input?: { androidPackage?: string | null; fingerprints?: string[] }):
  | { relation: string[]; target: { namespace: string; package_name: string; sha256_cert_fingerprints: string[] } }[]
  | null;
export function aasaFor(input?: { teamId?: string | null; bundleId?: string | null }):
  | { applinks: { apps: string[]; details: { appID: string; paths: string[] }[] }; webcredentials: { apps: string[] } }
  | null;
