export type TaskInstanceStateRow = {
  id: string;
  completed_at: Date | null;
  completed_by: string | null;
  recorded_value: string | null;
  notes: string | null;
};

export type TaskInstanceListRow = TaskInstanceStateRow & {
  name_snapshot: string;
  description_snapshot: string;
  category_snapshot: 'Opening' | 'Midday' | 'Closing';
  scheduled_at: Date;
  // Selected as text so pg does not turn the local calendar day into a Date.
  scheduled_day: string;
  is_all_day_snapshot: boolean;
  timezone_snapshot: string;
  due_time_snapshot: string | null;
  numeric_unit_snapshot: string | null;
  numeric_min_snapshot: string | null;
  numeric_max_snapshot: string | null;
};
