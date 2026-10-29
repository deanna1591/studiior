import type { IconName } from "@/components/member/icons";

export type GuideButtonVariant = "solid" | "tint" | "outline";
export const TABS: Record<string, { icon: IconName }>;
export const BUTTONS: Record<string, GuideButtonVariant>;
export const SCREENS: Record<string, true>;
