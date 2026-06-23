# Artifact Guide

## Overview

This artifact supports the paper "Recovery-Lifetime Data Pages for Reducing
Full-Page WAL". It is organized around the paper's evaluation questions:
checkpoint first-dirty WAL attribution, targeted crash recovery, end-to-end
TPC-C behavior, capacity cost, and locality cost.

## Reproduction Status

The artifact is under preparation. Final commands, expected outputs, and
environment requirements will be added before the full-paper deadline.

## Expected Layout

- `patches/` contains the prototype patch or links to exact implementation
  commits.
- `scripts/` contains experiment runners grouped by experiment.
- `configs/` records PostgreSQL, benchmark, and machine configuration.
- `results/` stores raw logs and processed summaries.
- `analysis/` stores parsers and summarization scripts.
