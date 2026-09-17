proc newImage*(width, height: uint16): int = int(width) + int(height)
proc copy*(value: int): int = value + 100
proc readImage*(value: uint16): int {.inline.} = int(value) + 200
