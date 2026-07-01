# Build Patched PostgreSQL

This artifact provides the RLDP prototype as a patch against PostgreSQL commit
`378668d50b44afb52688988de6651aa8585f3f5c`.

From a PostgreSQL source checkout:

```sh
git checkout 378668d50b44afb52688988de6651aa8585f3f5c
git apply /path/to/rldp-artifact/patches/postgresql-rldp.patch

./configure \
  --prefix=/path/to/install \
  --with-umbra \
  CFLAGS='-O2 -g -fno-omit-frame-pointer'

make -j"$(getconf _NPROCESSORS_ONLN)" world
make install-world
```

Replace `/path/to/rldp-artifact` with this artifact repository path, and replace
`/path/to/install` with the installation prefix that the experiment scripts will
use for `PG_BIN`.
