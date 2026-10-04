# gnt

Small Gentoo package/database tools written in Free Pascal.

The common core is `portage.pas`, a read-only parser for the installed Portage
vardb (`/var/db/pkg`). `gntpkg`, `gntorphan`, and `gntfsorphan` read that
database directly and do not invoke Portage commands. `gnt-get` also uses the
vardb for planning, then invokes `emerge` directly with an argument vector to
perform installs, syncs, and unmerges; no command is passed through a shell.

The tools are intentionally simple. They inspect what is *installed now*; they
are not a replacement for Portage's dependency solver.

## Components

| component | purpose |
|---|---|
| `portage.pas` | shared read-only vardb parser and ownership index |
| `tportage.pas` | synthetic/live regression tests for `portage.pas` |
| `gntpkg` | query installed packages, files, reverse dependencies and USE flags |
| `gnt-get` | apt-get-like front end; notably recursive reverse-dependency removal |
| `gntorphan` | find installed packages that nothing else depends on |
| `gntfsorphan` | find filesystem objects that no installed package owns |

## Build

```sh
make
make test
```

or compile an individual program directly, for example:

```sh
fpc gntpkg.pas
fpc gnt-get.pas
```

Free Pascal 3.2.2 or newer is sufficient. No third-party Pascal units are
required.

## Database location

By default the tools read:

```text
/var/db/pkg
```

Set `GNTPKG_DB_PATH` to an absolute path to use another vardb:

```sh
GNTPKG_DB_PATH=/tmp/fake-vardb ./gntpkg list
```

This variable belongs to `gnt`; Portage itself does not define it. It is useful
for tests and recovery work.

---

## gntpkg

Query the installed vardb.

```text
gntpkg list                     list cat/name-version
gntpkg files  <spec>            list paths owned by one installed package
gntpkg belongs <path-or-text>   find the package/file owning a path
gntpkg depends <atom>           list installed reverse dependencies
gntpkg hasuse <flag>            list packages enabling/declaring a USE flag
gntpkg uses   <spec>            list enabled USE flags for a package
gntpkg help
```

Examples:

```sh
gntpkg list
gntpkg files dev-lang/fpc
gntpkg belongs /usr/bin/fpc
gntpkg belongs libQt6Core.so
gntpkg depends fpc
gntpkg depends dev-lang/fpc
gntpkg hasuse wayland
gntpkg uses dev-qt/qtbase
```

`<spec>` can be a bare package name, `cat/pkg`, or an exact installed atom such
as `=app-portage/eix-0.36.9`.

Historical `epkg`-style aliases are kept:

```text
-l, all, --list       -> list
-L, --listfiles       -> files
-S, -s, --search      -> belongs
query                 -> depends
```

The short options are case-sensitive: `-l` lists packages, while `-L` lists the
files of a package.

For an absolute pathname, `belongs` uses the ownership index and understands
merged-/usr aliases such as `/lib64/x` and `/usr/lib64/x`. For non-absolute
text it performs a substring search over recorded `CONTENTS` paths.

`depends` is deliberately conservative. Dependency expressions are reduced to
installed `cat/pkg` names; USE conditionals and `|| ( ... )` alternatives are
flattened. A versioned reverse query is checked against the raw dependency
files and may over-approximate rather than hide a possible dependant.

---

## gnt-get

An apt-get-flavoured front end. The interesting operation is recursive remove.

```text
gnt-get update
gnt-get install <package>... [-d|--download-only]
gnt-get source  <package>... [-d|--download-only]
gnt-get remove  <package>... [-n|--dry-run] [-y|--yes]
```

Examples:

```sh
gnt-get update
gnt-get install dev-lang/fpc
gnt-get install -d dev-lang/fpc
gnt-get remove -n dev-python/electrum-aionostr
gnt-get remove -y dev-python/electrum-aionostr
```

`install` calls `emerge` normally. `-d` uses `emerge -f` and only fetches the
required distfiles. `source` is currently an install alias kept for the old
interface; normal Gentoo `emerge` builds from source unless the user's Portage
binary-package policy/options say otherwise.

### Recursive remove

`remove` finds every installed package that depends on the requested package,
recurses through that reverse dependency graph, prints dependants first, asks
for confirmation, then unmerges exact installed CPVs with `emerge --unmerge`.

Use `-n` first when the graph is non-trivial:

```sh
gnt-get remove -n dev-lang/fpc
```

Important: this is intentionally more conservative than a full Portage solver.
The dependency graph contains `DEPEND`, `RDEPEND`, `PDEPEND`, `BDEPEND`, and
`IDEPEND`; build/install-time relationships therefore count too. USE
conditionals and OR groups are flattened, and slots/alternative providers are
not solved. Consequently recursive remove can schedule more packages than are
strictly necessary. It is a "what declares a dependency on this?" operation,
not `emerge --depclean`.

`gnt-get` looks for `/usr/bin/emerge` first and falls back to `$PATH`. If an
`emerge` invocation fails, `gnt-get` stops immediately instead of continuing a
partial recursive removal.

---

## gntorphan

Find installed packages that have no reverse dependency in the vardb graph.

```text
gntorphan                    library-like package names only (contains "lib")
gntorphan -a                 consider every installed package
gntorphan -c dev-libs        restrict to one category
gntorphan -s                 summary only
```

Example:

```sh
gntorphan -a
gntorphan -a -c dev-python
gntorphan -s
```

A self-dependency does not prevent a package from being reported.

An **orphan is not automatically removable**. `gntorphan` does not read the
world file, profile/system sets, preserved-libs state, or Portage's complete
solver state. Top-level packages that you intentionally installed are expected
to be graph leaves. Treat this command as a query, not as `depclean`.

---

## gntfsorphan

Find filesystem objects under library/program trees that are not claimed by any
installed package's `CONTENTS` file.

```text
gntfsorphan                  unowned ELF objects under the default roots
gntfsorphan -a               every unowned file and symlink
gntfsorphan -r               conservative stale-library removal candidates
gntfsorphan -s               summary only
gntfsorphan -n               skip DT_NEEDED consumer indexing
gntfsorphan -0               NUL-separated path output
gntfsorphan /opt /usr/local  scan explicit roots
```

Default roots:

```text
/usr/lib
/usr/lib64
/usr/libexec
```

`/usr/lib/modules` and `/usr/lib/firmware` are excluded from recursive walks.
The walker uses `lstat`, so it never follows a directory symlink into another
tree.

### Normal report

For an unowned ELF object, `gntfsorphan` reads `DT_SONAME` and `DT_NEEDED` and
may print lines such as:

```text
/usr/lib64/libfoo.so.1.2.3 (soname libfoo.so.1)
    SONAME provider: /usr/lib64/libfoo.so.1.2.4 [owned by dev-libs/foo]
    status: SHADOWED STALE - removal candidate (normal SONAME lookup uses owned provider)
    SONAME referenced by app-misc/bar
```

The important statuses are:

* `SHADOWED STALE` — the orphan's SONAME resolves to a *different*, owned file;
  if the orphan is not mapped, this is the high-confidence stale case.
* `SHADOWED STALE BUT MAPPED` — replacement exists, but this exact old file is
  still mapped by a process; restart/inspect before removing it.
* `REFERENCED UNOWNED PROVIDER` — installed ELF objects name this SONAME and the
  current provider is itself unowned; reconstruct/claim the provider first.
* `UNREFERENCED UNOWNED PROVIDER` — current provider is unowned, but the
  installed ELF scan found no `DT_NEEDED` user. It may still be loaded with
  `dlopen()` or through a plugin mechanism.
* `NO SONAME / DIRECT-LOAD OBJECT` — ordinary SONAME provider reasoning does
  not apply (common for Python extensions, Qt plugins, helper executables,
  etc.).
* `UNRESOLVED SONAME` — no provider was found in the conservative lookup.

`SONAME referenced by ...` is a name match, not proof of the concrete file the
runtime linker selected. `(leaf)` means that the *consumer package* itself has
no reverse dependants.

`[used]` is an informational marker based on `/proc/*/maps`. Safety-critical
removal classification uses the exact canonical pathname; the broad human
marker can also match the basename.

### Conservative removal list

`-r` is the machine-useful mode. It prints **only** paths for which all of the
following are true:

1. the file is unowned;
2. it is an ELF object with a SONAME;
3. that SONAME resolves to a different file;
4. the different provider is owned by an installed package; and
5. the orphan is not currently mapped by a process.

Preview it first:

```sh
gntfsorphan -r
```

Summary only:

```sh
gntfsorphan -r -s
```

If the list has been reviewed, NUL-safe deletion can be done explicitly by the
operator:

```sh
gntfsorphan -r -0 | xargs -0 -r rm -v --
```

`gntfsorphan` itself **never deletes files**.

### `-a` is forensic, not a removal list

`-a` reports every unowned file/symlink under the selected roots. This can
include perfectly legitimate generated state, caches, configuration-created
links, files installed outside Portage (`pip`, `make install`, local scripts),
or remnants of packages whose vardb entry has been lost.

Examples include Python `__pycache__` files, `locale-archive`, loader caches,
eselect/config symlinks, plugin data, and manually installed software.

Therefore do not treat this as equivalent to `-r`:

```sh
# broad investigation
gntfsorphan -a

# NOT recommended as an automatic cleanup rule:
# gntfsorphan -a -0 | xargs -0 rm
```

### Loader-model limits

The SONAME provider check intentionally does not try to reproduce every dynamic
loader rule. In particular it does not prove behavior involving arbitrary
`LD_LIBRARY_PATH`, per-executable `RPATH`/`RUNPATH`, or `dlopen()` of a concrete
filename. Plugin systems can also load an object by pathname even when nothing
has a `DT_NEEDED` entry for it. This is why only the much narrower shadowed-by-
an-owned-provider case is emitted by `-r`.

---

## `portage.pas` behavior

`portage.pas` is read-only and never prints. Callers decide how results are
shown.

Notable behavior:

* scans the category/package layout below the active vardb;
* skips Portage transaction directories such as `-MERGING-*`, `-MERGED-*`,
  `-SAVE-*`, `-CH-*`, and `-CLEAN-*`;
* reads `USE`, `IUSE`, `DEPEND`, `RDEPEND`, `PDEPEND`, `BDEPEND`, `IDEPEND`,
  `SLOT`, `CATEGORY`, and `CONTENTS` as needed;
* normalizes IUSE defaults (`+flag`/`-flag`) to the flag name;
* ignores blockers (`!cat/pkg`, `!!cat/pkg`, `?cat/pkg`) when constructing the
  dependency graph;
* flattens USE-conditional and `|| ( ... )` dependency alternatives;
* stores dependency targets as normalized `cat/pkg` atoms;
* treats versioned reverse-dependency queries conservatively: raw dependency
  text is searched, so a query can produce extra possible dependants rather
  than hide one;
* builds the large file-ownership index lazily;
* discovers merged-/usr aliases from the live filesystem and canonicalizes
  both `CONTENTS` entries and lookup paths through the same alias table;
* reports ownership collisions internally when more than one package records
  the same canonical path.

The dependency representation is intentionally an inspection graph, not a
complete implementation of PMS/Portage dependency resolution.

## Exit status

The query tools use conventional nonzero exits for invalid arguments and failed
lookups. `gnt-get` propagates a failed `emerge` status and stops immediately.

## Safety model

The project separates three kinds of operation:

* **query** — `gntpkg`, `gntorphan`, normal `gntfsorphan`;
* **recommendation** — `gntfsorphan -r` emits a narrow stale-file candidate
  set but still does not delete;
* **mutation** — only `gnt-get` invokes Portage to change installed packages;
  filesystem deletion remains an explicit operator action.

That separation is deliberate: the vardb is useful for recovery and forensic
work precisely because reading it should not silently change the system.
