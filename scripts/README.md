# Experiment Scripts

Experiment runners are grouped by paper experiment:

- `exp1_first_dirty/`
- `exp2_crash_recovery/`
- `exp3_tpcc/`
- `exp4_capacity/`
- `exp5_locality/`

## Common Setup

Build and install the patched PostgreSQL variants before running these scripts.
The default Linux runners assume:

- user: `jiamingwei`
- base directory: `/home/jiamingwei`
- installed variants under `/home/jiamingwei/<variant>/bin`
- root privileges for data-directory cleanup and Linux page-cache drops

The variant names used by the scripts are:

- `mdonrelease`: PostgreSQL storage with `full_page_writes=on`
- `mdoffrelease`: PostgreSQL storage with `full_page_writes=off`
- `chunk`: Umbra chunk-paired RLDP prototype

Run the scripts on a disposable Linux machine. They create and remove PostgreSQL
data directories under `/home/jiamingwei`, may drop OS page cache, and can run
for many hours.

## Commands

Experiment 1, checkpoint first-dirty WAL attribution:

```sh
sudo bash scripts/exp1_first_dirty/run_checkpoint_first_dirty_linux.sh
```

Output:

```text
/home/jiamingwei/exp1/results/exp1_summary_results.csv
```

Experiment 2, targeted crash-recovery correctness:

```sh
sudo bash scripts/exp2_crash_recovery/run_c2_c3_chunk_linux.sh
```

Output:

```text
/home/jiamingwei/exp2/results/exp2_c2_c3_chunk_summary.csv
```

The runner uses historical case labels `C2` and `C3`. The paper reports these
same obligations as `C1` and `C2`; see `exp2_crash_recovery/README.md`.

Experiment 3, checkpoint-pressure TPC-C:

```sh
sudo bash scripts/exp3_tpcc/run_tpcc_checkpoint_pressure.sh --background
```

Useful status files:

```text
/home/jiamingwei/exp3/results/tpcc_checkpoint_pressure_runner.log
/home/jiamingwei/exp3/results/tpcc_checkpoint_pressure_runner.pid
/home/jiamingwei/exp3/results/tpcc_checkpoint_pressure_summary.csv
```

Use `--foreground` instead of `--background` to keep the run attached to the
current shell.

Experiment 4, sustained space/capacity behavior:

```sh
sudo bash scripts/exp4_capacity/run_exp4_space_reclaim.sh --background
```

Useful status files:

```text
/home/jiamingwei/exp4/results/exp4_space_reclaim_runner.log
/home/jiamingwei/exp4/results/exp4_space_reclaim_runner.pid
/home/jiamingwei/exp4/results/exp4_summary_results.csv
```

Use `--foreground` instead of `--background` for an attached run.

Experiment 5, remap locality cost:

```sh
sudo bash scripts/exp5_locality/run_remap_locality_cost_linux.sh
```

Output:

```text
/home/jiamingwei/exp5/results/exp5_remap_locality_results.txt
```

Hardware and disk report:

```sh
sudo bash scripts/hardware_disk_report.sh
```

Record the generated report under `configs/` before comparing experiment
results across machines.

## Stored Results

Processed result files used by the paper are stored under `results/*/processed`.
They can be inspected without rerunning the experiments.
