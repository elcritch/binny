## Read-only FigDraw integration probe; all generated artifacts stay in Binny.
## Run with the BIF-capable compiler and a FigDraw Atlas checkout as argument.

import std/[assertions, json, os, osproc, strutils]
import binny/native_dynlib
import binny/native_dynlib/staticlib

proc run(arguments: openArray[string]) =
  var command: seq[string]
  for argument in arguments: command.add argument.quoteShell
  let executed = execCmdEx(command.join(" "))
  doAssert executed.exitCode == 0, command.join(" ") & "\n" & executed.output

doAssert paramCount() == 1, "usage: probe_figdraw_renderer /path/to/figdraw"
when not defined(macosx):
  quit("The FigDraw Metal renderer probe requires macOS.")
let
  figdraw = expandFilename(paramStr(1))
  probe = currentSourcePath.parentDir.parentDir / ".nimcache/figdraw-renderer-probe"
  cache = probe / "producer-cache"
  source = probe / "producer.nim"
  output = cache / "backend"
  library = probe / DynlibFormat.replace("$1", "figdraw_renderer_probe")
  compiler = getCurrentCompilerExe()
createDir(cache)
var paths = @["--path:" & figdraw / "src"]
for line in lines(figdraw / "nim.cfg"):
  if line.startsWith("--path:"):
    let path = line["--path:".len .. ^1].strip(chars = {'"'})
    paths.add "--path:" & absolutePath(path, figdraw)
writeFile(source, """
import figdraw/[figrender, figbackend]
import figdraw/windowing/siwinshim

type
  NativeRenderer* = FigRenderer[SiwinRenderBackend]
  ProbeContext = ref object of BackendContext
    lcd, subpixel, variants: bool

method kind(context: ProbeContext): RendererBackendKind = rbMetal
method textLcdFilteringEnabled(context: ProbeContext): bool = context.lcd
method setTextLcdFilteringEnabled(context: ProbeContext, enabled: bool) = context.lcd = enabled
method textSubpixelPositioningEnabled(context: ProbeContext): bool = context.subpixel
method setTextSubpixelPositioningEnabled(context: ProbeContext, enabled: bool) = context.subpixel = enabled
method textSubpixelGlyphVariantsEnabled(context: ProbeContext): bool = context.variants
method setTextSubpixelGlyphVariantsEnabled(context: ProbeContext, enabled: bool) = context.variants = enabled

proc newRenderer*(): NativeRenderer =
  result = newFigRenderer(ProbeContext(), SiwinRenderBackend())
  result.setTextLcdFiltering(true)
  result.setTextSubpixelPositioning(true)
  result.setTextSubpixelGlyphVariants(true)
  doAssert result.textLcdFiltering()
  doAssert result.textSubpixelPositioning()
  doAssert result.textSubpixelGlyphVariants()
  doAssert result.backendKind() == rbMetal

proc desiredFlags*(renderer: NativeRenderer): int =
  for name, value in fieldPairs(renderer[]):
    when name == "textLcdFilteringDesired":
      if value: result = result or 1
    elif name == "textSubpixelPositioningDesired":
      if value: result = result or 2
    elif name == "textSubpixelGlyphVariantsDesired":
      if value: result = result or 4
""")
var arguments = @[
  compiler, "c", "--genBif:on", "--app:staticlib", "--mm:arc", "-d:useMalloc",
  "--noNimblePath", "-d:release", "--passC:-Wno-incompatible-function-pointer-types",
  "--nimcache:" & cache, "--out:" & output,
]
arguments.add paths
let names = ["backendKind", "setTextLcdFiltering", "textLcdFiltering",
  "setTextSubpixelPositioning", "textSubpixelPositioning",
  "setTextSubpixelGlyphVariants", "textSubpixelGlyphVariants"]
var config = initNativeExportConfig(includeProcs = [includeProc("*", "producer.nim")])
for name in names:
  config.includeProcs.add includeProc(name, "*src/figdraw/figrender.nim",
    typeArgs = @[relativePath(figdraw / "src/figdraw/windowing/siwinshim.nim", probe) &
      ":SiwinRenderBackend"])
config.typeImports = @[
  importType("Rect", "bumpy"), importType("Image", "pixie"),
  importType("Vec2", "vmath"), importType("IVec2", "vmath"), importType("Mat4", "vmath"),
  importType("ColorRGBA", "chroma"), importType("ColorRGBX", "chroma"),
  importType("Rune", "std/unicode"), importType("Duration", "std/times"),
  importType("Lock", "std/locks"), importType("Cond", "std/locks"),
  importType("NSView", "darwin/app_kit/nsview", source = "*darwin/darwin/app_kit/nsview.nim"),
  importType("CAMetalLayer", "metalx/cametal", source = "*metalx/src/metalx/cametal.nim"),
]
run(arguments & @[source])
let root = nativeCRootSourcePath(cache)
discard prepareNativeRoutines(cache, probe, source, root, config, cBuildManifest = output & ".json")
run(arguments & @[root])
let exports = nativeExportSymbols(cache, probe, config)
let init_symbol = nativeInitSymbol(library, findSemanticBifPath(cache, source))
writeNativeExportList(probe / "exports", init_symbol, exports)
var archive_arguments = @["/usr/bin/libtool", "-static", "-o", output & ".a"]
for node in parseFile(output & ".json")["link"]: archive_arguments.add node.getStr
run(archive_arguments)
promoteNativeArchive(output & ".a", probe / "public.a", exports)
linkNativeDynlib(probe / "public.a", library, probe / "exports", init_symbol, linkerArgs = @[
  "-framework", "AppKit", "-framework", "CoreFoundation", "-framework", "CoreGraphics",
  "-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore",
  "-framework", "Security", "-lobjc",
])
discard initBifNativeBindingsConfig(source, cache, library, probe, config).
  writeNativeBindings(probe / "renderer_abi.nim")
writeFile(probe / "consumer.nim", """
import renderer_abi
let renderer = newRenderer()
doAssert renderer.backendKind() == rbMetal
doAssert renderer.desiredFlags() == 7
renderer.setTextLcdFiltering(false)
renderer.setTextSubpixelPositioning(false)
renderer.setTextSubpixelGlyphVariants(false)
doAssert not renderer.textLcdFiltering()
doAssert not renderer.textSubpixelPositioning()
doAssert not renderer.textSubpixelGlyphVariants()
doAssert renderer.desiredFlags() == 0
renderer.setTextLcdFiltering(true)
renderer.setTextSubpixelPositioning(true)
renderer.setTextSubpixelGlyphVariants(true)
doAssert renderer.textLcdFiltering()
doAssert renderer.textSubpixelPositioning()
doAssert renderer.textSubpixelGlyphVariants()
doAssert renderer.desiredFlags() == 7
""")
run(@[compiler, "c", "-r", "--mm:arc", "-d:useMalloc", "--noNimblePath",
  "--path:" & probe, "--nimcache:" & probe / "consumer-cache", "--out:" & probe / "consumer"] &
  paths & @[probe / "consumer.nim"])
let manifest = readFile(probe / "consumer-cache/consumer.json")
for module in ["siwinshim.nim", "figrender.nim", "siwinmetal.nim", "producer.nim"]:
  doAssert module notin manifest
doAssert "@psiwin" notin manifest and "/siwin/src/" notin manifest
for name in names: echo "direct export passed: ", name
echo "desired flags preserved; consumer implementation isolation passed"
