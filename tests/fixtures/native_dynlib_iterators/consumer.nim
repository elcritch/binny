import iterators_abi

block empty_and_repeat:
  var values: seq[int]
  for value in counting(0): values.add value
  doAssert values.len == 0
  for _ in 0..<2:
    for value in counting(3): values.add value
  doAssert values == @[0, 1, 2, 0, 1, 2]

block lazy_break:
  resetVisited()
  for value in counting(100):
    doAssert value == 0
    break
  doAssert visitedCount() == 1

block nested:
  var values: seq[int]
  for outer in counting(2):
    for inner in counting(2):
      values.add outer * 10 + inner
  doAssert values == @[0, 1, 10, 11]

block overload_and_tuple:
  var values: seq[string]
  for value in counting("abc"): values.add value
  doAssert values == @["a", "ab", "abc"]
  values.setLen(0)
  for index, value in entries("abc"):
    doAssert value.len == index + 1
    values.add value
  doAssert values == @["a", "ab", "abc"]

block closure_state:
  var first = resumable
  var second = resumable
  doAssert first(3) == 0
  doAssert first(3) == 2
  doAssert second(3) == 0
  doAssert first(3) == 4
  discard first(3)
  doAssert finished(first)
  doAssert not finished(second)
  var values: seq[int]
  for value in resumable(3): values.add value
  doAssert values == @[0, 2, 4]

block borrowed_and_mutable:
  var values = @[1, 2, 3]
  for value in mutableValues(values): value *= 10
  doAssert values == @[10, 20, 30]
  var total = 0
  for value in borrowedValues(values): total += value
  doAssert total == 60

static:
  doAssert not declared(excluded)

block concrete_generic:
  var values: seq[int]
  for value in genericValues(@[4, 5]): values.add value
  doAssert values == @[4, 5]

block changing_arguments:
  var next = changing
  doAssert next(1) == 1
  doAssert next(2) == 2
  discard next(3)
  doAssert finished(next)

block void_yields:
  var next = pulses
  var count = 0
  next(count)
  doAssert count == 1
  next(count)
  doAssert count == 2
  next(count)
  doAssert finished(next)

block iterator_type:
  let next = makeIterator()
  var values: seq[int]
  for value in next(3): values.add value
  doAssert values == @[0, 2, 4]

block early_cleanup:
  let before_released = releasedCount()
  let before_finalized = finalizedCount()
  for value in guarded():
    doAssert value == 1
    break
  doAssert releasedCount() == before_released + 1
  doAssert finalizedCount() == before_finalized + 1

block sink_arguments:
  var values: seq[string]
  for value in ownedValues(@["a", "b", "c"]): values.add value
  doAssert values == @["a", "b", "c"]

block argument_names:
  var values: seq[int]
  for value in keywordValues(7, 8): values.add value
  doAssert values == @[7, 8]

block generic_closure_state:
  var next = genericClosure
  doAssert next("first") == "first"
  doAssert next("second") == "second"
  discard next("end")
  doAssert finished(next)

block evaluate_arguments_once:
  var calls = 0
  proc limit(): int =
    inc calls
    3
  var total = 0
  for value in counting(limit()): total += value
  doAssert calls == 1
  doAssert total == 3
  for value in counting(limit()): break
  doAssert calls == 2

block early_mutable_exit:
  var values = @[1, 2]
  for value in mutableValues(values):
    value = 9
    break
  doAssert values == @[9, 2]

block cleanup_after_consumer_exception:
  let before_finalized = finalizedCount()
  try:
    for value in guarded():
      raise newException(ValueError, "stop")
  except ValueError:
    discard
  doAssert finalizedCount() == before_finalized + 1

block cleanup_after_return:
  proc first(): int =
    for value in guarded(): return value
  let before_finalized = finalizedCount()
  doAssert first() == 1
  doAssert finalizedCount() == before_finalized + 1

static:
  doAssert not declared(privateValues)
  doAssert not declared(uninstantiated)
