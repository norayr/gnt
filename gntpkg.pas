// gntpkg - query the installed Portage database (/var/db/pkg).
//
// Reads the vardb directly through portage.pas; never shells out to emerge,
// equery or the old epkg. The old spelling of every command is kept as an
// alias so existing scripts keep working.
//
//   gntpkg list                     cat/name-version of every installed package
//   gntpkg files  <spec>            paths owned by a package
//   gntpkg belongs <path-or-text>   packages owning a path
//   gntpkg depends <atom>           packages depending on an atom
//   gntpkg hasuse <flag>            packages declaring/enabling a USE flag
//   gntpkg uses   <spec>            USE flags of a package
//   gntpkg --help

program gntpkg;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, contnrs, portage;

var
  DB: TPortageDB;

procedure Usage;
begin
  WriteLn('gntpkg ', '1.1', ' - query the installed Portage database');
  WriteLn;
  WriteLn('usage: gntpkg <command> [argument]');
  WriteLn;
  WriteLn('  list, -l, all            list installed packages (cat/name-version)');
  WriteLn('  files, -L <spec>         list files owned by a package');
  WriteLn('  belongs, -S <path>       list packages owning a path or path fragment');
  WriteLn('  depends <atom>           list packages depending on an atom');
  WriteLn('  hasuse <flag>            list packages using/declaring a USE flag');
  WriteLn('  uses <spec>              list a package''s USE flags');
  WriteLn('  help, -h, --help         this text');
  WriteLn;
  WriteLn('<spec> is a package name, cat/name, or =cat/name-version.');
  WriteLn('The database can be overridden with $', DBEnvVar, '.');
end;

function Arg(const N: integer): string;
begin
  if N <= ParamCount then
    Result := ParamStr(N)
  else
    Result := '';
end;

procedure CmdList;
var
  i: integer;
begin
  for i := 0 to DB.Count - 1 do
    WriteLn(TPkgInfo(DB.Packages[i]).CPV);
end;

procedure CmdFiles(const Spec: string);
var
  l: TObjectList;
  p: TPkgInfo;
  i, j: integer;
begin
  l := DB.FindAll(Spec);
  try
    if l.Count = 0 then
    begin
      WriteLn(StdErr, 'gntpkg: no package matches ''', Spec, '''');
      Halt(1);
    end;
    if l.Count > 1 then
    begin
      WriteLn(StdErr, 'gntpkg: ''', Spec, ''' matches ', l.Count, ' packages:');
      for i := 0 to l.Count - 1 do
        WriteLn(StdErr, '  ', TPkgInfo(l.Items[i]).CPV);
      Halt(1);
    end;
    p := TPkgInfo(l.Items[0]);
    p.LoadContents;
    for j := 0 to p.Contents.Count - 1 do
      WriteLn(p.Contents[j]);
  finally
    l.Free;
  end;
end;

// An absolute path is resolved exactly through the vardb's ownership index,
// which knows about merged-usr aliases (/lib64/x <-> /usr/lib64/x) in both
// directions. Anything else is a substring search, which is what makes
// "belongs libz.so" useful.
procedure CmdBelongs(const Needle: string);
var
  i, j: integer;
  p: TPkgInfo;
  hit: boolean;
begin
  if Needle = '' then
  begin
    WriteLn(StdErr, 'gntpkg: belongs needs a path or search text');
    Halt(2);
  end;

  if Needle[1] = '/' then
  begin
    p := DB.OwnerOf(Needle);
    if p = nil then
      Halt(1);
    WriteLn(p.CPV, ' (', DB.OwnerPathOf(Needle), ')');
    exit;
  end;

  hit := False;
  for i := 0 to DB.Count - 1 do
  begin
    p := TPkgInfo(DB.Packages[i]);
    p.LoadContents;
    for j := 0 to p.Contents.Count - 1 do
      if Pos(Needle, p.Contents[j]) > 0 then
      begin
        WriteLn(p.CPV, ' (', p.Contents[j], ')');
        hit := True;
      end;
  end;
  if not hit then
    Halt(1);
end;

procedure CmdDepends(const Spec: string);
var
  l: TObjectList;
  i: integer;
begin
  if Spec = '' then
  begin
    WriteLn(StdErr, 'gntpkg: depends needs an atom');
    Halt(2);
  end;
  l := DB.ReverseDepends(Spec);
  try
    for i := 0 to l.Count - 1 do
      WriteLn(TPkgInfo(l.Items[i]).CPV);
    if l.Count = 0 then
      Halt(1);
  finally
    l.Free;
  end;
end;

procedure CmdHasUse(const Flag: string);
var
  i: integer;
  p: TPkgInfo;
  enabled, declared: boolean;
begin
  if Flag = '' then
  begin
    WriteLn(StdErr, 'gntpkg: hasuse needs a flag');
    Halt(2);
  end;
  for i := 0 to DB.Count - 1 do
  begin
    p := TPkgInfo(DB.Packages[i]);
    enabled := p.HasUseFlag(Flag);
    declared := p.DeclaresUseFlag(Flag);
    if enabled or declared then
    begin
      Write(p.CPV);
      if enabled then Write(' USE');
      if declared then Write(' IUSE');
      WriteLn;
    end;
  end;
end;

procedure CmdUses(const Spec: string);
var
  l: TObjectList;
  p: TPkgInfo;
  j: integer;
begin
  l := DB.FindAll(Spec);
  try
    if l.Count <> 1 then
    begin
      if l.Count = 0 then
        WriteLn(StdErr, 'gntpkg: no package matches ''', Spec, '''')
      else
        WriteLn(StdErr, 'gntpkg: ''', Spec, ''' matches ', l.Count, ' packages');
      Halt(1);
    end;
    p := TPkgInfo(l.Items[0]);
    WriteLn(p.CPV);
    for j := 0 to p.UseFlags.Count - 1 do
      WriteLn('  ', p.UseFlags[j]);
  finally
    l.Free;
  end;
end;

function Lower(const s: string): string;
begin
  Result := LowerCase(s);
end;

var
  cmd, rawcmd, a: string;
begin
  DB := TPortageDB.Create;
  try
    if ParamCount = 0 then
    begin
      Usage;
      Halt(2);
    end;

    rawcmd := Arg(1);
    cmd := Lower(rawcmd);
    a := Arg(2);

    // Preserve the case-sensitive historical short options before comparing
    // the lower-cased long command names.  Lower('-L') is '-l', which used to
    // make -L accidentally run the package list command.
    if rawcmd = '-L' then
      CmdFiles(a)
    else if rawcmd = '-S' then
      CmdBelongs(a)
    else if (cmd = 'help') or (cmd = '-h') or (cmd = '--help') then
      Usage
    else if (cmd = 'list') or (cmd = '-l') or (cmd = 'all') or (cmd = '--list') then
      CmdList
    else if (cmd = 'files') or (cmd = '--listfiles') then
      CmdFiles(a)
    else if (cmd = 'belongs') or (cmd = '-s') or (cmd = '--search') then
      CmdBelongs(a)
    else if (cmd = 'depends') or (cmd = 'query') then
      CmdDepends(a)
    else if (cmd = 'hasuse') then
      CmdHasUse(a)
    else if (cmd = 'uses') then
      CmdUses(a)
    else
    begin
      WriteLn(StdErr, 'gntpkg: unknown command ''', Arg(1), '''');
      Usage;
      Halt(2);
    end;
  finally
    DB.Free;
  end;
end.
