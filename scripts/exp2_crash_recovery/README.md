# Experiment 2 Crash-Recovery Scripts

`run_c2_c3_chunk_linux.sh` is the Linux runner used for the current Experiment 2
summary.

The runner keeps its historical case labels:

- runner `C2`: torn-target physical page recovery
- runner `C3`: checkpoint-publication ordering

The paper reports the same two obligations as:

- paper `C1`: damaged target physical page
- paper `C2`: checkpoint publication

The result file `results/exp2_crash_recovery/processed/exp2_c2_c3_chunk_summary.csv`
therefore preserves the runner labels, while the paper table uses the paper
labels.
