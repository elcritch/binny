type
  ImportedValue* = object
    label*: string

{.pragma: exportabi.}

proc newImportedValue*(label: string): ImportedValue {.exportabi.} =
  ImportedValue(label: label)

proc importedLabel*(value: ImportedValue): string {.exportabi.} =
  value.label
