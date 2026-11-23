#!/usr/bin/env python3
"""Stage the guest virtio-GPU transport fixes for the Piano MMIO build."""
import argparse
from pathlib import Path
import shutil


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'unsupported transport revision: expected one occurrence of {old!r}')
    return text.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    header = args.source / 'DroidVMVirtioGpu.h'
    transport = args.source / 'DroidVMVirtioGpu.cpp'
    context = args.source / 'DroidVMVirtioGpu3D.cpp'
    changed = {
        header: replace_once(header.read_text(), 'uint64_t features();',
                             'uint64_t features();\nuint32_t advertisedCapsets();'),
        context: replace_once(context.read_text(),
                              '    for (uint32_t index = 0; index < 16; ++index) {',
                              '    const uint32_t count = advertisedCapsets();\n'
                              '    for (uint32_t index = 0; index < count && index < 64; ++index) {'),
    }
    text = replace_once(transport.read_text(), 'uint64_t features() { return negotiated; }',
                        'uint64_t features() { return negotiated; }\n'
                        '// virtio_mmio config starts at 0x100; num_capsets is its fourth le32.\n'
                        'uint32_t advertisedCapsets() { return ready() ? rd(0x10c) : 0; }')
    changed[transport] = replace_once(text, '        waitCompletion(epoch, timeoutUs - elapsed);',
                                      '        // A missing completion interrupt must not hold an already used slot\n'
                                      '        // until the full command timeout. Keep the original deadline.\n'
                                      '        const uint64_t remaining = timeoutUs - elapsed;\n'
                                      '        waitCompletion(epoch, remaining < 10000 ? remaining : 10000);')
    shutil.copytree(args.source, args.output)
    for path, contents in changed.items():
        (args.output / path.name).write_text(contents)


if __name__ == '__main__':
    main()
