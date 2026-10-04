// gntfsorphan - files on disk that no installed package owns.
//
// This is the file-level companion to gntorphan. It walks the library
// directories, compares every file against the ownership index built from
// CONTENTS, and reports the leftovers - by default only ELF objects, because
// those are the ones that matter when a package is unmerged: a shared library
// nobody links any more is dead weight, and a shared library some other package
// still links is not (and is the reason not to run "rm" blindly).
//
// It is deliberately *report-only*. Deleting files the package manager does not
// know about is a good way to break a system, so that decision stays with the
// operator.
//
//   gntfsorphan                    orphaned ELF objects under the lib dirs
//   gntfsorphan -a                 every unowned file, not just ELF
//   gntfsorphan /opt               scan a specific root
//   gntfsorphan -s                 summary only
//
// For each ELF object it prints which installed packages reference its SONAME in
// DT_NEEDED.  For shared libraries it also resolves the SONAME through the usual
// library symlink and classifies the orphan as the active provider, a shadowed
// stale copy, or unresolved.  This is deliberately conservative: dlopen() of an
// exact filename and unusual per-binary RPATH/RUNPATH rules are not proven by this
// check.  "[used]" means a running process currently maps the exact file according
// to /proc/<pid>/maps.

program gntfsorphan;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, StrUtils, BaseUnix, portage;

const
  DefaultRoots: array[0..2] of string =
    ('/usr/lib', '/usr/lib64', '/usr/libexec');

  // Only these trees are expected to hold ELF objects; restricting the
  // consumer scan to them avoids opening every documentation and Python file
  // in the database (there are hundreds of thousands of those).
  BinaryPrefixes: array[0..8] of string =
    ('/usr/bin/', '/usr/sbin/', '/usr/lib/', '/usr/lib64/', '/usr/libexec/',
     '/bin/', '/sbin/', '/lib/', '/lib64/');

  // Never cross into these: kernel/pseudo filesystems and scratch space, plus
  // the kernel build/module and firmware trees. Those hold tens of thousands of
  // ELF objects that are not usefully "orphaned" and swamp the real debris.
  ExcludedPrefixes: array[0..8] of string =
    ('/proc', '/sys', '/dev', '/run', '/tmp', '/var/tmp', '/var/cache',
     '/usr/lib/modules', '/usr/lib/firmware');

var
  DB: TPortageDB;
  InUse: TStringList;        // sorted; full paths and basenames from /proc maps
  Consumers: TStringList;    // sorted; Name = needed object, Objects = TStringList of CPVs
  DependedOn: TStringList;   // sorted; "cat/pkg" that some package depends on
  OptAll: Boolean;
  Summary: Boolean;
  NoConsumers: Boolean;
  Print0: Boolean;
  RemoveOnly: Boolean;      // print only high-confidence stale removal candidates
  Total, Used, RemoveCandidates: integer;

// --- small filesystem helpers ----------------------------------------------

function IsExcluded(const APath: string): boolean;
var
  i: integer;
  p: string;
begin
  p := IncludeTrailingPathDelimiter(APath);
  for i := Low(ExcludedPrefixes) to High(ExcludedPrefixes) do
    if (APath = ExcludedPrefixes[i]) or
       (Copy(p, 1, Length(ExcludedPrefixes[i]) + 1) = ExcludedPrefixes[i] + '/') then
      exit(True);
  Result := False;
end;

function IsBinaryPath(const APath: string): boolean;
var
  i: integer;
begin
  for i := Low(BinaryPrefixes) to High(BinaryPrefixes) do
    if Copy(APath, 1, Length(BinaryPrefixes[i])) = BinaryPrefixes[i] then
      exit(True);
  Result := False;
end;

// map lines look like:
//   7f...-7f... r-xp 00000000 fd:01 123456 /usr/lib64/libc.so.6
// The pathname is everything after the inode column and may contain spaces.
procedure CollectInUse;
var
  sr: TSearchRec;
  sl: TStringList;
  i, j, field: integer;
  line, pid, path, maps: string;
begin
  InUse.Sorted := True;
  InUse.Duplicates := dupIgnore;
  if FindFirst('/proc/*', faDirectory, sr) <> 0 then exit;
  try
    repeat
      pid := sr.Name;
      if (pid = '.') or (pid = '..') or (pid = '') or
         not (pid[1] in ['0'..'9']) then continue;
      maps := '/proc/' + pid + '/maps';
      if not FileExists(maps) then continue;
      sl := TStringList.Create;
      try
        try
          sl.LoadFromFile(maps);
        except
          continue;
        end;
        for i := 0 to sl.Count - 1 do
        begin
          line := sl[i];
          field := 0;
          j := 1;
          while (j <= Length(line)) and (field < 5) do
          begin
            while (j <= Length(line)) and (line[j] = ' ') do Inc(j);
            while (j <= Length(line)) and (line[j] <> ' ') do Inc(j);
            Inc(field);
          end;
          while (j <= Length(line)) and (line[j] = ' ') do Inc(j);
          if j > Length(line) then continue;
          path := Copy(line, j, Length(line));
          InUse.Add(CanonicalPath(path));
          InUse.Add(ExtractFileName(path));
        end;
      finally
        sl.Free;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

// --- minimal ELF reader -----------------------------------------------------

// Extracts DT_NEEDED entries and DT_SONAME from a 32/64-bit little-endian ELF
// object. Returns False for anything it cannot parse, in which case the caller
// treats the file as an opaque blob.
function RdU16(const B: TBytes; const off: QWord): cardinal; inline;
begin
  Result := B[off] or (B[off + 1] shl 8);
end;

function RdU32(const B: TBytes; const off: QWord): cardinal; inline;
begin
  Result := cardinal(B[off]) or (cardinal(B[off + 1]) shl 8) or
            (cardinal(B[off + 2]) shl 16) or (cardinal(B[off + 3]) shl 24);
end;

function RdU64(const B: TBytes; const off: QWord): QWord; inline;
begin
  Result := QWord(RdU32(B, off)) or (QWord(RdU32(B, off + 4)) shl 32);
end;

function BytesToStr(const B: TBytes; const AOff: QWord): string;
var
  start, j: QWord;
begin
  Result := '';
  if AOff >= QWord(Length(B)) then exit;
  start := AOff;
  j := start;
  while (j < QWord(Length(B))) and (B[j] <> 0) do Inc(j);
  SetLength(Result, j - start);
  if j > start then
    Move(B[start], Result[1], j - start);
end;

// Extracts DT_NEEDED entries and DT_SONAME from a 32/64-bit little-endian ELF
// object. Only the ELF header, the program headers, the dynamic section and a
// bounded window of the string table are read, so multi-megabyte binaries do
// not have to be slurped whole. Returns False for anything it cannot parse, in
// which case the caller treats the file as an opaque blob.
function ParseElf(const APath: string; Needs: TStringList; out Soname: string): boolean;
const
  PT_LOAD = 1;
  PT_DYNAMIC = 2;
  DT_NULL = 0;
  DT_NEEDED = 1;
  DT_STRTAB = 5;
  DT_SONAME = 14;
  StrWindow = 1 shl 20;   // 1 MiB is far more than any real NEEDED list
type
  TLoad = record
    Vaddr, Offset, Filesz: QWord;
  end;
var
  fs: TFileStream;
  Hdr, Ph, Dyn, Str: TBytes;
  fsize, phbytes: QWord;
  is64: boolean;
  phoff, phentsize, phnum: QWord;
  loads: array of TLoad;
  nloads, i: integer;
  phbase: QWord;
  ptype: cardinal;
  poffset, pvaddr, pfilesz: QWord;
  dynoff, dynsize: QWord;
  strtab_vaddr, strtab_off, strchunk: QWord;
  dtag, dval: QWord;
  ent, entoff: QWord;
begin
  Result := False;
  Needs.Clear;
  Soname := '';

  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    exit;
  end;
  try
    fsize := fs.Size;
    if fsize < 52 then exit;

    // The 64-bit header reaches offset 58, so a 52-byte read is not enough.
    if fsize >= 64 then
      SetLength(Hdr, 64)
    else
      SetLength(Hdr, 52);
    fs.ReadBuffer(Hdr[0], Length(Hdr));
    if (Hdr[0] <> $7f) or (Hdr[1] <> Ord('E')) or (Hdr[2] <> Ord('L')) or
       (Hdr[3] <> Ord('F')) then exit;
    if Hdr[5] <> 1 then exit;                 // little-endian only
    is64 := Hdr[4] = 2;
    if not is64 and (Hdr[4] <> 1) then exit;
    if is64 and (Length(Hdr) < 64) then exit;

    if is64 then
    begin
      phoff := RdU64(Hdr, 32);
      phentsize := RdU16(Hdr, 54);
      phnum := RdU16(Hdr, 56);
    end
    else
    begin
      phoff := RdU32(Hdr, 28);
      phentsize := RdU16(Hdr, 42);
      phnum := RdU16(Hdr, 44);
    end;

    if (phnum = 0) or (phentsize = 0) or (phoff >= fsize) then exit;
    phbytes := phnum * phentsize;
    if phoff + phbytes > fsize then phbytes := fsize - phoff;
    if phbytes < phentsize then exit;

    SetLength(Ph, phbytes);
    fs.Position := phoff;
    fs.ReadBuffer(Ph[0], phbytes);

    SetLength(loads, phnum);
    nloads := 0;
    dynoff := 0;
    dynsize := 0;
    i := 0;
    while (QWord(i) < phnum) and (QWord(i) * phentsize + phentsize <= phbytes) do
    begin
      phbase := QWord(i) * phentsize;
      ptype := RdU32(Ph, phbase);
      if is64 then
      begin
        poffset := RdU64(Ph, phbase + 8);
        pvaddr := RdU64(Ph, phbase + 16);
        pfilesz := RdU64(Ph, phbase + 32);
      end
      else
      begin
        poffset := RdU32(Ph, phbase + 4);
        pvaddr := RdU32(Ph, phbase + 8);
        pfilesz := RdU32(Ph, phbase + 16);
      end;

      if ptype = PT_LOAD then
      begin
        loads[nloads].Offset := poffset;
        loads[nloads].Vaddr := pvaddr;
        loads[nloads].Filesz := pfilesz;
        Inc(nloads);
      end
      else if ptype = PT_DYNAMIC then
      begin
        dynoff := poffset;
        dynsize := pfilesz;
      end;
      Inc(i);
    end;

    if (dynoff = 0) or (dynsize = 0) or (dynoff >= fsize) then exit;
    if dynoff + dynsize > fsize then dynsize := fsize - dynoff;

    SetLength(Dyn, dynsize);
    fs.Position := dynoff;
    fs.ReadBuffer(Dyn[0], dynsize);

    ent := 16;
    if not is64 then ent := 8;

    // First pass: the string table virtual address.
    strtab_vaddr := 0;
    entoff := 0;
    while entoff + ent <= dynsize do
    begin
      if is64 then
      begin
        dtag := RdU64(Dyn, entoff);
        dval := RdU64(Dyn, entoff + 8);
      end
      else
      begin
        dtag := RdU32(Dyn, entoff);
        dval := RdU32(Dyn, entoff + 4);
      end;
      if dtag = DT_NULL then break;
      if dtag = DT_STRTAB then strtab_vaddr := dval;
      Inc(entoff, ent);
    end;

    if strtab_vaddr = 0 then exit;
    strtab_off := 0;
    for i := 0 to nloads - 1 do
      if (strtab_vaddr >= loads[i].Vaddr) and
         (strtab_vaddr < loads[i].Vaddr + loads[i].Filesz) then
      begin
        strtab_off := loads[i].Offset + (strtab_vaddr - loads[i].Vaddr);
        break;
      end;
    if (strtab_off = 0) or (strtab_off >= fsize) then exit;

    strchunk := fsize - strtab_off;
    if strchunk > StrWindow then strchunk := StrWindow;
    SetLength(Str, strchunk);
    fs.Position := strtab_off;
    fs.ReadBuffer(Str[0], strchunk);

    // Second pass: the names.
    entoff := 0;
    while entoff + ent <= dynsize do
    begin
      if is64 then
      begin
        dtag := RdU64(Dyn, entoff);
        dval := RdU64(Dyn, entoff + 8);
      end
      else
      begin
        dtag := RdU32(Dyn, entoff);
        dval := RdU32(Dyn, entoff + 4);
      end;
      if dtag = DT_NULL then break;
      if dtag = DT_NEEDED then
        Needs.Add(BytesToStr(Str, dval))
      else if dtag = DT_SONAME then
        Soname := BytesToStr(Str, dval);
      Inc(entoff, ent);
    end;

    Result := True;
  finally
    fs.Free;
  end;
end;

// Read the four magic bytes through a stream: the untyped Reset path depends
// on the global FileMode, whose default is read/write and therefore fails on
// the root-owned, read-only files that make up most of /usr.
function IsElfMagic(const APath: string): boolean;
var
  fs: TFileStream;
  magic: array[0..3] of byte;
begin
  Result := False;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    exit;
  end;
  try
    if fs.Size < 4 then exit;
    fs.ReadBuffer(magic, 4);
    Result := (magic[0] = $7f) and (magic[1] = Ord('E')) and
              (magic[2] = Ord('L')) and (magic[3] = Ord('F'));
  finally
    fs.Free;
  end;
end;

// --- consumer / orphan bookkeeping -----------------------------------------

procedure AddConsumer(const ANeeded, ACpv: string);
var
  idx: integer;
  l: TStringList;
begin
  if ANeeded = '' then exit;
  idx := Consumers.IndexOf(ANeeded);
  if idx < 0 then
  begin
    l := TStringList.Create;
    l.Sorted := True;
    l.Duplicates := dupIgnore;
    Consumers.AddObject(ANeeded, l);
    idx := Consumers.IndexOf(ANeeded);
  end;
  TStringList(Consumers.Objects[idx]).Add(ACpv);
end;

function ConsumersOf(const ANeeded: string): TStringList;
var
  idx: integer;
begin
  idx := Consumers.IndexOf(ANeeded);
  if idx < 0 then
    Result := nil
  else
    Result := TStringList(Consumers.Objects[idx]);
end;

// A package is orphaned when no *other* package depends on it (same rule as
// gntorphan). The bare cat/pkg atoms in DependAtoms are exactly the names that
// count as "depended on".
procedure BuildDependedOn;
var
  i, j: integer;
  p: TPkgInfo;
begin
  DependedOn.Sorted := True;
  DependedOn.Duplicates := dupIgnore;
  for i := 0 to DB.Count - 1 do
  begin
    p := TPkgInfo(DB.Packages[i]);
    for j := 0 to p.DependAtoms.Count - 1 do
      if p.DependAtoms[j] <> p.Atom then
        DependedOn.Add(p.DependAtoms[j]);
  end;
end;

function IsOrphanAtom(const AAtom: string): boolean;
begin
  Result := DependedOn.IndexOf(AAtom) < 0;
end;

// Walks every installed ELF object once and records which DT_NEEDED names it
// references. This is what turns "this library is unowned" into "and app/bar,
// which is itself an orphan, is the last thing that links it".
procedure BuildConsumers;
var
  i, j, k: integer;
  p: TPkgInfo;
  path: string;
  needs: TStringList;
  soname: string;
begin
  needs := TStringList.Create;
  try
    for i := 0 to DB.Count - 1 do
    begin
      p := TPkgInfo(DB.Packages[i]);
      p.LoadContents;
      for j := 0 to p.Contents.Count - 1 do
      begin
        path := p.Contents[j];
        if not IsBinaryPath(path) then continue;
        if not IsElfMagic(path) then continue;
        if ParseElf(path, needs, soname) then
          for k := 0 to needs.Count - 1 do
            AddConsumer(needs[k], p.Atom);
      end;
    end;
  finally
    needs.Free;
  end;
end;

// --- the walk ---------------------------------------------------------------

// Defined below Report, beside the other filesystem helpers.
function ResolveSonameProvider(const APath, ASoname: string): string; forward;

procedure Report(const APath: string);
var
  isUsed, isMappedExact, isLink, isElf, isRemovalCandidate: boolean;
  target, soname, line, neededName, provider, providerNote, status: string;
  needs, cons: TStringList;
  owner: TPkgInfo;
  k: integer;
begin
  Inc(Total);
  isRemovalCandidate := False;

  // Historical machine-readable mode: without -r, -0 emits every orphan and
  // deliberately skips the expensive classification/reporting work.  With
  // -r, classification must run first so only safe removal candidates are
  // emitted below.
  if Print0 and not RemoveOnly then
  begin
    Write(APath);
    Write(#0);
    exit;
  end;

  // Keep the historical broad [used] marker (full path or basename), but use
  // the exact pathname for safety-critical classifications below.  Two
  // unrelated plugins can easily share the same basename.
  isMappedExact := InUse.IndexOf(CanonicalPath(APath)) >= 0;
  isUsed := isMappedExact or
            (InUse.IndexOf(ExtractFileName(APath)) >= 0);
  if isUsed then Inc(Used);

  isLink := False;
  {$I-}
  target := fpReadLink(APath);
  {$I+}
  if target <> '' then isLink := True;

  needs := nil;
  soname := '';
  isElf := (not isLink) and IsElfMagic(APath);
  if isElf then
  begin
    needs := TStringList.Create;
    ParseElf(APath, needs, soname);
  end;

  neededName := soname;
  if neededName = '' then
    neededName := ExtractFileName(APath);

  if Summary and not RemoveOnly then
  begin
    if needs <> nil then needs.Free;
    exit;
  end;

  line := APath;
  if isUsed then line := line + ' [used]';
  if isLink then line := line + ' -> ' + target;
  if (soname <> '') and (soname <> ExtractFileName(APath)) then
    line := line + ' (soname ' + soname + ')';
  if not RemoveOnly then
    WriteLn(line);

  // Determine the reference set once.  DT_NEEDED names a SONAME, not this
  // concrete filename.  Consumers therefore tell us whether the SONAME is
  // referenced somewhere, while the provider check below tells us which file
  // normal lookup would actually select today.
  cons := nil;
  if (not NoConsumers) and (not RemoveOnly) then
    cons := ConsumersOf(neededName);

  if isElf then
  begin
    if soname <> '' then
    begin
      provider := ResolveSonameProvider(APath, soname);
      if provider <> '' then
      begin
        owner := DB.OwnerOf(provider);
        if owner <> nil then
          providerNote := ' [owned by ' + owner.Atom + ']'
        else
          providerNote := ' [unowned]';
        if not RemoveOnly then
          WriteLn('    SONAME provider: ', provider, providerNote);

        if CanonicalPath(ExpandFileName(provider)) =
           CanonicalPath(ExpandFileName(APath)) then
        begin
          if owner <> nil then
            status := 'ACTIVE OWNED - ownership index/path canonicalization needs checking'
          else if isMappedExact then
            status := 'MAPPED UNOWNED - exact file is mapped now; reconstruct/claim it; do not delete'
          else if NoConsumers then
            status := 'UNOWNED PROVIDER - consumer scan disabled; inspect/reconstruct before removal'
          else if (cons <> nil) and (cons.Count > 0) then
            status := 'REFERENCED UNOWNED PROVIDER - installed ELF objects reference this SONAME; reconstruct/claim before removal'
          else
            status := 'UNREFERENCED UNOWNED PROVIDER - current provider, but no installed ELF DT_NEEDED reference found; inspect for dlopen/plugins before removal';
        end
        else if owner <> nil then
        begin
          if isMappedExact then
            status := 'SHADOWED STALE BUT MAPPED - exact old file is mapped now; inspect/restart process before removal'
          else
          begin
            status := 'SHADOWED STALE - removal candidate (normal SONAME lookup uses owned provider)';
            isRemovalCandidate := True;
          end;
        end
        else
        begin
          if isMappedExact then
            status := 'SHADOWED BY UNOWNED PROVIDER, OLD FILE MAPPED - inspect both files before removal'
          else
            status := 'SHADOWED BY UNOWNED PROVIDER - inspect/reconstruct provider first';
        end;
      end
      else
        status := 'UNRESOLVED SONAME - no default provider found; inspect manually';

      if not RemoveOnly then
        WriteLn('    status: ', status);
    end
    else
    begin
      // Many plugin/module objects intentionally have no DT_SONAME and are
      // loaded by pathname or plugin discovery rather than ordinary linker
      // SONAME lookup.  Calling these ACTIVE merely because the file resolves
      // to itself is misleading.
      if isMappedExact then
        status := 'MAPPED UNOWNED DIRECT-LOAD OBJECT - exact file is mapped now; do not delete'
      else
        status := 'NO SONAME / DIRECT-LOAD OBJECT - provider logic not applicable; inspect plugin/module ownership';
      if not RemoveOnly then
        WriteLn('    status: ', status);
    end;
  end;

  if (not RemoveOnly) and (not NoConsumers) and (cons <> nil) then
    for k := 0 to cons.Count - 1 do
      // This is only a SONAME/DT_NEEDED name match.  The provider/status
      // lines above say what normal current lookup resolves that SONAME to.
      // "(leaf)" is package-level: nothing installed depends on that package.
      WriteLn('    SONAME referenced by ', cons[k],
              IfThen(IsOrphanAtom(cons[k]), ' (leaf)'));

  // -r is intentionally conservative.  A path qualifies only when this exact
  // orphan is not mapped, its SONAME resolves to a *different* file, and that
  // provider is owned by an installed package.  No automatic deletion occurs.
  if isRemovalCandidate then
  begin
    Inc(RemoveCandidates);
    if RemoveOnly and not Summary then
    begin
      if Print0 then
      begin
        Write(APath);
        Write(#0);
      end
      else
        WriteLn(APath);
    end;
  end;

  if needs <> nil then needs.Free;
end;

// Whether a path resolves to something on disk. FileExists() is not usable
// here: a symlink to a *directory* resolves fine but FPC's FileExists returns
// false for directories, which would make a valid symlink look dangling.
function TargetExists(const APath: string): boolean;
var
  st: stat;
begin
  Result := FpStat(APath, st) = 0;
end;


// Merged-/usr path identity is delegated to portage.pas so this tool follows
// the same dynamically discovered alias table as the ownership index.  On a
// split-/usr system CanonicalPath is the identity.

// Resolve the last-component symlink chain without invoking external tools.
// This is enough for the normal libfoo.so.N -> libfoo.so.N.x.y layout.  The
// directory itself may be a merged-/usr alias; CanonicalPath handles that.
function ResolveLinkChain(const APath: string): string;
var
  cur, target: string;
  st: stat;
  hops: integer;
begin
  Result := '';
  cur := ExpandFileName(APath);
  for hops := 0 to 31 do
  begin
    if FpLStat(cur, st) <> 0 then exit;
    if not FPS_ISLNK(st.st_mode) then
    begin
      Result := CanonicalPath(ExpandFileName(cur));
      exit;
    end;

    {$I-}
    target := fpReadLink(cur);
    {$I+}
    if target = '' then exit;

    if target[1] = '/' then
      cur := ExpandFileName(target)
    else
      cur := ExpandFileName(IncludeTrailingPathDelimiter(ExtractFileDir(cur)) + target);
  end;
end;

// Resolve the default provider for SONAME.  Prefer the orphan's own directory
// (which catches the normal Gentoo layout), then the standard library dirs.
// This is not a complete ld.so implementation: it deliberately does not claim
// to model every executable's DT_RPATH/DT_RUNPATH or LD_LIBRARY_PATH.
function ResolveSonameProvider(const APath, ASoname: string): string;
const
  StdDirs: array[0..3] of string =
    ('/usr/lib64', '/usr/lib', '/lib64', '/lib');
var
  i: integer;
  candidate, resolved: string;
begin
  Result := '';
  if ASoname = '' then exit;

  // Prefer the orphan's own directory, then the standard directories.
  candidate := IncludeTrailingPathDelimiter(ExtractFileDir(APath)) + ASoname;
  if TargetExists(candidate) then
  begin
    resolved := ResolveLinkChain(candidate);
    if resolved <> '' then
    begin
      Result := resolved;
      exit;
    end;
  end;

  for i := Low(StdDirs) to High(StdDirs) do
  begin
    candidate := IncludeTrailingPathDelimiter(StdDirs[i]) + ASoname;
    if not TargetExists(candidate) then continue;
    resolved := ResolveLinkChain(candidate);
    if resolved <> '' then
    begin
      Result := resolved;
      exit;
    end;
  end;
end;

// Enumerates with opendir/readdir, not FindFirst. On Unix FindFirst calls
// stat() on each entry, which (a) reports a symlink to a directory as a plain
// directory with no faSymLink bit, so the walk descended through owned aliases
// such as /usr/lib/rust/lib-bin-1.97.1 -> /opt/rust-bin-1.97.1/lib and invented
// unowned paths no CONTENTS mentions, and (b) silently drops entries whose
// target does not exist, so dangling symlinks were never even seen. readdir
// returns the raw entries; lstat then tells us what each one really is.
procedure Walk(const ADir: string);
var
  d: pDir;
  ent: pDirent;
  name, path: string;
  st: stat;
begin
  if IsExcluded(ADir) then exit;
  d := FpOpendir(PChar(ADir));
  if d = nil then exit;
  try
    while True do
    begin
      ent := FpReaddir(d^);
      if ent = nil then break;
      name := StrPas(@ent^.d_name);
      if (name = '.') or (name = '..') then continue;
      path := IncludeTrailingPathDelimiter(ADir) + name;

      if FpLStat(path, st) <> 0 then
        continue;

      if FPS_ISLNK(st.st_mode) then
      begin
        // Never descend, whatever the target is. By default only a dangling
        // symlink is worth reporting; -a also reports valid but unowned ones
        // (config/eselect convenience links).
        if not DB.IsOwned(path) and (OptAll or not TargetExists(path)) then
          Report(path);
        continue;
      end;

      if FPS_ISDIR(st.st_mode) then
        Walk(path)
      else if not DB.IsOwned(path) then
      begin
        if OptAll or IsElfMagic(path) then
          Report(path);
      end;
    end;
  finally
    FpClosedir(d^);
  end;
end;

procedure Usage;
begin
  WriteLn('gntfsorphan 1.3 - report files that no installed package owns');
  WriteLn;
  WriteLn('usage: gntfsorphan [options] [directory...]');
  WriteLn;
  WriteLn('  default roots: /usr/lib /usr/lib64 /usr/libexec');
  WriteLn('  -a, --all             report every unowned file and symlink, not just ELF');
  WriteLn('  -n, --no-consumers    skip the installed-ELF consumer scan');
  WriteLn('  -0, --print0          emit only NUL-terminated paths (for xargs -0)');
  WriteLn('  -r, --removal-candidates');
  WriteLn('                        print only conservative removal-candidate paths');
  WriteLn('  -s, --summary         print only a count');
  WriteLn('  -h, --help            this text');
  WriteLn;
  WriteLn('Removal candidates are only orphan shared libraries shadowed by a');
  WriteLn('different owned SONAME provider and not currently mapped.');
  WriteLn('This tool only reports; it never deletes anything.');
  WriteLn('The database can be overridden with $', DBEnvVar, '.');
end;

var
  i: integer;
  roots: TStringList;
begin
  OptAll := False;
  Summary := False;
  NoConsumers := False;
  Print0 := False;
  RemoveOnly := False;
  roots := TStringList.Create;
  try
    for i := 1 to ParamCount do
    begin
      if (ParamStr(i) = '-h') or (ParamStr(i) = '--help') then
      begin
        Usage;
        Halt(0);
      end
      else if (ParamStr(i) = '-a') or (ParamStr(i) = '--all') then
        OptAll := True
      else if (ParamStr(i) = '-n') or (ParamStr(i) = '--no-consumers') then
        NoConsumers := True
      else if (ParamStr(i) = '-s') or (ParamStr(i) = '--summary') then
        Summary := True
      else if (ParamStr(i) = '-0') or (ParamStr(i) = '--print0') then
        Print0 := True
      else if (ParamStr(i) = '-r') or (ParamStr(i) = '--removal-candidates') then
        RemoveOnly := True
      else if (ParamStr(i) <> '') and (ParamStr(i)[1] = '-') then
      begin
        WriteLn(StdErr, 'gntfsorphan: unknown option ''', ParamStr(i), '''');
        Usage;
        Halt(2);
      end
      else
        roots.Add(ParamStr(i));
    end;

    if roots.Count = 0 then
      for i := Low(DefaultRoots) to High(DefaultRoots) do
        roots.Add(DefaultRoots[i]);

    DB := TPortageDB.Create;
    InUse := TStringList.Create;
    Consumers := TStringList.Create;
    Consumers.Sorted := True;
    Consumers.Duplicates := dupIgnore;
    Consumers.OwnsObjects := True;
    DependedOn := TStringList.Create;
    try
      DB.BuildFileIndex;
      CollectInUse;
      if (not NoConsumers) and (not RemoveOnly) then
      begin
        BuildDependedOn;
        BuildConsumers;
      end;

      Total := 0;
      Used := 0;
      RemoveCandidates := 0;
      for i := 0 to roots.Count - 1 do
        Walk(roots[i]);

      if Summary and not Print0 then
      begin
        if RemoveOnly then
          WriteLn(RemoveCandidates, ' removal candidate',
                  IfThen(RemoveCandidates = 1, '', 's'))
        else
          WriteLn(Total, ' unowned file', IfThen(Total = 1, '', 's'), ', ',
                  Used, ' currently in use');
      end;
    finally
      DependedOn.Free;
      Consumers.Free;
      InUse.Free;
      DB.Free;
    end;
  finally
    roots.Free;
  end;
end.
