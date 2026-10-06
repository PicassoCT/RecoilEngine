/* This file is part of the Recoil engine (GPL v2 or later), see LICENSE.html */

#include "FrameStream.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>

#include "Rendering/GL/myGL.h"
#include "Rendering/GlobalRendering.h"
#include "System/Log/ILog.h"
#include "System/Misc/TracyDefs.h"

namespace {
constexpr std::size_t MAX_DATAGRAM_SIZE = 1200;
constexpr std::size_t HEADER_SIZE = 28;
constexpr std::size_t MAX_PAYLOAD_SIZE = MAX_DATAGRAM_SIZE - HEADER_SIZE;
constexpr std::uint32_t FRAME_MAGIC = 0x4D415253; // "MARS"
constexpr std::uint8_t FRAME_PROTOCOL_VERSION = 1;

double SteadySeconds()
{
	using Clock = std::chrono::steady_clock;
	return std::chrono::duration<double>(Clock::now().time_since_epoch()).count();
}

void PushU16(std::vector<std::uint8_t>& out, std::uint16_t v)
{
	out.push_back((v >> 8) & 0xff);
	out.push_back(v & 0xff);
}

void PushU32(std::vector<std::uint8_t>& out, std::uint32_t v)
{
	out.push_back((v >> 24) & 0xff);
	out.push_back((v >> 16) & 0xff);
	out.push_back((v >> 8) & 0xff);
	out.push_back(v & 0xff);
}

struct QOIPixel {
	std::uint8_t r = 0;
	std::uint8_t g = 0;
	std::uint8_t b = 0;
	std::uint8_t a = 255;

	bool operator==(const QOIPixel& p) const {
		return r == p.r && g == p.g && b == p.b && a == p.a;
	}
	bool operator!=(const QOIPixel& p) const { return !(*this == p); }
};

std::uint8_t QOIHash(const QOIPixel& p)
{
	return (p.r * 3u + p.g * 5u + p.b * 7u + p.a * 11u) % 64u;
}
}

CFrameStream& CFrameStream::GetInstance()
{
	static CFrameStream instance;
	return instance;
}

CFrameStream::~CFrameStream()
{
	Stop();
}

bool CFrameStream::Start(const std::string& host, std::uint16_t port, int width, int height, float fps)
{
	RECOIL_DETAILED_TRACY_ZONE;

	Stop();

	if (host.empty() || port == 0)
		return false;

	outputWidth = std::clamp(width, 64, 1920);
	outputHeight = std::clamp(height, 64, 1080);
	outputFPS = std::clamp(fps, 1.0f, 60.0f);

	try {
		asio::error_code ec;
		const auto address = asio::ip::make_address(host, ec);
		if (ec) {
			LOG_L(L_ERROR, "[FrameStream] invalid target address %s: %s", host.c_str(), ec.message().c_str());
			return false;
		}

		endpoint = asio::ip::udp::endpoint(address, port);
		socket.open(endpoint.protocol(), ec);
		if (ec) {
			LOG_L(L_ERROR, "[FrameStream] failed to open UDP socket: %s", ec.message().c_str());
			return false;
		}

		socket.non_blocking(false, ec);
		if (ec) {
			LOG_L(L_WARNING, "[FrameStream] failed to configure UDP socket: %s", ec.message().c_str());
		}
	} catch (const std::exception& e) {
		LOG_L(L_ERROR, "[FrameStream] start failed: %s", e.what());
		return false;
	}

	{
		std::lock_guard<std::mutex> lock(mutex);
		stopWorker = false;
		framePending = false;
		pendingFrame.clear();
	}

	frameCounter = 0;
	nextCaptureTime = SteadySeconds();
	active = true;
	worker = std::thread(&CFrameStream::WorkerLoop, this);

	LOG("[FrameStream] streaming QOI/RGBA to %s:%u at %dx%d %.1f FPS",
		host.c_str(), port, outputWidth, outputHeight, outputFPS);
	return true;
}

void CFrameStream::Stop()
{
	RECOIL_DETAILED_TRACY_ZONE;

	if (!active && !worker.joinable())
		return;

	active = false;

	{
		std::lock_guard<std::mutex> lock(mutex);
		stopWorker = true;
		framePending = false;
		pendingFrame.clear();
	}
	cv.notify_all();

	if (worker.joinable())
		worker.join();

	asio::error_code ec;
	if (socket.is_open())
		socket.close(ec);

	stopWorker = false;
	LOG("[FrameStream] stopped");
}

void CFrameStream::RenderFrame()
{
	RECOIL_DETAILED_TRACY_ZONE;

	if (!active || globalRendering == nullptr)
		return;

	const double now = SteadySeconds();
	if (now < nextCaptureTime)
		return;

	nextCaptureTime = now + (1.0 / outputFPS);

	const int srcWidth = globalRendering->viewSizeX;
	const int srcHeight = globalRendering->viewSizeY;
	if (srcWidth <= 0 || srcHeight <= 0)
		return;

	std::vector<std::uint8_t> pixels(std::size_t(srcWidth) * std::size_t(srcHeight) * 4u);

	GLint oldPackAlignment = 4;
	glGetIntegerv(GL_PACK_ALIGNMENT, &oldPackAlignment);
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadPixels(
		globalRendering->viewPosX,
		globalRendering->viewPosY,
		srcWidth,
		srcHeight,
		GL_RGBA,
		GL_UNSIGNED_BYTE,
		pixels.data()
	);
	glPixelStorei(GL_PACK_ALIGNMENT, oldPackAlignment);

	{
		std::lock_guard<std::mutex> lock(mutex);
		// Deliberately overwrite an unsent frame: AR needs fresh frames, not a queue.
		pendingFrame = std::move(pixels);
		pendingWidth = srcWidth;
		pendingHeight = srcHeight;
		pendingFrameId = ++frameCounter;
		framePending = true;
	}
	cv.notify_one();
}

void CFrameStream::WorkerLoop()
{
	while (true) {
		std::vector<std::uint8_t> frame;
		int srcWidth = 0;
		int srcHeight = 0;
		std::uint32_t frameId = 0;

		{
			std::unique_lock<std::mutex> lock(mutex);
			cv.wait(lock, [this] { return stopWorker || framePending; });

			if (stopWorker)
				break;

			frame = std::move(pendingFrame);
			srcWidth = pendingWidth;
			srcHeight = pendingHeight;
			frameId = pendingFrameId;
			framePending = false;
		}

		SendFrame(std::move(frame), srcWidth, srcHeight, frameId);
	}
}

void CFrameStream::SendFrame(std::vector<std::uint8_t>&& rgba, int srcWidth, int srcHeight, std::uint32_t frameId)
{
	if (!active || rgba.empty())
		return;

	auto scaled = DownsampleRGBA(rgba, srcWidth, srcHeight, outputWidth, outputHeight);
	auto encoded = EncodeQOI(scaled, outputWidth, outputHeight);
	if (encoded.empty())
		return;

	const std::size_t chunkCountSz = (encoded.size() + MAX_PAYLOAD_SIZE - 1) / MAX_PAYLOAD_SIZE;
	if (chunkCountSz == 0 || chunkCountSz > std::numeric_limits<std::uint16_t>::max()) {
		LOG_L(L_WARNING, "[FrameStream] encoded frame too large: %zu bytes", encoded.size());
		return;
	}

	const auto chunkCount = static_cast<std::uint16_t>(chunkCountSz);

	for (std::uint16_t chunkIndex = 0; chunkIndex < chunkCount && active; ++chunkIndex) {
		const std::size_t offset = std::size_t(chunkIndex) * MAX_PAYLOAD_SIZE;
		const std::size_t payloadSize = std::min(MAX_PAYLOAD_SIZE, encoded.size() - offset);

		std::vector<std::uint8_t> packet;
		packet.reserve(HEADER_SIZE + payloadSize);

		PushU32(packet, FRAME_MAGIC);
		packet.push_back(FRAME_PROTOCOL_VERSION);
		packet.push_back(1); // codec 1 = QOI RGBA
		PushU16(packet, 0); // flags, reserved
		PushU32(packet, frameId);
		PushU16(packet, static_cast<std::uint16_t>(outputWidth));
		PushU16(packet, static_cast<std::uint16_t>(outputHeight));
		PushU16(packet, chunkIndex);
		PushU16(packet, chunkCount);
		PushU32(packet, static_cast<std::uint32_t>(encoded.size()));
		PushU16(packet, static_cast<std::uint16_t>(payloadSize));
		PushU16(packet, 0); // reserved to keep header fixed at 28 bytes

		packet.insert(packet.end(), encoded.begin() + offset, encoded.begin() + offset + payloadSize);

		asio::error_code ec;
		socket.send_to(asio::buffer(packet), endpoint, 0, ec);
		if (ec) {
			LOG_L(L_WARNING, "[FrameStream] UDP send failed: %s", ec.message().c_str());
			break;
		}
	}
}

std::vector<std::uint8_t> CFrameStream::DownsampleRGBA(
	const std::vector<std::uint8_t>& src,
	int srcWidth,
	int srcHeight,
	int dstWidth,
	int dstHeight
) {
	if (srcWidth == dstWidth && srcHeight == dstHeight)
		return src;

	std::vector<std::uint8_t> dst(std::size_t(dstWidth) * std::size_t(dstHeight) * 4u);

	for (int y = 0; y < dstHeight; ++y) {
		const int sy = std::min(srcHeight - 1, (y * srcHeight) / dstHeight);
		for (int x = 0; x < dstWidth; ++x) {
			const int sx = std::min(srcWidth - 1, (x * srcWidth) / dstWidth);
			const std::size_t si = (std::size_t(sy) * srcWidth + sx) * 4u;
			const std::size_t di = (std::size_t(y) * dstWidth + x) * 4u;
			std::memcpy(&dst[di], &src[si], 4);
		}
	}

	return dst;
}

std::vector<std::uint8_t> CFrameStream::EncodeQOI(
	const std::vector<std::uint8_t>& rgba,
	int width,
	int height
) {
	if (rgba.size() != std::size_t(width) * std::size_t(height) * 4u)
		return {};

	std::vector<std::uint8_t> out;
	out.reserve(rgba.size() + 32);

	out.push_back('q'); out.push_back('o'); out.push_back('i'); out.push_back('f');
	PushU32(out, static_cast<std::uint32_t>(width));
	PushU32(out, static_cast<std::uint32_t>(height));
	out.push_back(4); // RGBA
	out.push_back(0); // sRGB with linear alpha

	std::array<QOIPixel, 64> index {};
	QOIPixel prev {};
	prev.a = 255;
	int run = 0;

	const std::size_t pixelCount = std::size_t(width) * std::size_t(height);
	for (std::size_t i = 0; i < pixelCount; ++i) {
		const std::size_t p = i * 4u;
		QOIPixel px {rgba[p], rgba[p + 1], rgba[p + 2], rgba[p + 3]};

		if (px == prev) {
			++run;
			if (run == 62 || i == pixelCount - 1) {
				out.push_back(0xC0 | (run - 1));
				run = 0;
			}
			continue;
		}

		if (run > 0) {
			out.push_back(0xC0 | (run - 1));
			run = 0;
		}

		const std::uint8_t idx = QOIHash(px);
		if (index[idx] == px) {
			out.push_back(idx);
		} else {
			index[idx] = px;

			if (px.a == prev.a) {
				const int dr = int(px.r) - int(prev.r);
				const int dg = int(px.g) - int(prev.g);
				const int db = int(px.b) - int(prev.b);

				if (dr >= -2 && dr <= 1 && dg >= -2 && dg <= 1 && db >= -2 && db <= 1) {
					out.push_back(0x40 | ((dr + 2) << 4) | ((dg + 2) << 2) | (db + 2));
				} else {
					const int drdg = dr - dg;
					const int dbdg = db - dg;
					if (dg >= -32 && dg <= 31 && drdg >= -8 && drdg <= 7 && dbdg >= -8 && dbdg <= 7) {
						out.push_back(0x80 | (dg + 32));
						out.push_back(((drdg + 8) << 4) | (dbdg + 8));
					} else {
						out.push_back(0xFE);
						out.push_back(px.r); out.push_back(px.g); out.push_back(px.b);
					}
				}
			} else {
				out.push_back(0xFF);
				out.push_back(px.r); out.push_back(px.g); out.push_back(px.b); out.push_back(px.a);
			}
		}

		prev = px;
	}

	for (int i = 0; i < 7; ++i) out.push_back(0);
	out.push_back(1);
	return out;
}
