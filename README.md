# Darktide Optimizer

One script to put your Warhammer 40,000: Darktide performance fixes back after every patch.

Darktide updates and Steam's **Verify integrity of game files** reset the engine config in the game folder. This script re-applies the fixes in one go, backs up everything it touches, and can undo itself.

> Unofficial community tool. Not affiliated with or endorsed by Fatshark. It only edits plain-text config files; it does not touch game code, mods or your account.

## Quick start

1. Close Darktide.
2. [Download the repo as a ZIP](../../archive/refs/heads/main.zip) and extract it anywhere.
3. Double-click **`Run-Optimizer.bat`** and accept the administrator prompt. Admin rights are needed because the game lives in `Program Files`.
4. Start the game.

Run it again after every Darktide update.

## What it changes

### 1. Streaming hitch fix (`bundle\application_settings\settings_common.ini`, `win32_settings.ini`)

The sudden "160 fps → 60 fps → back" drops in missions show up in Darktide's console log as 100–400 ms stalls in `Apply safe delete resources`, `RI::wait_for_fence` and `d3d12_resource_context::dispatch`. That is, the engine is freeing and reloading graphics resources. Fatshark ships a 512 MB texture pool and evicts streamed tiles and meshes after 5 seconds, regardless of how much graphics memory you have.

The script sizes the budget to your card (detected automatically):

| Setting | Default | 8–12 GB VRAM | 12 GB+ VRAM |
|---|---|---|---|
| Texture streaming pool | 512 MB | 1024 MB | 2048 MB |
| Feedback streamer max pool | 1024 MB | 2048 MB | 4096 MB |
| Mesh streamer limit | 700 | 1000 | 1400 |
| Texture tile lifetime | 5 s | 30 s | 30 s |
| Mesh eviction timeout | 5 s | 30 s | 30 s |
| Tiles aged out per frame | 64 | 16 | 16 |

Under 8 GB the streaming values are left at Fatshark's defaults.

### 2. Display sync (`win32_settings.ini`)

After a verify, this file ships with **ray tracing on, windowed mode and 1920×1080**, which can override what you picked in-game. The script copies your real screen mode and resolution from your settings and switches ray tracing off unless you use it.

### 3. Performance graphics preset (`%APPDATA%\Fatshark\Darktide\user_settings.config`)

These are the settings that cost the most frames for the least visual difference:

- Volumetric fog **Low**. This is usually the biggest single gain.
- Lighting/shadows **Medium**, ambient occlusion **Low**.
- Screen-space reflections, depth of field, lens flare, motion blur and ray tracing **Off**.
- **AMD Radeon RX 9000 only:** FSR frame generation **Off**. Fatshark has listed a GPU crash issue with it on these cards, and it is unstable in exclusive fullscreen.

It does **not** change upscaling (FSR/DLSS/XeSS and quality mode), texture quality, Reflex, resolution, FOV or anything outside graphics. To keep your own graphics settings, use `-Preset EngineOnly`.

### 4. Optional DNS fix (`-SetDns`)

If you get **"Backend Error – Error signing in"** while everything else online works, look in your console log (`%APPDATA%\Fatshark\Darktide\console_logs`). If it is full of `Could not resolve host: bsp-td-prod.atoma.cloud`, your router's DNS may be failing on the game's burst of simultaneous lookups. `-SetDns` points your connected network adapters at Cloudflare (1.1.1.1 / 1.0.0.1). It prints the undo command for each adapter.

## Options

Run these from PowerShell in the extracted folder:

```powershell
.\Optimize-Darktide.ps1                       # engine fixes + Performance preset
.\Optimize-Darktide.ps1 -DryRun               # show what would change, write nothing
.\Optimize-Darktide.ps1 -Preset EngineOnly    # engine fixes only, keep my graphics settings
.\Optimize-Darktide.ps1 -SetDns               # also apply the sign-in DNS fix
.\Optimize-Darktide.ps1 -Restore              # undo the last run
.\Optimize-Darktide.ps1 -VramGB 16            # override graphics memory detection
.\Optimize-Darktide.ps1 -GamePath "D:\SteamLibrary\steamapps\common\Warhammer 40,000 DARKTIDE"
```

The `.bat` passes any options through, e.g. `Run-Optimizer.bat -DryRun`.

If PowerShell refuses to run the script, use the `.bat`. It runs with `-ExecutionPolicy Bypass` for this one script only.

## Backups and undo

Before writing, the script copies every file it is about to change to:

```
%APPDATA%\Fatshark\Darktide\optimizer-backups\<date-time>\
```

`-Restore` puts back the most recent set. You can also get the stock game files back any time with Steam → Darktide → Properties → Installed Files → **Verify integrity of game files**.

## Notes

- The game must be closed. Darktide rewrites `user_settings.config` when it exits.
- The script edits values in place and never adds new ones. If a future patch renames or removes a setting, it prints `[warn] ... not found` and leaves it alone, so it can't break a newer version of the file.
- Steam only. Detects the install from Steam's library folders, including other drives.
- If the game ever fails to start after running it, use `-Restore` or verify game files, and please open an issue with your `console_logs` file.

## Contributing

Issues and pull requests are welcome. Measurements are especially useful: count the `Stall` lines in a mission's console log before and after.

## Licence

MIT
