-- One row per job of the English or Chinese model in a android/perf/perf.sh trace (Perfetto trace_processor),
-- from the engines' trace sections (#320, #264): job "rank" (a ranking of the letters typed) or "next" (next
-- words, the worker's other job, which a ranking asked for meanwhile waits behind), "zh rank" and "zh next"
-- for 中文's model, "zh fixes" (Rime's typo corrections looked up on the keyboard's thread, #478) and "zh fix"
-- (the model weighing them), and its time in ms. Jobs still running when the trace ended are left out.
with ime as (select p.upid from process p left join thread t on t.upid = p.upid and t.tid = p.pid
  where p.name = 'dev.sebb.sebtype' or t.name = 'ev.sebb.sebtype')
select substr(s.name, 9) as job, round(s.dur / 1e6, 1) as ms
from slice s join thread_track tt on s.track_id = tt.id join thread t using (utid)
where t.upid in (select upid from ime) and s.name in ('SebType rank', 'SebType next', 'SebType zh rank', 'SebType zh next', 'SebType zh fixes', 'SebType zh fix') and s.dur >= 0
order by s.ts;
