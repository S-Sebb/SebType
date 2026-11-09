-- Keyboard opens in a sebtype/perf.sh trace (Perfetto trace_processor), one row per open: from the
-- request to the end of the keyboard's first frame on screen after it, in ms.
--   first  the test field's first frame (first open after install)
--   warm   a tap on the test field (its main thread's ACTION_UP)
--   cold   a keyboard process starting during the trace (it runs bindApplication), from its
--          first scheduled moment
-- Frames and slices only: ImeTracker's log lines are missing on some phones (Android 16 user builds).
with
-- A process forked during the trace can keep zygote64's name; its main thread has the app's name
-- (the last 15 characters).
ime as (select p.upid from process p left join thread t on t.upid = p.upid and t.tid = p.pid
  where p.name = 'dev.sebb.sebtype' or t.name = 'ev.sebb.sebtype'),
field as (select p.upid, p.pid from process p left join thread t on t.upid = p.upid and t.tid = p.pid
  where p.name = 'dev.sebb.sebtype.perffield' or t.name = 'btype.perffield'),
ime_frames as (
  select a.ts, a.ts + a.dur as end_ts from actual_frame_timeline_slice a
  where a.upid in (select upid from ime)
),
req as (
  select 'first' as kind, min(a.ts) as ts from actual_frame_timeline_slice a
  where a.upid in (select upid from field) group by a.upid
  union all
  select 'warm', s.ts
  from slice s join thread_track tt on s.track_id = tt.id join thread t using (utid) join field using (upid)
  where t.tid = field.pid and s.depth = 0 and s.name like 'dispatchInputEvent MotionEvent ACTION_UP%'
  union all
  select 'cold', min(ss.ts) from sched_slice ss join thread t using (utid)
  where t.upid in (select p.upid from ime p join thread m on m.upid = p.upid
    join thread_track tt on tt.utid = m.utid join slice s on s.track_id = tt.id
    where s.name = 'bindApplication')
  group by t.upid
)
select kind, round(((select min(end_ts) from ime_frames f where f.ts >= req.ts) - req.ts) / 1e6) as ms
from req where ts is not null order by req.ts;
