# RLDP PVLDB Volume 20 Artifact

This repository contains supplemental material for the PVLDB submission
"Recovery-Lifetime Data Pages for Reducing Full-Page WAL".

The artifact includes prototype patches, experiment scripts, configuration
files, result-processing utilities, and selected stored summaries used for
the paper evaluation.

## Contents

- `patches/`: PostgreSQL/RLDP prototype patch or implementation reference.
- `scripts/`: experiment runners for checkpoint first-dirty WAL attribution,
  crash recovery, TPC-C, capacity, and locality measurements.
- `configs/`: database, benchmark, and machine configuration notes.
- `results/`: stored experiment summaries used by the paper.
- `analysis/`: scripts for parsing logs and producing summary tables.
- `figures/`: generated figures and table inputs.
- `docs/`: build and reproduction instructions.

## Build

To build the patched PostgreSQL prototype from the baseline commit, see
`docs/BUILD.md`.

## Status

This artifact is being completed for the PVLDB full-paper submission. The
repository will be updated with final scripts, results, and reproduction
instructions before the full-paper deadline.
