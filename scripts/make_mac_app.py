#!/usr/bin/env python3
# A self-contained Mac app from a finished `build_ipa_from_nsp.py --platform mac` run (the Mac is the development host: this app is not a supported way to play).
# The build's last line is the command that runs the game; it names every file the game needs (the Mac host, the rewritten code, RomFS, Mac shaders, button-icon font, DLC, the profile's shader tables).
#   They are cloned (cp -c: no extra space on the same APFS volume, a plain copy elsewhere) into <app>/Contents/Resources, and Contents/MacOS/launch runs the host with the same environment,
#   its save, temporary files and log in ~/Library/Application Support/<name>/. The app does not need the build folder afterwards.
# Usage: make_mac_app.py <app path, ending in .app> <name> <the run command, as the build printed it>
import os, plistlib, re, shlex, shutil, subprocess, sys
from pathlib import Path

PATHS = {'DM_ROMFS': 'romfs', 'DM_MSL_DIR': 'msl', 'DM_FONT_DIR': 'font', 'DM_AOC_DIR': 'aoc'}   # the run command's folders and where they go in Resources
OWN = {'DM_ROOT', 'DM_SAVE', 'DM_TEMP'}   # the app's own folder replaces these


def parse(cmd):   # (environment, host, patched folder) of `cd <dir> && K=V ... <host> <patched>`
    toks = shlex.split(cmd)
    if toks[:1] == ['cd']: toks = toks[toks.index('&&') + 1:]
    env = {}
    while toks and toks[0].partition('=')[0].isidentifier() and '=' in toks[0]:
        k, _, v = toks.pop(0).partition('='); env[k] = v
    if len(toks) != 2 or 'DM_ROMFS' not in env: raise SystemExit(f'not the run command of a Mac build: {cmd[:200]}')
    return env, Path(toks[0]), Path(toks[1])


def make(app, name, cmd):
    if re.search(r'[/:"$`\\]', name): raise SystemExit(f'the name must not hold / : " $ ` \\ : {name}')
    env, host, patched = parse(cmd)
    items = [(host, 'dmhost'), (patched, 'patched')] + [(Path(env[k]), d) for k, d in PATHS.items() if k in env]
    shmap = Path(env['DM_NVN_SHMAP']) if 'DM_NVN_SHMAP' in env else None
    if shmap: items.append((shmap.parent, 'profile'))   # c1_full.tsv and cb_extent.tsv are read beside the shader map
    for src, _ in items:
        if not src.exists(): raise SystemExit(f'missing: {src}')
    app = Path(app); tmp = app.with_name(app.name + '.partial'); res = tmp / 'Contents/Resources'
    shutil.rmtree(tmp, ignore_errors=True); res.mkdir(parents=True); (tmp / 'Contents/MacOS').mkdir()
    try:
        for src, dst in items: subprocess.run(['cp', '-cR', src, res / dst], check=True)
        rest = ' '.join(f'{k}={shlex.quote(v)}' for k, v in env.items() if k not in OWN | set(PATHS) | {'DM_NVN_SHMAP'})   # the language, DM_WINDOW, DM_AUDIO, an env file's switches
        own = ' '.join([*(f'{k}="$R/{d}"' for k, d in PATHS.items() if k in env), *([f'DM_NVN_SHMAP="$R/profile/{shmap.name}"'] if shmap else [])])
        launch = tmp / 'Contents/MacOS/launch'
        launch.write_text(f'#!/bin/bash\nR="$(cd "$(dirname "$0")/../Resources" && pwd)"\nD="$HOME/Library/Application Support/{name}"\nmkdir -p "$D/save" "$D/temp"; cd "$D"\n'
                          f'export DM_ROOT="$D" DM_SAVE="$D/save" DM_TEMP="$D/temp" {own} {rest}\nexec "$R/dmhost" "$R/patched" > "$D/log.txt" 2>&1\n')
        launch.chmod(0o755)
        tid = Path(env['DM_ROOT']).name.removesuffix('_build')
        with open(tmp / 'Contents/Info.plist', 'wb') as f:
            plistlib.dump({'CFBundleExecutable': 'launch', 'CFBundleName': name, 'CFBundleIdentifier': f'org.nxnative.mac.{tid}', 'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon'}, f)
        icon = Path(env['DM_ROMFS']).parent / 'icon.jpg'   # the extracted game's icon, next to its RomFS
        if icon.is_file(): subprocess.run(['sips', '-s', 'format', 'icns', icon, '--out', res / 'AppIcon.icns'], capture_output=True)
        shutil.rmtree(app, ignore_errors=True); os.rename(tmp, app)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    subprocess.run(['codesign', '--force', '--deep', '-s', '-', app], check=True, capture_output=True)
    subprocess.run(['xattr', '-cr', app], check=True)
    print(f'created {app}')


if __name__ == '__main__':
    if len(sys.argv) != 4 or not sys.argv[1].endswith('.app'): sys.exit(__doc__ or 'usage: make_mac_app.py <app path ending in .app> <name> <run command>')
    make(*sys.argv[1:])
