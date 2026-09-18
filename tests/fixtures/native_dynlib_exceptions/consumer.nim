import std/assertions
import exceptions_abi

doAssert doubleValue(21) == 42
doAssert maybeText(false) == "text ok"
doAssert externalDouble(6) == 12
doAssert identityValue(ExternalValue(amount: 9)).amount == 9

block typed_exception:
  var caught = false
  try:
    discard failValue("bridge value")
  except ValueError as error:
    caught = true
    doAssert error.msg == "bridge value"
  doAssert caught

block managed_result_failure:
  doAssertRaises ValueError:
    discard maybeText(true)

block mutation_before_failure:
  var value = 0
  try:
    mutateThenFail(value)
  except ValueError as error:
    doAssert error.msg == "mutation failed"
  doAssert value == 41

block inferred_effect:
  try:
    inferredFailure()
  except ValueError as error:
    doAssert error.msg == "inferred failure"

block borrowed_result:
  borrowedValue(false) = 11
  doAssert borrowedValue(false) == 11
  try:
    borrowedValue(true) = 12
  except ValueError as error:
    doAssert error.msg == "borrow failed"
  doAssert borrowedValue(false) == 11

when declared(valuesThenFail):
  block iterator_exception:
    var values: seq[int]
    try:
      for value in valuesThenFail():
        values.add value
    except ValueError as error:
      doAssert error.msg == "iterator failed"
    doAssert values == @[1, 2]

block repeated_failures:
  for index in 0 ..< 5:
    try:
      discard failValue("failure " & $index)
    except ValueError as error:
      doAssert error.msg == "failure " & $index

doAssert doubleValue(5) == 10
