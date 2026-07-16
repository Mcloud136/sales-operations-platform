-- Task 3: 跟进记录增加 start_time / end_time 字段

ALTER TABLE follow_ups ADD COLUMN start_time TIMESTAMPTZ;
ALTER TABLE follow_ups ADD COLUMN end_time   TIMESTAMPTZ;
