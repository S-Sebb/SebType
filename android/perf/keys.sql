-- One row per key tap in a android/perf/perf.sh trace (Perfetto trace_processor), times in ms from the
-- keyboard receiving the touch (ACTION_DOWN on its main thread):
--   handle_ms  main-thread time handling the touch (DOWN + UP dispatch, incl. the engine's sync work)
--   text_ms    until the test field's frame showing the changed text is presented (null: no change)
--   cand_ms    until the frame that drew the candidate bar's last new list before the next tap is
--              presented (its "SebType candidates" section; null: the key left the list as it was)
--   settle_ms  until the keyboard's last frame before the next tap is presented (incl. the key
--              preview's animation)
--   space      what a space or Enter found (its "SebType space" section): the model's ranking "ready" or
--              "waited" for, or the decoder's rule because the ranking was "late", "skipped" or "none"
--   space_ms   how long that space waited for the ranking
-- The model's rankings and next words, one row per job, are in jobs.sql.
--   app_jank   the field's or the keyboard's frames in the window that missed their deadline
--              because of the app itself (SurfaceFlinger-side misses are left out)
with
-- A process forked during the trace can keep zygote64's name; its main thread has the app's name
-- (the last 15 characters).
ime as (select p.upid, p.pid from process p left join thread t on t.upid = p.upid and t.tid = p.pid
  where p.name = 'dev.sebb.sebtype' or t.name = 'ev.sebb.sebtype'),
field as (select p.upid from process p left join thread t on t.upid = p.upid and t.tid = p.pid
  where p.name = 'dev.sebb.sebtype.perffield' or t.name = 'btype.perffield'),
-- Android 14 names a touch's slice only by its event time ("deliverInputEvent src=0x1002
-- eventTimeNano=…"): there a DOWN is the event more than 50 ms after the one before, since monkey's
-- taps put their UP a few ms after the DOWN and taps 100 ms or more apart. That holds only for
-- single-finger taps (no swipe, long press or second finger); perf.sh checks the count against its taps.
ev as (
  select ts, dur, case when a14 then coalesce(event_ns - lag(event_ns) over (order by ts) > 50000000, 1)
    else name like '%ACTION_DOWN%' end as down
  from (select s.ts, s.dur, s.name, s.name like 'deliverInputEvent src=0x1002 %' as a14,
      cast(substr(s.name, instr(s.name, 'eventTimeNano=') + 14) as int) as event_ns
    from slice s join thread_track tt on s.track_id = tt.id join thread t using (utid) join ime using (upid)
    where t.tid = ime.pid and s.depth = 0
      and (s.name like 'dispatchInputEvent MotionEvent ACTION_DOWN%'
        or s.name like 'dispatchInputEvent MotionEvent ACTION_UP%'
        or s.name like 'deliverInputEvent src=0x1002 %'))
),
taps as (
  -- until the next tap, at most 1 s: the last tap of a run must not take in the next field's start
  select ts, min(coalesce(lead(ts) over (order by ts), ts + 1000000000), ts + 1000000000) as next_ts
  from ev where down
),
len as (
  select c.ts from counter c join process_counter_track pct on c.track_id = pct.id
  where pct.name = 'sebperf_len' and pct.upid in (select upid from field)
),
cand as (
  select s.ts from slice s join thread_track tt on s.track_id = tt.id join thread t using (utid)
  where t.upid in (select upid from ime) and s.name = 'SebType candidates'
),
sections as (
  select s.ts, s.dur, s.name, (select c.name from slice c where c.parent_id = s.id) as outcome
  from slice s join thread_track tt on s.track_id = tt.id join thread t using (utid)
  where t.upid in (select upid from ime) and s.name = 'SebType space'
    and s.dur >= 0  -- -1: still open when the trace ended
),
frames as (
  select a.ts, a.ts + a.dur as end_ts, a.upid in (select upid from ime) as is_ime,
    a.jank_type like '%App Deadline Missed%' as app_late
  from actual_frame_timeline_slice a
  where a.upid in (select upid from ime) or a.upid in (select upid from field)
)
select
  taps.ts,
  round((select sum(dur) from ev where ev.ts >= taps.ts and ev.ts < taps.next_ts) / 1e6, 2) as handle_ms,
  round(((select min(f.end_ts) from frames f where not f.is_ime and f.ts >= (
      select min(len.ts) from len where len.ts >= taps.ts and len.ts < taps.next_ts))
    - taps.ts) / 1e6, 1) as text_ms,
  round(((select min(f.end_ts) from frames f where f.is_ime and f.end_ts >= (
      select max(cand.ts) from cand where cand.ts >= taps.ts and cand.ts < taps.next_ts))
    - taps.ts) / 1e6, 1) as cand_ms,
  round(((select max(f.end_ts) from frames f where f.is_ime and f.ts >= taps.ts and f.ts < taps.next_ts)
    - taps.ts) / 1e6, 1) as settle_ms,
  (select sp.outcome from sections sp where sp.name = 'SebType space' and sp.ts >= taps.ts and sp.ts < taps.next_ts)
    as space,
  round((select sp.dur from sections sp where sp.name = 'SebType space' and sp.ts >= taps.ts and sp.ts < taps.next_ts)
    / 1e6, 1) as space_ms,
  (select count(*) from frames f where f.app_late and f.ts >= taps.ts and f.ts < taps.next_ts) as app_jank,
  (select count(*) from frames f where f.ts >= taps.ts and f.ts < taps.next_ts) as frames
from taps order by taps.ts;
