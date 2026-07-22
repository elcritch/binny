type
  ImportedValue* = object
    label*: string

proc newImportedValue*(label: string): ImportedValue =
  ImportedValue(label: label)

proc importedLabel*(value: ImportedValue): string =
  value.label
