proc doubleValue*(value: int): int {.raises: [].} =
  value * 2

proc failValue*(message: string): int =
  raise newException(ValueError, message)

proc maybeText*(shouldFail: bool): string =
  if shouldFail:
    raise newException(ValueError, "text failed")
  "text ok"

proc mutateThenFail*(value: var int) =
  value = 41
  raise newException(ValueError, "mutation failed")

proc privateFailure() =
  raise newException(ValueError, "inferred failure")

proc inferredFailure*() =
  privateFailure()

var storedValue = 7

proc borrowedValue*(shouldFail: bool): var int =
  if shouldFail:
    raise newException(ValueError, "borrow failed")
  storedValue

when not defined(exceptionIncremental):
  iterator valuesThenFail*(): int =
    yield 1
    yield 2
    raise newException(ValueError, "iterator failed")
