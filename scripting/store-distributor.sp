#pragma semicolon 1

#include <sourcemod>
#include <store>

#define PLUGIN_NAME "[Store] Distributor Module"
#define PLUGIN_DESCRIPTION "Distributor module for the Sourcemod Store."
#define PLUGIN_VERSION_CONVAR "store_distributor_version"

#define MAX_FILTERS 128

enum Filter
{
	String:FilterMap[128],
	FilterPlayerCount,
	FilterFlags,
	Float:FilterMultiplier,
	Float:FilterMinimumMultiplier,
	Float:FilterMaximumMultiplier,
	FilterAddend,
	FilterMinimumAddend,
	FilterMaximumAddend,
	FilterTeam
}

new String:g_currencyName[64];

//Config Globals
new Float:g_timeInSeconds = 180.0;
new bool:g_enableMessagePerTick = true;
new g_baseMinimum = 1;
new g_baseMaximum = 3;
new g_filters[MAX_FILTERS][Filter];
new g_filterCount;

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = STORE_AUTHORS,
	description = PLUGIN_DESCRIPTION,
	version = STORE_VERSION,
	url = STORE_URL
};

public OnPluginStart()
{
	LoadTranslations("store.phrases");
	
	CreateConVar(PLUGIN_VERSION_CONVAR, STORE_VERSION, PLUGIN_NAME, FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_DONTRECORD);
		
	LoadConfig();
	
	CreateTimer(g_timeInSeconds, ForgivePoints, _, TIMER_REPEAT);
}

public OnAllPluginsLoaded()
{
	Store_GetCurrencyName(g_currencyName, sizeof(g_currencyName));
}

public Store_OnDatabaseInitialized()
{
	Store_RegisterPluginModule(PLUGIN_NAME, PLUGIN_DESCRIPTION, PLUGIN_VERSION_CONVAR, STORE_VERSION);
}

LoadConfig()
{
	new Handle:kv = CreateKeyValues("root");

	new String:path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/store/distributor.cfg");

	if (!FileToKeyValues(kv, path))
	{
		CloseHandle(kv);
		SetFailState("Can't read config file %s", path);
	}

	g_timeInSeconds = KvGetFloat(kv, "time_per_distribute", 180.0);
	g_enableMessagePerTick = bool:KvGetNum(kv, "enable_message_per_distribute", 1);

	if (KvJumpToKey(kv, "distribution"))
	{
		g_baseMinimum = KvGetNum(kv, "base_minimum", 1);
		g_baseMaximum = KvGetNum(kv, "base_maximum", 3);

		if (KvJumpToKey(kv, "filters"))
		{
			g_filterCount = 0;

			if (KvGotoFirstSubKey(kv))
			{
				do
				{
					g_filters[g_filterCount][FilterMultiplier] = KvGetFloat(kv, "multiplier", 1.0);
					g_filters[g_filterCount][FilterMinimumMultiplier] = KvGetFloat(kv, "min_multiplier", 1.0);
					g_filters[g_filterCount][FilterMaximumMultiplier] = KvGetFloat(kv, "max_multiplier", 1.0);

					g_filters[g_filterCount][FilterAddend] = KvGetNum(kv, "addend");
					g_filters[g_filterCount][FilterMinimumAddend] = KvGetNum(kv, "min_addend");
					g_filters[g_filterCount][FilterMaximumAddend] = KvGetNum(kv, "max_addend");

					g_filters[g_filterCount][FilterPlayerCount] = KvGetNum(kv, "player_count", 0);
					g_filters[g_filterCount][FilterTeam] = KvGetNum(kv, "team", -1);

					new String:flags[32];
					KvGetString(kv, "flags", flags, sizeof(flags));

					if (!StrEqual(flags, ""))
					{
						g_filters[g_filterCount][FilterFlags] = ReadFlagString(flags);
					}

					KvGetString(kv, "map", g_filters[g_filterCount][FilterMap], 32);

					g_filterCount++;
				} while (KvGotoNextKey(kv));
			}
		}
	}

	CloseHandle(kv);
}


public Action:ForgivePoints(Handle:timer)
{
	new String:map[128];
	GetCurrentMap(map, sizeof(map));

	new clientCount = GetClientCount();

	new accountIds[MaxClients];
	new credits[MaxClients];

	new count = 0;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || IsClientObserver(i)) continue;
		
		accountIds[count] = GetSteamAccountID(i);
		credits[count] = Calculate(i, map, clientCount);
		
		if (g_enableMessagePerTick)
		{
			CPrintToChat(i, "%t%t", "Store Tag Colored", "Received Credits", credits[count], g_currencyName);
		}
		
		count++;
	}

	Store_GiveDifferentCreditsToUsers(accountIds, count, credits);
}

Calculate(client, const String:map[], clientCount)
{
	new min = g_baseMinimum;
	new max = g_baseMaximum;

	for (new filter = 0; filter < g_filterCount; filter++)
	{
		if ((g_filters[filter][FilterPlayerCount] == 0 || clientCount >= g_filters[filter][FilterPlayerCount]) && (StrEqual(g_filters[filter][FilterMap], "") || StrEqual(g_filters[filter][FilterMap], map)) && (g_filters[filter][FilterFlags] == 0 || HasPermission(client, g_filters[filter][FilterFlags])) && (g_filters[filter][FilterTeam] == -1 || g_filters[filter][FilterTeam] == GetClientTeam(client)))
		{
			min = RoundToZero(min * g_filters[filter][FilterMultiplier] * g_filters[filter][FilterMinimumMultiplier]) + g_filters[filter][FilterAddend] + g_filters[filter][FilterMinimumAddend];
			max = RoundToZero(max * g_filters[filter][FilterMultiplier] * g_filters[filter][FilterMaximumMultiplier]) + g_filters[filter][FilterAddend] + g_filters[filter][FilterMaximumAddend];
		}
	}

	return GetRandomInt(min, max);
}

bool:HasPermission(client, flags)
{
	new AdminId:admin = GetUserAdmin(client);
	
	if (admin == INVALID_ADMIN_ID)
	{
		return false;
	}

	new count = 0, found = 0;
	for (new i = 0; i <= 20; i++)
    {
		if (flags & (1<<i))
		{
			count++;

			if (GetAdminFlag(admin, AdminFlag:i))
			{
				found++;
			}
		}
	}

	if (count == found)
	{
		return true;
	}

	return false;
}