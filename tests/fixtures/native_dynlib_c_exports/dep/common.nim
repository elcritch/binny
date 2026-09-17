type Image* = ref object
  width*, height*: int
  data*: seq[uint8]

proc newImage*(width, height: int): Image =
  Image(width: width, height: height, data: newSeq[uint8](width * height))

proc copy*(image: Image): Image =
  Image(width: image.width, height: image.height, data: image.data)

proc copy*(image: Image, offset: int): Image =
  result = image.copy()
  result.width += offset
