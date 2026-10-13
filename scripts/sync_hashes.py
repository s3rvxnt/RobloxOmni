import hashlib, json, re, os

repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def compute_hash(rel_path):
    full_path = os.path.join(repo_root, rel_path)
    with open(full_path, 'rb') as f:
        content = f.read().replace(b'\r\n', b'\n')
    return hashlib.sha256(content).hexdigest()

ktm_hash = compute_hash('kernel/KernelTaskManager.lua')
oes_hash = compute_hash('gameloaded/OmniEnhancementSuite.lua')
lsm_hash = compute_hash('gameloaded/OmniLoadstringManager.lua')

print(f"KernelTaskManager SHA256:     {ktm_hash}")
print(f"OmniEnhancementSuite SHA256:  {oes_hash}")
print(f"OmniLoadstringManager SHA256: {lsm_hash}")

# 1. Update manifest.json
manifest_path = os.path.join(repo_root, 'manifest.json')
with open(manifest_path, 'r', encoding='utf-8') as f:
    manifest = json.load(f)

for stage in manifest.get('stages', []):
    if stage.get('name') == 'KernelTaskManager':
        stage['sha256'] = ktm_hash
    elif stage.get('name') == 'OmniEnhancementSuite':
        stage['sha256'] = oes_hash
    elif stage.get('name') == 'OmniLoadstringManager':
        stage['sha256'] = lsm_hash

with open(manifest_path, 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')
print("Updated manifest.json")

# 2. Update Bootloader.lua
bootloader_path = os.path.join(repo_root, 'Bootloader.lua')
with open(bootloader_path, 'r', encoding='latin1') as f:
    bootloader_src = f.read()

# Replace hashes in Bootloader.lua
# Replace KernelTaskManager hashes (old was 64b0edf8821e12f666bbb6b3c814c4a5dfde846f1adecc36c389121991151f82)
bootloader_src = re.sub(
    r'(name\s*=\s*"KernelTaskManager",\s*sha256\s*=\s*")[a-f0-9]{64}(")',
    rf'\g<1>{ktm_hash}\2',
    bootloader_src
)

# Replace OmniEnhancementSuite hashes
bootloader_src = re.sub(
    r'(name\s*=\s*"OmniEnhancementSuite",\s*sha256\s*=\s*")[a-f0-9]{64}(")',
    rf'\g<1>{oes_hash}\2',
    bootloader_src
)

# Replace OmniLoadstringManager hashes
bootloader_src = re.sub(
    r'(name\s*=\s*"OmniLoadstringManager",\s*sha256\s*=\s*")[a-f0-9]{64}(")',
    rf'\g<1>{lsm_hash}\2',
    bootloader_src
)

with open(bootloader_path, 'w', encoding='latin1') as f:
    f.write(bootloader_src)
print("Updated Bootloader.lua")
