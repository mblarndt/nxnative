# LEGO® Star Wars™: The Skywalker Saga (`010042D00D900000`)

Update 1.0.8 (`v524288`) over the base game (no other update exists for this title ID), SDK 12.3.6 (NVN API 53), TT Games' NuCore engine on NVN. Modules `main` (the game, 98.5 MB of text, 16 MB of bss), `sdk`, `subsdk0` (GLSLC, not loaded: `main` imports nothing from it) and `subsdk1` (NintendoSDK_movie). The RomFS is 7 TT Games archives (`GAME.DAT`, `GAME0.DAT` … `GAME4.DAT`, `PATCH.DAT`: 15.6 GB, no `.HDR`) and `BootScreen.png`; the DLC (11 add-on contents) are small `.DAT` files of their own. 30 fps by the game's own choice (present interval 2).

Work in progress: the Mac host runs it through the language menu; the rest is noted as it is checked.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `mem_used 0xcdbc000` | [`game.tsv`](game.tsv) | the provisional profile's values, kept: the NPDM declares no system resource, the game sets a heap with `SetMemoryHeapSize` (asks for 5.95 GB and takes 2 MB less until the pool allows it, see [`SetHeapSize` above the heap region](../../../docs/reference/memory.md#setheapsize-above-the-heap-region-is-resultlimitreached)): 2.99 GB |
| `tex_flush_upload on`, `tex_dirty_upload on` | `game.tsv` | the textures are filled by the CPU into one 1.4 GB pool after `nvnTextureInitialize` |
| `romfs_marker GAME0.DAT`, `zip_store .dat:.png:.metallib` | `game.tsv` | |

No `patches.py`, no `sdk_patches.py` cut, no `pad_layout`.

## Shaders

98,023 programs in 19,755 different code areas, all offline: 664 in `main` (code area right before the control section, no pointer to it) and 97,359 in the `*.nnx_shaders` files inside the DAT archives (48,472 vertex, 48,818 pixel, 733 compute). Neither is a container the split knew; see [Control sections with their code area right before them](../../../docs/reference/shaders.md#control-sections-with-their-code-area-right-before-them-in-main-and-in-tt-games-dat-archives) and [TT Games DAT archives](../../../docs/reference/shaders.md#tt-games-dat-archives). The first build decodes 42 GB of archives (36 s) and translates and compiles every shader (about 1 min and more than an hour); later builds hit the caches. No shader pairs: every vertex shader is paired with the single-stage cover.

## Found on this game

- **Boot:** `SetHeapSize` above the heap region ([memory](../../../docs/reference/memory.md#setheapsize-above-the-heap-region-is-resultlimitreached)); the notification pop that never gave the core back ([threads](../../../docs/reference/threads.md#blocking-host-waits-give-the-core-back-dm_thread_host_wait)); the audio renderer's event on a stack ([audio](../../../docs/reference/audio.md#the-games-renderer-event-is-a-local-of-the-function-that-opens-it)).
- **Black picture at 30 fps:** the dynamic constant buffer objects hold the game's own offset and size in the `NVNbuffer` ([NVN objects](../../../docs/reference/nvn-objects.md#a-game-writes-the-offset-and-size-into-its-nvnbuffer-buf_t)).
- **Red lines:** `nvnCommandBufferSetStencilCullCriteria` is a hint.

## Open

- **Menu text.** The language menu draws completely (flags, "Language"). The screen after it (rows, check boxes, an orange panel) has no text, and A / Plus do not leave it. Its UI draws sample two BC3 textures the game makes at about 25 s, 1024×1024 (11 levels) and 1224×572, with the Mac's `DM_NVN_PASSDUMP`; their guest memory (`texlist 1` and `memdump` through `DM_CTL`, block height log2 4, decoded by hand) holds a plain white fill at 45 s and at 105 s (with `tex_flush_upload` / `tex_dirty_upload` on; the picture was the same with them off). The game read about 2 MB of its archives at 24.4 s (four 512 KB reads), before it made them. Whether the real data is decoded into another place, or never arrives, is not known. `DM_PROBE=main:67fc1c` (`NuTextureManager::CreateHardwareTexture`) shows 231 textures in the first 6 s and two at 25 s.
- Everything after that screen: title, first level, sound, controller.
- The 363 files of mode 6 (`ZIPX`, scrambled; 73 MB in all) are not read by the shader split; it is not known whether one holds shaders.
