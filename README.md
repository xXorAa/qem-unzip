# qem-unzip

An unzipper for Sinclair QL emulators that allows you to unzip on the host
to a directory the emulator understands with properly escaped filenames and
QDOS header creation.

This is useful for unzipping some copy protected games from QL.

## Build

```
cargo build --release
```

## Running

```
Usage: qem-unzip [OPTIONS] -d <DIRECTORY> <FILE>

Arguments:
  <FILE>

Options:
  -d <DIRECTORY>      directory to extract to
  -e                  escpae the filenames sQLux/Q-Emulator style
  -h, --help          Print help
  -V, --version       Print version
```

