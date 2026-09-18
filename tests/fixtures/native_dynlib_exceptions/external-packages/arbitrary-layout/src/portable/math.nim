import types

proc externalDouble*(value: int): int {.raises: [].} =
  value * 2

proc identityValue*[T](value: T): T {.raises: [].} =
  value
