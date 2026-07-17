/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#pragma once

struct lua_State;

class LuaAssetAtlasModels
{
public:
	static bool PushEntries(lua_State* L);

private:
	static bool CreateMetatable(lua_State* L);

	static int meta_gc(lua_State* L);

	static int CreateAssetAtlas(lua_State* L);
	static int DeleteAssetAtlas(lua_State* L);
	static int AssetAtlasAddPiece(lua_State* L);
	static int AssetAtlasSetPieceTransform(lua_State* L);
	static int AssetAtlasSetPieceVisible(lua_State* L);
	static int AssetAtlasGetPieceCount(lua_State* L);
	static int AssetAtlasGetBounds(lua_State* L);
	static int DrawAssetAtlas(lua_State* L);
};
