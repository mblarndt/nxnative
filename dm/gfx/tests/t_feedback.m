// Feedback snapshots and their per-draw argument substitution include separate texture slots and the depth attachment.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static id<MTLTexture> target_fmt(tex_t *t, uint64_t serial, int format) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=serial};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=format,
        .width=4, .height=4, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = format == NVN_FORMAT_RGBA8 ? MTLStorageModeShared : MTLStorageModePrivate;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:d];
    CHECK(texture != nil, "render target created");
    res_add(texture); mtl_tex_init(t); serial_put(serial, texture);
    return texture;
}
static id<MTLTexture> target(tex_t *t, uint64_t serial) { return target_fmt(t, serial, NVN_FORMAT_RGBA8); }
static void clear(MTLClearColor color) {
    R.clear_c[0] = 1; R.cc[0] = color;
    CHECK(rp_begin() != nil, "production render pass opens");
}
static void sample(NvShader *fs, id<MTLRenderPipelineState> pipeline) {
    clear(MTLClearColorMake(0, 0, 0, 1));
    enc_r_pso(g_enc, pipeline);
    enc_r_viewport(g_enc, (MTLViewport){0, 0, 4, 4, 0, 1});
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "production fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    rp_end();
}
static void readback(id<MTLTexture> t, id<MTLBuffer> b, unsigned offset) {
    enc_b_copy_texture_buffer(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(4, 4, 1), b, offset, 256, 1024);
}
static void pixels(id<MTLBuffer> b, unsigned offset, const uint8_t want[4], const char *label) {
    int valid = 1;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++)
        valid &= !memcmp((const uint8_t *)b.contents + offset + y * 256 + x * 4, want, 4);
    CHECK(valid, label);
}
static void slot_case(NvProg *pr, id<MTLRenderPipelineState> pipeline, int slot, int index) {
    int before = failed, tid = 600 + index;
    NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = slot;
    tex_t source, output;
    id<MTLTexture> original = target(&source, 99700 + index * 2);
    id<MTLTexture> destination = target(&output, 99701 + index * 2);
    mtl_reg_tex(tid, &source, NULL);
    id<MTLBuffer> result = [g_dev newBufferWithLength:2048 options:MTLResourceStorageModeShared]; res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][slot] = tid;
    clear(MTLClearColorMake(1, 0, 0, 1));
    fb_prepare(pr);
    CHECK(!g_enc, "snapshot closes the preceding render pass");
    CHECK(g_fb_n == 1, "feedback attachment receives a snapshot");
    CHECK(g_fb_n == 1 && g_fb_src[0] == original && g_fb_use[0] != original,
          "snapshot substitutes a distinct texture for the registered source");
    rp_end();
    // Overwrite the attachment after the snapshot, then render the sampled value
    // into a distinct target. This makes a missing snapshot fail deterministically
    // even on GPUs that happen to tolerate sampling an attached render target.
    clear(MTLClearColorMake(0, 1, 0, 1)); rp_end();
    R.rt.color[0] = &output;
    sample(fs, pipeline);
    uint64_t bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    CHECK(g_fb_n == 1 && bound == g_fb_rid[0] && bound != original.gpuResourceID._impl,
          "production argument buffer contains the snapshot resource ID");
    readback(destination, result, 0);
    // With a different attachment the following draw restores the original binding.
    fb_prepare(pr);
    CHECK(g_fb_n == 0, "following draw needs no snapshot");
    sample(fs, pipeline);
    bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    CHECK(bound == original.gpuResourceID._impl, "following draw restores the original resource ID");
    readback(destination, result, 1024);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    pixels(result, 0, (const uint8_t[]){255, 0, 0, 255}, "first draw reads the red pre-overwrite snapshot");
    pixels(result, 1024, (const uint8_t[]){0, 255, 0, 255}, "following draw reads the green original attachment");
    printf("feedback slot %d: %s\n", slot, before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&source); mtl_tex_release(&output);
}
// The depth attachment sampled by a draw of its own pass: the snapshot holds the depth from before the overwrite (0.25 → 64), the next draw's snapshot the new one (0.75 → 191)
static void depth_case(NvProg *pr, id<MTLRenderPipelineState> pipeline) {
    int before = failed, tid = 650;
    NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = 0;
    tex_t depth, output;
    id<MTLTexture> original = target_fmt(&depth, 99800, NVN_FORMAT_DEPTH32F_STENCIL8);
    id<MTLTexture> destination = target(&output, 99801);
    mtl_reg_tex(tid, &depth, NULL);
    id<MTLBuffer> result = [g_dev newBufferWithLength:2048 options:MTLResourceStorageModeShared]; res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &output; R.rt.depth = &depth; S.tex[1][0] = tid;
    R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 1); R.clear_d = 1; R.cd = 0.25;
    CHECK(rp_begin() != nil, "production render pass with a depth attachment opens");
    fb_prepare(pr);
    CHECK(!g_enc, "snapshot closes the preceding render pass");
    CHECK(g_fb_n == 1 && g_fb_src[0] == original && g_fb_use[0] != original, "the depth attachment receives a snapshot");
    R.clear_d = 1; R.cd = 0.75; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 1);
    CHECK(rp_begin() != nil, "the overwriting pass opens"); rp_end();
    sample(fs, pipeline);
    uint64_t bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    CHECK(g_fb_n == 1 && bound == g_fb_rid[0] && bound != original.gpuResourceID._impl, "argument buffer holds the depth snapshot");
    readback(destination, result, 0);
    fb_prepare(pr);
    CHECK(g_fb_n == 1, "the next draw takes a new snapshot of the depth attachment");
    sample(fs, pipeline);
    readback(destination, result, 1024);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    pixels(result, 0, (const uint8_t[]){64, 0, 0, 255}, "first draw reads the depth from before the overwrite");
    pixels(result, 1024, (const uint8_t[]){191, 0, 0, 255}, "next draw reads the overwritten depth");
    printf("feedback depth attachment: %s\n", before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&depth); mtl_tex_release(&output);
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_FB_SNAP", "0123456789abcdef", 1);
    setenv("DM_NVN_TBDR", "0", 1);
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A {texture2d<float, access::read> source[[id(0)]];};\n"
        "fragment float4 f(float4 p[[position]], constant A&a[[buffer(0)]]) {return a.source.read(uint2(p.xy));}\n"
        options:nil error:&error];
    CHECK(lib != nil, "synthetic shader compiles");
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvProg *pr = [NvProg new]; NvShader *fs = [NvShader new]; pr->sh[1] = fs;
    fs->stage = 1; strcpy(fs->key, "0123456789abcdef"); fs->fn = [lib newFunctionWithName:@"f"];
    fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; fs->arg_len = fs->ae.encodedLength;
    fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .aid=0, .dtt=MTLTextureType2D};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"v"]; d.fragmentFunction = fs->fn;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    CHECK(pipeline != nil, "synthetic render pipeline compiles");
    if (!pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    const int slots[] = {0, 128, 255};
    for (int i = 0; i < 3; i++) slot_case(pr, pipeline, slots[i], i);
    id<MTLLibrary> dlib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A {depth2d<float, access::read> source[[id(0)]];};\n"
        "fragment float4 f(float4 p[[position]], constant A&a[[buffer(0)]]) {return float4(a.source.read(uint2(p.xy)), 0, 0, 1);}\n"
        options:nil error:&error];
    CHECK(dlib != nil, "synthetic depth shader compiles");
    if (!dlib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvProg *dpr = [NvProg new]; NvShader *dfs = [NvShader new]; dpr->sh[1] = dfs;
    dfs->stage = 1; strcpy(dfs->key, "0123456789abcdef"); dfs->fn = [dlib newFunctionWithName:@"f"];
    dfs->ae = [dfs->fn newArgumentEncoderWithBufferIndex:0]; dfs->arg_len = dfs->ae.encodedLength;
    dfs->rf.nb = 1; dfs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .aid=0, .dtt=MTLTextureType2D};
    d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [dlib newFunctionWithName:@"v"]; d.fragmentFunction = dfs->fn;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8; d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    id<MTLRenderPipelineState> dpipeline = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    CHECK(dpipeline != nil, "synthetic depth render pipeline compiles");
    if (!dpipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    depth_case(dpr, dpipeline);
    printf("feedback snapshot: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
