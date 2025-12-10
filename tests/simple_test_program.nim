## Simple test program to verify DWARF line info parsing

proc fibonacci(n: int): int =
  ## Calculate fibonacci number
  if n <= 1:
    return n
  else:
    return fibonacci(n-1) + fibonacci(n-2)

proc factorial(n: int): int =
  ## Calculate factorial
  if n <= 1:
    return 1
  else:
    return n * factorial(n-1)

proc main() =
  echo "Testing DWARF line info"
  let fib10 = fibonacci(10)
  let fact5 = factorial(5)
  echo "fib(10) = ", fib10
  echo "fact(5) = ", fact5

when isMainModule:
  main()
