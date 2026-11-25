# WIP (#556): r4 retrain evaluation scripts, handed off mid-task. Not for merging: delete this folder before the PR.

All paths below are on yanglab16 under ~/scratch/SebType/556/.
- r4code/: rsync of main 2e5652532c used for prepare/train/select. r4run/: the run (data, ckpt/r4, select/).
- eval/: these scripts; eval/main, eval/pr568 (12112507db) and eval/pr568x (#568 + pr568x-toggles.patch:
  SEBTYPE_CAP, SEBTYPE_BARE_HINT env toggles) trees with 539-tests.patch applied; eval/sets/ the probe sets
  (#561's 154-row contractions, homographs, lone-i, next-contr; owner.tsv the owner's rows; h-* the harness's).
- probe.sh TREE MODEL OUT [SETS]: core + model-only stacks; cmp.py OUT...: tables. sweep.sh MODEL LABEL: cap/hint
  sweep on pr568x. sel-live.sh / sel-b.sh: select.sh evaluating checkpoints as they appear (two lanes),
  using r4code/tools/english-lm/dev-nolock.sh (dev.sh with eval/main's prebuilt harness binary).
