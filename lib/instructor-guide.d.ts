export interface IntroCard { title: string; body: string }
export interface GuideSection { title: string; go: string; lines: string[] }
export const INTRO_CARDS: IntroCard[];
export const HINTS: { roster: string; pay: string; cover: string };
export const SECTIONS: GuideSection[];
export function fillStudio(text: string, studioName: string): string;
