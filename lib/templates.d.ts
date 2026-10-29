export type TemplateAudience = "Members" | "Instructors" | "Staff";
export type TemplateFeature = "flex" | "free_first" | "guest_passes" | "challenges" | "shop" | "guarantees";
export type TemplateKey = {
  key: string;
  label: string;
  audience: TemplateAudience;
  when: string;
  feature?: TemplateFeature;
};
export type TemplateGroup = { title: string; keys: TemplateKey[] };
export const TEMPLATE_GROUPS: TemplateGroup[];
export function isEditableTemplate(key: string): boolean;
export function templateEntry(key: string): TemplateKey | null;
export function templateLabel(key: string): string;
export function templateFeature(key: string): TemplateFeature | null;
export function isTemplateVisible(key: string, features: Set<string>): boolean;
export function featureSet(flags: {
  flex?: boolean; freeFirst?: boolean; guest?: boolean;
  challenges?: boolean; shop?: boolean; guarantees?: boolean;
}): Set<string>;
export function templateKeysForMaster(master: "convert" | "keep" | string): TemplateKey[];
export function placeholdersFrom(...texts: (string | null | undefined)[]): string[];
