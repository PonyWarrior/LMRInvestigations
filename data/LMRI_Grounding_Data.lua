-- =============================================================================
-- LMRI_Grounding_Data.lua - SNAPSHOT of vanilla ExQuestRewardSetting.user.3
-- Ground-truth oracle to CONFIRM the live in-game reader produces the same
-- per-(field,rank,item) caps. The live tables are the SOURCE of legality
-- checks; this file only cross-checks the reader after loading the game.
-- Regenerate: python extract_legality.py <vanilla.json> <out.lua>
-- =============================================================================

local G = {}

-- rank enum hash -> 'REWARD_RANK_xx' (names are stable across updates)
G.RANK_NAMES = {
    [-1866562304] = "REWARD_RANK_04",
    [-1196666624] = "REWARD_RANK_01",
    [-771966272] = "REWARD_RANK_07",
    [-731883392] = "REWARD_RANK_06",
    [316158848] = "REWARD_RANK_08",
    [1893483520] = "REWARD_RANK_05",
    [2010001152] = "REWARD_RANK_09",
}

-- item id -> display name (id space = RewardItem enum _Value)
G.ITEM_NAMES = {
    [156] = "Mystery Orb - Armor",
    [157] = "Glowing Orb - Armor",
    [158] = "Ancient Orb - Armor",
    [159] = "Damaged Weapon Shard",
    [160] = "Rusted Weapon Shard",
    [479] = "Ancient Weapon Fragment",
    [619] = "Mystery Orb - Sword",
    [620] = "Glowing Orb - Sword",
    [621] = "Ancient Orb - Sword",
    [822] = "Glowing Stone",
}

-- caps[field][rank][item] = max Num; field names match live fields (_X)
G.ITEM_CAPS = {
    AmuletRewardTbl = {
        REWARD_RANK_09 = {
            [822] = 1,
        },
    },
    ["AmuletRewardTblByEm.AmuletRewardTbl"] = {
        REWARD_RANK_09 = {
            [822] = 2,
        },
    },
    ["AmuletRewardTblByEm.AmuletRewardTbl_SpOffer"] = {
        REWARD_RANK_09 = {
            [822] = 2,
        },
    },
    ArtianRewardTbl = {
        REWARD_RANK_05 = {
            [159] = 3,
        },
        REWARD_RANK_06 = {
            [160] = 3,
        },
        REWARD_RANK_07 = {
            [479] = 1,
        },
        REWARD_RANK_08 = {
            [479] = 2,
        },
    },
    ["ArtianRewardTblByEm.ArtianRewardTbl"] = {
        REWARD_RANK_08 = {
            [479] = 3,
        },
    },
    ["ArtianRewardTblByEm.ArtianRewardTbl_SpOffer"] = {
        REWARD_RANK_08 = {
            [479] = 3,
        },
    },
    SkillGemRewardTbl = {
        REWARD_RANK_04 = {
            [156] = 2,
            [157] = 1,
            [619] = 2,
            [620] = 1,
        },
        REWARD_RANK_05 = {
            [157] = 2,
            [620] = 2,
        },
        REWARD_RANK_06 = {
            [158] = 2,
            [621] = 2,
        },
        REWARD_RANK_07 = {
            [158] = 3,
            [621] = 3,
        },
        REWARD_RANK_08 = {
            [158] = 4,
            [621] = 4,
        },
    },
    ["SkillGemRewardTblByEm.SkillGemRewardTbl"] = {
        REWARD_RANK_08 = {
            [158] = 4,
            [621] = 4,
        },
    },
    ["SkillGemRewardTblByEm.SkillGemRewardTbl_SpOffer"] = {
        REWARD_RANK_08 = {
            [158] = 4,
            [621] = 4,
        },
    },
}

-- slot caps: SLOT_CAPS[rank][grade] = max LotNum (normal + SpOffer)
G.SLOT_CAPS = {
    REWARD_RANK_01 = {
        [1] = 6,
        [2] = 6,
        [3] = 10,
        [4] = 10,
        [5] = 10,
    },
    REWARD_RANK_09 = {
        [0] = 10,
        [3] = 7,
        [4] = 7,
        [5] = 8,
    },
}

G.FRENZY_CAP = 3

return G
