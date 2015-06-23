#pragma semicolon 1

#include <sourcemod>
#include <store>

#define PLUGIN_NAME "[Store] Core Module"
#define PLUGIN_DESCRIPTION "Core module for the Sourcemod Store."
#define PLUGIN_VERSION_CONVAR "store_core_version"

#define MAX_MENU_ITEMS 32
#define MAX_CHAT_COMMANDS 100

enum MenuItem
{
	String:MenuItemDisplayName[32],
	String:MenuItemDescription[128],
	String:MenuItemValue[64],
	Handle:MenuItemPlugin,
	Store_MenuItemClickCallback:MenuItemCallback,
	MenuItemOrder,
	bool:MenuItemTranslate
}

enum ChatCommand
{
	String:ChatCommandName[32],
	Handle:ChatCommandPlugin,
	Store_ChatCommandCallback:ChatCommandCallback,
}

//Config Globals
new String:g_currencyName[64];
new String:g_sqlconfigentry[64];
new g_firstConnectionCredits = 0;
new bool:g_hideMenuItemDescriptions = false;
new g_serverID = -1;

new g_chatCommands[MAX_CHAT_COMMANDS + 1][ChatCommand];
new g_chatCommandCount = 0;

new g_menuItems[MAX_MENU_ITEMS + 1][MenuItem];
new g_menuItemCount = 0;

new bool:g_allPluginsLoaded = false;

new bool:g_bHideChatCommands = false;

new Handle:g_hOnChatCommandForward;
new Handle:g_hOnChatCommandPostForward;
new Handle:g_hOnCoreLoaded;

new bool:bLateLoad;

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = STORE_AUTHORS,
	description = PLUGIN_DESCRIPTION,
	version = STORE_VERSION,
	url = STORE_URL
};

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("Store_OpenMainMenu", Native_OpenMainMenu);
	CreateNative("Store_AddMainMenuItem", Native_AddMainMenuItem);
	CreateNative("Store_AddMainMenuItemEx", Native_AddMainMenuItemEx);
	CreateNative("Store_GetCurrencyName", Native_GetCurrencyName);
	CreateNative("Store_GetSQLEntry", Native_GetSQLEntry);
	CreateNative("Store_RegisterChatCommands", Native_RegisterChatCommands);
	CreateNative("Store_GetServerID", Native_GetServerID);
	
	g_hOnChatCommandForward = CreateGlobalForward("Store_OnChatCommand", ET_Event, Param_Cell, Param_String, Param_String);
	g_hOnChatCommandPostForward = CreateGlobalForward("Store_OnChatCommand_Post", ET_Ignore, Param_Cell, Param_String, Param_String);
	g_hOnCoreLoaded = CreateGlobalForward("Store_OnCoreLoaded", ET_Ignore);

	RegPluginLibrary("store");
	bLateLoad = late;
	return APLRes_Success;
}

public OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("store.phrases");
	
	//Keep the original version just to keep OCD people happy.
	CreateConVar("store_version", STORE_VERSION, "Store Version", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_DONTRECORD);
	
	CreateConVar(PLUGIN_VERSION_CONVAR, STORE_VERSION, PLUGIN_NAME, FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_DONTRECORD);
	
	RegAdminCmd("sm_givecredits", Command_GiveCredits, ADMFLAG_ROOT, "Gives credits to a player.");
	RegAdminCmd("sm_removecredits", Command_RemoveCredits, ADMFLAG_ROOT, "Remove credits from a player.");

	g_allPluginsLoaded = false;
	
	LoadConfig();
}

public OnConfigsExecuted()
{
	if (bLateLoad)
	{
		Call_StartForward(g_hOnCoreLoaded);
		Call_Finish();
		bLateLoad = false;
	}
}

public OnAllPluginsLoaded()
{
	SortMainMenuItems();
	g_allPluginsLoaded = true;
	
	if (g_serverID > 0)
	{
		PrintToServer("%t This plugin has been assigned the ID '%i'.", "Store Tag", g_serverID);
	}
	else if (g_serverID == 0)
	{
		Store_LogError("The ServerID 0 is reserved for modular use for the system, please choose an ID over the number 1.");
	}
	else
	{
		Store_LogError("You must set a unique Server ID (server_id) for this server, please double check your core config.");
	}
}

public Store_OnDatabaseInitialized()
{
	Store_RegisterPluginModule(PLUGIN_NAME, PLUGIN_DESCRIPTION, PLUGIN_VERSION_CONVAR, STORE_VERSION);
}

LoadConfig()
{
	new Handle:kv = CreateKeyValues("root");

	new String:path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/store/core.cfg");

	if (!FileToKeyValues(kv, path))
	{
		CloseHandle(kv);
		SetFailState("Can't read config file %s", path);
	}

	KvGetString(kv, "currency_name", g_currencyName, sizeof(g_currencyName), "Credits");
	KvGetString(kv, "sql_config_entry", g_sqlconfigentry, sizeof(g_sqlconfigentry), "default");

	if (KvJumpToKey(kv, "Commands"))
	{
		new String:buffer[256];

		KvGetString(kv, "mainmenu_commands", buffer, sizeof(buffer), "!store /store");
		Store_RegisterChatCommands(buffer, ChatCommand_OpenMainMenu);

		KvGetString(kv, "credits_commands", buffer, sizeof(buffer), "!credits /credits");
		Store_RegisterChatCommands(buffer, ChatCommand_Credits);

		KvGoBack(kv);
	}

	g_firstConnectionCredits = KvGetNum(kv, "first_connection_credits");
	g_hideMenuItemDescriptions = bool:KvGetNum(kv, "hide_menu_descriptions", 0);
	g_bHideChatCommands = bool:KvGetNum(kv, "hide_chat_commands", 0);
	g_serverID = KvGetNum(kv, "server_id", -1);
	
	CloseHandle(kv);
}

public OnClientPostAdminCheck(client)
{
	Store_RegisterClient(client, g_firstConnectionCredits);
}

public Action:OnClientSayCommand(client, const String:command[], const String:sArgs[])
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		return Plugin_Continue;
	}
	
	new String:sArgsTrimmed[256];
	new sArgsLen = strlen(sArgs);

	if (sArgsLen >= 2 && sArgs[0] == '"' && sArgs[sArgsLen - 1] == '"')
	{
		strcopy(sArgsTrimmed, sArgsLen - 1, sArgs[1]);
	}
	else
	{
		strcopy(sArgsTrimmed, sizeof(sArgsTrimmed), sArgs);
	}

	static String:cmds[2][256];
	ExplodeString(sArgsTrimmed, " ", cmds, sizeof(cmds), sizeof(cmds[]), true);

	if (strlen(cmds[0]) <= 0)
	{
		return Plugin_Continue;
	}
	
	for (new i = 0; i < g_chatCommandCount; i++)
	{
		if (StrEqual(cmds[0], g_chatCommands[i][ChatCommandName], false))
		{
			new Action:result = Plugin_Continue;
			Call_StartForward(g_hOnChatCommandForward);
			Call_PushCell(client);
			Call_PushString(cmds[0]);
			Call_PushString(cmds[1]);
			Call_Finish(_:result);

			if (result == Plugin_Handled || result == Plugin_Stop)
			{
				return Plugin_Continue;
			}
			
			Call_StartFunction(g_chatCommands[i][ChatCommandPlugin], g_chatCommands[i][ChatCommandCallback]);
			Call_PushCell(client);
			Call_PushString(cmds[0]);
			Call_PushString(cmds[1]);
			Call_Finish();

			Call_StartForward(g_hOnChatCommandPostForward);
			Call_PushCell(client);
			Call_PushString(cmds[0]);
			Call_PushString(cmds[1]);
			Call_Finish();

			if ((cmds[0][0] == 0x2F) || g_bHideChatCommands)
			{
				return Plugin_Handled;
			}
			else
			{
				return Plugin_Continue;
			}
		}
	}

	return Plugin_Continue;
}

public ChatCommand_OpenMainMenu(client)
{
	OpenMainMenu(client);
}

public ChatCommand_Credits(client)
{
	Store_GetCredits(GetSteamAccountID(client), OnCommandGetCredits, client);
}

public OnCommandGetCredits(credits, any:client)
{
	CPrintToChat(client, "%t%t", "Store Tag Colored", "Store Menu Credits", credits, g_currencyName);
}

public Action:Command_GiveCredits(client, args)
{
	if (args < 2)
	{
		CReplyToCommand(client, "%t Usage: sm_givecredits <target-string> <credits>", "Store Tag Colored");
		return Plugin_Handled;
	}
	
	new String:target[65];
	GetCmdArg(1, target, sizeof(target));
	
	new String:sAmount[32];
	GetCmdArg(2, sAmount, sizeof(sAmount));
	new iMoney = StringToInt(sAmount);
	
	new target_list[MAXPLAYERS];
	new String:target_name[MAX_TARGET_LENGTH];
	new bool:tn_is_ml;
	
	new target_count = ProcessTargetString(target, 0, target_list, MAXPLAYERS, 0, target_name, sizeof(target_name), tn_is_ml);

	if (target_count <= 0)
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}
	
	new accountIds[target_count];
	new count = 0;
	
	for (new i = 0; i < target_count; i++)
	{
		if (!IsClientInGame(target_list[i]) || IsFakeClient(target_list[i])) continue;
		accountIds[count] = GetSteamAccountID(target_list[i]);
		count++;

		CPrintToChat(target_list[i], "%t%t", "Store Tag Colored", "Received Credits", iMoney, g_currencyName);
	}

	Store_GiveCreditsToUsers(accountIds, count, iMoney);
	return Plugin_Handled;
}

public Action:Command_RemoveCredits(client, args)
{
	if (args < 2)
	{
		CReplyToCommand(client, "%t Usage: sm_removecredits <target-string> <credits>", "Store Tag Colored");
		return Plugin_Handled;
	}
	
	new String:target[65];
	GetCmdArg(1, target, sizeof(target));
	
	new String:sAmount[32];
	GetCmdArg(2, sAmount, sizeof(sAmount));
	new iMoney = StringToInt(sAmount);
	
	new target_list[MAXPLAYERS];
	new String:target_name[MAX_TARGET_LENGTH];
	new bool:tn_is_ml;
	
	new target_count = ProcessTargetString(target, 0, target_list, MAXPLAYERS, 0, target_name, sizeof(target_name), tn_is_ml);

	if (target_count <= 0)
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}
	
	for (new i = 0; i < target_count; i++)
	{
		if (!IsClientInGame(target_list[i]) || IsFakeClient(target_list[i])) continue;
		Store_RemoveCredits(GetSteamAccountID(target_list[i]), iMoney, OnRemoveCreditsCallback, GetClientUserId(client));
	}
	
	return Plugin_Handled;
}

public OnRemoveCreditsCallback(accountId, credits, bool:bIsNegative, any:data)
{
	new client = GetClientOfUserId(data);
	
	if (client && IsClientInGame(client))
	{
		CPrintToChat(client, "%t%t", "Store Tag Colored", "Deducted Credits", credits, g_currencyName);
		
		if (bIsNegative)
		{
			CPrintToChat(client, "%t%t", "Store Tag Colored", "Deducted Credits Less Than Zero", g_currencyName);
		}
	}
}

AddMainMenuItem(bool:bTranslate, const String:displayName[], const String:description[] = "", const String:value[] = "", Handle:plugin = INVALID_HANDLE, Store_MenuItemClickCallback:callback, order = 32)
{
	new item;

	for (; item <= g_menuItemCount; item++)
	{
		if (item == g_menuItemCount || StrEqual(g_menuItems[item][MenuItemDisplayName], displayName))
		{
			break;
		}
	}

	strcopy(g_menuItems[item][MenuItemDisplayName], 32, displayName);
	strcopy(g_menuItems[item][MenuItemDescription], 128, description);
	strcopy(g_menuItems[item][MenuItemValue], 64, value);
	g_menuItems[item][MenuItemPlugin] = plugin;
	g_menuItems[item][MenuItemCallback] = callback;
	g_menuItems[item][MenuItemOrder] = order;
	g_menuItems[item][MenuItemTranslate] = bTranslate;

	if (item == g_menuItemCount)
	{
		g_menuItemCount++;
	}
	
	if (g_allPluginsLoaded)
	{
		SortMainMenuItems();
	}
}

SortMainMenuItems()
{
	new sortIndex = sizeof(g_menuItems) - 1;

	for (new x = 0; x < g_menuItemCount; x++)
	{
		for (new y = 0; y < g_menuItemCount; y++)
		{
			if (g_menuItems[x][MenuItemOrder] < g_menuItems[y][MenuItemOrder])
			{
				g_menuItems[sortIndex] = g_menuItems[x];
				g_menuItems[x] = g_menuItems[y];
				g_menuItems[y] = g_menuItems[sortIndex];
			}
		}
	}
}

OpenMainMenu(client)
{
	Store_GetCredits(GetSteamAccountID(client), OnGetCreditsComplete, GetClientUserId(client));
}

public OnGetCreditsComplete(credits, any:data)
{
	new client = GetClientOfUserId(data);

	if (!client)
	{
		return;
	}
	
	new Handle:menu = CreateMenu(MainMenuSelectHandle);
	SetMenuTitle(menu, "%T\n%T\n \n", "Store Menu Title", client, STORE_VERSION, "Store Menu Credits", client, credits, g_currencyName);

	for (new item = 0; item < g_menuItemCount; item++)
	{
		new String:text[255];
		
		if(!g_hideMenuItemDescriptions)
		{
			if (g_menuItems[item][MenuItemTranslate])
			{
				Format(text, sizeof(text), "%T\n%T", g_menuItems[item][MenuItemDisplayName], client, g_menuItems[item][MenuItemDescription], client);
			}
			else
			{
				Format(text, sizeof(text), "%s\n%s", g_menuItems[item][MenuItemDisplayName], g_menuItems[item][MenuItemDescription]);
			}
		}
		else
		{
			if (g_menuItems[item][MenuItemTranslate])
			{
				Format(text, sizeof(text), "%T", g_menuItems[item][MenuItemDisplayName], client);
			}
			else
			{
				Format(text, sizeof(text), "%s", g_menuItems[item][MenuItemDisplayName]);
			}
		}

		AddMenuItem(menu, g_menuItems[item][MenuItemValue], text);
	}

	SetMenuExitButton(menu, true);
	DisplayMenu(menu, client, 0);
}

public MainMenuSelectHandle(Handle:menu, MenuAction:action, client, slot)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			Call_StartFunction(g_menuItems[slot][MenuItemPlugin], g_menuItems[slot][MenuItemCallback]);
			Call_PushCell(client);
			Call_PushString(g_menuItems[slot][MenuItemValue]);
			Call_Finish();
		}
		case MenuAction_End: CloseHandle(menu);
	}
}

public Native_OpenMainMenu(Handle:plugin, params)
{
	OpenMainMenu(GetNativeCell(1));
}

public Native_AddMainMenuItem(Handle:plugin, params)
{
	new String:displayName[32];
	GetNativeString(1, displayName, sizeof(displayName));

	new String:description[128];
	GetNativeString(2, description, sizeof(description));

	new String:value[64];
	GetNativeString(3, value, sizeof(value));

	AddMainMenuItem(true, displayName, description, value, plugin, Store_MenuItemClickCallback:GetNativeFunction(4), GetNativeCell(5));
}

public Native_AddMainMenuItemEx(Handle:plugin, params)
{
	new String:displayName[32];
	GetNativeString(1, displayName, sizeof(displayName));

	new String:description[128];
	GetNativeString(2, description, sizeof(description));

	new String:value[64];
	GetNativeString(3, value, sizeof(value));

	AddMainMenuItem(false, displayName, description, value, plugin, Store_MenuItemClickCallback:GetNativeFunction(4), GetNativeCell(5));
}

public Native_GetCurrencyName(Handle:plugin, params)
{
	SetNativeString(1, g_currencyName, GetNativeCell(2));
}

public Native_GetSQLEntry(Handle:plugin, params)
{
	SetNativeString(1, g_sqlconfigentry, GetNativeCell(2));
}

bool:RegisterCommands(Handle:plugin, const String:commands[], Store_ChatCommandCallback:callback)
{
	if (g_chatCommandCount >= MAX_CHAT_COMMANDS)
	{
		return false;
	}
	
	new String:splitcommands[32][32];
	new count;

	count = ExplodeString(commands, " ", splitcommands, sizeof(splitcommands), sizeof(splitcommands[]));

	if (count <= 0)
	{
		return false;
	}
	
	if (g_chatCommandCount + count >= MAX_CHAT_COMMANDS)
	{
		return false;
	}

	for (new i = 0; i < g_chatCommandCount; i++)
	{
		for (new n = 0; n < count; n++)
		{
			if (StrEqual(splitcommands[n], g_chatCommands[i][ChatCommandName], false))
			{
				return false;
			}
		}
	}

	for (new i = 0; i < count; i++)
	{
		strcopy(g_chatCommands[g_chatCommandCount][ChatCommandName], 32, splitcommands[i]);
		g_chatCommands[g_chatCommandCount][ChatCommandPlugin] = plugin;
		g_chatCommands[g_chatCommandCount][ChatCommandCallback] = callback;

		g_chatCommandCount++;
	}

	return true;
}

public Native_RegisterChatCommands(Handle:plugin, params)
{
	new String:command[32];
	GetNativeString(1, command, sizeof(command));

	return RegisterCommands(plugin, command, Store_ChatCommandCallback:GetNativeFunction(2));
}

public Native_GetServerID(Handle:plugin, params)
{
	if (g_serverID <= 0)
	{
		new String:sPluginName[128];
		GetPluginInfo(plugin, PlInfo_Name, sPluginName, sizeof(sPluginName));
		Store_LogError("Plugin Module '%s' attempted to get the serverID when It's currently set to 0.", sPluginName);
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid ServerID currently set, please check core configuration file field 'server_id'.");
	}
	
	return g_serverID;
}
