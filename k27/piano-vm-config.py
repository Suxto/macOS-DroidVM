#!/usr/bin/env python3
"""Plan a separate Piano MMIO VM from a working DroidVM App configuration."""

import argparse
import copy
import json
from pathlib import Path, PurePosixPath
import re
import uuid


def create_operation(base, existing, slug, mac):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,39}', slug):
        raise ValueError('instance must contain 1–40 lowercase letters, digits or hyphens')
    if not re.fullmatch(r'(?:[0-9a-f]{2}:){5}[0-9a-f]{2}', mac) or int(mac[:2], 16) & 3 != 2:
        raise ValueError('use a locally administered unicast MAC address')
    if any(n.get('mac_address', '').lower() == mac for vm in existing for n in vm.get('networks', [])):
        raise ValueError('MAC address is already registered')
    if (base.get('crosvm_runtime'), base.get('hypervisor'), base.get('cpu_count'), base.get('memory_mb')) != (
        'macos', 'gunyah', 6, 8192
    ):
        raise ValueError('the boot image requires the Piano macOS runtime with 6 CPUs and 8192 MiB')
    screen = base.get('screens', {}).get('gpu-0', {})
    if (screen.get('exporter'), screen.get('width'), screen.get('height')) != ('native', 1280, 800):
        raise ValueError('expected native 1280×800 scanout')
    if len(base.get('networks', [])) != 1 or base.get('disks') or base.get('shared_dirs') or base.get('peripherals'):
        raise ValueError('expected the standard Piano MMIO profile without external devices or disk entries')
    options = base['extra_options']
    if len(options) != 8 or options[:4:2] != ['--virtio-mmio-block'] * 2 or options[4:7] != [
        '--virtio-mmio-net', '--virtio-mmio-gpu', '--dump-device-tree-blob'
    ] or not options[1].endswith(',ro=true,lock=false'):
        raise ValueError('unsupported MMIO layout or device order')
    source_files = PurePosixPath('/data/data/cn.classfun.droidvm/files')
    folder = source_files / slug
    firmware = PurePosixPath(base['boot']['uefi']['firmware'])
    if folder == firmware.parent:
        raise ValueError('instance folder must differ from the source')
    if any(f'{folder}/' in json.dumps(vm) for vm in existing):
        raise ValueError('instance folder is already referenced by another VM')
    instance_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, f'macos-piano-mmio.{slug}.droidvm'))
    name = f'macOS 27.2 (Piano MMIO · {slug})'
    if any(vm['id'] == instance_id or vm['name'] == name for vm in existing):
        raise ValueError('instance is already registered')
    vm = copy.deepcopy(base)
    vm.update(id=instance_id, name=name)
    vm['boot']['uefi']['firmware'] = str(folder / 'firmware.fd')
    vm['extra_options'][1] = f'{folder}/boot.img,ro=true,lock=false'
    vm['extra_options'][3] = f'{folder}/data-store.img,lock=false'
    vm['extra_options'][7] = str(folder / 'generated.dtb')
    vm['networks'][0]['mac_address'] = mac
    for port in vm['serial_ports']:
        if port.get('backend') == 'file':
            port['path'] = str(folder / f'serial-{port["num"]}.log')
    return {'op': 'create', 'config': vm}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('vms_json', type=Path)
    parser.add_argument('revision', help='revision from vm_config_status')
    parser.add_argument('--base-id', required=True)
    parser.add_argument('--instance', required=True, help='new directory name below the app files directory')
    parser.add_argument('--mac', required=True)
    args = parser.parse_args()
    existing = json.loads(args.vms_json.read_text(encoding='utf-8-sig'))['vms']
    base = next((vm for vm in existing if vm['id'] == args.base_id), None)
    if base is None:
        parser.error('base-id is not registered')
    try:
        operation = create_operation(base, existing, args.instance, args.mac)
    except (KeyError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps({'revision': args.revision, 'operations': [operation]}, indent=2))


if __name__ == '__main__':
    main()
