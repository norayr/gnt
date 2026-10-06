// gnt-get - an apt-get flavoured front end for Gentoo.
//
// Native installed-state solving lives in portage.pas: USE conditionals,
// slots, version atoms and ||/^^/?? dependency groups are evaluated directly
// from the installed Portage vardb. Package mutation/building still uses
// emerge as a backend for now; the solver is deliberately being grown
// independently so it can become a full package-manager core over time.

program gntget;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, contnrs, process, portage;

var
  DB: TPortageDB;

procedure Usage;
begin
  WriteLn('gnt-get 1.3.2 - Gentoo package front end + native installed-state solver');
  WriteLn;
  WriteLn('usage:');
  WriteLn('  gnt-get update                         sync repositories (emerge backend)');
  WriteLn('  gnt-get install <package>...           install (emerge backend)');
  WriteLn('  gnt-get source  <package>...           install alias');
  WriteLn('  gnt-get upgrade                        update @world');
  WriteLn('  gnt-get full-upgrade                   deep @world update incl. build deps');
  WriteLn('  gnt-get remove  <package>...           native recursive removal solver');
  WriteLn('  gnt-get rdepends <package>...          show what would recursively break');
  WriteLn('  gnt-get check                          verify installed runtime dependency graph');
  WriteLn;
  WriteLn('flags:');
  WriteLn('  -d, --download-only   fetch only (install/source)');
  WriteLn('  -n, --dry-run         remove: print the plan, change nothing');
  WriteLn('  -y, --yes             remove: do not ask for confirmation');
end;

function Lower(const S: string): string;
begin
  Result := LowerCase(S);
end;

function JoinArgs(const AArgs: array of string): string;
var
  i: integer;
begin
  Result := '';
  for i := 0 to High(AArgs) do
  begin
    if i > 0 then Result := Result + ' ';
    Result := Result + AArgs[i];
  end;
end;

function EmergePath: string;
begin
  if FileExists('/usr/bin/emerge') then exit('/usr/bin/emerge');
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

function ResolveInstalledSpecs(const Specs: array of string): TObjectList;
var
  i, j: integer;
  l: TObjectList;
  p: TPkgInfo;
begin
  Result := TObjectList.Create(False);
  for i := 0 to High(Specs) do
  begin
    l := DB.FindAll(Specs[i]);
    try
      if l.Count = 0 then
      begin
        WriteLn(StdErr, 'gnt-get: package not installed: ', Specs[i]);
        Result.Free;
        Halt(1);
      end;
      if AmbiguousBareSpec(Specs[i], l) then
      begin
        PrintAmbiguousMatches(Specs[i], l);
        Result.Free;
        Halt(1);
      end;
      for j := 0 to l.Count - 1 do
      begin
        p := TPkgInfo(l[j]);
        if Result.IndexOf(p) < 0 then Result.Add(p);
      end;
    finally
      l.Free;
    end;
  end;
end;

procedure PrintRemovalPlan(Closure: TObjectList; Reasons: TStringList);
var
  i: integer;
  p: TPkgInfo;
  why: string;
begin
  WriteLn('The following packages will be REMOVED:');
  for i := 0 to Closure.Count - 1 do
  begin
    p := TPkgInfo(Closure[i]);
    why := Reasons.Values[p.CPV];
    if (why <> '') and (why <> 'requested') then
      WriteLn('  ', p.CPV, '  [', why, ']')
    else
      WriteLn('  ', p.CPV);
  end;
end;

procedure CmdRemove(const Specs: array of string; DryRun, AssumeYes: Boolean);
var
  i: integer;
  Initial, Closure: TObjectList;
  Reasons: TStringList;
  answer: string;
begin
  Initial := ResolveInstalledSpecs(Specs);
  try
    Write('Building dependency tree... ');
    Closure := DB.RemovalClosure(Initial, Reasons);
    try
      WriteLn('Done');
      if Closure.Count = 0 then
      begin
        WriteLn('Nothing to do.');
        exit;
      end;

      PrintRemovalPlan(Closure, Reasons);
      if DryRun then
      begin
        WriteLn('(dry run: no packages were removed)');
        exit;
      end;

      if not AssumeYes then
      begin
        Write('Do you want to continue? [y/N] ');
        ReadLn(answer);
        if (answer = '') or (UpCase(answer[1]) <> 'Y') then
        begin
          WriteLn('Aborted.');
          Halt(1);
        end;
      end;

      for i := 0 to Closure.Count - 1 do
        RunEmerge(['--unmerge', '=' + TPkgInfo(Closure[i]).CPV]);
    finally
      Closure.Free;
      Reasons.Free;
    end;
  finally
    Initial.Free;
  end;
end;

procedure CmdRDepends(const Specs: array of string);
var
  i: integer;
  Initial, Closure: TObjectList;
  Reasons: TStringList;
  p: TPkgInfo;
begin
  Initial := ResolveInstalledSpecs(Specs);
  try
    Closure := DB.RemovalClosure(Initial, Reasons);
    try
      for i := 0 to Closure.Count - 1 do
      begin
        p := TPkgInfo(Closure[i]);
        if Reasons.Values[p.CPV] <> 'requested' then
          WriteLn(p.CPV);
      end;
    finally
      Closure.Free;
      Reasons.Free;
    end;
  finally
    Initial.Free;
  end;
end;

procedure CmdCheck;
var
  i, broken: integer;
  p: TPkgInfo;
  Empty: TStringList;
  why: string;
begin
  Empty := TStringList.Create;
  try
    Empty.Sorted := True;
    broken := 0;
    for i := 0 to DB.Packages.Count - 1 do
    begin
      p := TPkgInfo(DB.Packages[i]);
      if not DB.RuntimeSatisfied(p, Empty, why) then
      begin
        Inc(broken);
        WriteLn(p.CPV, ': ', why);
      end;
    end;
    if broken = 0 then
      WriteLn('All installed runtime dependency expressions are satisfied.')
    else
      WriteLn(broken, ' installed package(s) have unsatisfied runtime dependencies.');
  finally
    Empty.Free;
  end;
  if broken <> 0 then Halt(1);
end;

var
  Args, PackageArgs: TStringList;
  Cmd: string;
  DryRun, AssumeYes, DownloadOnly: Boolean;
  i: integer;
  Specs: array of string;

begin
  if ParamCount = 0 then
  begin
    Usage;
    Halt(2);
  end;

  Args := TStringList.Create;
  try
    for i := 1 to ParamCount do Args.Add(ParamStr(i));

    Cmd := Lower(Args[0]);
    DryRun := (Args.IndexOf('-n') >= 0) or
              (Args.IndexOf('--dry-run') >= 0) or
              (Args.IndexOf('--pretend') >= 0);
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

    if Cmd = 'upgrade' then
    begin
      RunEmerge(['-avuD', '--changed-use', '@world']);
      Halt(0);
    end;

    if (Cmd = 'full-upgrade') or (Cmd = 'dist-upgrade') then
    begin
      RunEmerge(['-avuDN', '--changed-use', '--with-bdeps=y',
        '--complete-graph=y', '@world']);
      Halt(0);
    end;

    if Cmd = 'check' then
    begin
      DB := TPortageDB.Create;
      try
        CmdCheck;
      finally
        DB.Free;
      end;
      Halt(0);
    end;

    if (Cmd <> 'remove') and (Cmd <> 'rdepends') and
       (Cmd <> 'install') and (Cmd <> 'source') then
    begin
      WriteLn(StdErr, 'gnt-get: unknown command ''', Args[0], '''');
      Usage;
      Halt(2);
    end;

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

      if (Cmd = 'remove') or (Cmd = 'rdepends') then
      begin
        SetLength(Specs, PackageArgs.Count);
        for i := 0 to PackageArgs.Count - 1 do Specs[i] := PackageArgs[i];
        DB := TPortageDB.Create;
        try
          if Cmd = 'remove' then
            CmdRemove(Specs, DryRun, AssumeYes)
          else
            CmdRDepends(Specs);
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
