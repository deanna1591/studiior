export interface GuideRef { kind: "tab" | "button" | "screen"; key: string }
export type GuideRun =
  | { t: "text"; value: string }
  | { t: "ref"; kind: "tab" | "button"; key: string };
export interface IntroCard { title: string; body: string }
export interface GuideHintContent { text: string }
export interface GuideStep { text?: string; screen?: string; caption?: string }
export interface GuideSection {
  title: string;
  go: string;
  important?: string;
  intro?: string;
  steps: GuideStep[];
}
export function splitGuideText(text: string): GuideRun[];
export const INTRO_CARDS: IntroCard[];
export const INTRO_DONE_LABEL: string;
export const HINTS: { roster: GuideHintContent; pay: GuideHintContent; cover: GuideHintContent };
export const SECTIONS: GuideSection[];
export function fillStudio(text: string, studioName: string): string;
