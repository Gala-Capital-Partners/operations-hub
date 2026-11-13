export type TaskInstanceStateRow = {
  id: string;
  completed_at: Date | null;
  completed_by: string | null;
  recorded_value: string | null;
  notes: string | null;
};