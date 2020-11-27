import std/[os, strformat, strutils, terminal]
import pkg/[cligen/parseopt3]

type
  Mode* = enum
    modeChoose = "choose"
    modeInclude = "include"
    modeExclude = "exclude"

  Verbosity* = enum
    verQuiet = "quiet"
    verNormal = "normal"
    verDetailed = "detailed"

  Conf* = object
    exercise*: string
    check*: bool
    mode*: Mode
    verbosity*: Verbosity
    probSpecsDir*: string
    offline*: bool

  Opt = enum
    optExercise = "exercise"
    optCheck = "check"
    optMode = "mode"
    optVerbosity = "verbosity"
    optProbSpecsDir = "probSpecsDir"
    optOffline = "offline"
    optHelp = "help"
    optVersion = "version"

func genShortKeys: array[Opt, char] =
  ## Returns a lookup that gives the valid short option key for an `Opt`.
  for opt in Opt:
    if opt == optVersion:
      result[opt] = '_' # No short option for `--version`
    else:
      result[opt] = ($opt)[0]

const
  NimblePkgVersion {.strdefine.}: string = "unknown"

  short = genShortKeys()

  optsNoVal = {optCheck, optOffline, optHelp, optVersion}

func generateNoVals: tuple[shortNoVal: set[char], longNoVal: seq[string]] =
  ## Returns the short and long keys for the options in `optsNoVal`.
  result.shortNoVal = {}
  result.longNoVal = newSeq[string](optsNoVal.len)
  var i = 0
  for opt in optsNoVal:
    result.shortNoVal.incl(short[opt])
    result.longNoVal[i] = $opt
    inc i

const
  (shortNoVal, longNoVal) = generateNoVals()

func camelToKebab(s: string): string =
  ## Converts the string `s` to lowercase, adding a `-` before each previously
  ## uppercase letter.
  result = newStringOfCap(s.len + 2)
  for c in s:
    if c in {'A'..'Z'}:
      result &= '-'
      result &= toLowerAscii(c)
    else:
      result &= c

func list(opt: Opt): string =
  if short[opt] == '_':
    &"    --{camelToKebab($opt)}"
  else:
    &"-{short[opt]}, --{camelToKebab($opt)}"

func genHelpText: string =
  ## Returns a string that lists all the CLI options.

  func allowedValues(T: typedesc[enum]): string =
    ## Returns a string that describes the allowed values for an enum `T`.
    result = "Allowed values: "
    for val in T:
      result &= &"{($val)[0]}"
      result &= &"[{($val)[1 .. ^1]}], "
    setLen(result, result.len - 2)

  func genSyntaxStrings: tuple[syntax: array[Opt, string], maxLen: int] =
    ## Returns:
    ## - A lookup that returns the start of the help text for each option.
    ## - The length of the longest string in the above, which is useful to
    ##   set the column width.
    for opt in Opt:
      let paramName =
        case opt
        of optExercise: "slug"
        of optMode: "mode"
        of optVerbosity: "verbosity"
        of optProbSpecsDir: "dir"
        else: ""

      let paramText = if paramName.len > 0: &" <{paramName}>" else: ""
      let optText = &"  {opt.list}{paramText}  "
      result.syntax[opt] = optText
      result.maxLen = max(result.maxLen, optText.len)

  const (syntax, maxLen) = genSyntaxStrings()

  const descriptions: array[Opt, string] = [
    optExercise: "Only sync this exercise",
    optCheck: "Terminates with a non-zero exit code if one or more tests " &
              "are missing. Doesn't update the tests",
    optMode: &"What to do with missing test cases. {allowedValues(Mode)}",
    optVerbosity: &"The verbosity of output. {allowedValues(Verbosity)}",
    optProbSpecsDir: "Use this `problem-specifications` directory, " &
                     "rather than cloning temporarily",
    optOffline: "Do not check that the directory specified by " &
                &"`{list(optProbSpecsDir)}` is up-to-date",
    optHelp: "Show this help message and exit",
    optVersion: "Show this tool's version information and exit",
  ]

  result = "Options:\n"
  for opt in Opt:
    result &= alignLeft(syntax[opt], maxLen) & descriptions[opt] & "\n"
  setLen(result, result.len - 1)

proc showHelp(exitCode: range[0..255] = 0) =
  const helpText = genHelpText()
  let applicationName = extractFilename(getAppFilename())
  let usage = &"Usage: {applicationName} [options]\n\n"
  stdout.write usage
  echo helpText
  quit(exitCode)

proc showVersion =
  echo &"Canonical Data Syncer v{NimblePkgVersion}"
  quit(0)

proc showError*(s: string) =
  stdout.styledWrite(fgRed, "Error: ")
  stdout.write(s)
  stdout.write("\n\n")
  showHelp(exitCode = 1)

func formatOpt(kind: CmdLineKind, key: string, val = ""): string =
  ## Returns a string that describes an option, given its `kind`, `key` and
  ## optionally `val`. This is useful for displaying in error messages.
  runnableExamples:
    import pkg/[cligen/parseopt3]
    assert formatOpt(cmdShortOption, "h") == "'-h'"
    assert formatOpt(cmdLongOption, "help") == "'--help'"
    assert formatOpt(cmdShortOption, "v", "quiet") == "'-v': 'quiet'"
  let prefix =
    case kind
    of cmdShortOption: "-"
    of cmdLongOption: "--"
    of cmdArgument, cmdEnd, cmdError: ""
  result =
    if val.len > 0:
      &"'{prefix}{key}': '{val}'"
    else:
      &"'{prefix}{key}'"

proc initConf: Conf =
  result = Conf(
    exercise: "",
    check: false,
    mode: modeChoose,
    verbosity: verNormal,
    probSpecsDir: "",
    offline: false,
  )

func normalizeOption(s: string): string =
  ## Returns the string `s`, but converted to lowercase and without '_' or '-'.
  result = newString(s.len)
  var i = 0
  for c in s:
    if c in {'A'..'Z'}:
      result[i] = toLowerAscii(c)
      inc i
    elif c notin {'_', '-'}:
      result[i] = c
      inc i
  if i != s.len:
    setLen(result, i)

proc parseOption(kind: CmdLineKind, key: string, val: string): Opt =
  ## Parses `key` as an `Opt`, using a style-insensitive comparison.
  ##
  ## Raises an error:
  ## - if `key` cannot be parsed as an `Opt`.
  ## - if the parsed `Opt` requires a value, but `val` is of zero-length.
  var keyNormalized = normalizeOption(key)
  # Parse a valid single-letter abbreviation.
  if keyNormalized.len == 1:
    for opt in Opt:
      if keyNormalized[0] == short[opt]:
        keyNormalized = $opt
        break
  try:
    result = parseEnum[Opt](keyNormalized) # `parseEnum` does not normalize for `-`.
    if val.len == 0 and result notin optsNoVal:
      showError(&"{formatOpt(kind, key)} was given without a value")
  except ValueError:
    showError(&"invalid option: {formatOpt(kind, key)}")

proc parseVal[T: enum](kind: CmdLineKind, key: string, val: string): T =
  ## Parses `val` as a value of the enum `T`, using a case-insensitive
  ## comparsion.
  ##
  ## Exits with an error if `key` cannot be parsed as a value of `T`.
  var valNormalized = toLowerAscii(val)
  # Convert a valid single-letter abbreviation to the string value of the enum.
  if valNormalized.len == 1:
    for e in T:
      if valNormalized[0] == ($e)[0]:
        valNormalized = $e
        break
  try:
    result = parseEnum[T](valNormalized)
  except ValueError:
    showError(&"invalid value for {formatOpt(kind, key, val)}")

proc processCmdLine*: Conf =
  result = initConf()

  for kind, key, val in getopt(shortNoVal = shortNoVal, longNoVal = longNoVal):
    case kind
    of cmdLongOption, cmdShortOption:
      case parseOption(kind, key, val)
      of optExercise:
        result.exercise = val
      of optCheck:
        result.check = true
      of optMode:
        result.mode = parseVal[Mode](kind, key, val)
      of optVerbosity:
        result.verbosity = parseVal[Verbosity](kind, key, val)
      of optProbSpecsDir:
        result.probSpecsDir = val
      of optOffline:
        result.offline = true
      of optHelp:
        showHelp()
      of optVersion:
        showVersion()
    of cmdArgument:
      case key.toLowerAscii
      of $optHelp:
        showHelp()
      else:
        showError(&"invalid argument: '{key}'")
    # cmdError can only occur if we pass `requireSep = true` to `getopt`.
    of cmdEnd, cmdError:
      discard

  if result.offline and result.probSpecsDir.len == 0:
    showError(&"'{list(optOffline)}' was given without passing '{list(optProbSpecsDir)}'")
