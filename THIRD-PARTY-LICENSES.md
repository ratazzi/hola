# Third-Party Licenses

This project includes and links against binary dependencies from the `hola-deps` project. Each dependency retains its original license.

## Binary Dependencies (hola-deps)

The `hola-deps` project provides pre-built binary libraries that this project depends on. For complete license information, see the [hola-deps repository](https://github.com/ratazzi/hola-deps).

### Dependencies Included

#### http-parser (v2.9.0)
- **License**: MIT License
- **Copyright**: Joyent, Inc. and other Node contributors
- **Source**: https://github.com/nodejs/http-parser

#### mruby
- **License**: MIT License
- **Copyright**: mruby developers
- **Source**: https://github.com/mruby/mruby

#### zlib (v1.3.1)
- **License**: Zlib License
- **Copyright**: Jean-loup Gailly and Mark Adler
- **Source**: https://github.com/madler/zlib
- **Notes**: Very permissive license similar to MIT/BSD

#### libssh2 (1.11.0)
- **License**: BSD 3-Clause License
- **Copyright**: Multiple contributors
- **Source**: https://github.com/libssh2/libssh2

#### pcre2 (10.42)
- **License**: BSD License
- **Copyright**: University of Cambridge, Zoltan Herczeg
- **Source**: https://github.com/PCRE2Project/pcre2

#### openssl (3.6.0)
- **License**: Apache License 2.0
- **Copyright**: The OpenSSL Project
- **Source**: https://github.com/openssl/openssl

#### libgit2
- **License**: GPLv2 with Linking Exception
- **Copyright**: libgit2 contributors
- **Source**: https://github.com/libgit2/libgit2
- **Notes**: The linking exception permits linking this library with any program regardless of that program's license

## License Compatibility

All dependencies are compatible with this project's MIT License:
- MIT, BSD, and Zlib licenses are permissive and fully compatible
- Apache 2.0 is compatible with MIT for distribution
- libgit2's GPLv2 with Linking Exception explicitly permits linking without GPL requirements

## Full License Texts

For the complete text of each dependency's license, please refer to:
- The hola-deps repository: https://github.com/ratazzi/hola-deps
- The original source repositories listed above
