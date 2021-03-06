#include <sourcemod>
#include "include/Merx"

public Plugin:myinfo = 
{
	name = "Merx Points System",
	author = "necavi",
	description = "Tracks player points",
	version = MERX_BUILD,
	url = "http://necavi.org"
}
new Handle:g_hEventOnPrePlayerPointChange = INVALID_HANDLE;
new Handle:g_hEventOnPlayerPointChange = INVALID_HANDLE;
new Handle:g_hEventOnPlayerPointChanged = INVALID_HANDLE;
new Handle:g_hEventOnDatabaseReady = INVALID_HANDLE;
new Handle:g_hEventOnPlayerPointsRetrieved = INVALID_HANDLE;

new Handle:g_hCvarDefaultPoints = INVALID_HANDLE;
new Handle:g_hCvarSaveTimer = INVALID_HANDLE;
new Handle:g_hCvarTag = INVALID_HANDLE;
new Handle:g_hDatabase = INVALID_HANDLE;

new g_iPlayerPoints[MAXPLAYERS + 2];
new g_iPlayerTotalPoints[MAXPLAYERS + 2];
new g_iPlayerID[MAXPLAYERS + 2];
new g_iDefaultPoints;

new bool:g_bHasTotalPointsColumn = false;

new String:g_sMerxTag[64];

new DBType:g_DatabaseType;

new ValveGame:g_Game = Game_UNKNOWN;

public APLRes:AskPluginLoad2(Handle:plugin, bool:late, String:error[], err_max) 
{
	FindGameType();
	CreateNative("GetGame", Native_GetGame);
	CreateNative("GivePlayerPoints", Native_GivePlayerPoints);
	CreateNative("TakePlayerPoints", Native_TakePlayerPoints);
	CreateNative("SetPlayerPoints", Native_SetPlayerPoints);
	CreateNative("GetPlayerPoints", Native_GetPlayerPoints);
	CreateNative("GetPlayerTotalPoints", Native_GetPlayerTotalPoints);
	CreateNative("SavePlayerPoints", Native_SavePlayerPoints);
	CreateNative("ResetPlayerPoints", Native_ResetPlayerPoints);
	CreateNative("GetPlayerID", Native_GetPlayerID);
	CreateNative("MerxPrintToChat", Native_MerxPrintToChat);
	CreateNative("MerxPrintToChatAll", Native_MerxPrintToChatAll);
	CreateNative("MerxReplyToCommand", Native_MerxReplyToCommand);
	CreateNative("GetDatabaseHandle", Native_GetDatabaseHandle);
	g_hEventOnPrePlayerPointChange = CreateGlobalForward("OnPrePlayerPointsChange", ET_Hook, Param_Cell, Param_Cell, Param_CellByRef);
	g_hEventOnPlayerPointChange = CreateGlobalForward("OnPlayerPointsChange", ET_Event, Param_Cell, Param_Cell, Param_Cell);
	g_hEventOnPlayerPointChanged = CreateGlobalForward("OnPlayerPointsChanged", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	g_hEventOnDatabaseReady = CreateGlobalForward("OnDatabaseReady", ET_Ignore, Param_Cell, Param_Cell);
	g_hEventOnPlayerPointsRetrieved = CreateGlobalForward("OnPlayerPointsRetrieved", ET_Ignore, Param_Cell, Param_Cell);
	return APLRes_Success;
}
public OnPluginStart()
{
	LoadTranslations("merx.core");
	RegConsoleCmd("sm_points", ConCmd_Points, "Displays your current points.");
	RegConsoleCmd("sm_toppoints", ConCmd_TopPoints, "Displays the top players by total points.");
	CreateConVar("merx_version", MERX_BUILD, "Either the current build number or CUSTOM for a hand-compile.", FCVAR_PLUGIN | FCVAR_NOTIFY);
	g_hCvarDefaultPoints = CreateConVar("merx_default_points", "10", "Sets the default number of points to give new players.", FCVAR_PLUGIN, true, 0.0);
	g_iDefaultPoints = GetConVarInt(g_hCvarDefaultPoints);
	HookConVarChange(g_hCvarDefaultPoints, ConVar_DefaultPoints);
	g_hCvarSaveTimer = CreateConVar("merx_save_timer", "300", "Sets the duration between automatic saves.", FCVAR_PLUGIN);
	CreateTimer(GetConVarFloat(g_hCvarSaveTimer), Timer_SavePoints);
	g_hCvarTag = CreateConVar("merx_tag", "{OG}[{G}MERX{OG}]{N}", "Controls the command tag for merx.", FCVAR_PLUGIN);
	GetConVarString(g_hCvarTag, g_sMerxTag, sizeof(g_sMerxTag));
	HookConVarChange(g_hCvarTag, ConVar_Tag);
	if(SQL_CheckConfig("merx"))
	{
		SQL_TConnect(SQLCallback_DBConnect, "merx");
	}
	else
	{
		SQL_TConnect(SQLCallback_DBConnect);
	}
}
public OnPluginEnd()
{
	for(new i = 0; i <= MaxClients; i++)
	{
		if(IsValidPlayer(i))
		{
			new String:query[256];
			CreatePlayerSaveQuery(i, query, sizeof(query));
			SQL_FastQuery(g_hDatabase, query);
		}
	}
}
public OnMapEnd()
{
	for(new i = 0; i <= MaxClients; i++)
	{
		if(IsValidPlayer(i))
		{
			SaveClientPoints(i);
		}
	}
}
public OnClientConnected(client) 
{
	g_iPlayerPoints[client] = 0;
	g_iPlayerTotalPoints[client] = 0;
	g_iPlayerID[client] = -1;
}
public OnClientDisconnect(client)
{
	SaveClientPoints(client);
}
public OnClientAuthorized(client, const String:auth[]) 
{
	if(!IsFakeClient(client))
	{
		new String:query[256];
		if(g_bHasTotalPointsColumn)
		{
			Format(query, sizeof(query), "SELECT `player_id`, `player_points`, `player_total_points` FROM `merx_players` WHERE `player_steamid` = '%s';", auth);
		}
		else
		{
			Format(query, sizeof(query), "SELECT `player_id`, `player_points` FROM `merx_players` WHERE `player_steamid` = '%s';", auth);
		}
		SQL_TQuery(g_hDatabase, SQLCallback_Connect, query, GetClientUserId(client));
	}
}
public Action:ConCmd_Points(client, args)
{
	if(client > 0)
	{
		MerxReplyToCommand(client, "%T", "current_points", client, GetPlayerPoints(client));
	}
	else
	{
		MerxReplyToCommand(client, "%T", "unable_to_use_points", client);
	}
	return Plugin_Handled;
}
public Action:ConCmd_TopPoints(client, args)
{
	if(client > 0)
	{
		if(g_bHasTotalPointsColumn)
		{
			ShowTopPlayers(client);
		}
		else
		{
			MerxReplyToCommand(client, "%T", "database_missing_total_points_column", client);
		}
	}
	return Plugin_Handled;
}
ShowTopPlayers(client)
{
	new String:query[256];
	Format(query, sizeof(query), "SELECT `player_name`, `player_total_points` FROM `merx_players` WHERE `player_id` != -1 ORDER BY `player_total_points` DESC LIMIT 10;");
	SQL_TQuery(g_hDatabase, SQLCallback_ShowTopPlayers, query, GetClientUserId(client));
}
public Native_GetDatabaseHandle(Handle:plugin, numParams)
{
	return _:g_hDatabase;
}
public SQLCallback_ShowTopPlayers(Handle:db, Handle:hndl, const String:error[], any:userid)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error selecting top players. %s.", error);
	} 
	else 
	{	
		new client = GetClientOfUserId(userid);
		new Handle:menu = CreateMenu(MenuHandler_ShowTopPlayers);
		SetMenuTitle(menu, "%T", "menu_title_top_players", client);
		new String:name[MAX_NAME_LENGTH];
		new String:item[128];
		while(SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, name, sizeof(name));
			Format(item, sizeof(item), "%s (%d)", name, SQL_FetchInt(hndl, 1));
			AddMenuItem(menu, "", item);
		}
		DisplayMenu(menu, client, MENU_TIME_FOREVER);
	}
}
public MenuHandler_ShowTopPlayers(Handle:menu, MenuAction:action, client, item) 
{
	switch(action)
	{
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}
public SQLCallback_Connect(Handle:db, Handle:hndl, const String:error[], any:userid) 
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error selecting player. %s.", error);
	} 
	else 
	{
		new client = GetClientOfUserId(userid);
		if(client == 0)
		{
			return;
		}
		if(SQL_GetRowCount(hndl)>0) 
		{
			SQL_FetchRow(hndl);
			g_iPlayerID[client] = SQL_FetchInt(hndl, 0);
			g_iPlayerPoints[client] += SQL_FetchInt(hndl, 1);
			if(g_bHasTotalPointsColumn)
			{
				g_iPlayerTotalPoints[client] += SQL_FetchInt(hndl, 2);
			}
			else
			{
				g_iPlayerTotalPoints[client] = g_iPlayerPoints[client];
			}
			FirePlayerPointsRetrieved(client);
		} 
		else 
		{
			new String:query[128];
			Format(query, sizeof(query), "SELECT max(`player_id`) FROM `merx_players`;");
			SQL_TQuery(g_hDatabase, SQLCallback_GetNextID, query, GetClientUserId(client));
		}
	}
}
public SQLCallback_GetNextID(Handle:db, Handle:hndl, const String:error[], any:userid) 
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error getting next database ID. %s.", error);
	} 
	else 
	{
		new client = GetClientOfUserId(userid);
		if(client == 0)
		{
			return;
		}
		SQL_FetchRow(hndl);
		g_iPlayerID[client] = SQL_FetchInt(hndl, 0) + 1;
		new String:query[512];
		new String:auth[32];
		GetClientAuthString(client, auth, sizeof(auth));
		g_iPlayerPoints[client] += g_iDefaultPoints;
		new String:szName[MAX_NAME_LENGTH * 2 + 1];
		GetClientName(client, szName, sizeof(szName));
		SQL_EscapeString(g_hDatabase, szName, szName, sizeof(szName));
		if(g_bHasTotalPointsColumn)
		{
			Format(query, sizeof(query), "INSERT INTO `merx_players` (`player_id`, `player_steamid`, `player_name`, `player_points`, `player_total_points`, `player_joindate`) VALUES ('%d', '%s', '%s', '%d', '%d', CURRENT_TIMESTAMP);", g_iPlayerID[client], auth, szName, g_iPlayerPoints[client], g_iPlayerTotalPoints[client]);
		}
		else
		{
			Format(query, sizeof(query), "INSERT INTO `merx_players` (`player_id`, `player_steamid`, `player_name`, `player_points`, `player_joindate`) VALUES ('%d', '%s', '%s', '%d', CURRENT_TIMESTAMP);", g_iPlayerID[client], auth, szName, g_iPlayerPoints[client]);
		}
		SQL_TQuery(g_hDatabase, SQLCallback_NewPlayer, query, userid);
	}
}
public SQLCallback_NewPlayer(Handle:db, Handle:hndl, const String:error[], any:userid) 
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error inserting new player. %s.", error);
	} 
	else 
	{
		new client = GetClientOfUserId(userid);
		if(client == 0)
		{
			return;
		}
		FirePlayerPointsRetrieved(client);
	}
}
FirePlayerPointsRetrieved(client)
{
	Call_StartForward(g_hEventOnPlayerPointsRetrieved);
	Call_PushCell(client);
	Call_PushCell(g_iPlayerID[client]);
	Call_Finish();
}
public SQLCallback_Void(Handle:db, Handle:hndl, const String:error[], any:data) 
{
	if(hndl == INVALID_HANDLE)
	{
		LogError("Error during SQL query. %s", error);
	}
}
CreateDatabaseTables()
{
	new String:ident[32];
	SQL_GetDriverIdent(SQL_ReadDriver(g_hDatabase), ident, sizeof(ident));
	if(StrEqual("mysql", ident, false))
	{
		g_DatabaseType = DB_MySQL;
	}
	else if(StrEqual("sqlite", ident, false))
	{
		g_DatabaseType = DB_SQLite;
	}
	new String:query[512];
	if(g_DatabaseType == DB_SQLite)
	{
		Format(query, sizeof(query),"CREATE TABLE IF NOT EXISTS `merx_players` ( \
		`player_id` INTEGER UNSIGNED PRIMARY KEY, \
		`player_steamid` VARCHAR(32) NOT NULL, \
		`player_name` VARCHAR(32) NOT NULL, \
		`player_joindate` TIMESTAMP NULL, \
		`player_lastseen` TIMESTAMP NULL, \
		`player_points` INT NOT NULL, \
		`player_total_points` INT NOT NULL \
		);");
		SQL_TQuery(g_hDatabase, SQLCallback_CreatePlayerTable, query);
	}
	else
	{
		Format(query, sizeof(query),"CREATE TABLE IF NOT EXISTS `merx_players` ( \
		`player_id` INTEGER UNSIGNED PRIMARY KEY, \
		`player_steamid` VARCHAR(32) NOT NULL, \
		`player_name` VARCHAR(32) NOT NULL, \
		`player_joindate` TIMESTAMP NULL, \
		`player_lastseen` TIMESTAMP NULL ON UPDATE CURRENT_TIMESTAMP(), \
		`player_points` INT NOT NULL, \
		`player_total_points` INT NOT NULL DEFAULT 0 \
		);");
		SQL_TQuery(g_hDatabase, SQLCallback_CreateUpdateTrigger, query);
	}	
}
public SQLCallback_DBConnect(Handle:db, Handle:hndl, const String:error[], any:data) 
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error connecting to database. %s.", error);
	} 
	else 
	{
		g_hDatabase = hndl;
		CreateDatabaseTables();
	}
}
public SQLCallback_CreatePlayerTable(Handle:db, Handle:hndl, const String:error[], any:data) 
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("Error creating player table. %s.", error);
	} 
	else
	{
		new String:query[512];
		Format(query, sizeof(query), "CREATE TRIGGER IF NOT EXISTS [UpdateLastTime] \
		AFTER UPDATE \
		ON `merx_players` \
		FOR EACH ROW \
		BEGIN \
		UPDATE `merx_players` SET `player_lastseen` = CURRENT_TIMESTAMP WHERE `player_id` = old.`player_id`; \
		END");
		SQL_TQuery(g_hDatabase, SQLCallback_CreateUpdateTrigger, query);
	}
}
public SQLCallback_CreateUpdateTrigger(Handle:db, Handle:hndl, const String:error[], any:data)
{
	if(hndl == INVALID_HANDLE)
	{
		LogError("Error creating update trigger. %s.", error);
	}
	else
	{
		new String:query[256];
		if(g_DatabaseType == DB_MySQL)
		{
			Format(query, sizeof(query), "show fields from `merx_players`;");
			SQL_TQuery(g_hDatabase, SQLCallback_CheckTotalPointsColumn, query);
		}
		else
		{
			Format(query, sizeof(query), "PRAGMA table_info(`merx_players`);");
			SQL_TQuery(g_hDatabase, SQLCallback_CheckTotalPointsColumn, query);
		}
	}
}
public SQLCallback_CheckTotalPointsColumn(Handle:db, Handle:hndl, const String:error[], any:data)
{
	if(hndl == INVALID_HANDLE)
	{	
		LogError("Error checking total points column. %s.", error);
	}
	else
	{
		new String:fieldname[32];
		new field;
		while(SQL_FetchRow(hndl))
		{
			if(g_DatabaseType == DB_MySQL)
			{
				SQL_FieldNameToNum(hndl, "field", field);
			}
			else
			{
				SQL_FieldNameToNum(hndl, "name", field);
			}
			SQL_FetchString(hndl, field, fieldname, sizeof(fieldname));
			if(StrEqual(fieldname, "player_total_points", false))
			{
				g_bHasTotalPointsColumn = true;
				break;
			}
		}
		if(g_bHasTotalPointsColumn)
		{
			NotifyDatabaseReady();
		}
		else
		{
			if(g_DatabaseType == DB_MySQL)
			{
				new String:query[256];
				Format(query, sizeof(query), "ALTER TABLE `merx_players` ADD `player_total_points` INT NOT NULL DEFAULT 0;");
				SQL_TQuery(g_hDatabase, SQLCallback_AddTotalPointsColumn, query);
			}
			else
			{
				LogError("Database missing player_total_points column, please run scripts/merx_update_sqlite.py to fix it.");
				NotifyDatabaseReady();
			}
		}
	}
}
NotifyDatabaseReady()
{
	Call_StartForward(g_hEventOnDatabaseReady);
	Call_PushCell(g_hDatabase);
	Call_PushCell(g_DatabaseType);
	Call_Finish();
}
public SQLCallback_AddTotalPointsColumn(Handle:db, Handle:hndl, const String:error[], any:data)
{
	if(hndl == INVALID_HANDLE)
	{	
		LogError("Error checking total points column. %s.", error);
	}
	else
	{
		new String:query[256];
		Format(query, sizeof(query), "UPDATE `merx_players` SET `player_total_points` = `player_points`  where `player_id` != -1;");
		SQL_TQuery(g_hDatabase, SQLCallback_Void, query);
		NotifyDatabaseReady();
	}
}
public Action:Timer_SavePoints(Handle:timer)
{
	for(new i = 1; i <= MaxClients; i++)
	{
		if(IsValidPlayer(i))
		{
			SaveClientPoints(i);
		}
	}
	CreateTimer(GetConVarFloat(g_hCvarSaveTimer), Timer_SavePoints);
}
public ConVar_Tag(Handle:convar, String:oldValue[], String:newValue[]) 
{
	Format(g_sMerxTag, sizeof(g_sMerxTag), "%s", newValue);
}
public ConVar_DefaultPoints(Handle:convar, String:oldValue[], String:newValue[]) 
{
	new value = StringToInt(newValue);
	if(value == 0) 
	{
		LogError("Invalid value for merx_default_points");
	} 
	else 
	{
		g_iDefaultPoints = value;
	}
}
public Native_GetPlayerID(Handle:plugin, args)
{
	return g_iPlayerID[GetNativeCell(1)];
}
public Native_SavePlayerPoints(Handle:plugin, args)
{
	new client = GetNativeCell(1);
	SaveClientPoints(client);
}
public Native_GivePlayerPoints(Handle:plugin, args) 
{
	new client = GetNativeCell(1);
	SetClientPoints(client, GetClientPoints(client) + GetNativeCell(2));
}
public Native_TakePlayerPoints(Handle:plugin, args) 
{
	new client = GetNativeCell(1);
	SetClientPoints(client, GetClientPoints(client) - GetNativeCell(2));
}
public Native_SetPlayerPoints(Handle:plugin, args) 
{
	SetClientPoints(GetNativeCell(1), GetNativeCell(2));	
}
public Native_GetPlayerPoints(Handle:plugin, args) 
{
	return GetClientPoints(GetNativeCell(1));
}
public Native_GetPlayerTotalPoints(Handle:plugin, args) 
{
	return g_iPlayerTotalPoints[GetNativeCell(1)];
}
public Native_ResetPlayerPoints(Handle:plugin, args) 
{
	SetClientPoints(GetNativeCell(1), g_iDefaultPoints);
}
public Native_GetGame(Handle:plugin, args)
{
	return _:g_Game;
}
SaveClientPoints(client)
{
	if(g_iPlayerID[client] != -1)
	{
		new String:query[256];
		CreatePlayerSaveQuery(client, query, sizeof(query));
		SQL_TQuery(g_hDatabase, SQLCallback_Void, query);
	}
}
SetClientPoints(client, points) 
{
	new Action:result;
	Call_StartForward(g_hEventOnPrePlayerPointChange);
	Call_PushCell(client);
	Call_PushCell(GetClientPoints(client));
	Call_PushCellRef(points);
	Call_Finish(result);
	if(result > Plugin_Handled) 
	{
		return;
	}
	Call_StartForward(g_hEventOnPlayerPointChange);
	Call_PushCell(client);
	Call_PushCell(GetClientPoints(client));
	Call_PushCell(points);
	Call_Finish(result);
	if(result > Plugin_Handled) 
	{
		return;
	}
	new oldpoints = g_iPlayerPoints[client];
	g_iPlayerPoints[client] = points;
	Call_StartForward(g_hEventOnPlayerPointChanged);
	Call_PushCell(client);
	Call_PushCell(oldpoints);
	Call_PushCell(points);
	Call_Finish();
	if(points > oldpoints)
	{
		g_iPlayerTotalPoints[client] += (points - oldpoints);
	}
}
CreatePlayerSaveQuery(client, String:query[], size)
{
	new String:szName[MAX_NAME_LENGTH * 2 + 1];
	GetClientName(client, szName, sizeof(szName));
	SQL_EscapeString(g_hDatabase, szName, szName, sizeof(szName));
	if(g_bHasTotalPointsColumn)
	{
		Format(query, size, "UPDATE `merx_players` SET `player_points` = '%d', `player_total_points` = '%d', `player_name` = '%s' WHERE `player_id` = '%d';", g_iPlayerPoints[client], g_iPlayerTotalPoints[client], szName, g_iPlayerID[client]);
	}
	else
	{
		Format(query, size, "UPDATE `merx_players` SET `player_points` = '%d', `player_name` = '%s' WHERE `player_id` = '%d';", g_iPlayerPoints[client], szName, g_iPlayerID[client]);
	}
}
GetClientPoints(client) 
{
	return g_iPlayerPoints[client];
}
FindGameType()
{
	new String:folderName[32];
	GetGameFolderName(folderName, sizeof(folderName));
	if(StrEqual(folderName, "cstrike"))
	{
		g_Game = Game_CSS;
	}
	else if(StrEqual(folderName, "csgo"))
	{
		g_Game = Game_CSGO;
	}
	else if(StrEqual(folderName, "dod"))
	{
		g_Game = Game_DOD;
	}
	else if(StrEqual(folderName, "left4dead"))
	{
		g_Game = Game_L4D;
	}
	else if(StrEqual(folderName, "left4dead2"))
	{
		g_Game = Game_L4D2;
	}
	else if(StrEqual(folderName, "tf"))
	{
		g_Game = Game_TF2;
	}
	else if(StrEqual(folderName, "nucleardawn"))
	{
		g_Game = Game_ND;
	}
	else if(StrEqual(folderName, "hl2mp"))
	{
		g_Game = Game_HLDM;
	}
}
public Native_MerxPrintToChatAll(Handle:plugin, numParams)
{
	new String:szBuffer[1024];
	FormatNativeString(0, 1, 2, sizeof(szBuffer), _, szBuffer);
	Client_PrintToChatAll(true, " %s %s", g_sMerxTag, szBuffer);
}
public Native_MerxPrintToChat(Handle:plugin, numParams)
{
	new String:szBuffer[1024];
	FormatNativeString(0, 2, 3, sizeof(szBuffer), _, szBuffer);
	Client_PrintToChat(GetNativeCell(1), true, " %s %s", g_sMerxTag, szBuffer);
}
public Native_MerxReplyToCommand(Handle:plugin, numParams)
{
	new String:szBuffer[1024];
	FormatNativeString(0, 2, 3, sizeof(szBuffer), _, szBuffer);
	Client_Reply(GetNativeCell(1), " %s %s", g_sMerxTag, szBuffer);
}





