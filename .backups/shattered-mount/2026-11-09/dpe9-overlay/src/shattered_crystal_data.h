#pragma once
#include "../include/shattered_species.h"

struct ShatteredCrystalSpeciesRecord
{
    unsigned short species;
    unsigned char hp, attack, defense, spAttack, spDefense, speed;
    unsigned char type1, type2;
    unsigned short evolutionItem;
    unsigned short evolutionTarget;
};

/* Ice/Rock; CRYSTAL_BODY is installed at the final-damage ability hook. */
static const struct ShatteredCrystalSpeciesRecord gShatteredCrystalSpecies[] =
{
    {SPECIES_SHATTERED_ONIX, 50, 115, 105, 30, 105, 40, 15, 5, ITEM_ICE_STONE, SPECIES_CRYSTALIX},
    {SPECIES_CRYSTALIX,       95, 140, 145, 40, 125, 25, 15, 5, ITEM_NONE,     SPECIES_NONE},
};
