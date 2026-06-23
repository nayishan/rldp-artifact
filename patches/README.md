# RLDP PostgreSQL Patch

This directory contains the PostgreSQL patch used by the RLDP prototype.

## Base Commit

The patch applies to PostgreSQL commit:

```text
378668d50b44afb52688988de6651aa8585f3f5c
```

The same commit is recorded in `base_commit.txt`.

## Patch File

```text
postgresql-rldp.patch
```

This is a single patch generated from the `chunk-paired-umbra-poc` branch
relative to the base commit above.

## Apply

From a clean PostgreSQL checkout at the base commit:

```sh
git apply /path/to/rldp-artifact/patches/postgresql-rldp.patch
```

Then inspect and commit the applied changes if desired:

```sh
git status --short
```
