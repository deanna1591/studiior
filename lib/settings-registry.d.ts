export type SettingSection = { anchor: string; title: string; summary: string };

export type SettingGroup = {
  id: string;
  label: string;
  route: string;
  description: string;
  /** Ordered section headings for the home card and the group page. */
  sections: SettingSection[];
};

export type SettingEntry = {
  /** Unique, kebab-case. */
  id: string;
  /** One of GROUPS[].id. */
  group: string;
  /** Plain-language label (Decision 71 inventory). */
  label: string;
  /** 2–4 things a studio owner might type. */
  synonyms: string[];
  /** The route the setting lives on (a group route, or /plans etc.). */
  page: string;
  /** The in-page section id to scroll to. */
  anchor: string;
  /** Owner-only: a manager sees it greyed ("Owner only"). */
  ownerOnly?: boolean;
  /** If set, the setting has its own route and renders as a summary row. */
  standalone?: string;
  /** The studio_settings/membership_plans columns this entry edits (audit). */
  columns?: string[];
};

export const GROUPS: SettingGroup[];
export const SETTINGS: SettingEntry[];
export function searchSettings(query: string): SettingEntry[];
