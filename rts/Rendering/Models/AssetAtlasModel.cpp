/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "AssetAtlasModel.hpp"

#include <limits>

#include "3DModel.hpp"
#include "3DModelPiece.hpp"
#include "Rendering/GL/myGL.h"
#include "System/Misc/TracyDefs.h"

AssetAtlasModel::AssetAtlasModel(const S3DModel* atlas)
	: atlas(atlas)
{}

void AssetAtlasModel::SetAtlas(const S3DModel* newAtlas)
{
	atlas = newAtlas;
	Clear();
}

bool AssetAtlasModel::AddPiece(size_t atlasPieceIndex, const Transform& transform)
{
	if (atlas == nullptr || atlasPieceIndex >= atlas->pieceObjects.size())
		return false;

	pieces.push_back({atlas->GetPiece(atlasPieceIndex), transform, true});
	boundsDirty = true;
	return true;
}

bool AssetAtlasModel::AddPiece(const std::string& atlasPieceName, const Transform& transform)
{
	if (atlas == nullptr)
		return false;

	const S3DModelPiece* piece = atlas->FindPiece(atlasPieceName);
	if (piece == nullptr)
		return false;

	pieces.push_back({piece, transform, true});
	boundsDirty = true;
	return true;
}

void AssetAtlasModel::Clear()
{
	pieces.clear();
	mins = ZeroVector;
	maxs = ZeroVector;
	boundsDirty = false;
	hasBounds = false;
}

const AssetAtlasPiece* AssetAtlasModel::GetPiece(size_t index) const
{
	return (index < pieces.size()) ? &pieces[index] : nullptr;
}

bool AssetAtlasModel::SetPieceTransform(size_t index, const Transform& transform)
{
	if (index >= pieces.size())
		return false;

	pieces[index].transform = transform;
	boundsDirty = true;
	return true;
}

bool AssetAtlasModel::SetPieceVisible(size_t index, bool visible)
{
	if (index >= pieces.size())
		return false;

	if (pieces[index].visible != visible) {
		pieces[index].visible = visible;
		boundsDirty = true;
	}

	return true;
}

bool AssetAtlasModel::HasBounds() const
{
	UpdateBounds();
	return hasBounds;
}

const float3& AssetAtlasModel::GetMins() const
{
	UpdateBounds();
	return mins;
}

const float3& AssetAtlasModel::GetMaxs() const
{
	UpdateBounds();
	return maxs;
}

float3 AssetAtlasModel::GetMidPos() const
{
	UpdateBounds();
	return (mins + maxs) * 0.5f;
}

float AssetAtlasModel::GetDrawRadius() const
{
	UpdateBounds();
	return (maxs - mins).Length() * 0.5f;
}

void AssetAtlasModel::UpdateBounds() const
{
	if (!boundsDirty)
		return;

	const float maxFloat = std::numeric_limits<float>::max();
	float3 newMins(maxFloat, maxFloat, maxFloat);
	float3 newMaxs(-maxFloat, -maxFloat, -maxFloat);
	bool foundGeometry = false;

	for (const AssetAtlasPiece& atlasPiece: pieces) {
		const S3DModelPiece* geometry = atlasPiece.geometry;
		if (!atlasPiece.visible || geometry == nullptr || !geometry->HasGeometryData())
			continue;

		const float3& pieceMins = geometry->mins;
		const float3& pieceMaxs = geometry->maxs;
		const float3 corners[8] = {
			{pieceMins.x, pieceMins.y, pieceMins.z},
			{pieceMaxs.x, pieceMins.y, pieceMins.z},
			{pieceMaxs.x, pieceMins.y, pieceMaxs.z},
			{pieceMins.x, pieceMins.y, pieceMaxs.z},
			{pieceMins.x, pieceMaxs.y, pieceMins.z},
			{pieceMaxs.x, pieceMaxs.y, pieceMins.z},
			{pieceMaxs.x, pieceMaxs.y, pieceMaxs.z},
			{pieceMins.x, pieceMaxs.y, pieceMaxs.z},
		};

		for (const float3& corner: corners) {
			const float3 transformedCorner = atlasPiece.transform * corner;
			newMins = float3::min(newMins, transformedCorner);
			newMaxs = float3::max(newMaxs, transformedCorner);
		}

		foundGeometry = true;
	}

	hasBounds = foundGeometry;
	mins = foundGeometry ? newMins : ZeroVector;
	maxs = foundGeometry ? newMaxs : ZeroVector;
	boundsDirty = false;
}

void AssetAtlasModel::DrawLegacy() const
{
	RECOIL_DETAILED_TRACY_ZONE;
	S3DModelHelpers::BindLegacyAttrVBOs();

	for (const AssetAtlasPiece& atlasPiece: pieces) {
		const S3DModelPiece* geometry = atlasPiece.geometry;
		if (!atlasPiece.visible || geometry == nullptr || !geometry->HasGeometryData())
			continue;

		glPushMatrix();
		glMultMatrixf(atlasPiece.transform.ToMatrix());
		geometry->DrawElements();
		glPopMatrix();
	}

	S3DModelHelpers::UnbindLegacyAttrVBOs();
}
