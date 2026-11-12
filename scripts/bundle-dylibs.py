#!/usr/bin/env python3
"""Copy non-system dylib dependencies into the .app and rewrite load paths.

usage: bundle-dylibs.py <App.app> <extra Mach-O files (plugins) ...>
"""
import os, shutil, subprocess, sys

app = sys.argv[1]
frameworks = os.path.join(app, "Contents", "Frameworks")
os.makedirs(frameworks, exist_ok=True)
SYSTEM = ("/usr/lib/", "/System/")

def deps(path):
    out = subprocess.check_output(["otool", "-L", path], text=True).splitlines()[1:]
    return [l.strip().split(" (")[0] for l in out]

def rpaths(path):
    out = subprocess.check_output(["otool", "-l", path], text=True).splitlines()
    res = []
    for i, l in enumerate(out):
        if l.strip() == "cmd LC_RPATH":
            res.append(out[i + 2].strip().split(" ")[1])
    return res

def resolve(dep, owner):
    if dep.startswith("@rpath/"):
        name = dep[len("@rpath/"):]
        for rp in rpaths(owner):
            rp = rp.replace("@loader_path", os.path.dirname(owner))
            cand = os.path.join(rp, name)
            if os.path.exists(cand):
                return os.path.realpath(cand)
        # Homebrew fallback
        for base in ["/opt/homebrew/lib", "/opt/homebrew/opt/postgresql@17/lib/postgresql"]:
            cand = os.path.join(base, name)
            if os.path.exists(cand):
                return os.path.realpath(cand)
        return None
    if dep.startswith("@"):
        return None
    return os.path.realpath(dep)

done = {}

def process(binary, loader_prefix):
    """Rewrite deps of `binary`; loader_prefix is how binary reaches Frameworks."""
    for dep in deps(binary):
        if dep.startswith(SYSTEM) or dep.startswith("@executable_path") or dep.startswith("@loader_path"):
            continue
        real = resolve(dep, binary)
        if real is None or not os.path.exists(real):
            if dep.startswith("@rpath/") and os.path.exists(os.path.join(frameworks, os.path.basename(dep))):
                subprocess.check_call(["install_name_tool", "-change", dep, f"{loader_prefix}/{os.path.basename(dep)}", binary])
                continue
            print(f"  ! unresolved {dep} in {binary}")
            continue
        name = os.path.basename(dep)
        target = os.path.join(frameworks, name)
        if real not in done:
            if not os.path.exists(target):
                shutil.copy2(real, target)
                os.chmod(target, 0o755)
            done[real] = target
            subprocess.check_call(["install_name_tool", "-id", f"@rpath/{name}", target], stderr=subprocess.DEVNULL)
            process(target, "@loader_path")
        subprocess.check_call(["install_name_tool", "-change", dep, f"{loader_prefix}/{name}", binary], stderr=subprocess.DEVNULL)

exe_dir = os.path.join(app, "Contents", "MacOS")
for exe in os.listdir(exe_dir):
    process(os.path.join(exe_dir, exe), "@executable_path/../Frameworks")
for extra in sys.argv[2:]:
    rel = os.path.relpath(frameworks, os.path.dirname(extra))
    process(extra, f"@loader_path/{rel}")
print("bundled:", ", ".join(sorted(os.listdir(frameworks))))
