#!/usr/bin/env python3
"""Pack an existing K27 collection and the corresponding Piano MMIO ADT."""
import argparse
import importlib.util
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kernel', type=Path, required=True)
    parser.add_argument('--adt', type=Path, required=True)
    parser.add_argument('--trust', type=Path, required=True)
    parser.add_argument('--seed', type=Path, required=True)
    parser.add_argument('--efi-inputs', type=Path, required=True)
    parser.add_argument('--boot-inputs', type=Path, required=True, help='JSON containing the tested kernel_args string')
    parser.add_argument('--cpu-present', action='store_true', help='convert scanout to 8-bit in the guest; keep Metal enabled')
    parser.add_argument('output', type=Path, help='new output directory')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('run_macos_vm', root / 'scripts/run-macos-vm.py')
    run = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(run)
    run.KERNEL, run.INPUTS = args.kernel, args.efi_inputs
    inputs = [args.kernel, args.adt, args.trust, args.seed, args.efi_inputs / 'UniXNU.efi',
              args.efi_inputs / 'DarwinBoot.efi', args.boot_inputs]
    for inp in inputs:
        if not inp.is_file() or not inp.stat().st_size:
            parser.error(f'missing input: {inp}')
    line = json.loads(args.boot_inputs.read_text())['kernel_args']
    if not isinstance(line, str) or any(ch in line for ch in '\r\n\x00"\\'):
        parser.error('invalid kernel_args string')
    if not {'vgpu-3d=1', 'droidvm-display-hz=60', 'droidvm-timebase-hz=24000000'}.issubset(line.split()):
        parser.error('expected the Piano MMIO GPU, display and timer settings')
    if args.cpu_present:
        flags = [arg for arg in line.split() if not arg.startswith('droidvm-display-virtio-gpu=')]
        line = ' '.join([*flags, 'droidvm-display-virtio-gpu=0'])
    args.output.mkdir(parents=True, exist_ok=False)
    image = run.build_boot_disk(args.output, args.trust, args.seed, args.adt, line, title='DroidVM: macOS 27.2 (Piano MMIO)')
    manifest = {'macos': '27.2', 'transport': 'mmio', 'cpus': 6, 'memory_mib': 8192, 'kernel_args': line,
                'sha256': {p.name: run.sha256(p) for p in [*inputs, image]}}
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{image}: {manifest["sha256"][image.name]}')


if __name__ == '__main__':
    main()
