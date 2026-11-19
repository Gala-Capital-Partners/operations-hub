export type GenerationWindow = { from: string; to: string };
export type DefinitionSchedule = {
  recurrenceRule: string | null;
  startDate: string;
  endDate: string | null;
};
export type GenerationDefinition = DefinitionSchedule & {
  id: string;
  version: string;
  targetTimezones: string[];
};
