# zpak

`zpak` is a high-performance archiving and compression utility written in Zig. It provides tools for creating and extracting compressed archives from directories, with support for multiple compression algorithms.

## Features

- **Efficient Compression**: Supports LZ4, Zstd and Lzma compression algorithms.
- **Fast Archiving**: Quickly packs directories into compact archive files.
- **Simple CLI**: Minimal, intuitive commands for encoding and decoding.
- **Cross-Platform**: Built with Zig, ensuring portability across various operating systems.

## Installation

You can either download prebuilt binaries (if available) or build from source.

### Build from Source

You’ll need Zig installed (matching the version this project was developed with).

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/zpak.git
   cd zpak
   ```
2. Build the project:
   ```bash
   zig build
   ```
3. The compiled executable will be in:
   ```bash
   zig-out/bin/zpak
   ```

### Usage

```bash
# Encode a directory into an archive (default: LZ4 compression)
zpak encode <input_dir> <output_file>

# Encode with a specific algorithm: lz4, zstd
zpak encode <input_dir> <output_file> <algorithm>

# Decode an archive into a directory
zpak decode <input_file> <output_dir>
```

### Examples

```bash
# Compress the folder "assets" into "assets.zpak" using default (LZ4)
zpak encode assets assets.zpak

# Compress using Zstd
zpak encode assets assets.zpak zstd

# Extract the archive into a folder
zpak decode assets.zpak extracted_assets
```

### Notes

- Incorrect usage will print a help message with the correct command format.

### Licence

This project is licensed under the terms specified in the LICENSE file.
