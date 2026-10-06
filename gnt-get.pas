// gnt-get - an apt-get flavoured front end for Gentoo.
//
// The useful addition here is recursive reverse-dependency removal.  The
// dependency closure is computed directly from the installed Portage vardb via
// portage.pas; emerge is invoked only to perform the requested package action.
// No command is passed through a shell.
//
//   gnt-get update
//   gnt-get install <package>... [-d|--download-only]
//   gnt-get source  <package>... [-d|--download-only]   // install alias
//   gnt-get remove  <package>... [-n|--dry-run] [-y|--yes]

program gntget;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, contnrs, process, portage;

var
  DB: TPortageDB;

procedure Usage;
begin
  WriteLn('gnt-get 1.1 - apt-get style interface for Gentoo');
  WriteLn;
  WriteLn('usage:');
  WriteLn('  gnt-get update                         sync the tree (emerge --sync)');
  WriteLn('  gnt-get install <package>...           install (emerge)');
  WriteLn('  gnt-get source  <package>...           install alias (Gentoo normally builds source)');
  WriteLn('  gnt-get remove  <package>...           remove, and everything using it');
  WriteLn;
  WriteLn('flags:');
  WriteLn('  -d, --download-only   fetch only (install/source)');
  WriteLn('  -n, --dry-run         remove: print the plan, change nothing');
  WriteLn('  -y, --yes             remove: do not ask for confirmation');
end;

function Lower(const s: string): string;
begin
  Result := LowerCase(s);
end;

// --- recursive removal ------------------------------------------------------

var
  Seen: TStringList;    // sorted, dupIgnore; holds CPVs already scheduled
  Order: TStringList;   // CPVs in removal order: dependants before the target

// Depth-first post-order: a package is appended only after every package that
// depends on it, so dependants are unmerged first. Cycles are stopped by Seen.
//
// The lookup uses the bare "cat/pkg" atom, not the installed version: a
// dependant may constrain us with ">=cat/pkg-2" and still break the moment we
// disappear, even though its DEPEND text never names the installed version.
procedure CollectDependants(P: TPkgInfo);
var
  Deps: TObjectList;
  i: integer;
begin
  if Seen.IndexOf(P.CPV) >= 0 then
    exit;
  Seen.Add(P.CPV);

  Deps := DB.ReverseRuntimeDepends(P.Atom);
  try
    for i := 0 to Deps.Count - 1 do
      CollectDependants(TPkgInfo(Deps.Items[i]));
  finally
    Deps.Free;
  end;

  Order.Add(P.CPV);
end;

function JoinArgs(const AArgs: array of string): string;
var
  i: integer;
begin
  Result := '';
  for i := 0 to High(AArgs) do
  begin
    if i > 0 then
      Result := Result + ' ';
    Result := Result + AArgs[i];
  end;
end;

function EmergePath: string;
begin
  // ExecuteProcess() does not reliably PATH-search a bare executable name on
  // every FPC/process combination.  Gentoo's canonical path is preferred; the
  // PATH lookup keeps test/chroot layouts usable.
  if FileExists('/usr/bin/emerge') then
    exit('/usr/bin/emerge');
  Result := FileSearch('emerge', GetEnvironmentVariable('PATH'));
  if Result = '' then
  begin
    WriteLn(StdErr, 'gnt-get: cannot find emerge (/usr/bin/emerge or $PATH)');
    Halt(127);
  end;
end;

procedure RunEmerge(const AArgs: array of string);
var
  rc: integer;
  exe: string;
begin
  WriteLn('+ emerge ', JoinArgs(AArgs));
  exe := EmergePath;
  try
    rc := ExecuteProcess(exe, AArgs);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'gnt-get: failed to execute ', exe, ': ', E.Message);
      Halt(127);
    end;
  end;
  if rc <> 0 then
  begin
    WriteLn(StdErr, 'gnt-get: emerge exited with status ', rc);
    Halt(rc);
  end;
end;

procedure RunEmergePackages(FetchOnly: Boolean; Packages: TStrings);
var
  a: array of string;
  i, n: integer;
begin
  n := Packages.Count;
  if FetchOnly then Inc(n);
  SetLength(a, n);
  n := 0;
  if FetchOnly then
  begin
    a[n] := '-f';
    Inc(n);
  end;
  for i := 0 to Packages.Count - 1 do
  begin
    a[n] := Packages[i];
    Inc(n);
  end;
  RunEmerge(a);
end;

function AmbiguousBareSpec(const Spec: string; Matches: TObjectList): boolean;
var
  atoms: TStringList;
  i: integer;
begin
  Result := False;
  // A category-qualified atom is already unambiguous. Multiple installed
  // versions/slots of that one atom are legitimate matches.
  if Pos('/', Spec) > 0 then exit;

  atoms := TStringList.Create;
  try
    atoms.Sorted := True;
    atoms.Duplicates := dupIgnore;
    for i := 0 to Matches.Count - 1 do
      atoms.Add(TPkgInfo(Matches[i]).Atom);
    Result := atoms.Count > 1;
  finally
    atoms.Free;
  end;
end;

procedure PrintAmbiguousMatches(const Spec: string; Matches: TObjectList);
var
  i: integer;
begin
  WriteLn(StdErr, 'gnt-get: ambiguous package name: ', Spec);
  WriteLn(StdErr, 'matches:');
  for i := 0 to Matches.Count - 1 do
    WriteLn(StdErr, '  ', TPkgInfo(Matches[i]).CPV,
      '  [slot ', TPkgInfo(Matches[i]).Slot, ']');
  WriteLn(StdErr, 'Please specify the category (and slot if needed).');
end;

procedure CmdRemove(const Specs: array of string; DryRun, AssumeYes: Boolean);
var
  i, j: integer;
  l: TObjectList;
  answer: string;
begin
  Seen := TStringList.Create;
  Seen.Sorted := True;
  Seen.Duplicates := dupIgnore;
  Order := TStringList.Create;
  try
    // Validate every name first, so a typo aborts the whole operation rather
    // than removing a partial set.
    for i := 0 to High(Specs) do
    begin
      l := DB.FindAll(Specs[i]);
      try
        if l.Count = 0 then
        begin
          WriteLn(StdErr, 'gnt-get: package not installed: ', Specs[i]);
          Halt(1);
        end;
        if AmbiguousBareSpec(Specs[i], l) then
        begin
          PrintAmbiguousMatches(Specs[i], l);
          Halt(1);
        end;
      finally
        l.Free;
      end;
    end;

    Write('Building dependency tree... ');
    for i := 0 to High(Specs) do
    begin
      l := DB.FindAll(Specs[i]);
      try
        for j := 0 to l.Count - 1 do
          CollectDependants(TPkgInfo(l.Items[j]));
      finally
        l.Free;
      end;
    end;
    WriteLn('Done');

    if Order.Count = 0 then
    begin
      WriteLn('Nothing to do.');
      exit;
    end;

    WriteLn('The following packages will be REMOVED:');
    for i := 0 to Order.Count - 1 do
      WriteLn('  ', Order[i]);

    if DryRun then
    begin
      WriteLn('(dry run: no packages were removed)');
      exit;
    end;

    if not AssumeYes then
    begin
      Write('Do you want to continue? [y/N] ');
      ReadLn(answer);
      if answer = '' then
      begin
        WriteLn('Aborted.');
        Halt(1);
      end;
      if UpCase(answer[1]) <> 'Y' then
      begin
        WriteLn('Aborted.');
        Halt(1);
      end;
    end;

    for i := 0 to Order.Count - 1 do
      // Order contains an exact installed CPV.  Prefix '=' so emerge parses it
      // as an exact atom rather than a package name containing digits.
      RunEmerge(['--unmerge', '=' + Order[i]]);
  finally
    Order.Free;
    Seen.Free;
  end;
end;

// --- dispatch ---------------------------------------------------------------

var
  Args, PackageArgs: TStringList;
  Cmd: string;
  DryRun, AssumeYes, DownloadOnly: Boolean;
  i: integer;
  RemoveSpecs: array of string;

begin
  if ParamCount = 0 then
  begin
    Usage;
    Halt(2);
  end;

  Args := TStringList.Create;
  try
    for i := 1 to ParamCount do
      Args.Add(ParamStr(i));

    Cmd := Lower(Args[0]);
    DryRun := (Args.IndexOf('-n') >= 0) or (Args.IndexOf('--dry-run') >= 0);
    AssumeYes := (Args.IndexOf('-y') >= 0) or (Args.IndexOf('--yes') >= 0);
    DownloadOnly := (Args.IndexOf('-d') >= 0) or
                    (Args.IndexOf('--download-only') >= 0);

    if (Cmd = 'help') or (Cmd = '-h') or (Cmd = '--help') then
    begin
      Usage;
      Halt(0);
    end;

    if Cmd = 'update' then
    begin
      RunEmerge(['--sync']);
      Halt(0);
    end;

    if (Cmd <> 'remove') and (Cmd <> 'install') and (Cmd <> 'source') then
    begin
      WriteLn(StdErr, 'gnt-get: unknown command ''', Args[0], '''');
      Usage;
      Halt(2);
    end;

    // Flags may appear before, between or after package names.  Only non-option
    // arguments become package specs.
    PackageArgs := TStringList.Create;
    try
      for i := 1 to Args.Count - 1 do
        if (Args[i] <> '') and (Args[i][1] <> '-') then
          PackageArgs.Add(Args[i]);

      if PackageArgs.Count = 0 then
      begin
        WriteLn(StdErr, 'gnt-get: ', Cmd, ' needs at least one package');
        Usage;
        Halt(2);
      end;

      if Cmd = 'remove' then
      begin
        SetLength(RemoveSpecs, PackageArgs.Count);
        for i := 0 to PackageArgs.Count - 1 do
          RemoveSpecs[i] := PackageArgs[i];
        DB := TPortageDB.Create;
        try
          CmdRemove(RemoveSpecs, DryRun, AssumeYes);
        finally
          DB.Free;
        end;
      end
      else
        RunEmergePackages(DownloadOnly, PackageArgs);
    finally
      PackageArgs.Free;
    end;
  finally
    Args.Free;
  end;
end.
