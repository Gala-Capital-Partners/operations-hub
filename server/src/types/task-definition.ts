export type TaskDefinitionInput = {
  brandId: string;
  locationId: string | null;
  name: string;
  description: string;
  category: 'Opening' | 'Midday' | 'Closing';
  recurrenceRule: string | null;
  startDate: string;
  endDate: string | null;
  scheduleMode: 'all_day' | 'timed';
  scheduledTimes: string[];
  dueTime: string | null;
  numericUnit: string | null;
  numericMin: number | null;
  numericMax: number | null;
};

/** PostgreSQL row returned by the creation query; dates are formatted in SQL. */
export type TaskDefinitionRow = {
  id: string;
  brand_id: string;
  location_id: string | null;
  created_by: string;
  name: string;
  description: string;
  category: TaskDefinitionInput['category'];
  recurrence_rule: string | null;
  start_date: string;
  end_date: string | null;
  schedule_mode: TaskDefinitionInput['scheduleMode'];
  scheduled_times: string[];
  due_time: string | null;
  numeric_unit: string | null;
  numeric_min: string | null;
  numeric_max: string | null;
  is_active: boolean;
  created_at: Date;
  updated_at: Date;
};
