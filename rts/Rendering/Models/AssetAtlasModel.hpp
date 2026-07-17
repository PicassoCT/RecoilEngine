/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "System/Transform.hpp"
#include "System/float3.h"

struct S3DModel;
struct S3DModelPiece;

/**
 * A lightweight reference to one piece of an immutable atlas model.
 *
 * Geometry remains owned by the source S3DModel. An assembled model only
 * stores this reference, its placement transform, and instance visibility.
 */
struct AssetAtlasPiece
{
	const S3DModelPiece* geometry = nullptr;
	Transform transform;
	bool visible = true;
};

/**
 * Runtime model assembled from selected pieces of one shared S3DModel.
 *
 * The source model acts as the asset atlas and must outlive this object.
 * Pieces are rigid, independent instances; no source hierarchy is copied.
 * Texture binding remains the responsibility of the owning draw path.
 */
class AssetAtlasModel
{
public:
	explicit AssetAtlasModel(const S3DModel* atlas = nullptr);

	void SetAtlas(const S3DModel* atlas);
	const S3DModel* GetAtlas() const { return atlas; }

	bool AddPiece(size_t atlasPieceIndex, const Transform& transform = Transform{});
	bool AddPiece(const std::string& atlasPieceName, const Transform& transform = Transform{});
	void Clear();

	size_t GetPieceCount() const { return pieces.size(); }
	const AssetAtlasPiece* GetPiece(size_t index) const;

	bool SetPieceTransform(size_t index, const Transform& transform);
	bool SetPieceVisible(size_t index, bool visible);

	bool HasBounds() const;
	const float3& GetMins() const;
	const float3& GetMaxs() const;
	float3 GetMidPos() const;
	float GetDrawRadius() const;

	void DrawLegacy() const;

private:
	void UpdateBounds() const;

private:
	const S3DModel* atlas = nullptr;
	std::vector<AssetAtlasPiece> pieces;

	mutable float3 mins = ZeroVector;
	mutable float3 maxs = ZeroVector;
	mutable bool boundsDirty = true;
	mutable bool hasBounds = false;
};
