include binny/native_dynlib/bifreader

# A realized generic type and its instance may share a variant record.
# Finalizing either layout must leave the other's branch labels usable.
let variant = NativeRecordPart(
  kind: nrCase,
  discriminant: NativeField(typeSymbol: "kind"),
  branches: @[NativeBranch(selectors: @["0", "4"])],
)
var layouts = {
  "kind": AbiTypeEntry(enumValues: @[
    NativeEnumValue(name: "small", ordinal: 0),
    NativeEnumValue(name: "large", ordinal: 4),
  ]),
  "body": AbiTypeEntry(kind: "object", record: @[variant]),
  "instance": AbiTypeEntry(instantiatedTypeSymbol: "body", kind: "genericinstance"),
}.toTable
finalizeLayouts(layouts)
for symbol in ["body", "instance"]:
  doAssert layouts[symbol].record[0].branches[0].selectors == @["small", "large"]
