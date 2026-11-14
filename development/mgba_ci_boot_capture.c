#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba-util/vfs.h>
#include <mgba/internal/gba/input.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>

static void write_ppm(const char *path, const color_t *pixels) {
    FILE *out = fopen(path, "wb");
    if (!out) exit(10);
    fprintf(out, "P6\n240 160\n255\n");
    for (int i = 0; i < 240 * 160; i++) {
        unsigned p = pixels[i];
        fputc(p & 0xFF, out);
        fputc((p >> 8) & 0xFF, out);
        fputc((p >> 16) & 0xFF, out);
    }
    fclose(out);
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    struct mCore *core = mCoreCreate(mPLATFORM_GBA);
    if (!core || !core->init(core)) return 3;
    mCoreInitConfig(core, NULL);
    struct VFile *rom = VFileOpen(argv[1], O_RDONLY);
    if (!rom || !core->loadROM(core, rom)) return 4;

    color_t *pixels = calloc(240 * 160, sizeof(*pixels));
    if (!pixels) return 5;
    core->setVideoBuffer(core, pixels, 240);
    core->reset(core);

    for (int frame = 0; frame < 420; frame++) {
        if (frame == 150 || frame == 270) core->setKeys(core, 1 << GBA_KEY_START);
        if (frame == 152 || frame == 272) core->setKeys(core, 0);
        core->runFrame(core);
        if (frame == 60) write_ppm(argv[2], pixels);
        if (frame == 180) write_ppm("evidence/boot-180.ppm", pixels);
        if (frame == 360) write_ppm("evidence/boot-360.ppm", pixels);
    }

    unsigned lit = 0;
    for (int i = 0; i < 240 * 160; i++) if (pixels[i]) lit++;
    printf("lit_pixels=%u\n", lit);
    core->deinit(core);
    free(pixels);
    return lit ? 0 : 6;
}
