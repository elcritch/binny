import std/[strutils, strformat]

# Itanium C++ ABI Name Demangler
# Based on the Itanium C++ ABI specification for mangled names
# Supports basic demangling for common C++ constructs

type
  DemangleState = object
    input: string
    pos: int
    length: int

proc initState(mangled: string): DemangleState =
  DemangleState(input: mangled, pos: 0, length: mangled.len)

proc peek(state: var DemangleState): char =
  if state.pos < state.length:
    state.input[state.pos]
  else:
    '\0'

proc consume(state: var DemangleState): char =
  if state.pos < state.length:
    result = state.input[state.pos]
    inc state.pos
  else:
    result = '\0'

proc consumeIf(state: var DemangleState, expected: char): bool =
  if state.peek() == expected:
    discard state.consume()
    return true
  return false

proc consumeIf(state: var DemangleState, expected: string): bool =
  if state.pos + expected.len <= state.length:
    if state.input[state.pos..<state.pos + expected.len] == expected:
      state.pos += expected.len
      return true
  return false

proc parseNumber(state: var DemangleState): int =
  result = 0
  while state.pos < state.length and state.peek().isDigit():
    result = result * 10 + int(ord(state.consume()) - ord('0'))

proc parseIdentifier(state: var DemangleState): string =
  let length = parseNumber(state)
  if length > 0 and state.pos + length <= state.length:
    result = state.input[state.pos..<state.pos + length]
    state.pos += length
  else:
    result = ""

proc parseBuiltinType(state: var DemangleState): string =
  let c = state.consume()
  case c:
    of 'v': "void"
    of 'w': "wchar_t"
    of 'b': "bool"
    of 'c': "char"
    of 'a': "signed char"
    of 'h': "unsigned char"
    of 's': "short"
    of 't': "unsigned short"
    of 'i': "int"
    of 'j': "unsigned int"
    of 'l': "long"
    of 'm': "unsigned long"
    of 'x': "long long"
    of 'y': "unsigned long long"
    of 'n': "__int128"
    of 'o': "unsigned __int128"
    of 'f': "float"
    of 'd': "double"
    of 'e': "long double"
    of 'g': "__float128"
    of 'z': "..."
    else: fmt"<unknown:{c}>"

proc parseQualifiedName(state: var DemangleState): string
proc parseType(state: var DemangleState): string

proc parseNestedName(state: var DemangleState): string =
  if not state.consumeIf('N'):
    return ""

  var parts: seq[string] = @[]

  # Handle CV qualifiers
  while state.peek() in ['r', 'V', 'K']:
    discard state.consume()  # Skip qualifiers for now

  # Parse name components
  while state.pos < state.length and state.peek() != 'E':
    case state.peek():
      of '0'..'9':
        let part = parseIdentifier(state)
        if part.len > 0:
          parts.add(part)
      of 'S':
        # Substitution - simplified handling
        discard state.consume()
        if state.peek() == '_':
          discard state.consume()
        parts.add("<subst>")
      else:
        break

  if state.consumeIf('E'):
    result = parts.join("::")
  else:
    result = parts.join("::")

proc parseUnqualifiedName(state: var DemangleState): string =
  if state.peek().isDigit():
    return parseIdentifier(state)
  elif state.peek() == 'C':
    discard state.consume()
    if state.peek() in ['1', '2', '3']:
      discard state.consume()
      return "<constructor>"
  elif state.peek() == 'D':
    discard state.consume()
    if state.peek() in ['0', '1', '2']:
      discard state.consume()
      return "<destructor>"

  # Operator overloads
  case state.peek():
    of 'n':
      if state.consumeIf("nw"): return "operator new"
      elif state.consumeIf("na"): return "operator new[]"
      elif state.consumeIf("ng"): return "operator-"
      elif state.consumeIf("nt"): return "operator!"
    of 'p':
      if state.consumeIf("pl"): return "operator+"
      elif state.consumeIf("ps"): return "operator+"
    of 'm':
      if state.consumeIf("mi"): return "operator-"
      elif state.consumeIf("ml"): return "operator*"
    of 'd':
      if state.consumeIf("dv"): return "operator/"
      elif state.consumeIf("dl"): return "operator delete"
      elif state.consumeIf("da"): return "operator delete[]"
    of 'r':
      if state.consumeIf("rm"): return "operator%"
    of 'e':
      if state.consumeIf("eq"): return "operator=="
      elif state.consumeIf("eo"): return "operator^"
    of 'l':
      if state.consumeIf("lt"): return "operator<"
      elif state.consumeIf("le"): return "operator<="
      elif state.consumeIf("ls"): return "operator<<"
    of 'g':
      if state.consumeIf("gt"): return "operator>"
      elif state.consumeIf("ge"): return "operator>="
    of 'a':
      if state.consumeIf("an"): return "operator&"
      elif state.consumeIf("ad"): return "operator&"
      elif state.consumeIf("aS"): return "operator&="
    of 'o':
      if state.consumeIf("or"): return "operator|"
      elif state.consumeIf("oo"): return "operator||"
    else:
      discard

  let c = state.consume()
  return fmt"<op:{c}>"

proc parseQualifiedName(state: var DemangleState): string =
  case state.peek():
    of 'N':
      return parseNestedName(state)
    of '0'..'9':
      return parseIdentifier(state)
    of 'C', 'D':
      return parseUnqualifiedName(state)
    else:
      return parseUnqualifiedName(state)

proc parseType(state: var DemangleState): string =
  # Handle pointer, reference, const, etc.
  case state.peek():
    of 'P':
      discard state.consume()
      return parseType(state) & "*"
    of 'R':
      discard state.consume()
      return parseType(state) & "&"
    of 'K':
      discard state.consume()
      return "const " & parseType(state)
    of 'V':
      discard state.consume()
      return "volatile " & parseType(state)
    of 'S':
      discard state.consume()
      if state.peek().isDigit():
        discard parseNumber(state)
      if state.peek() == '_':
        discard state.consume()
      return "<subst>"
    of 'v', 'w', 'b', 'c', 'a', 'h', 's', 't', 'i', 'j', 'l', 'm', 'x', 'y', 'n', 'o', 'f', 'd', 'e', 'g', 'z':
      return parseBuiltinType(state)
    of '0'..'9', 'N':
      return parseQualifiedName(state)
    else:
      let c = state.consume()
      return fmt"<unknown-type:{c}>"

proc parseBareFunctionType(state: var DemangleState): string =
  # Parse return type (if present) and parameter types
  var params: seq[string] = @[]

  while state.pos < state.length and state.peek() != 'E':
    let paramType = parseType(state)
    if paramType.len > 0:
      params.add(paramType)
    else:
      break

  if params.len > 0:
    result = "(" & params.join(", ") & ")"
  else:
    result = "()"

proc parseEncoding(state: var DemangleState): string =
  case state.peek():
    of 'T':
      # Special names (vtables, typeinfo, etc.)
      discard state.consume()
      case state.peek():
        of 'V': return "<vtable>"
        of 'T': return "<VTT>"
        of 'I': return "<typeinfo>"
        of 'S': return "<typeinfo-name>"
        else: return "<special>"
    else:
      let name = parseQualifiedName(state)
      let funcType = parseBareFunctionType(state)
      return name & funcType

proc demangle*(mangled: string): string =
  ## Demangle an Itanium C++ ABI mangled name
  ## Returns the original name if not a mangled C++ name or if demangling fails

  # Check if it's a mangled C++ name (starts with _Z)
  if not mangled.startsWith("_Z"):
    return mangled

  var state = initState(mangled)

  # Consume _Z prefix
  if not state.consumeIf("_Z"):
    return mangled

  try:
    let demangled = parseEncoding(state)
    if demangled.len > 0:
      return demangled
    else:
      return mangled
  except:
    return mangled

proc isMangled*(name: string): bool =
  ## Check if a name appears to be Itanium C++ mangled
  name.startsWith("_Z") and name.len > 2

# Some test cases for validation
when isMainModule:
  let testCases = [
    ("_Z3foov", "foo()"),
    ("_Z3fooi", "foo(int)"),
    ("_ZN3Bar3fooEv", "Bar::foo()"),
    ("_ZN6MyName9ClassNameE", "MyName::ClassName"),
    ("_ZplRK7ComplexS1_", "operator+(const Complex&, const Complex&)"),
    # Simple cases that should work with our basic implementation
    ("main", "main"),  # Not mangled
    ("_Z4mainv", "main()"),
  ]

  echo "Testing C++ name demangler:"
  for (mangled, expected) in testCases:
    let result = demangle(mangled)
    echo fmt"  {mangled:30} -> {result}"