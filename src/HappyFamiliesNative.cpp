#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <sstream>
#include <string>
#include <vector>
#include <map>

#include <kenshi/Character.h>
#include <kenshi/CharStats.h>
#include <kenshi/RaceData.h>
#include <kenshi/Enums.h>
#include <kenshi/util/StringPair.h>
#include <kenshi/util/lektor.h>
#include <core/Functions.h>
#include <Debug.h>

#include <KenshiLua.h>

namespace
{
    struct CharacterGenetics
    {
        bool isPregnant;
        bool hasHybridGenes;
        float hybridHungerRate;
        float statMults[STAT_END];

        CharacterGenetics() : isPregnant(false), hasHybridGenes(false), hybridHungerRate(1.0f)
        {
            for (int i = 0; i < STAT_END; ++i)
                statMults[i] = 1.0f;
        }
    };

    std::map<Character*, CharacterGenetics> g_charData;
    bool g_registered = false;

    __declspec(thread) Character* t_activeChar = NULL;

    float (*GetRaceStatModOriginal)(RaceData*, StatsEnumerated) = NULL;

    // Lista de habilidades entrenables válidas para mutación
    const StatsEnumerated kMutatableStats[] = {
        STAT_STRENGTH, STAT_MELEE_ATTACK, STAT_LABOURING, STAT_SCIENCE,
        STAT_ENGINEERING, STAT_ROBOTICS, STAT_SMITHING_WEAPON, STAT_SMITHING_ARMOUR,
        STAT_MEDIC, STAT_THIEVING, STAT_TURRETS, STAT_FARMING, STAT_COOKING,
        STAT_STEALTH, STAT_ATHLETICS, STAT_DEXTERITY, STAT_MELEE_DEFENCE,
        STAT_TOUGHNESS, STAT_ASSASSINATION, STAT_SWIMMING, STAT_PERCEPTION,
        STAT_KATANAS, STAT_SABRES, STAT_HACKERS, STAT_HEAVYWEAPONS, STAT_BLUNT,
        STAT_MARTIALARTS, STAT_MASSCOMBAT, STAT_DODGE, STAT_SURVIVAL,
        STAT_POLEARMS, STAT_CROSSBOWS, STAT_FRIENDLY_FIRE, STAT_LOCKPICKING,
        STAT_SMITHING_BOW
    };
    const int kNumMutatableStats = sizeof(kMutatableStats) / sizeof(kMutatableStats[0]);

    // Modifica temporalmente los floats en RaceData::statMods y los restaura por puntero directo al salir
    struct ScopedHybridRace
    {
        RaceData* race;
        bool active;
        float origHunger;
        float* modifiedPtrs[STAT_END];
        float modifiedOrigVals[STAT_END];
        int modifiedCount;

        ScopedHybridRace(Character* ch) : race(NULL), active(false), origHunger(1.0f), modifiedCount(0)
        {
            if (!ch) return;
            std::map<Character*, CharacterGenetics>::iterator it = g_charData.find(ch);
            if (it == g_charData.end() || !it->second.hasHybridGenes) return;

            race = ch->getRace();
            if (!race) return;

            active = true;
            origHunger = race->hungerRate;
            race->hungerRate = it->second.hybridHungerRate;

            for (ogre_unordered_map<StatsEnumerated, float>::type::iterator mit = race->statMods.begin();
                 mit != race->statMods.end(); ++mit)
            {
                StatsEnumerated st = mit->first;
                if (st > STAT_NONE && st < STAT_END && modifiedCount < STAT_END)
                {
                    modifiedPtrs[modifiedCount] = &(mit->second);
                    modifiedOrigVals[modifiedCount] = mit->second;
                    modifiedCount++;
                    mit->second = it->second.statMults[st];
                }
            }
        }

        ~ScopedHybridRace()
        {
            if (active && race)
            {
                race->hungerRate = origHunger;
                for (int i = 0; i < modifiedCount; ++i)
                {
                    *(modifiedPtrs[i]) = modifiedOrigVals[i];
                }
            }
        }
    };

    // Redimensiona lektor<StringPair> usando el allocator de Ogre compatible con Kenshi
    void AppendToLektor(lektor<StringPair>* list, const std::string& left, const std::string& right)
    {
        if (!list) return;

        if (list->count >= list->maxSize)
        {
            Ogre::STLAllocator<StringPair, Ogre::GeneralAllocPolicy> alloc;
            uint32_t newCap = (list->maxSize == 0) ? 8 : (list->maxSize * 2);
            StringPair* newBuf = alloc.allocate(newCap);
            if (!newBuf) return;

            for (uint32_t i = 0; i < list->count; ++i)
            {
                new (&newBuf[i]) StringPair(list->stuff[i]);
                list->stuff[i].~StringPair();
            }

            if (list->stuff)
                alloc.deallocate(list->stuff, list->maxSize);

            list->stuff = newBuf;
            list->maxSize = newCap;
        }

        new (&list->stuff[list->count]) StringPair(left, right);
        list->count++;
    }

    std::string SerializeGenes(const CharacterGenetics& g)
    {
        std::ostringstream oss;
        oss << g.hybridHungerRate << "|";
        for (int i = 0; i < kNumMutatableStats; ++i)
        {
            int st = (int)kMutatableStats[i];
            if (i > 0) oss << ",";
            oss << st << ":" << g.statMults[st];
        }
        return oss.str();
    }

    void DeserializeGenes(const std::string& str, CharacterGenetics& g)
    {
        size_t pipePos = str.find('|');
        if (pipePos == std::string::npos)
        {
            g.hasHybridGenes = false;
            return;
        }

        g.hybridHungerRate = (float)atof(str.substr(0, pipePos).c_str());
        if (g.hybridHungerRate <= 0.01f) g.hybridHungerRate = 1.0f;

        std::string statsPart = str.substr(pipePos + 1);
        size_t start = 0;
        while (start < statsPart.size())
        {
            size_t comma = statsPart.find(',', start);
            std::string token = (comma == std::string::npos)
                ? statsPart.substr(start)
                : statsPart.substr(start, comma - start);

            size_t colon = token.find(':');
            if (colon != std::string::npos)
            {
                int st = atoi(token.substr(0, colon).c_str());
                float val = (float)atof(token.substr(colon + 1).c_str());
                if (st > STAT_NONE && st < STAT_END && val > 0.01f)
                    g.statMults[st] = val;
            }

            if (comma == std::string::npos) break;
            start = comma + 1;
        }

        g.hasHybridGenes = true;
    }

    // --- FUNCIONES EXPUESTAS A LUA ---

    int Lua_SyncCharacter(lua_State* L)
    {
        Character* ch = KenshiLua::Test<Character>(L, 1);
        if (!ch) return 0;

        bool isPreg = KenshiLua::GetBoolean(L, 2);
        std::string genes = KenshiLua::GetString(L, 3);

        CharacterGenetics& entry = g_charData[ch];
        entry.isPregnant = isPreg;

        if (genes == "NONE")
            entry.hasHybridGenes = false;
        else if (!genes.empty())
            DeserializeGenes(genes, entry);

        return 0;
    }

    int Lua_GenerateGenes(lua_State* L)
    {
        Character* mother = KenshiLua::Test<Character>(L, 1);
        Character* father = KenshiLua::Test<Character>(L, 2);
        Character* child  = KenshiLua::Test<Character>(L, 3);

        if (!mother || !father || !child)
        {
            KenshiLua::Push(L, std::string(""));
            return 1;
        }

        RaceData* raceM = mother->getRace();
        RaceData* raceF = father->getRace();

        CharacterGenetics genes;
        genes.hasHybridGenes = true;

        float hungerM = raceM ? raceM->hungerRate : 1.0f;
        float hungerF = raceF ? raceF->hungerRate : 1.0f;
        genes.hybridHungerRate = (hungerM + hungerF) * 0.5f;

        for (int i = 0; i < kNumMutatableStats; ++i)
        {
            StatsEnumerated st = kMutatableStats[i];
            float modM = raceM ? (GetRaceStatModOriginal ? GetRaceStatModOriginal(raceM, st) : raceM->getStatMod(st)) : 1.0f;
            float modF = raceF ? (GetRaceStatModOriginal ? GetRaceStatModOriginal(raceF, st) : raceF->getStatMod(st)) : 1.0f;
            genes.statMults[st] = (modM + modF) * 0.5f;
        }

        // Mutación genética: +0.1x en una stat aleatoria, -0.1x en otra distinta
        int idxUp = rand() % kNumMutatableStats;
        int idxDown = rand() % kNumMutatableStats;
        if (idxDown == idxUp)
            idxDown = (idxUp + 1) % kNumMutatableStats;

        StatsEnumerated statUp = kMutatableStats[idxUp];
        StatsEnumerated statDown = kMutatableStats[idxDown];

        genes.statMults[statUp] += 0.10f;
        genes.statMults[statDown] = (genes.statMults[statDown] > 0.20f)
            ? (genes.statMults[statDown] - 0.10f)
            : 0.10f;

        g_charData[child] = genes;

        KenshiLua::Push(L, SerializeGenes(genes));
        return 1;
    }

    bool EnsureRegistered()
    {
        if (g_registered) return true;
        if (!KenshiLua::IsAvailable()) return false;

        std::string err;
        if (KenshiLua::RegisterFunction("HF_SyncCharacter", Lua_SyncCharacter, &err) != KenshiLua::STATUS_OK ||
            KenshiLua::RegisterFunction("HF_GenerateGenes", Lua_GenerateGenes, &err) != KenshiLua::STATUS_OK)
        {
            KenshiLua::LogError("[HappyFamiliesNative] Failed to register Lua functions: " + err);
            return false;
        }

        g_registered = true;
        KenshiLua::LogInfo("[HappyFamiliesNative] Native functions registered.");
        return true;
    }

    // --- HOOKS NATIVOS DEL MOTOR ---

    float (*CalcHungerMultOriginal)(CharStats*) = NULL;
    float CalcHungerMultHook(CharStats* self)
    {
        float mult = CalcHungerMultOriginal ? CalcHungerMultOriginal(self) : 1.0f;
        if (!self || !self->me) return mult;

        std::map<Character*, CharacterGenetics>::iterator it = g_charData.find(self->me);
        if (it == g_charData.end()) return mult;

        const CharacterGenetics& g = it->second;

        if (g.hasHybridGenes && self->me->getRace())
        {
            float baseRaceHunger = self->me->getRace()->hungerRate;
            if (baseRaceHunger > 0.01f)
                mult *= (g.hybridHungerRate / baseRaceHunger);
        }

        if (g.isPregnant)
            mult *= 1.5f;

        return mult;
    }

    void (*PrintHungerTooltipOriginal)(CharStats*, lektor<StringPair>*) = NULL;
    void PrintHungerTooltipHook(CharStats* self, lektor<StringPair>* dats)
    {
        if (PrintHungerTooltipOriginal)
            PrintHungerTooltipOriginal(self, dats);

        if (!self || !self->me || !dats) return;

        std::map<Character*, CharacterGenetics>::iterator it = g_charData.find(self->me);
        if (it == g_charData.end()) return;

        const CharacterGenetics& g = it->second;

        if (g.hasHybridGenes)
        {
            char buf[32];
            sprintf_s(buf, "%.2fx", g.hybridHungerRate);

            bool replaced = false;
            for (uint32_t i = 0; i < dats->count; ++i)
            {
                if (dats->stuff[i].s1.find("Racial hunger rate") != std::string::npos)
                {
                    dats->stuff[i].s2 = buf;
                    replaced = true;
                    break;
                }
            }

            if (!replaced)
                AppendToLektor(dats, "Racial hunger rate:", buf);
        }

        if (g.isPregnant)
        {
            AppendToLektor(dats, "Pregnancy:", "1.50x");
        }
    }

    float GetRaceStatModHook(RaceData* self, StatsEnumerated st)
    {
        if (t_activeChar && t_activeChar->getRace() == self && st > STAT_NONE && st < STAT_END)
        {
            std::map<Character*, CharacterGenetics>::iterator it = g_charData.find(t_activeChar);
            if (it != g_charData.end() && it->second.hasHybridGenes)
            {
                return it->second.statMults[st];
            }
        }
        return GetRaceStatModOriginal ? GetRaceStatModOriginal(self, st) : 1.0f;
    }

    typedef std::string* (__fastcall *GetStatMultGUIFn)(CharStats*, std::string*, StatsEnumerated);
    GetStatMultGUIFn GetStatMultGUIOriginal = NULL;

    std::string* __fastcall GetStatMultGUIHook(CharStats* self, std::string* outStr, StatsEnumerated st)
    {
        if (self && self->me && st > STAT_NONE && st < STAT_END)
        {
            std::map<Character*, CharacterGenetics>::iterator it = g_charData.find(self->me);
            if (it != g_charData.end() && it->second.hasHybridGenes)
            {
                char buf[32];
                sprintf_s(buf, "x%.3f", it->second.statMults[st]);
                new (outStr) std::string(buf);
                return outStr;
            }
        }
        return GetStatMultGUIOriginal
            ? GetStatMultGUIOriginal(self, outStr, st)
            : new (outStr) std::string("x1.000");
    }

    float (*GetStatMultOriginal)(const CharStats*, StatsEnumerated) = NULL;
    float GetStatMultHook(const CharStats* self, StatsEnumerated st)
    {
        if (self && self->me && st > STAT_NONE && st < STAT_END)
        {
            std::map<Character*, CharacterGenetics>::iterator it = g_charData.find(self->me);
            if (it != g_charData.end() && it->second.hasHybridGenes)
            {
                return it->second.statMults[st];
            }
        }
        return GetStatMultOriginal ? GetStatMultOriginal(self, st) : 1.0f;
    }

    // --- HOOKS DE UI Y XP CON OVERRIDE TEMPORAL POR PUNTERO DIRECTO ---

    void (*GetGUIDataOriginal)(CharStats*, DatapanelGUI*, int) = NULL;
    void GetGUIDataHook(CharStats* self, DatapanelGUI* panel, int category)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (GetGUIDataOriginal) GetGUIDataOriginal(self, panel, category);
        t_activeChar = prev;
    }

    void (*GetGUIDataMainOriginal)(CharStats*, DatapanelGUI*, int, bool) = NULL;
    void GetGUIDataMainHook(CharStats* self, DatapanelGUI* panel, int category, bool combatMode)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (GetGUIDataMainOriginal) GetGUIDataMainOriginal(self, panel, category, combatMode);
        t_activeChar = prev;
    }

    void (*XpGeneralOriginal)(CharStats*, float, float, StatsEnumerated) = NULL;
    void XpGeneralHook(CharStats* self, float time, float mult, StatsEnumerated what)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpGeneralOriginal) XpGeneralOriginal(self, time, mult, what);
        t_activeChar = prev;
    }

    void (*XpTrainingOriginal)(CharStats*, float, float, float&, float, StatsEnumerated) = NULL;
    void XpTrainingHook(CharStats* self, float time, float mult, float& stat, float upperLimit, StatsEnumerated what)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpTrainingOriginal) XpTrainingOriginal(self, time, mult, stat, upperLimit, what);
        t_activeChar = prev;
    }

    void (*XpMeleeOriginal)(CharStats*, CharStats::DeadTimeState, Character*, const Damages&) = NULL;
    void XpMeleeHook(CharStats* self, CharStats::DeadTimeState what, Character* target, const Damages& damage)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpMeleeOriginal) XpMeleeOriginal(self, what, target, damage);
        t_activeChar = prev;
    }

    void (*XpDodgeOriginal)(CharStats*, float, bool) = NULL;
    void XpDodgeHook(CharStats* self, float enemySkill, bool successful)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpDodgeOriginal) XpDodgeOriginal(self, enemySkill, successful);
        t_activeChar = prev;
    }

    void (*XpToughnessRagdollOriginal)(CharStats*) = NULL;
    void XpToughnessRagdollHook(CharStats* self)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpToughnessRagdollOriginal) XpToughnessRagdollOriginal(self);
        t_activeChar = prev;
    }

    void (*XpToughnessGetUpOriginal)(CharStats*) = NULL;
    void XpToughnessGetUpHook(CharStats* self)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpToughnessGetUpOriginal) XpToughnessGetUpOriginal(self);
        t_activeChar = prev;
    }

    void (*XpToughnessPunchOriginal)(CharStats*, HitMaterialType) = NULL;
    void XpToughnessPunchHook(CharStats* self, HitMaterialType mat)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpToughnessPunchOriginal) XpToughnessPunchOriginal(self, mat);
        t_activeChar = prev;
    }

    void (*XpFirstAidOriginal)(CharStats*, Character*, float, StatsEnumerated) = NULL;
    void XpFirstAidHook(CharStats* self, Character* patient, float time, StatsEnumerated medicStat)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpFirstAidOriginal) XpFirstAidOriginal(self, patient, time, medicStat);
        t_activeChar = prev;
    }

    void (*XpRunningOriginal)(CharStats*, float, float) = NULL;
    void XpRunningHook(CharStats* self, float time, float speed)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpRunningOriginal) XpRunningOriginal(self, time, speed);
        t_activeChar = prev;
    }

    void (*XpStealthOriginal)(CharStats*, float, bool, YesNoMaybe, bool) = NULL;
    void XpStealthHook(CharStats* self, float time, bool enemiesAbout, YesNoMaybe seen, bool isMoving)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpStealthOriginal) XpStealthOriginal(self, time, enemiesAbout, seen, isMoving);
        t_activeChar = prev;
    }

    void (*XpStealthHearOriginal)(CharStats*, bool, bool, bool) = NULL;
    void XpStealthHearHook(CharStats* self, bool enemiesAbout, bool trespassing, bool seen)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpStealthHearOriginal) XpStealthHearOriginal(self, enemiesAbout, trespassing, seen);
        t_activeChar = prev;
    }

    void (*XpMassCombatOriginal)(CharStats*) = NULL;
    void XpMassCombatHook(CharStats* self)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpMassCombatOriginal) XpMassCombatOriginal(self);
        t_activeChar = prev;
    }

    void (*XpEngineeringOriginal)(CharStats*, float) = NULL;
    void XpEngineeringHook(CharStats* self, float time)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpEngineeringOriginal) XpEngineeringOriginal(self, time);
        t_activeChar = prev;
    }

    void (*XpLockpickingOriginal)(CharStats*, int, bool) = NULL;
    void XpLockpickingHook(CharStats* self, int lockLevel, bool success)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpLockpickingOriginal) XpLockpickingOriginal(self, lockLevel, success);
        t_activeChar = prev;
    }

    void (*XpTimeBasedOriginal)(CharStats*, StatsEnumerated) = NULL;
    void XpTimeBasedHook(CharStats* self, StatsEnumerated st)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpTimeBasedOriginal) XpTimeBasedOriginal(self, st);
        t_activeChar = prev;
    }

    void (*XpEventBasedOriginal)(CharStats*, StatsEnumerated, float) = NULL;
    void XpEventBasedHook(CharStats* self, StatsEnumerated st, float amount)
    {
        Character* ch = self ? self->me : NULL;
        Character* prev = t_activeChar;
        t_activeChar = ch;
        ScopedHybridRace guard(ch);
        if (XpEventBasedOriginal) XpEventBasedOriginal(self, st, amount);
        t_activeChar = prev;
    }

    void (*CharGetGUIDataOriginal)(Character*, DatapanelGUI*, int) = NULL;
    void CharGetGUIDataHook(Character* self, DatapanelGUI* datapanel, int category)
    {
        Character* prev = t_activeChar;
        t_activeChar = self;
        ScopedHybridRace guard(self);
        if (CharGetGUIDataOriginal) CharGetGUIDataOriginal(self, datapanel, category);
        t_activeChar = prev;
    }

    void (*UpdateGUIStatsDetailsOriginal)(Character*, DatapanelGUI*, const std::string&, int) = NULL;
    void UpdateGUIStatsDetailsHook(Character* self, DatapanelGUI* datapanel, const std::string& name, int statId)
    {
        Character* prev = t_activeChar;
        t_activeChar = self;
        ScopedHybridRace guard(self);
        if (UpdateGUIStatsDetailsOriginal) UpdateGUIStatsDetailsOriginal(self, datapanel, name, statId);
        t_activeChar = prev;
    }

    void (*PrintRaceXPBonusLineOriginal)(Character*, DatapanelGUI*, StatsEnumerated) = NULL;
    void PrintRaceXPBonusLineHook(Character* self, DatapanelGUI* panel, StatsEnumerated s)
    {
        Character* prev = t_activeChar;
        t_activeChar = self;
        ScopedHybridRace guard(self);
        if (PrintRaceXPBonusLineOriginal) PrintRaceXPBonusLineOriginal(self, panel, s);
        t_activeChar = prev;
    }

    void (*CharSelectOriginal)(Character*) = NULL;
    void CharSelectHook(Character* ch)
    {
        if (CharSelectOriginal)
            CharSelectOriginal(ch);
        EnsureRegistered();
    }
}

__declspec(dllexport) void startPlugin()
{
    srand((unsigned int)time(NULL));
    
    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&Character::_NV_getGUIData),
        &CharGetGUIDataHook,
        &CharGetGUIDataOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&Character::updateGUIStatsDetails),
        &UpdateGUIStatsDetailsHook,
        &UpdateGUIStatsDetailsOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&Character::_printRaceXPBonusLine),
        &PrintRaceXPBonusLineHook,
        &PrintRaceXPBonusLineOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::getStatMultiplier),
        &GetStatMultHook,
        &GetStatMultOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::getStatMultiplierForGUI),
        &GetStatMultGUIHook,
        &GetStatMultGUIOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::calculateHungerMult),
        &CalcHungerMultHook,
        &CalcHungerMultOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::printExertionHungerMultTooltip),
        &PrintHungerTooltipHook,
        &PrintHungerTooltipOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&RaceData::getStatMod),
        &GetRaceStatModHook,
        &GetRaceStatModOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::getGUIData),
        &GetGUIDataHook,
        &GetGUIDataOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::getGUIDataForMainInfo),
        &GetGUIDataMainHook,
        &GetGUIDataMainOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpGeneral),
        &XpGeneralHook,
        &XpGeneralOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpTraining),
        &XpTrainingHook,
        &XpTrainingOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpMelee),
        &XpMeleeHook,
        &XpMeleeOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpDodgeEvent),
        &XpDodgeHook,
        &XpDodgeOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpToughness_RagdollEvent),
        &XpToughnessRagdollHook,
        &XpToughnessRagdollOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpToughness_GetUpEvent),
        &XpToughnessGetUpHook,
        &XpToughnessGetUpOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpToughness_PunchSomething),
        &XpToughnessPunchHook,
        &XpToughnessPunchOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpFirstAid),
        &XpFirstAidHook,
        &XpFirstAidOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpRunning),
        &XpRunningHook,
        &XpRunningOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpStealth),
        &XpStealthHook,
        &XpStealthOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpStealthHearCheckEvent),
        &XpStealthHearHook,
        &XpStealthHearOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpMassCombat),
        &XpMassCombatHook,
        &XpMassCombatOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpEngineering),
        &XpEngineeringHook,
        &XpEngineeringOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpLockpicking),
        &XpLockpickingHook,
        &XpLockpickingOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpStat_timeBased),
        &XpTimeBasedHook,
        &XpTimeBasedOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&CharStats::xpStat_eventBased),
        &XpEventBasedHook,
        &XpEventBasedOriginal);

    KenshiLib::AddHook(
        KenshiLib::GetRealAddress(&Character::_NV_select),
        &CharSelectHook,
        &CharSelectOriginal);

    EnsureRegistered();
}