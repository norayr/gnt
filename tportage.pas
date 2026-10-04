// Test harness for portage.pas.
//
// Two phases:
//   1. A synthetic vardb built in a temp directory, so the *semantics* are
//      pinned without depending on what happens to be installed. This is the
//      part that guards against regressions.
//   2. A read-only smoke test against the real /var/db/pkg, which catches
//      integration problems the synthetic tree cannot (huge CONTENTS files,
//      odd dep syntax, ...).
//
//   fpc -Mobjfpc -Sh tportage.pas && ./tportage
//
// Exits nonzero on the first failed assertion.

program tportage;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, contnrs, process, portage;

var
  Failures: integer = 0;

procedure Check(const What: string; Cond: boolean);
begin
  if Cond then
    WriteLn('ok   ', What)
  else
  begin
    WriteLn('FAIL ', What);
    Inc(Failures);
  end;
end;

procedure CheckEq(const What: string; Got, Want: integer);
begin
  if Got = Want then
    WriteLn('ok   ', What, ' = ', Got)
  else
  begin
    WriteLn('FAIL ', What, ': got ', Got, ' want ', Want);
    Inc(Failures);
  end;
end;

procedure CheckStr(const What, Got, Want: string);
begin
  if Got = Want then
    WriteLn('ok   ', What, ' = ''', Got, '''')
  else
  begin
    WriteLn('FAIL ', What, ': got ''', Got, ''' want ''', Want, '''');
    Inc(Failures);
  end;
end;

procedure WriteFile(const Path, Content: string);
var
  sl: TStringList;
  dir: string;
begin
  dir := ExtractFileDir(Path);
  ForceDirectories(dir);
  sl := TStringList.Create;
  try
    sl.Text := Content;
    sl.SaveToFile(Path);
  finally
    sl.Free;
  end;
end;

// A tiny fake vardb that exercises the parser and the lookup helpers.
const
  TestRoot = '/tmp/gnt-portage-test';

procedure Pkg(const Cat, PF, Contents, Depend, RDepend, Use, IUse, Slot: string);
var
  dir: string;
begin
  dir := TestRoot + '/' + Cat + '/' + PF;
  WriteFile(dir + '/CATEGORY', Cat + #10);
  WriteFile(dir + '/SLOT', Slot + #10);
  if Use <> '' then WriteFile(dir + '/USE', Use + #10);
  if IUse <> '' then WriteFile(dir + '/IUSE', IUse + #10);
  if Contents <> '' then WriteFile(dir + '/CONTENTS', Contents);
  if Depend <> '' then WriteFile(dir + '/DEPEND', Depend + #10);
  if RDepend <> '' then WriteFile(dir + '/RDEPEND', RDepend + #10);
end;

procedure BuildFakeDB;
begin
  if DirectoryExists(TestRoot) then
    ExecuteProcess('/bin/rm', ['-rf', TestRoot]);

  // foo depends on bar (plain), blocks baz, and pulls an alternative from an
  // "||" group. ">=dev-test/qux-2.0" must still count as a qux dependency.
  Pkg('app-test', 'foo-1.0-r1',
    'obj /usr/bin/foo deadbeef 1700000000'#10 +
    'dir /usr/share/foo 1700000000'#10 +
    'sym /usr/bin/foo-link -> foo 1700000000'#10,
    'app-test/bar app-test/qux',
    '!app-test/baz >=dev-test/qux-2.0 || ( dev-test/qux app-test/alt )',
    'nls python', 'nls python sqlite', '0');

  Pkg('app-test', 'bar-2.0',
    'obj /usr/bin/bar deadbeef 1700000000'#10,
    '', '', '', '', '0');

  Pkg('app-test', 'baz-3.0',
    'obj /usr/bin/baz deadbeef 1700000000'#10,
    '', '', '', '', '0');

  // Same base name as the blocker target but a different category: a bare
  // "baz" query must include both, a "app-test/baz" query only this one.
  Pkg('dev-test', 'baz-1.5',
    '', '', '', '', '', '0');

  Pkg('dev-test', 'qux-2.5',
    'obj /usr/lib/libqux.so.1 deadbeef 1700000000'#10,
    '', '', '', '', '0');

  Pkg('app-test', 'alt-1.0',
    'obj /usr/bin/alt deadbeef 1700000000'#10,
    '', '', '', '', '0');

  // A transient install directory that must be ignored entirely.
  WriteFile(TestRoot + '/app-test/-MERGING-foo-9.9/CATEGORY', 'app-test'#10);
  WriteFile(TestRoot + '/app-test/-MERGING-foo-9.9/RDEPEND', 'app-test/bar'#10);
end;

function Cnt(const L: TObjectList): integer;
begin
  Result := L.Count;
end;

procedure TestFakeDB;
var
  db: TPortageDB;
  l: TObjectList;
  p: TPkgInfo;
begin
  WriteLn;
  WriteLn('=== synthetic vardb ===');
  db := TPortageDB.Create(TestRoot);
  try
    CheckEq('package count (transient dirs excluded)', db.Count, 6);
    Check('transient package not resolvable',
          db.FindByCPV('app-test/-MERGING-foo-9.9') = nil);

    // --- atom helpers ---
    CheckStr('StripVersion(sys-libs/glibc-2.42-r5)',
             StripVersion('sys-libs/glibc-2.42-r5'), 'sys-libs/glibc');
    CheckStr('ExtractVersion(sys-libs/glibc-2.42-r5)',
             ExtractVersion('sys-libs/glibc-2.42-r5'), '2.42-r5');
    CheckStr('StripVersion(elt-patches-20250718)',
             StripVersion('elt-patches-20250718'), 'elt-patches');
    CheckStr('StripRevision(0.36.9-r2)', StripRevision('0.36.9-r2'), '0.36.9');
    CheckStr('NormalizeDep(>=dev-libs/libassuan-2.5.3:0/3.0=)',
             NormalizeDep('>=dev-libs/libassuan-2.5.3:0/3.0='),
             'dev-libs/libassuan');
    CheckStr('NormalizeDep(dev-lang/python:3.14[threads(+)])',
             NormalizeDep('dev-lang/python:3.14[threads(+)]'), 'dev-lang/python');
    CheckStr('NormalizeDep(!sys-apps/coreutils[hostname]) blocker',
             NormalizeDep('!sys-apps/coreutils[hostname]'), '');
    CheckStr('NormalizeDep(!!cat/pkg) strong blocker',
             NormalizeDep('!!cat/pkg'), '');
    CheckStr('NormalizeDep(?cat/pkg) weak blocker',
             NormalizeDep('?cat/pkg'), '');
    CheckStr('NormalizeDep(||)', NormalizeDep('||'), '');
    CheckStr('NormalizeDep(bareword)', NormalizeDep('bareword'), '');

    // --- dep atom extraction ---
    p := db.FindByCPV('app-test/foo-1.0-r1');
    Check('foo is installed', p <> nil);
    if p <> nil then
    begin
      CheckEq('foo dep atoms (blocker excluded, || flattened)',
              p.DependAtoms.Count, 4);
      Check('foo depends on bar', p.DependAtoms.IndexOf('app-test/bar') >= 0);
      Check('foo blocker on baz is not a dep',
            p.DependAtoms.IndexOf('app-test/baz') < 0);
      Check('foo depends on qux', p.DependAtoms.IndexOf('dev-test/qux') >= 0);
      Check('foo || alternative is captured',
            p.DependAtoms.IndexOf('app-test/alt') >= 0);
      CheckEq('foo USE flags', p.UseFlags.Count, 2);
      CheckEq('foo IUSE flags', p.IUse.Count, 3);
      Check('foo has nls enabled', p.HasUseFlag('nls'));
      Check('foo does not have sqlite enabled', not p.HasUseFlag('sqlite'));
      Check('foo declares sqlite', p.DeclaresUseFlag('sqlite'));
    end;

    // --- reverse dependencies ---
    l := db.ReverseDepends('app-test/bar');
    CheckEq('rdep(app-test/bar)', Cnt(l), 1);
    if l.Count = 1 then
      CheckStr('rdep(app-test/bar) member',
               TPkgInfo(l.Items[0]).CPV, 'app-test/foo-1.0-r1');
    l.Free;

    l := db.ReverseDepends('bar');
    CheckEq('rdep(bare bar)', Cnt(l), 1);
    l.Free;

    l := db.ReverseDepends('app-test/baz');
    CheckEq('rdep(app-test/baz) excludes blocker', Cnt(l), 0);
    l.Free;

    l := db.ReverseDepends('baz');
    CheckEq('rdep(bare baz) finds the other-category baz only', Cnt(l), 0);
    l.Free;

    l := db.ReverseDepends('dev-test/qux');
    CheckEq('rdep(dev-test/qux)', Cnt(l), 1);
    l.Free;

    l := db.ReverseDepends('app-test/alt');
    CheckEq('rdep(app-test/alt) from || group', Cnt(l), 1);
    l.Free;

    l := db.ReverseDepends('=app-test/bar-2.0');
    CheckEq('rdep(=app-test/bar-2.0) exact version', Cnt(l), 0);
    l.Free;

    // --- self dependency ---
    // foo does not depend on itself, so a query for foo returns nothing.
    l := db.ReverseDepends('app-test/foo');
    CheckEq('rdep(app-test/foo) self excluded', Cnt(l), 0);
    l.Free;

    // --- file ownership ---
    CheckEq('owned paths', db.OwnedCount, 7);
    CheckStr('owner /usr/bin/foo', db.OwnerOf('/usr/bin/foo').CPV, 'app-test/foo-1.0-r1');
    CheckStr('owner /usr/bin/foo-link (symlink follows CONTENTS path)',
             db.OwnerOf('/usr/bin/foo-link').CPV, 'app-test/foo-1.0-r1');
    Check('bar owns /usr/bin/bar', db.IsOwned('/usr/bin/bar'));
    Check('unknown path is unowned', not db.IsOwned('/usr/bin/none'));

    // --- FindAll / IsInstalled ---
    CheckEq('FindAll(baz) membership (bare name spans categories)',
            Cnt(db.FindAll('baz')), 2);
    CheckEq('FindAll(dev-test/baz)', Cnt(db.FindAll('dev-test/baz')), 1);
    CheckEq('FindAll(=app-test/bar-2.0)', Cnt(db.FindAll('=app-test/bar-2.0')), 1);
    Check('bar is installed', db.IsInstalled('app-test/bar'));
    Check('nosuch is not installed', not db.IsInstalled('nosuch/pkg'));
  finally
    db.Free;
  end;
end;

procedure TestLiveDB;
var
  db: TPortageDB;
  l: TObjectList;
  p, q: TPkgInfo;
begin
  WriteLn;
  WriteLn('=== live vardb (', ActiveDBPath, ') ===');
  if not DirectoryExists(ActiveDBPath) then
  begin
    WriteLn('skip: no live vardb');
    exit;
  end;

  db := TPortageDB.Create;
  try
    Check('live vardb has a plausible package count', db.Count > 1000);

    // net-tools only *blocks* coreutils; it must never appear as a dependant.
    l := db.ReverseDepends('sys-apps/coreutils');
    Check('net-tools is not a coreutils dependant (blocker)',
          l.IndexOf(db.FindByCPV('sys-apps/net-tools-2.10')) < 0);
    l.Free;

    // A bare name spanning two categories must find both.
    l := db.ReverseDepends('glibc');
    Check('glibc has many dependants', l.Count > 500);
    l.Free;

    // Versioned queries must be a strict subset of the unversioned one.
    l := db.ReverseDepends('>=sys-libs/glibc-2.43');
    Check('versioned glibc query returns dependants', l.Count > 0);
    l.Free;

    // merged-/usr: libc is reachable both as /usr/lib64/libc.so.6 and through
    // the compatibility symlink /lib64/libc.so.6, but CONTENTS records only one
    // spelling. Both lookups must agree, or half the system looks unowned.
    p := db.OwnerOf('/usr/lib64/libc.so.6');
    q := db.OwnerOf('/lib64/libc.so.6');
    Check('physical /usr/lib64/libc.so.6 is owned', p <> nil);
    Check('compat /lib64/libc.so.6 is owned', q <> nil);
    Check('both libc spellings resolve to one owner', p = q);
    Check('owner path is the recorded spelling',
          db.OwnerPathOf('/usr/lib64/libc.so.6') = db.OwnerPathOf('/lib64/libc.so.6'));
    Check('unowned path has no recorded owner path',
          db.OwnerPathOf('/no/such/path') = '');
  finally
    db.Free;
  end;
end;

// The merged-usr machinery is pure string work, so it is tested directly.
// Split-/usr is the "no aliases discovered" case, which must leave every path
// untouched; the live database test covers the merged case end to end.
procedure TestPaths;
begin
  WriteLn;
  WriteLn('=== path normalisation ===');

  CheckStr('normalise ..', NormalizePath('/usr/bin/../sbin'), '/usr/sbin');
  CheckStr('normalise . and //', NormalizePath('/usr//bin/./x'), '/usr/bin/x');
  CheckStr('normalise above root stays at root', NormalizePath('/../../x'), '/x');

  CheckStr('alias matches a path',
           CanonicalPathApply('/sbin/ldconfig', '/sbin', '/usr/bin'),
           '/usr/bin/ldconfig');
  CheckStr('alias matches the bare directory',
           CanonicalPathApply('/sbin', '/sbin', '/usr/bin'), '/usr/bin');
  CheckStr('alias does not match a longer name',
           CanonicalPathApply('/binary/x', '/bin', '/usr/bin'), '/binary/x');
  CheckStr('aliasing /lib does not touch /lib64',
           CanonicalPathApply('/lib64/x', '/lib', '/usr/lib'), '/lib64/x');
  CheckStr('unrelated path is untouched',
           CanonicalPathApply('/opt/x', '/bin', '/usr/bin'), '/opt/x');
  CheckStr('empty alias is a no-op', CanonicalPathApply('/opt/x', '', ''), '/opt/x');

  CheckStr('canonical keeps unaliased paths',
           CanonicalPath('/opt/foo/bar'), '/opt/foo/bar');

  if IsMergedUsr then
    Check('merged host maps /lib64/x',
          CanonicalPath('/lib64/x') = '/usr/lib64/x')
  else
    Check('split host leaves /lib64/x alone',
          CanonicalPath('/lib64/x') = '/lib64/x');
end;

begin
  BuildFakeDB;
  TestFakeDB;
  TestPaths;
  TestLiveDB;

  WriteLn;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  Halt(Ord(Failures <> 0));
end.
