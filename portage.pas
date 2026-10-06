unit portage;
// Shared library for working with a Portage vardb (/var/db/pkg).
//
// Consumers: gntpkg, gnt-get, gntorphan, gntfsorphan.
//
// Design notes:
//  * Nothing in here prints to stdout. Every entry point returns data so
//    callers decide on formatting. This is what lets gnt-get query the db
//    directly instead of shelling out to gntpkg.
//  * The package collection is small (a few thousand entries) so it is
//    iterated linearly. Only the file index (hundreds of thousands of
//    paths) gets a sorted lookup table.
//  * Nothing mutates /var/db/pkg. Reading it is the whole job.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs;

const
  // Portage does not export an environment variable for the vardb path, so we
  // provide our own. This also makes it possible to point the tools at a fake
  // tree for testing.
  DBEnvVar = 'GNTPKG_DB_PATH';
  DefaultDBPath = '/var/db/pkg';

type
  EPkgError = class(Exception);

  TPkgInfo = class
  private
    FUseFlags: TStringList;
    FIUse: TStringList;
    FDependAtoms: TStringList;
    FRuntimeDependAtoms: TStringList;
    FContents: TStringList;
    FContentsLoaded: boolean;
    function GetCPV: string;
    function GetAtom: string;
    function GetUseFlags: TStringList;
    function GetIUse: TStringList;
    function GetDependAtoms: TStringList;
    function GetRuntimeDependAtoms: TStringList;
    function GetContents: TStringList;
    function GetContentsLoaded: boolean;
    function GetVersionNoRev: string;
    function GetRev: string;
  public
    Category: string;
    Name: string;
    Version: string;
    Slot: string;
    PkgDir: string;
    HasContentsFile: boolean;

    constructor Create;
    destructor Destroy; override;

    // "app-portage/eix-0.36.9"
    property CPV: string read GetCPV;
    // "app-portage/eix"
    property Atom: string read GetAtom;
    // "0.36.9-r2" -> "0.36.9"
    property VersionNoRev: string read GetVersionNoRev;
    // "0.36.9-r2" -> "r2", empty when there is no revision
    property Rev: string read GetRev;

    property UseFlags: TStringList read GetUseFlags;
    property IUse: TStringList read GetIUse;
    // Normalised "cat/pkg" atoms from DEPEND + RDEPEND + PDEPEND + BDEPEND + IDEPEND.
    property DependAtoms: TStringList read GetDependAtoms;
    // Active installed runtime/post dependencies (RDEPEND + PDEPEND).
    property RuntimeDependAtoms: TStringList read GetRuntimeDependAtoms;
    // Every path recorded in this package's CONTENTS file.
    property Contents: TStringList read GetContents;
    property ContentsLoaded: boolean read GetContentsLoaded;

    function HasUseFlag(const Flag: string): boolean;
    function DeclaresUseFlag(const Flag: string): boolean;
    procedure LoadContents;
  end;

  // Orders packages by CPV so output is deterministic across tools.
  TPortageDB = class
  private
    FPath: string;
    FPackages: TObjectList;    // of TPkgInfo
    FPathIndex: TStringList;    // sorted; Name = path, Objects[0] = TPkgInfo
    FPathIndexBuilt: Boolean;
    function GetCount: integer;
    function GetDbPath: string;
    procedure Scan;
  public
    constructor Create(const ADbPath: string = '');
    destructor Destroy; override;

    property DbPath: string read GetDbPath;
    property Count: integer read GetCount;
    property Packages: TObjectList read FPackages;

    function FindByCPV(const ACpv: string): TPkgInfo;
    // Every installed package whose base name matches. AName may be "eix",
    // "app-portage/eix", "=app-portage/eix-0.36.9" or "app-portage/eix-0.36.9".
    // Results come back sorted by CPV.
    function FindAll(const AName: string): TObjectList;
    function IsInstalled(const AAtom: string): boolean;

    // Which package claims this absolute path. When several packages list the
    // same path the first one wins and AContested reports the collision.
    function OwnerOf(const APath: string): TPkgInfo; overload;
    // Same lookup, but reports when more than one installed package claims the
    // path (a broken vardb). AContested must come back to the caller, which is
    // why it is a var parameter rather than a defaulted value one.
    function OwnerOf(const APath: string; var AContested: Boolean): TPkgInfo; overload;
    // The path exactly as CONTENTS records it (merged-usr aliases resolved),
    // or '' when unowned. Useful to show the operator the recorded spelling.
    function OwnerPathOf(const APath: string): string;
    function IsOwned(const APath: string): boolean;
    function OwnedCount: integer;
    procedure BuildFileIndex;

    // Installed packages that declare a dependency on ADep. ADep may be a bare
    // package name, a "cat/pkg" atom, or a fully qualified "=cat/pkg-ver" atom.
    function ReverseDepends(const ADep: string): TObjectList;
    // Installed packages whose active RDEPEND/PDEPEND references ADep.
    function ReverseRuntimeDepends(const ADep: string): TObjectList;
    function ReverseDependsAtom(const AAtom: string; AExactVersion: string = ''): TObjectList;
  end;

// ---------------------------------------------------------------- helpers ---

// The active vardb path: $GNTPKG_DB_PATH if set, otherwise /var/db/pkg.
function ActiveDBPath: string;

// Merged-usr normalisation. The alias table is discovered from the filesystem
// once; on a split-/usr install there are none, so CanonicalPath is the
// identity. CanonicalPathApply applies one alias to a leading component.
function CanonicalPath(const APath: string): string;
function CanonicalPathApply(const APath, AFrom, ATo: string): string;
function NormalizePath(const APath: string): string;
function IsMergedUsr: boolean;

// "sys-libs/glibc-2.42-r5" -> "sys-libs/glibc"
// A version starts after the last hyphen that is followed by a digit, which is
// what lets package names themselves contain digits and hyphens.
function StripVersion(const ACpv: string): string;

// "sys-libs/glibc-2.42-r5" -> "2.42-r5"
function ExtractVersion(const ACpv: string): string;

// "0.36.9-r2" -> "0.36.9"
function StripRevision(const AVersion: string): string;

// Splits a user supplied atom into its parts. Handles the operator prefixes
// portage accepts (>=, <=, ~=, >, <, =, !, @, *) and slot/subslot suffixes.
// Returns false when ACat or APkg would end up empty.
function ParseAtom(const AAtom: string; out ACat, APkg, AVersion, ASlot: string): boolean;

// Same, but also reports the dependency operator ("=", ">=", "~=", ...), empty
// when the atom carried none. Reverse-dependency lookups need this because
// "=cat/pkg-ver" only matches dependants pinning one exact version, while
// ">=cat/pkg-ver" matches a whole range of them.
function ParseAtomOp(const AAtom: string; out AOp, ACat, APkg, AVersion,
  ASlot: string): boolean;

// Reduces one entry of an RDEPEND line to a bare "cat/pkg". Handles operator
// prefixes, "||" groups, USE dependencies, slots and trailing "=" markers.
// Returns an empty string for atoms that carry no category, which cannot be
// resolved without an ebuild and is therefore ignored.
function NormalizeDep(const ADep: string): string;

// True when the path looks like a shared library by name alone.
function LooksLikeLibrary(const APath: string): boolean;

implementation

uses StrUtils, BaseUnix;

const
  AtomChars = ['a'..'z', 'A'..'Z', '0'..'9', '_', '+', '-', '.'];
  OpChars   = ['<', '>', '=', '~', '!', '@', '*', '?'];

// Forward declared so the sort calls below can pass it as a procedure variable.
function ComparePkgProc(Item1, Item2: Pointer): Integer; forward;

// Splits a whitespace separated USE/IUSE line into individual flag names.
// IUSE may store default markers as +flag/-flag; those are declaration
// metadata, not part of the flag name.  Older vardbs can also carry a trailing
// '=' marker, which is likewise stripped.
procedure AddWords(List: TStringList; const ALine: string; NormalizeIUse: Boolean);
var
  i, start: integer;
  w: string;
begin
  i := 1;
  while i <= Length(ALine) do
  begin
    while (i <= Length(ALine)) and (ALine[i] in [' ', #9]) do Inc(i);
    start := i;
    while (i <= Length(ALine)) and not (ALine[i] in [' ', #9]) do Inc(i);
    if i > start then
    begin
      w := Copy(ALine, start, i - start);
      if NormalizeIUse and (w <> '') and (w[1] in ['+', '-']) then
        Delete(w, 1, 1);
      if (w <> '') and (w[Length(w)] = '=') then
        SetLength(w, Length(w) - 1);
      if (w <> '') and (List.IndexOf(w) < 0) then
        List.Add(w);
    end;
  end;
end;

{ Tokenise a dependency expression. Parentheses become standalone tokens,
  while USE dependency brackets (cat/pkg[foo?,bar]) remain part of the atom. }
procedure TokenizeDeps(const ARaw: string; Tokens: TStringList);
var
  i, bracketDepth: integer;
  tok: string;

  procedure Flush;
  begin
    if tok <> '' then
    begin
      Tokens.Add(tok);
      tok := '';
    end;
  end;

begin
  Tokens.Clear;
  tok := '';
  bracketDepth := 0;
  for i := 1 to Length(ARaw) do
  begin
    if ARaw[i] = '[' then
    begin
      Inc(bracketDepth);
      tok := tok + ARaw[i];
    end
    else if ARaw[i] = ']' then
    begin
      if bracketDepth > 0 then Dec(bracketDepth);
      tok := tok + ARaw[i];
    end
    else if (bracketDepth = 0) and (ARaw[i] in ['(', ')']) then
    begin
      Flush;
      Tokens.Add(ARaw[i]);
    end
    else if (bracketDepth = 0) and (ARaw[i] in [' ', #9, #10, #13]) then
      Flush
    else
      tok := tok + ARaw[i];
  end;
  Flush;
end;

// A dependency conditional is "flag?" or "!flag?".  "??" is a group
// operator in REQUIRED_USE, not a USE conditional; it is excluded here.
function ParseUseConditional(const Tok: string; out Flag: string;
  out Negated: boolean): boolean;
var
  s: string;
begin
  Result := False;
  Flag := '';
  Negated := False;
  if (Tok = '') or (Tok = '??') or (Tok[Length(Tok)] <> '?') then exit;

  s := Copy(Tok, 1, Length(Tok) - 1);
  if s = '' then exit;
  if s[1] = '!' then
  begin
    Negated := True;
    Delete(s, 1, 1);
  end;
  if (s = '') or (Pos('/', s) > 0) then exit;
  Flag := s;
  Result := True;
end;

{ Extract active dependency atoms from a full PMS dependency expression.

  USE conditionals are evaluated against the USE flags recorded for the
  installed package in /var/db/pkg.  Nested conditionals are supported.

  Any-of groups (||) are intentionally conservative: all alternatives in an
  active group are retained.  The vardb does not record which alternative was
  selected at merge time, and guessing would risk hiding a reverse dependency. }
procedure AddActiveDepAtoms(const Pkg: TPkgInfo; const ARaw: string;
  Dest: TStringList);
var
  Tokens: TStringList;
  Posn: integer;

  procedure ParseGroup(Active: boolean);
  var
    tok, flag, atom: string;
    negated, cond: boolean;
  begin
    while Posn < Tokens.Count do
    begin
      tok := Tokens[Posn];

      if tok = ')' then
      begin
        Inc(Posn);
        exit;
      end;

      // Plain all-of group.
      if tok = '(' then
      begin
        Inc(Posn);
        ParseGroup(Active);
        continue;
      end;

      // Any-of.  For package dependency variables PMS only permits || here;
      // accepting ^^/?? as groups as well makes malformed/legacy metadata fail
      // conservative rather than accidentally treating them as atoms.
      if (tok = '||') or (tok = '^^') or (tok = '??') then
      begin
        Inc(Posn);
        if (Posn < Tokens.Count) and (Tokens[Posn] = '(') then
        begin
          Inc(Posn);
          ParseGroup(Active);
        end;
        continue;
      end;

      if ParseUseConditional(tok, flag, negated) then
      begin
        Inc(Posn);
        cond := Pkg.HasUseFlag(flag);
        if negated then cond := not cond;
        if (Posn < Tokens.Count) and (Tokens[Posn] = '(') then
        begin
          Inc(Posn);
          ParseGroup(Active and cond);
        end;
        continue;
      end;

      Inc(Posn);
      if Active then
      begin
        atom := NormalizeDep(tok);
        if atom <> '' then
          Dest.Add(atom);
      end;
    end;
  end;

begin
  Tokens := TStringList.Create;
  try
    TokenizeDeps(ARaw, Tokens);
    Posn := 0;
    ParseGroup(True);
  finally
    Tokens.Free;
  end;
end;

// True when AText contains ANeedle as a whole dependency token, i.e. it is
// preceded by an operator/whitespace/open-bracket (or starts the text) and
// followed by a non-atom character (or ends the text).
function MatchesAtomInText(const AText, ANeedle: string): boolean;
var
  at: integer;
begin
  at := 1;
  while True do
  begin
    at := PosEx(ANeedle, AText, at);
    if at = 0 then exit(False);
    if (at = 1) or (AText[at - 1] in OpChars + ['(', ' ']) then
      if (at + Length(ANeedle) > Length(AText)) or
         not (AText[at + Length(ANeedle)] in AtomChars) then
        exit(True);
    Inc(at);
  end;
end;

// Looser variant for range operators: ">=/<=/~=/>/<" also have to match when
// the dependency pins a revision our version omits (">=sys-libs/glibc-2.43"
// must match ">=/sys-libs/glibc-2.43-r4"), so a trailing "-rN" is tolerated.
function MatchesVersionRangeInText(const AText, ANeedle: string): boolean;
var
  at, after: integer;
begin
  at := 1;
  while True do
  begin
    at := PosEx(ANeedle, AText, at);
    if at = 0 then exit(False);
    if (at = 1) or (AText[at - 1] in OpChars + ['(', ' ']) then
    begin
      after := at + Length(ANeedle);
      if (after > Length(AText)) or not (AText[after] in AtomChars) then
        exit(True);
      // Only a revision suffix may trail the version.
      if (AText[after] = '-') and (after + 1 <= Length(AText)) and
         (AText[after + 1] = 'r') and
         (after + 2 <= Length(AText)) and (AText[after + 2] in ['0'..'9']) and
         ((after + 3 > Length(AText)) or not (AText[after + 3] in AtomChars)) then
        exit(True);
    end;
    Inc(at);
  end;
end;

// Dep atoms in the index are version-stripped, so "=cat/pkg-1.2.3" cannot be
// answered from DependAtoms alone. Versioned queries are rare, so rather than
// keeping every raw dep line around we re-read the dependency files and look for
// the versioned atom in the text.
//
// This compares text rather than evaluating portage version ranges, so it
// over-approximates: ">=cat/pkg-1.2" also matches a dependant pinning
// ">=cat/pkg-1.9". For a reverse-dependency query that is the safe direction -
// it never hides a dependant, it can only list a few extra ones.
function MatchesVersion(const APkg: TPkgInfo; const AOp, ACat, APkgName,
  AVersion: string): boolean;
const
  DepFiles: array[0..4] of string = ('DEPEND', 'RDEPEND', 'PDEPEND', 'BDEPEND', 'IDEPEND');
var
  i, at: integer;
  needle: string;
  sl: TStringList;
begin
  Result := False;
  if APkg = nil then exit;

  needle := ACat + '/' + APkgName + '-' + AVersion;

  for i := Low(DepFiles) to High(DepFiles) do
  begin
    if not FileExists(APkg.PkgDir + '/' + DepFiles[i]) then continue;
    sl := TStringList.Create;
    try
      sl.LoadFromFile(APkg.PkgDir + '/' + DepFiles[i]);
      for at := 0 to sl.Count - 1 do
        if (AOp = '=') and MatchesAtomInText(sl[at], needle) then
        begin
          Result := True;
          exit;
        end
        else if (AOp <> '=') and MatchesVersionRangeInText(sl[at], needle) then
        begin
          Result := True;
          exit;
        end;
    finally
      sl.Free;
    end;
  end;
end;

// Portage keeps in-progress and rolled-back installs in sibling directories
// whose names are prefixed with a state marker. They are not installed
// packages: they have no CONTENTS and reporting them makes "epkg list" show
// duplicates and orphans that do not exist.
function IsTransientPkgDir(const ADirName: string): boolean;
const
  Markers: array[0..4] of string =
    ('-MERGING-', '-MERGED-', '-SAVE-', '-CH-', '-CLEAN-');
var
  i: integer;
begin
  for i := Low(Markers) to High(Markers) do
    if Copy(ADirName, 1, Length(Markers[i])) = Markers[i] then
      exit(True);
  Result := False;
end;

function ActiveDBPath: string;
var
  v: string;
begin
  v := GetEnvironmentVariable(DBEnvVar);
  if (v <> '') and (v[1] = '/') then
    Result := v
  else
    Result := DefaultDBPath;
end;

function StripVersion(const ACpv: string): string;
var
  i, catpos: integer;
begin
  Result := ACpv;
  catpos := Pos('/', Result);
  for i := Length(Result) downto catpos + 1 do
    if (Result[i] = '-') and (i < Length(Result)) and (Result[i + 1] in ['0'..'9']) then
    begin
      Result := Copy(Result, 1, i - 1);
      exit;
    end;
end;

function ExtractVersion(const ACpv: string): string;
var
  full: string;
begin
  full := StripVersion(ACpv);
  if full = ACpv then
    Result := ''
  else
    Result := Copy(ACpv, Length(full) + 2, Length(ACpv) - Length(full) - 1);
end;

function StripRevision(const AVersion: string): string;
var
  i: integer;
begin
  Result := AVersion;
  if Result = '' then exit;
  i := RPos('-', Result);
  if (i > 0) and (i < Length(Result)) and (Result[i + 1] in ['r', 'R']) then
    Result := Copy(Result, 1, i - 1);
end;

function ParseAtomOp(const AAtom: string; out AOp, ACat, APkg, AVersion,
  ASlot: string): boolean;
var
  s, rest: string;
  i, b, c: integer;
begin
  AOp := '';
  ACat := '';
  APkg := '';
  AVersion := '';
  ASlot := '';

  // Flatten whitespace so a stray tab or newline in an atom cannot break parsing.
  s := '';
  for i := 1 to Length(AAtom) do
    if AAtom[i] in [#9, #10, #13] then
      s := s + ' '
    else
      s := s + AAtom[i];
  s := Trim(s);
  if s = '' then exit(False);

  // Keep the operator prefix, then drop the rest of it. "!!" and "@@" are not
  // version comparisons, so they leave AOp empty and only suppress blocking.
  if (s <> '') and (s[1] in OpChars) then
  begin
    if s[1] in ['<', '>', '=', '~'] then
      AOp := s[1]
    else if (s[1] = '!') or (s[1] = '@') then
      AOp := ''
    else
      AOp := '';
    if (Length(s) >= 2) and (s[2] = '=') and (AOp <> '') then
      AOp := AOp + '=';
  end;
  while (s <> '') and (s[1] in OpChars) do
    s := Copy(s, 2, Length(s) - 1);
  if s = '' then exit(False);

  c := Pos('/', s);
  if c = 0 then
    exit(False);

  ACat := Copy(s, 1, c - 1);
  rest := Copy(s, c + 1, Length(s) - c);
  if ACat = '' then exit(False);

  // Slot / subslot, ":2/3=" or ":0" or ":*".
  b := PosEx(':', rest, 1);
  if b > 0 then
  begin
    ASlot := Copy(rest, b + 1, Length(rest) - b);
    rest := Copy(rest, 1, b - 1);
    // Trailing "=" marks an exact slot match.
    if (ASlot <> '') and (ASlot[Length(ASlot)] = '=') then
      SetLength(ASlot, Length(ASlot) - 1);
    if Pos('/', ASlot) > 0 then
      ASlot := Copy(ASlot, 1, Pos('/', ASlot) - 1);
  end;

  // USE dependencies.
  b := PosEx('[', rest, 1);
  if b > 0 then rest := Copy(rest, 1, b - 1);

  if rest = '' then exit(False);

  APkg := StripVersion(rest);
  AVersion := ExtractVersion(rest);

  // Sanity: both halves must look like identifiers, otherwise this was not an
  // atom (e.g. a bare word or a URL).
  for i := 1 to Length(ACat) do
    if not (ACat[i] in AtomChars) then exit(False);
  if APkg = '' then exit(False);
  for i := 1 to Length(APkg) do
    if not (APkg[i] in AtomChars) then exit(False);

  Result := True;
end;

function ParseAtom(const AAtom: string; out ACat, APkg, AVersion, ASlot: string): boolean;
var
  op: string;
begin
  Result := ParseAtomOp(AAtom, op, ACat, APkg, AVersion, ASlot);
end;

// True when ADep is a blocking atom. Portage has three spellings: "!" is a weak
// blocker, "!!" a strong one and "?" a PMS weak blocker. None of them express a
// dependency, so none of them may become a reverse dependency.
function IsBlockerDep(const ADep: string): boolean;
var
  i: integer;
begin
  i := 1;
  while (i <= Length(ADep)) and (ADep[i] in [' ', #9]) do Inc(i);
  Result := (i <= Length(ADep)) and (ADep[i] in ['!', '?']);
end;

function NormalizeDep(const ADep: string): string;
var
  cat, pkg, ver, slot: string;
begin
  Result := '';
  // A blocker ("!cat/pkg", "!!cat/pkg", "?cat/pkg") declares that the package
  // must *not* be installed. Treating it as a dependency would list every
  // package that forbids something as depending on it, which is the opposite
  // of the truth - e.g. net-tools has "!sys-apps/coreutils[hostname]".
  if IsBlockerDep(ADep) then exit;
  if ParseAtom(ADep, cat, pkg, ver, slot) then
    Result := cat + '/' + pkg;
end;

function LooksLikeLibrary(const APath: string): boolean;
var
  base: string;
begin
  base := ExtractFileName(APath);
  Result := (Pos('.so', base) > 0) and (base <> '') and (base[1] <> '.');
end;

{ -------------------------------------------------------------------------- }

constructor TPkgInfo.Create;
begin
  inherited Create;
  FUseFlags := TStringList.Create;
  FUseFlags.Duplicates := dupIgnore;
  FIUse := TStringList.Create;
  FIUse.Duplicates := dupIgnore;
  FDependAtoms := TStringList.Create;
  FDependAtoms.Sorted := True;
  FDependAtoms.Duplicates := dupIgnore;
  FRuntimeDependAtoms := TStringList.Create;
  FRuntimeDependAtoms.Sorted := True;
  FRuntimeDependAtoms.Duplicates := dupIgnore;
FContents := TStringList.Create;
    FContents.Sorted := True;
    FContents.Duplicates := dupIgnore;
    Slot := '0';
    FContentsLoaded := False;
end;

destructor TPkgInfo.Destroy;
begin
  FUseFlags.Free;
  FIUse.Free;
  FDependAtoms.Free;
  FRuntimeDependAtoms.Free;
  FContents.Free;
  inherited Destroy;
end;

function TPkgInfo.GetCPV: string;
begin
  if Version = '' then
    Result := Atom
  else
    Result := Atom + '-' + Version;
end;

function TPkgInfo.GetAtom: string;
begin
  Result := Category + '/' + Name;
end;

function TPkgInfo.GetUseFlags: TStringList;
begin
  Result := FUseFlags;
end;

function TPkgInfo.GetIUse: TStringList;
begin
  Result := FIUse;
end;

function TPkgInfo.GetDependAtoms: TStringList;
begin
  Result := FDependAtoms;
end;

function TPkgInfo.GetRuntimeDependAtoms: TStringList;
begin
  Result := FRuntimeDependAtoms;
end;

function TPkgInfo.GetContents: TStringList;
begin
  Result := FContents;
end;

function TPkgInfo.GetContentsLoaded: boolean;
begin
  Result := FContentsLoaded;
end;

function TPkgInfo.GetVersionNoRev: string;
begin
  Result := StripRevision(Version);
end;

function TPkgInfo.GetRev: string;
var
  i: integer;
begin
  Result := '';
  i := RPos('-', Version);
  if (i > 0) and (i < Length(Version)) and (Version[i + 1] in ['r', 'R']) then
    Result := Copy(Version, i + 1, Length(Version) - i);
end;

function TPkgInfo.HasUseFlag(const Flag: string): boolean;
begin
  Result := FUseFlags.IndexOf(Flag) >= 0;
end;

function TPkgInfo.DeclaresUseFlag(const Flag: string): boolean;
var
  i: integer;
begin
  Result := FUseFlags.IndexOf(Flag) >= 0;
  if not Result then
  begin
    i := FIUse.IndexOf(Flag);
    Result := i >= 0;
  end;
end;

procedure TPkgInfo.LoadContents;
var
  sl: TStringList;
  i, sp: integer;
  kind, path: string;
begin
  if FContentsLoaded then exit;
  FContentsLoaded := True;
  if not HasContentsFile then exit;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(PkgDir + DirectorySeparator + 'CONTENTS');
    for i := 0 to sl.Count - 1 do
    begin
      // "obj /path <md5> <mtime>", "dir /path <mtime>",
      // "sym /path -> target <mtime>", "fif /path <mtime>", "dev /path <mtime>".
      // The path is always the token after the kind; the rest of the line is
      // metadata and must not end up in the index.
      sp := Pos(' ', sl[i]);
      if sp <= 1 then continue;
      kind := Copy(sl[i], 1, sp - 1);
      if not ((kind = 'obj') or (kind = 'dir') or (kind = 'sym') or
              (kind = 'fif') or (kind = 'dev')) then continue;
      path := Copy(sl[i], sp + 1, Length(sl[i]) - sp);
      sp := Pos(' ', path);
      if sp > 0 then path := Copy(path, 1, sp - 1);
      path := Trim(path);
      if path <> '' then
        FContents.Add(path);
    end;
  finally
    sl.Free;
  end;
end;

{ -------------------------------------------------------------------------- }

function ComparePkgProc(Item1, Item2: Pointer): Integer;
begin
  // TList hands the object address itself, not a pointer to it, so no
  // dereference is needed here.
  Result := AnsiCompareText(TPkgInfo(Item1).CPV, TPkgInfo(Item2).CPV);
end;

constructor TPortageDB.Create(const ADbPath: string);
begin
  inherited Create;
  if ADbPath = '' then
    FPath := ActiveDBPath
  else
    FPath := ADbPath;
  FPackages := TObjectList.Create(True);
  // dupAccept is deliberate: two installed packages claiming the same path is
  // a real broken-vardb condition we want to be able to detect, not noise.
  // Sorted stays off until BuildFileIndex has finished bulk-inserting; an
  // already-sorted list would shift the array on every one of the ~470k adds
  // and turn the build quadratic.
  FPathIndex := TStringList.Create;
  FPathIndex.Sorted := False;
  FPathIndex.Duplicates := dupAccept;
  Scan;
end;

destructor TPortageDB.Destroy;
begin
  FPackages.Free;
  FPathIndex.Free;
  inherited Destroy;
end;

function TPortageDB.GetDbPath: string;
begin
  Result := FPath;
end;

function TPortageDB.GetCount: integer;
begin
  Result := FPackages.Count;
end;

procedure TPortageDB.Scan;
var
  finder: TSearchRec;
  pkgFinder: TSearchRec;
  ver: string;
  sl: TStringList;

  procedure ReadOne(const CatDir, PkgDirName: string);
  var
    p: TPkgInfo;
    i, j: integer;
    Base: string;
    DepFiles: array[0..4] of string;
  begin
    // Work from the directory name only. StripVersion on a full path would
    // happily chew through a hyphen that belongs to a parent directory.
    Base := ExtractFileName(PkgDirName);
    ver := ExtractVersion(Base);
    if ver = '' then exit;   // not a package directory
    p := TPkgInfo.Create;
    p.Category := CatDir;
    p.Name := StripVersion(Base);
    p.Version := ver;
    p.PkgDir := PkgDirName;
    p.HasContentsFile := FileExists(PkgDirName + '/CONTENTS');

    // CATEGORY and SLOT are single line files; prefer them over deriving.
    if FileExists(PkgDirName + '/CATEGORY') then
    begin
      sl := TStringList.Create;
      try
        sl.LoadFromFile(PkgDirName + '/CATEGORY');
        if sl.Count > 0 then p.Category := Trim(sl[0]);
      finally
        sl.Free;
      end;
    end;

    if FileExists(PkgDirName + '/SLOT') then
    begin
      sl := TStringList.Create;
      try
        sl.LoadFromFile(PkgDirName + '/SLOT');
        if sl.Count > 0 then p.Slot := Trim(sl[0]);
      finally
        sl.Free;
      end;
    end;

    if FileExists(PkgDirName + '/USE') then
    begin
      sl := TStringList.Create;
      try
        sl.LoadFromFile(PkgDirName + '/USE');
        for j := 0 to sl.Count - 1 do
          AddWords(p.UseFlags, sl[j], False);
      finally
        sl.Free;
      end;
    end;

    if FileExists(PkgDirName + '/IUSE') then
    begin
      sl := TStringList.Create;
      try
        sl.LoadFromFile(PkgDirName + '/IUSE');
        for j := 0 to sl.Count - 1 do
          AddWords(p.IUse, sl[j], True);
      finally
        sl.Free;
      end;
    end;

    // Keep every dependency class for general queries, but evaluate USE
    // conditionals using the flags recorded for this installed package.
    DepFiles[0] := 'DEPEND';  DepFiles[1] := 'RDEPEND';
    DepFiles[2] := 'PDEPEND'; DepFiles[3] := 'BDEPEND';
    DepFiles[4] := 'IDEPEND';
    for i := 0 to High(DepFiles) do
      if FileExists(PkgDirName + '/' + DepFiles[i]) then
      begin
        sl := TStringList.Create;
        try
          sl.LoadFromFile(PkgDirName + '/' + DepFiles[i]);
          AddActiveDepAtoms(p, sl.Text, p.DependAtoms);
          // Recursive removal should follow dependencies needed by an already
          // installed package at runtime.  DEPEND/BDEPEND are build-time only,
          // and IDEPEND may be removed after installation.  PDEPEND is a
          // post-merge runtime dependency and belongs with RDEPEND.
          if (DepFiles[i] = 'RDEPEND') or (DepFiles[i] = 'PDEPEND') then
            AddActiveDepAtoms(p, sl.Text, p.RuntimeDependAtoms);
        finally
          sl.Free;
        end;
      end;

    FPackages.Add(p);
  end;

begin
  if not DirectoryExists(FPath) then
    raise EPkgError.CreateFmt('vardb not found: %s (set %s to override)',
      [FPath, DBEnvVar]);

  // Walk the two level category/package layout.
  //
  // Note on FPC semantics, which differ from Delphi: FindFirst/FindNext return
  // 0 on success and a nonzero error code when there is nothing left, so the
  // tests are written the other way round from what Delphi code looks like.
  // Also note that pattern '*' yields "." and ".." entries, which must be
  // filtered explicitly or the scan will recurse forever.
  if FindFirst(FPath + DirectorySeparator + '*', faDirectory, finder) = 0 then
  begin
    repeat
      if (finder.Name <> '.') and (finder.Name <> '..') and
         ((finder.Attr and faDirectory) <> 0) then
      begin
        if FindFirst(FPath + DirectorySeparator + finder.Name + DirectorySeparator +
                     '*', faDirectory, pkgFinder) = 0 then
        begin
          repeat
            if (pkgFinder.Name <> '.') and (pkgFinder.Name <> '..') and
               ((pkgFinder.Attr and faDirectory) <> 0) and
               (not IsTransientPkgDir(pkgFinder.Name)) then
              ReadOne(finder.Name, FPath + DirectorySeparator + finder.Name +
                DirectorySeparator + pkgFinder.Name);
          until FindNext(pkgFinder) <> 0;
          FindClose(pkgFinder);
        end;
      end;
    until FindNext(finder) <> 0;
    FindClose(finder);
  end;

  // Stable, deterministic ordering so every tool prints the same list.
  FPackages.Sort(@ComparePkgProc);
end;

function TPortageDB.FindByCPV(const ACpv: string): TPkgInfo;
var
  i: integer;
begin
  Result := nil;
  for i := 0 to FPackages.Count - 1 do
    if TPkgInfo(FPackages[i]).CPV = ACpv then
    begin
      Result := TPkgInfo(FPackages[i]);
      exit;
    end;
end;

function TPortageDB.FindAll(const AName: string): TObjectList;
var
  cat, pkg, ver, slot: string;
  wantCat, wantPkg, wantVer, wantSlot: string;
  haveAtom: boolean;
  i: integer;
  p: TPkgInfo;
begin
  // OwnsObjects stays false: these TPkgInfo objects are owned by the database.
  Result := TObjectList.Create(False);
  haveAtom := ParseAtom(AName, cat, pkg, ver, slot);
  if not haveAtom then
  begin
    // A bare word with no category: treat the whole thing as a package name.
    cat := '';
    pkg := Trim(AName);
    ver := '';
    if pkg = '' then exit;
  end;
  wantCat := cat;
  wantPkg := pkg;
  wantVer := ver;
  wantSlot := slot;

  for i := 0 to FPackages.Count - 1 do
  begin
    p := TPkgInfo(FPackages[i]);
    if (p.Name <> wantPkg) then continue;
    if (wantCat <> '') and (p.Category <> wantCat) then continue;
    if (wantVer <> '') and (p.Version <> wantVer) then continue;
    if (wantSlot <> '') and (p.Slot <> wantSlot) then continue;
    Result.Add(p);
  end;

  // The TPkgInfo instances belong to the database, never to this list.
  Result.OwnsObjects := False;
  Result.Sort(@ComparePkgProc);
end;

function TPortageDB.IsInstalled(const AAtom: string): boolean;
var
  l: TObjectList;
begin
  // FindAll hands back a non-owning list that still has to be freed, otherwise
  // this leaks a list every time a caller asks a yes/no question.
  l := FindAll(AAtom);
  try
    Result := l.Count > 0;
  finally
    l.Free;
  end;
end;

// On a merged-/usr system the same file is reachable under two names: the
// physical /usr/lib64/libc.so.6 and the compatibility alias /lib64/libc.so.6
// (a symlink to usr/lib64). Portage records whichever name the ebuild used, so
// an exact string comparison reports half the system as unowned. Both CONTENTS
// entries and lookup paths are therefore normalised to the physical spelling
// before they meet in the index.
//
// The alias table is read from the filesystem rather than hardcoded, so it
// adapts to whichever of /bin, /sbin, /lib, /lib64, /usr/bin, /usr/sbin,
// /usr/lib and /usr/lib64 are symlinks, and follows short chains such as
// /sbin -> usr/sbin -> bin. A genuinely split-/usr system has none of these
// symlinks, so nothing is rewritten and behaviour is unchanged.
type
  TPathAlias = record
    AFrom: string;
    ATo: string;
  end;

var
  Aliases: array of TPathAlias;
  AliasesBuilt: boolean = False;

function AliasesParent(const APath: string): string;
var
  i: integer;
begin
  for i := Length(APath) downto 1 do
    if APath[i] = '/' then
      exit(Copy(APath, 1, i - 1));
  Result := '';
end;

// Collapse //, /./ and /../ so symlink chains compare reliably.
function NormalizePath(const APath: string): string;
var
  comps: TStringList;
  i, j: integer;
  comp, res: string;
begin
  comps := TStringList.Create;
  try
    i := 1;
    if (APath <> '') and (APath[1] = '/') then i := 2;
    comp := '';
    for j := i to Length(APath) + 1 do
    begin
      if (j > Length(APath)) or (APath[j] = '/') then
      begin
        if comp = '..' then
        begin
          if comps.Count > 0 then comps.Delete(comps.Count - 1);
        end
        else if (comp <> '') and (comp <> '.') then
          comps.Add(comp);
        comp := '';
      end
      else
        comp := comp + APath[j];
    end;
    res := '';
    for j := 0 to comps.Count - 1 do
      res := res + '/' + comps[j];
    if res = '' then res := '/';
    Result := res;
  finally
    comps.Free;
  end;
end;

const
  AliasRoots: array[0..7] of string = (
    '/bin', '/sbin', '/lib', '/lib64',
    '/usr/bin', '/usr/sbin', '/usr/lib', '/usr/lib64');

procedure BuildAliases;
var
  i, j, depth: integer;
  target, parent, absTarget: string;
  changed: boolean;
begin
  if AliasesBuilt then exit;
  AliasesBuilt := True;
  SetLength(Aliases, 0);
  for i := Low(AliasRoots) to High(AliasRoots) do
  begin
    target := fpReadLink(AliasRoots[i]);
    if target = '' then continue;
    if target[1] = '/' then
      absTarget := NormalizePath(target)
    else
    begin
      parent := AliasesParent(AliasRoots[i]);
      if parent = '' then parent := '/';
      if parent = '/' then
        absTarget := NormalizePath('/' + target)
      else
        absTarget := NormalizePath(parent + '/' + target);
    end;
    SetLength(Aliases, Length(Aliases) + 1);
    Aliases[High(Aliases)].AFrom := AliasRoots[i];
    Aliases[High(Aliases)].ATo := absTarget;
  end;

  // Follow short chains (/sbin -> /usr/sbin -> /usr/bin).
  for depth := 1 to 8 do
  begin
    changed := False;
    for i := 0 to High(Aliases) do
      for j := 0 to High(Aliases) do
        if (Aliases[i].ATo = Aliases[j].AFrom) and
           (Aliases[i].ATo <> Aliases[j].ATo) then
        begin
          Aliases[i].ATo := Aliases[j].ATo;
          changed := True;
        end;
    if not changed then break;
  end;
end;

function IsMergedUsr: boolean;
begin
  BuildAliases;
  Result := Length(Aliases) > 0;
end;

// Applies AFrom -> ATo only when AFrom is a leading component of APath, so
// aliasing /lib never rewrites /lib64 or /libexec. A no-op otherwise.
function CanonicalPathApply(const APath, AFrom, ATo: string): string;
begin
  Result := APath;
  if (AFrom = '') or (Length(AFrom) > Length(APath)) then exit;
  if Copy(APath, 1, Length(AFrom)) <> AFrom then exit;
  if (Length(APath) > Length(AFrom)) and (APath[Length(AFrom) + 1] <> '/') then exit;
  Result := ATo + Copy(APath, Length(AFrom) + 1, MaxInt);
end;

function CanonicalPath(const APath: string): string;
var
  i, bestLen: integer;
  cand: string;
begin
  Result := APath;
  BuildAliases;
  bestLen := -1;
  for i := 0 to High(Aliases) do
    if Length(Aliases[i].AFrom) > bestLen then
    begin
      cand := CanonicalPathApply(APath, Aliases[i].AFrom, Aliases[i].ATo);
      if cand <> APath then
      begin
        Result := cand;
        bestLen := Length(Aliases[i].AFrom);
      end;
    end;
end;

procedure TPortageDB.BuildFileIndex;
var
  i, j: integer;
  p: TPkgInfo;
begin
  if FPathIndexBuilt then exit;
  for i := 0 to FPackages.Count - 1 do
  begin
    p := TPkgInfo(FPackages[i]);
    p.LoadContents;
    for j := 0 to p.Contents.Count - 1 do
      FPathIndex.AddObject(CanonicalPath(p.Contents[j]), p);
  end;
  // Sorting here rather than on every insert keeps the build linear; turning
  // Sorted back on afterwards is what makes IndexOf use a binary search.
  FPathIndex.Sort;
  FPathIndex.Sorted := True;
  FPathIndexBuilt := True;
end;

function TPortageDB.OwnerOf(const APath: string): TPkgInfo;
var
  ignored: Boolean;
begin
  Result := OwnerOf(APath, ignored);
end;

function TPortageDB.OwnerOf(const APath: string; var AContested: Boolean): TPkgInfo;
var
  i: integer;
  key: string;
  owner: TPkgInfo;
begin
  BuildFileIndex;
  Result := nil;
  AContested := False;
  key := CanonicalPath(APath);
  i := FPathIndex.IndexOf(key);
  if i < 0 then exit;

  owner := TPkgInfo(FPathIndex.Objects[i]);
  Result := owner;

  // Two installed packages both recording the same path is a broken vardb, so
  // flag it rather than silently picking a winner.
  if (i + 1 < FPathIndex.Count) and (FPathIndex[i + 1] = key) then
    AContested := True;
end;

function TPortageDB.IsOwned(const APath: string): boolean;
begin
  Result := OwnerOf(APath) <> nil;
end;

function TPortageDB.OwnerPathOf(const APath: string): string;
var
  owner: TPkgInfo;
  i: integer;
  key: string;
begin
  Result := '';
  owner := OwnerOf(APath);
  if owner = nil then exit;
  key := CanonicalPath(APath);
  for i := 0 to owner.Contents.Count - 1 do
    if CanonicalPath(owner.Contents[i]) = key then
      exit(owner.Contents[i]);
  Result := APath;
end;

function TPortageDB.OwnedCount: integer;
begin
  BuildFileIndex;
  Result := FPathIndex.Count;
end;

function TPortageDB.ReverseDependsAtom(const AAtom: string; AExactVersion: string): TObjectList;
var
  q: string;
begin
  // ReverseDepends already understands both spellings; keeping one
  // implementation avoids the two drifting apart.
  if AExactVersion <> '' then
    q := '=' + AAtom + '-' + AExactVersion
  else
    q := AAtom;
  Result := ReverseDepends(q);
end;

function TPortageDB.ReverseRuntimeDepends(const ADep: string): TObjectList;
var
  op, cat, pkg, ver, slot: string;
  wantAtom: string;
  bare: boolean;
  i, j: integer;
  p: TPkgInfo;
  depPkg: string;
  found: boolean;
begin
  Result := TObjectList.Create(False);

  bare := not ParseAtomOp(ADep, op, cat, pkg, ver, slot);
  if bare then
  begin
    cat := '';
    pkg := Trim(ADep);
    ver := '';
    op := '';
  end;
  wantAtom := cat + '/' + pkg;

  for i := 0 to FPackages.Count - 1 do
  begin
    p := TPkgInfo(FPackages[i]);
    if p.Atom = wantAtom then continue;

    found := False;
    for j := 0 to p.RuntimeDependAtoms.Count - 1 do
    begin
      if bare then
      begin
        depPkg := Copy(p.RuntimeDependAtoms[j], Pos('/', p.RuntimeDependAtoms[j]) + 1,
                       Length(p.RuntimeDependAtoms[j]));
        if depPkg = pkg then
        begin
          found := True;
          break;
        end;
      end
      else if p.RuntimeDependAtoms[j] = wantAtom then
      begin
        found := True;
        break;
      end;
    end;

    // gnt-get remove asks with an unversioned installed atom. Keep versioned
    // API queries conservative until full PMS range evaluation is implemented.
    if found and (ver <> '') then
      found := MatchesVersion(p, op, cat, pkg, ver);

    if found then Result.Add(p);
  end;
  Result.Sort(@ComparePkgProc);
end;

function TPortageDB.ReverseDepends(const ADep: string): TObjectList;
var
  op, cat, pkg, ver, slot: string;
  wantAtom: string;
  bare: boolean;
  i, j: integer;
  p: TPkgInfo;
  depPkg: string;
  found: boolean;
begin
  Result := TObjectList.Create(False);

  bare := not ParseAtomOp(ADep, op, cat, pkg, ver, slot);
  if bare then
  begin
    cat := '';
    pkg := Trim(ADep);
    ver := '';
    op := '';
  end;
  wantAtom := cat + '/' + pkg;

  for i := 0 to FPackages.Count - 1 do
  begin
    p := TPkgInfo(FPackages[i]);

    // A package must not be reported as depending on itself.
    if p.Atom = wantAtom then continue;

    // A bare query ("glibc") matches any category, so the candidates are
    // every installed package whose dep *atoms* mention it. The original epkg
    // filtered on the package name instead, which made "depends glibc" return
    // nothing at all.
    found := False;
    for j := 0 to p.DependAtoms.Count - 1 do
    begin
      if bare then
      begin
        depPkg := Copy(p.DependAtoms[j], Pos('/', p.DependAtoms[j]) + 1,
                       Length(p.DependAtoms[j]));
        if depPkg = pkg then
        begin
          found := True;
          break;
        end;
      end
      else if p.DependAtoms[j] = wantAtom then
      begin
        found := True;
        break;
      end;
    end;

    // A query carrying a version constrains the range: "=cat/pkg-1.2.3" only
    // matches dependants pinning that version, ">=cat/pkg-1.2" matches a whole
    // range. Dep atoms are stored version-stripped, so this falls back to a
    // text search of the raw dep files rather than silently reporting every
    // dependant.
    if found and (ver <> '') then
      found := MatchesVersion(p, op, cat, pkg, ver);

    if found then Result.Add(p);
  end;
  Result.Sort(@ComparePkgProc);
end;

initialization
end.