#pragma once
#include "../include/shattered_species.h"

enum ShatteredMountProfile
{
    SHATTERED_MOUNT_BULLGRUM,
    SHATTERED_MOUNT_CRYSTAL_ONIX,
    SHATTERED_MOUNT_CRYSTALIX,
};

static inline int ShatteredGetMountProfile(unsigned short species)
{
    switch (species)
    {
    case SPECIES_SHATTERED_ONIX: return SHATTERED_MOUNT_CRYSTAL_ONIX;
    case SPECIES_CRYSTALIX:      return SHATTERED_MOUNT_CRYSTALIX;
    case SPECIES_SHATTERED_BULLGRUM: return SHATTERED_MOUNT_BULLGRUM;
    default: return -1;
    }
}
