#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/internal/arm/arm.h>
#include <mgba-util/vfs.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

#define HANDLER 0x08372E45u
#define SENTINEL 0x02000101u
#define STACK 0x03007F00u
#define BATTLE_MON 0x02023BE4u
#define CURRENT_MOVE 0x02023D4Au
#define MOVE_DAMAGE 0x02023D50u

static void quiet(struct mLogger *logger, int category, enum mLogLevel level, const char *fmt, va_list args) {
    (void)logger; (void)category; (void)level; (void)fmt; (void)args;
}

static int run_case(struct mCore *core, uint8_t ability, uint16_t move, uint32_t damage, uint32_t expected) {
    struct ARMCore *cpu = core->cpu;
    core->busWrite8(core, BATTLE_MON + 0x20, ability);
    core->busWrite16(core, CURRENT_MOVE, move);
    core->busWrite32(core, MOVE_DAMAGE, damage);
    core->busWrite8(core, STACK, 0);
    cpu->gprs[9] = 0;
    cpu->gprs[13] = STACK;
    cpu->gprs[14] = SENTINEL;
    cpu->gprs[15] = HANDLER;
    cpu->executionMode = MODE_THUMB;
    for (unsigned i = 0; i < 200; i++) {
        core->step(core);
        if (cpu->gprs[15] == SENTINEL) break;
    }
    uint32_t actual = core->busRead32(core, MOVE_DAMAGE);
    if (actual != expected || cpu->gprs[15] != SENTINEL) {
        fprintf(stderr, "failed ability=%u move=%u expected=%u actual=%u pc=%08x\n", ability, move, expected, actual, cpu->gprs[15]);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    struct mLogger logger = {.log = quiet, .filter = NULL};
    mLogSetDefaultLogger(&logger);
    struct mCore *core = mCoreCreate(mPLATFORM_GBA);
    if (!core || !core->init(core)) return 3;
    mCoreInitConfig(core, NULL);
    struct VFile *rom = VFileOpen(argv[1], O_RDONLY);
    if (!rom || !core->loadROM(core, rom)) return 4;
    core->reset(core);
    int failed = 0;
    failed |= run_case(core, 16, 55, 73, 0);   /* Water Gun */
    failed |= run_case(core, 16, 52, 73, 146); /* Ember */
    failed |= run_case(core, 16, 33, 73, 36);  /* Tackle */
    failed |= run_case(core, 16, 33, 1, 1);    /* minimum damage */
    failed |= run_case(core, 0, 55, 73, 73);   /* suppressed */
    if (!failed) puts("PASS native mGBA Crystal Body handler contract");
    core->deinit(core);
    return failed;
}
