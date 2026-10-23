#!/usr/bin/python3

import struct
import sys
from pathlib import Path


LC_BUILD_VERSION = 0x32
MH_MAGIC_64 = 0xFEEDFACF
PLATFORM_MACOS = 1
PLATFORM_IOS = 2
PLATFORM_MACCATALYST = 6

SOURCE_PLATFORMS = {
  "ios": PLATFORM_IOS,
  "macos": PLATFORM_MACOS,
}


def encoded_version(value: str) -> int:
  components = value.split(".")
  if not 1 <= len(components) <= 3:
    raise ValueError(f"invalid version: {value}")
  parsed_components = tuple(int(component) for component in components)
  major, minor, patch = parsed_components + (0,) * (3 - len(parsed_components))
  if not 0 <= major <= 0xFFFF or not 0 <= minor <= 0xFF or not 0 <= patch <= 0xFF:
    raise ValueError(f"version component is out of range: {value}")
  return (major << 16) | (minor << 8) | patch


def main() -> None:
  if len(sys.argv) != 6:
    raise SystemExit(
      f"usage: {sys.argv[0]} INPUT OUTPUT SOURCE_PLATFORM MINIMUM_OS SDK_VERSION"
    )

  input_path, output_path = (Path(path) for path in sys.argv[1:3])
  source_platform_name = sys.argv[3]
  try:
    source_platform = SOURCE_PLATFORMS[source_platform_name]
  except KeyError:
    supported = ", ".join(sorted(SOURCE_PLATFORMS))
    raise SystemExit(
      f"unsupported source platform {source_platform_name!r}; expected one of: {supported}"
    )
  minimum_os = encoded_version(sys.argv[4])
  sdk_version = encoded_version(sys.argv[5])
  contents = bytearray(input_path.read_bytes())
  if len(contents) < 32 or struct.unpack_from("<I", contents)[0] != MH_MAGIC_64:
    raise SystemExit(f"{input_path} is not a little-endian 64-bit Mach-O file")

  _, _, _, _, command_count, command_size, _, _ = struct.unpack_from(
    "<IIIIIIII", contents
  )
  command_offset = 32
  command_end = command_offset + command_size
  if command_end > len(contents):
    raise SystemExit(f"{input_path} has invalid Mach-O load commands")

  replaced = 0
  for _ in range(command_count):
    if command_offset + 8 > command_end:
      raise SystemExit(f"{input_path} has a truncated Mach-O load command")
    command, size = struct.unpack_from("<II", contents, command_offset)
    if size < 8 or command_offset + size > command_end:
      raise SystemExit(f"{input_path} has an invalid Mach-O load command size")
    if command == LC_BUILD_VERSION:
      if size < 24:
        raise SystemExit(f"{input_path} has an invalid LC_BUILD_VERSION command")
      platform = struct.unpack_from("<I", contents, command_offset + 8)[0]
      if platform == source_platform:
        struct.pack_into(
          "<III",
          contents,
          command_offset + 8,
          PLATFORM_MACCATALYST,
          minimum_os,
          sdk_version,
        )
        replaced += 1
    command_offset += size

  if replaced != 1:
    raise SystemExit(
      f"expected one {source_platform_name} LC_BUILD_VERSION command in "
      f"{input_path}, found {replaced}"
    )
  output_path.write_bytes(contents)


if __name__ == "__main__":
  main()
