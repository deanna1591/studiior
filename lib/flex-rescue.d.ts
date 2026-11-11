export type RescueCard = {
  occurrence_id: string;
  name: string;
  starts_at: string;
  day_label?: string;
  time_label?: string;
  coach_first?: string;
  n_booked: number;
  spots_left: number;
};
export function orderRescueCards(rows: RescueCard[] | null | undefined): RescueCard[];
export function spotsLine(card: { n_booked?: number; spots_left?: number } | undefined): string;
export function moveResultLine(r: { class_name?: string; day?: string; time?: string } | undefined): string;
export const MOVE_REFUSALS: Record<string, string>;
export function refusalSentence(reason: string | null | undefined): string;
