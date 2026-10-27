# Super Mario Party Jamboree (`0100965017338000`)

Update 2.2.0 (`v393216`) over the base game, SDK 17.5.9. NDcube's Bezel engine on NVN. Runs on the Mac (Apple silicon) through the character select; the game after that is not checked. The profile started as the NSP script's provisional one; the keys below were measured on the Mac.

## What it needs

- Memory: the NPDM declares 16 MB of system resource (`sys_resource 0x1000000`) and `main` sets a 5 GB heap. The game wants a 56 GB address region from the VAMM: `mem_reserve 0x1030000000`, `mem_alias 0x1008000000` (a smaller alias region aborts in `nn::mem::StandardAllocator`), `mem_stack 0x10000000`, `app_pool 0xCD500000`.
- `zero_dynamic_pools on` (see Character select).
- The node area cut comes with the `sdk` build (`fcd13912…`, `dm/tools/sdk_patches.py`); whether it is needed here is not checked. No `patches.py`.

## Files and shaders

- Files are `.bea` archives (the engine's own format, version `0x600`, zstd entries, some with inline ASST entries; `dm/gfx/tools/shader_split.py` reads them). `romfs_marker` is `movie/flow/op/movie/bq_op.mp4`; `zip_store` keeps `.bea`, `.bfstm`, `.mp4` and `.metallib`.
- More than 64 modules load, so `MAX_MOD` in `dm/host/dm.h` is 192.

## Movies

The intro movie uses Nintendo's `movie::Decoder` in native-texture mode, which releases the output index with the texture copy (`CopyOutputBufferToClientTextureAndRelease`). The host releases it there as well (`dm/host/hle_movie.c`); before that the first frame stayed frozen, see [movies](../../../docs/reference/movies.md).

## Character select

The glitched character models (broken faces) came from the engine's per-instance face-mesh vertex buffers (4116 and 8316 bytes in pools with flags `0x22`): nothing ever writes them, so the engine relies on zero memory, but its allocator (`CoreSystem::Allocate` over `nn::mem::StandardAllocator`, no decommit) hands out memory that held file data or freed buffers. `zero_dynamic_pools on` zeroes such a pool when it is made and a buffer's memory when it is freed (going back to a character makes new models in memory that exists already). The packed app went through 48 of 48 steps of the character select clean (a script cycles through the characters and checks the pane); without the second part 15 of 47 glitched. That still left 3 to 5 % of the steps with slabs over a model, from position buffers of the hair and face meshes (depth and shadow passes) that lay over command memory the game had given back and held the host's old command records; a new buffer now clears those (hle_nvn.c `cmdmap_scrub`), and hand testing showed no glitch any more. Why the Switch itself does not show stale data is not known. Details: [nvn-objects](../../../docs/reference/nvn-objects.md).

Boo, Toad and Toadette had no eyes: their eye meshes (67 or 274 vertices) read their positions from a buffer that the game fills once, when the model is made, with a vertex-only draw under rasterizer discard whose shader writes a storage buffer. The host used to skip every discard draw without transform feedback; it now runs those whose vertex shader writes a storage buffer (`tf_draw` in `nvn_mtl.m`). Details: [rendering](../../../docs/reference/rendering.md#vertex-only-draws-under-rasterizer-discard-that-write-storage-buffers).

Tried without effect: a guard against NaN and huge values in the shaders, `render_cond`, zeroing all small pools (grey screen).
