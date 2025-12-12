import std/options

# DWARF Line Number Info structures and constants

# DWARF Line Number Program opcodes
const
  DW_LNS_extended_op* = 0'u8
  DW_LNS_copy* = 1'u8
  DW_LNS_advance_pc* = 2'u8
  DW_LNS_advance_line* = 3'u8
  DW_LNS_set_file* = 4'u8
  DW_LNS_set_column* = 5'u8
  DW_LNS_negate_stmt* = 6'u8
  DW_LNS_set_basic_block* = 7'u8
  DW_LNS_const_add_pc* = 8'u8
  DW_LNS_fixed_advance_pc* = 9'u8
  DW_LNS_set_prologue_end* = 10'u8
  DW_LNS_set_epilogue_begin* = 11'u8
  DW_LNS_set_isa* = 12'u8

  DW_LNE_end_sequence* = 1'u8
  DW_LNE_set_address* = 2'u8
  DW_LNE_define_file* = 3'u8
  DW_LNE_set_discriminator* = 4'u8
  DW_LNE_HP_source_file_correlation* = 0x80'u8

  # DWARF 5 Line number content types
  DW_LNCT_path* = 0x1'u8
  DW_LNCT_directory_index* = 0x2'u8
  DW_LNCT_timestamp* = 0x3'u8
  DW_LNCT_size* = 0x4'u8
  DW_LNCT_MD5* = 0x5'u8

  # DWARF forms
  DW_FORM_data2* = 0x05'u8
  DW_FORM_data4* = 0x06'u8
  DW_FORM_data8* = 0x07'u8
  DW_FORM_string* = 0x08'u8
  DW_FORM_data1* = 0x0b'u8
  DW_FORM_sdata* = 0x0d'u8
  DW_FORM_strp* = 0x0e'u8
  DW_FORM_udata* = 0x0f'u8
  DW_FORM_data16* = 0x1e'u8
  DW_FORM_line_strp* = 0x1f'u8

type
  DwarfLineHeader* = object
    totalLength*: uint64
    version*: uint16
    prologueLength*: uint64
    minInstructionLength*: uint8
    maxOpsPerInsn*: uint8
    defaultIsStmt*: uint8
    lineBase*: int8
    lineRange*: uint8
    opcodeBase*: uint8
    standardOpcodeLengths*: seq[uint8]

  DwarfLineEntry* = object
    pathName*: string
    directoryIndex*: uint64
    timestamp*: uint64
    size*: uint64
    md5*: array[16, byte]
    source*: Option[string]

  DwarfLineProgramRow* = object
    address*: uint64
    file*: uint32
    line*: uint32
    column*: uint32
    discriminator*: uint32

  DwarfLineTable* = object
    header*: DwarfLineHeader
    directories*: seq[string]
    files*: seq[DwarfLineEntry]
    entries*: seq[DwarfLineProgramRow]
