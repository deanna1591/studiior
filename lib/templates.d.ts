export type TemplateKey = { key: string; label: string };
export type TemplateGroup = { title: string; keys: TemplateKey[] };
export const TEMPLATE_GROUPS: TemplateGroup[];
export function isEditableTemplate(key: string): boolean;
export function templateLabel(key: string): string;
export function placeholdersFrom(...texts: (string | null | undefined)[]): string[];
