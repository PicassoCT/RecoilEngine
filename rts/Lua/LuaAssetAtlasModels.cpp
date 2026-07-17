/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "LuaAssetAtlasModels.h"

#include <memory>

#include "LuaHashString.h"
#include "LuaInclude.h"
#include "LuaOpenGL.h"
#include "Rendering/Common/ModelDrawerHelpers.h"
#include "Rendering/Models/3DModel.hpp"
#include "Rendering/Models/AssetAtlasModel.hpp"
#include "Rendering/Models/IModelParser.h"
#include "System/MathConstants.h"

namespace {
	constexpr const char* ASSET_ATLAS_METATABLE = "AssetAtlasModel";

	struct AssetAtlasUserData {
		std::unique_ptr<AssetAtlasModel> model;
	};

	AssetAtlasUserData* GetAssetAtlasUserData(lua_State* L, int index)
	{
		return static_cast<AssetAtlasUserData*>(luaL_checkudata(L, index, ASSET_ATLAS_METATABLE));
	}

	AssetAtlasModel* GetAssetAtlas(lua_State* L, int index)
	{
		AssetAtlasUserData* userData = GetAssetAtlasUserData(L, index);
		if (userData->model == nullptr)
			luaL_error(L, "attempt to use a deleted AssetAtlasModel");

		return userData->model.get();
	}

	Transform ParseTransform(lua_State* L, int firstArgument)
	{
		const float3 position {
			luaL_optfloat(L, firstArgument + 0, 0.0f),
			luaL_optfloat(L, firstArgument + 1, 0.0f),
			luaL_optfloat(L, firstArgument + 2, 0.0f),
		};
		const float3 rotation {
			luaL_optfloat(L, firstArgument + 3, 0.0f) * math::DEG_TO_RAD,
			luaL_optfloat(L, firstArgument + 4, 0.0f) * math::DEG_TO_RAD,
			luaL_optfloat(L, firstArgument + 5, 0.0f) * math::DEG_TO_RAD,
		};
		const float scale = luaL_optfloat(L, firstArgument + 6, 1.0f);

		return Transform {CQuaternion::FromEulerYPR(rotation), position, scale};
	}

	bool AddAtlasPiece(lua_State* L, AssetAtlasModel* atlas, int pieceArgument, const Transform& transform)
	{
		if (lua_isnumber(L, pieceArgument)) {
			const int pieceIndex = luaL_checkint(L, pieceArgument);
			return (pieceIndex >= 1) && atlas->AddPiece(static_cast<size_t>(pieceIndex - 1), transform);
		}

		return atlas->AddPiece(luaL_checkstring(L, pieceArgument), transform);
	}
}

bool LuaAssetAtlasModels::PushEntries(lua_State* L)
{
	CreateMetatable(L);

	HSTR_PUSH_CFUNC(L, "CreateAssetAtlas", CreateAssetAtlas);
	HSTR_PUSH_CFUNC(L, "DeleteAssetAtlas", DeleteAssetAtlas);
	HSTR_PUSH_CFUNC(L, "AssetAtlasAddPiece", AssetAtlasAddPiece);
	HSTR_PUSH_CFUNC(L, "AssetAtlasSetPieceTransform", AssetAtlasSetPieceTransform);
	HSTR_PUSH_CFUNC(L, "AssetAtlasSetPieceVisible", AssetAtlasSetPieceVisible);
	HSTR_PUSH_CFUNC(L, "AssetAtlasGetPieceCount", AssetAtlasGetPieceCount);
	HSTR_PUSH_CFUNC(L, "AssetAtlasGetBounds", AssetAtlasGetBounds);
	HSTR_PUSH_CFUNC(L, "DrawAssetAtlas", DrawAssetAtlas);

	return true;
}

bool LuaAssetAtlasModels::CreateMetatable(lua_State* L)
{
	luaL_newmetatable(L, ASSET_ATLAS_METATABLE);
	HSTR_PUSH_CFUNC(L, "__gc", meta_gc);
	lua_pop(L, 1);
	return true;
}

int LuaAssetAtlasModels::meta_gc(lua_State* L)
{
	AssetAtlasUserData* userData = GetAssetAtlasUserData(L, 1);
	std::destroy_at(userData);
	return 0;
}

/***
 * Create a runtime model backed by a shared model atlas.
 *
 * @function gl.CreateAssetAtlas
 * @param modelName string
 * @return AssetAtlasModel atlas
 */
int LuaAssetAtlasModels::CreateAssetAtlas(lua_State* L)
{
	const S3DModel* sourceModel = modelLoader.LoadModel(luaL_checkstring(L, 1));
	if (sourceModel == nullptr)
		return 0;

	void* storage = lua_newuserdata(L, sizeof(AssetAtlasUserData));
	std::construct_at(static_cast<AssetAtlasUserData*>(storage), AssetAtlasUserData {
		std::make_unique<AssetAtlasModel>(sourceModel)
	});

	luaL_getmetatable(L, ASSET_ATLAS_METATABLE);
	lua_setmetatable(L, -2);
	return 1;
}

/***
 * Explicitly release an asset atlas. Garbage collection also releases it.
 *
 * @function gl.DeleteAssetAtlas
 * @param atlas AssetAtlasModel
 */
int LuaAssetAtlasModels::DeleteAssetAtlas(lua_State* L)
{
	GetAssetAtlasUserData(L, 1)->model.reset();
	return 0;
}

/***
 * Add an independent rigid piece. Piece numbers are one-based.
 * Rotation is specified in degrees.
 *
 * @function gl.AssetAtlasAddPiece
 * @param atlas AssetAtlasModel
 * @param piece string|integer
 * @param x number? (Default: 0)
 * @param y number? (Default: 0)
 * @param z number? (Default: 0)
 * @param rotX number? (Default: 0)
 * @param rotY number? (Default: 0)
 * @param rotZ number? (Default: 0)
 * @param scale number? (Default: 1)
 * @return integer? assembledPieceIndex
 */
int LuaAssetAtlasModels::AssetAtlasAddPiece(lua_State* L)
{
	AssetAtlasModel* atlas = GetAssetAtlas(L, 1);
	if (!AddAtlasPiece(L, atlas, 2, ParseTransform(L, 3)))
		return 0;

	lua_pushnumber(L, atlas->GetPieceCount());
	return 1;
}

/***
 * Replace an assembled piece transform. Indices are one-based.
 *
 * @function gl.AssetAtlasSetPieceTransform
 * @param atlas AssetAtlasModel
 * @param assembledPieceIndex integer
 * @param x number? (Default: 0)
 * @param y number? (Default: 0)
 * @param z number? (Default: 0)
 * @param rotX number? (Default: 0)
 * @param rotY number? (Default: 0)
 * @param rotZ number? (Default: 0)
 * @param scale number? (Default: 1)
 * @return boolean success
 */
int LuaAssetAtlasModels::AssetAtlasSetPieceTransform(lua_State* L)
{
	AssetAtlasModel* atlas = GetAssetAtlas(L, 1);
	const int pieceIndex = luaL_checkint(L, 2);
	const bool success = (pieceIndex >= 1) && atlas->SetPieceTransform(pieceIndex - 1, ParseTransform(L, 3));
	lua_pushboolean(L, success);
	return 1;
}

/***
 * Set assembled piece visibility. Indices are one-based.
 *
 * @function gl.AssetAtlasSetPieceVisible
 * @param atlas AssetAtlasModel
 * @param assembledPieceIndex integer
 * @param visible boolean
 * @return boolean success
 */
int LuaAssetAtlasModels::AssetAtlasSetPieceVisible(lua_State* L)
{
	AssetAtlasModel* atlas = GetAssetAtlas(L, 1);
	const int pieceIndex = luaL_checkint(L, 2);
	const bool success = (pieceIndex >= 1) && atlas->SetPieceVisible(pieceIndex - 1, luaL_checkboolean(L, 3));
	lua_pushboolean(L, success);
	return 1;
}

/***
 * @function gl.AssetAtlasGetPieceCount
 * @param atlas AssetAtlasModel
 * @return integer pieceCount
 */
int LuaAssetAtlasModels::AssetAtlasGetPieceCount(lua_State* L)
{
	lua_pushnumber(L, GetAssetAtlas(L, 1)->GetPieceCount());
	return 1;
}

/***
 * Return the visible assembled bounds, or nil when no visible geometry exists.
 *
 * @function gl.AssetAtlasGetBounds
 * @param atlas AssetAtlasModel
 * @return number? minX
 * @return number? minY
 * @return number? minZ
 * @return number? maxX
 * @return number? maxY
 * @return number? maxZ
 */
int LuaAssetAtlasModels::AssetAtlasGetBounds(lua_State* L)
{
	AssetAtlasModel* atlas = GetAssetAtlas(L, 1);
	if (!atlas->HasBounds())
		return 0;

	const float3& mins = atlas->GetMins();
	const float3& maxs = atlas->GetMaxs();
	lua_pushnumber(L, mins.x);
	lua_pushnumber(L, mins.y);
	lua_pushnumber(L, mins.z);
	lua_pushnumber(L, maxs.x);
	lua_pushnumber(L, maxs.y);
	lua_pushnumber(L, maxs.z);
	return 6;
}

/***
 * Draw the assembled model at the current matrix transform.
 *
 * @function gl.DrawAssetAtlas
 * @param atlas AssetAtlasModel
 * @param bindModelState boolean? (Default: true)
 */
int LuaAssetAtlasModels::DrawAssetAtlas(lua_State* L)
{
	if (!LuaOpenGL::IsDrawingEnabled(L))
		luaL_error(L, "gl.DrawAssetAtlas can only be called while drawing is enabled");

	AssetAtlasModel* atlas = GetAssetAtlas(L, 1);
	const S3DModel* sourceModel = atlas->GetAtlas();
	const bool bindModelState = luaL_optboolean(L, 2, true);

	if (bindModelState)
		CModelDrawerHelper::PushModelRenderState(sourceModel);

	atlas->DrawLegacy();

	if (bindModelState)
		CModelDrawerHelper::PopModelRenderState(sourceModel);

	return 0;
}
