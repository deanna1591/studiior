export interface GuideRef { kind: "tab" | "button" | "screen"; key: string }
export interface IntroCard { title: string; body: string; refs: GuideRef[] }
export interface GuideHintContent { text: string; refs: GuideRef[] }
export interface GuideStep { text?: string; refs?: GuideRef[]; screen?: string; caption?: string }
export interface GuideSection {
  title: string;
  go: string;
  important?: string;
  intro?: string;
  steps: GuideStep[];
}
export const INTRO_CARDS: IntroCard[];
export const INTRO_DONE_LABEL: string;
export const HINTS: { roster: GuideHintContent; pay: GuideHintContent; cover: GuideHintContent };
export const SECTIONS: GuideSection[];
export function fillStudio(text: string, studioName: string): string;
