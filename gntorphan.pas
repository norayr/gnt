// gntorphan - installed packages that nothing depends on.
//
// This is the modern replacement for genorphan. The old tool shelled out to
// "epkg query" once per installed package and relied on its broken output; here
// every package's dependency list is read once and the set of names that are
// depended on is built in a single pass.
//
// By default only libraries are considered (the name contains "lib"), which is
// what genorphan did: the interesting orphans are usually unused libraries.
//
//   gntorphan            orphaned libraries
//   gntorphan -a         orphaned packages of any kind
//   gntorphan -c dev-libs
//   gntorphan -s         print a summary line only

program gntorphan;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, StrUtils, contnrs, portage;

type
  TOptions = record
    All: Boolean;
    Category: string;
    Summary: Boolean;
  end;

procedure Usage;
begin
  WriteLn('gntorphan 1.1 - find installed packages that nothing depends on');
  WriteLn;
  WriteLn('usage: gntorphan [options]');
  WriteLn;
  WriteLn('  -a, --all          consider every package, not just libraries');
  WriteLn('  -c, --category C   restrict to category C');
  WriteLn('  -s, --summary      print only the number of orphans');
  WriteLn('  -h, --help         this text');
  WriteLn;
  WriteLn('The database can be overridden with $', DBEnvVar, '.');
  WriteLn('This is a graph-leaf finder, not emerge --depclean: @world/profile');
  WriteLn('membership is not consulted, so an orphan is not automatically removable.');
end;

// A name is "depended on" if any *other* installed package lists it. A package
// that only depends on itself stays an orphan, which is what makes a broken
// self-dependency visible instead of hiding it.
procedure BuildDependedOn(DB: TPortageDB; var DependedOn: TStringList);
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

var
  DB: TPortageDB;
  Opt: TOptions;
  DependedOn: TStringList;
  i, n: integer;
  p: TPkgInfo;
  LibOnly: Boolean;

begin
  Opt.All := False;
  Opt.Category := '';
  Opt.Summary := False;

  if ParamCount > 0 then
  begin
    i := 1;
    while i <= ParamCount do
    begin
      if (ParamStr(i) = '-h') or (ParamStr(i) = '--help') then
      begin
        Usage;
        Halt(0);
      end
      else if (ParamStr(i) = '-a') or (ParamStr(i) = '--all') then
        Opt.All := True
      else if (ParamStr(i) = '-s') or (ParamStr(i) = '--summary') then
        Opt.Summary := True
      else if (ParamStr(i) = '-c') or (ParamStr(i) = '--category') then
      begin
        if i = ParamCount then
        begin
          WriteLn(StdErr, 'gntorphan: ', ParamStr(i), ' needs a category');
          Halt(2);
        end;
        Inc(i);
        Opt.Category := ParamStr(i);
      end
      else
      begin
        WriteLn(StdErr, 'gntorphan: unknown option ''', ParamStr(i), '''');
        Usage;
        Halt(2);
      end;
      Inc(i);
    end;
  end;

  LibOnly := not Opt.All;

  DB := TPortageDB.Create;
  DependedOn := TStringList.Create;
  try
    BuildDependedOn(DB, DependedOn);

    n := 0;
    for i := 0 to DB.Count - 1 do
    begin
      p := TPkgInfo(DB.Packages[i]);
      if LibOnly and (Pos('lib', p.Name) = 0) then continue;
      if (Opt.Category <> '') and (p.Category <> Opt.Category) then continue;
      if DependedOn.IndexOf(p.Atom) >= 0 then continue;
      if not Opt.Summary then
        WriteLn(p.CPV);
      Inc(n);
    end;

    if Opt.Summary then
      WriteLn(n, ' orphan', IfThen(n = 1, '', 's'));
  finally
    DependedOn.Free;
    DB.Free;
  end;
end.
