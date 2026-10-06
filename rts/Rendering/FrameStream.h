/* This file is part of the Recoil engine (GPL v2 or later), see LICENSE.html */

#ifndef FRAME_STREAM_H
#define FRAME_STREAM_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <asio/io_context.hpp>
#include <asio/ip/udp.hpp>

class CFrameStream {
public:
	static CFrameStream& GetInstance();

	bool Start(const std::string& host, std::uint16_t port, int width, int height, float fps);
	void Stop();
	void RenderFrame();

	bool IsActive() const { return active; }

private:
	CFrameStream() = default;
	~CFrameStream();
	CFrameStream(const CFrameStream&) = delete;
	CFrameStream& operator=(const CFrameStream&) = delete;

	void WorkerLoop();
	void SendFrame(std::vector<std::uint8_t>&& rgba, int srcWidth, int srcHeight, std::uint32_t frameId);

	static std::vector<std::uint8_t> DownsampleRGBA(
		const std::vector<std::uint8_t>& src,
		int srcWidth,
		int srcHeight,
		int dstWidth,
		int dstHeight
	);
	static std::vector<std::uint8_t> EncodeQOI(
		const std::vector<std::uint8_t>& rgba,
		int width,
		int height
	);

private:
	asio::io_context ioContext;
	asio::ip::udp::socket socket {ioContext};
	asio::ip::udp::endpoint endpoint;

	std::thread worker;
	mutable std::mutex mutex;
	std::condition_variable cv;

	std::vector<std::uint8_t> pendingFrame;
	int pendingWidth = 0;
	int pendingHeight = 0;
	std::uint32_t pendingFrameId = 0;
	bool framePending = false;
	bool stopWorker = false;
	std::atomic_bool active {false};

	int outputWidth = 640;
	int outputHeight = 360;
	float outputFPS = 20.0f;
	double nextCaptureTime = 0.0;
	std::uint32_t frameCounter = 0;
};

#endif // FRAME_STREAM_H
