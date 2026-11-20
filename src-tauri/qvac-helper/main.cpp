// Long-lived QVAC Parakeet worker. Handy speaks to it over a Unix socket so
// this process can link qvac-fabric-speech.cpp's ggml without colliding with
// the ggml copy inside transcribe-cpp.
//
// Request:  u32le opcode, u32le byte length, payload
// Response: u32le status (0 ok, 1 error), u32le byte length, payload
//
//   1 LOAD        utf-8 GGUF path -> backend name ("Metal" or "CPU")
//   2 TRANSCRIBE  f32le 16 kHz mono PCM -> utf-8 transcript
//   3 UNLOAD      empty -> "ok"
//   4 QUIT        empty -> process exits
//   5 PING        empty -> "ok"

#include "parakeet/parakeet.h"

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr uint32_t kLoad = 1;
constexpr uint32_t kTranscribe = 2;
constexpr uint32_t kUnload = 3;
constexpr uint32_t kQuit = 4;
constexpr uint32_t kPing = 5;
constexpr uint32_t kOk = 0;
constexpr uint32_t kErr = 1;
constexpr uint32_t kMaxPayload = 256u * 1024u * 1024u;

bool read_full(int fd, void* buf, size_t n) {
    auto* out = static_cast<uint8_t*>(buf);
    size_t got = 0;
    while (got < n) {
        const ssize_t nread = ::read(fd, out + got, n - got);
        if (nread == 0) {
            return false;
        }
        if (nread < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        got += static_cast<size_t>(nread);
    }
    return true;
}

bool write_full(int fd, const void* buf, size_t n) {
    auto* in = static_cast<const uint8_t*>(buf);
    size_t sent = 0;
    while (sent < n) {
        const ssize_t nwritten = ::write(fd, in + sent, n - sent);
        if (nwritten < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        sent += static_cast<size_t>(nwritten);
    }
    return true;
}

bool read_u32(int fd, uint32_t& value) {
    uint8_t bytes[4];
    if (!read_full(fd, bytes, 4)) {
        return false;
    }
    value = static_cast<uint32_t>(bytes[0]) | (static_cast<uint32_t>(bytes[1]) << 8) |
            (static_cast<uint32_t>(bytes[2]) << 16) | (static_cast<uint32_t>(bytes[3]) << 24);
    return true;
}

bool write_u32(int fd, uint32_t value) {
    uint8_t bytes[4] = {
        static_cast<uint8_t>(value & 0xff),
        static_cast<uint8_t>((value >> 8) & 0xff),
        static_cast<uint8_t>((value >> 16) & 0xff),
        static_cast<uint8_t>((value >> 24) & 0xff),
    };
    return write_full(fd, bytes, 4);
}

bool write_response(int fd, uint32_t status, const std::string& payload) {
    return write_u32(fd, status) && write_u32(fd, static_cast<uint32_t>(payload.size())) &&
           (payload.empty() || write_full(fd, payload.data(), payload.size()));
}

int listen_on(const std::string& path) {
    if (path.size() >= sizeof(sockaddr_un::sun_path)) {
        throw std::runtime_error("socket path is too long");
    }
    ::unlink(path.c_str());
    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        throw std::runtime_error("socket() failed");
    }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path.c_str());
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        throw std::runtime_error(std::string("bind() failed: ") + std::strerror(errno));
    }
    ::chmod(path.c_str(), 0600);
    if (::listen(fd, 1) != 0) {
        ::close(fd);
        throw std::runtime_error("listen() failed");
    }
    return fd;
}

std::optional<parakeet::Engine> load_engine(const std::string& path, std::string& backend_name) {
    const unsigned threads = std::max(1u, std::thread::hardware_concurrency());
    const char* backends[] = {"metal", "cpu"};
    std::string last_error;
    for (const char* backend : backends) {
        try {
            parakeet::EngineOptions opts;
            opts.model_gguf_path = path;
            opts.backend = backend;
            opts.n_threads = static_cast<int>(threads);
            opts.prewarm = true;
            parakeet::Engine engine(opts);
            backend_name = engine.backend_name();
            if (backend_name.empty()) {
                backend_name = backend;
            }
            std::cerr << "loaded " << path << " on " << backend_name << std::endl;
            return engine;
        } catch (const std::exception& ex) {
            last_error = ex.what();
            std::cerr << "backend " << backend << " failed: " << last_error << std::endl;
        }
    }
    throw std::runtime_error(last_error.empty() ? "failed to load model" : last_error);
}

void serve(int client, std::optional<parakeet::Engine>& engine, std::string& backend_name, bool& quit) {
    while (true) {
        uint32_t op = 0;
        uint32_t len = 0;
        if (!read_u32(client, op) || !read_u32(client, len)) {
            return;
        }
        if (len > kMaxPayload) {
            write_response(client, kErr, "payload too large");
            return;
        }
        std::vector<uint8_t> payload(len);
        if (len > 0 && !read_full(client, payload.data(), len)) {
            return;
        }

        try {
            if (op == kPing) {
                if (!write_response(client, kOk, "ok")) {
                    return;
                }
                continue;
            }
            if (op == kQuit) {
                write_response(client, kOk, "bye");
                quit = true;
                return;
            }
            if (op == kUnload) {
                engine.reset();
                backend_name.clear();
                if (!write_response(client, kOk, "ok")) {
                    return;
                }
                continue;
            }
            if (op == kLoad) {
                const std::string path(payload.begin(), payload.end());
                engine.reset();
                backend_name.clear();
                engine = load_engine(path, backend_name);
                if (!write_response(client, kOk, backend_name)) {
                    return;
                }
                continue;
            }
            if (op == kTranscribe) {
                if (!engine) {
                    if (!write_response(client, kErr, "no model loaded")) {
                        return;
                    }
                    continue;
                }
                if (len % sizeof(float) != 0) {
                    if (!write_response(client, kErr, "PCM length is not a multiple of 4")) {
                        return;
                    }
                    continue;
                }
                const auto n_samples = static_cast<int>(len / sizeof(float));
                if (n_samples == 0) {
                    if (!write_response(client, kOk, "")) {
                        return;
                    }
                    continue;
                }
                const auto* samples = reinterpret_cast<const float*>(payload.data());
                const parakeet::EngineResult result =
                    engine->transcribe_samples(samples, n_samples, 16000);
                std::cerr << "transcribed " << n_samples << " samples in " << result.total_ms
                          << " ms on " << backend_name << std::endl;
                if (!write_response(client, kOk, result.text)) {
                    return;
                }
                continue;
            }
            if (!write_response(client, kErr, "unknown opcode")) {
                return;
            }
        } catch (const std::exception& ex) {
            std::cerr << "request failed: " << ex.what() << std::endl;
            if (!write_response(client, kErr, ex.what())) {
                return;
            }
        }
    }
}

}  // namespace

int main(int argc, char** argv) {
    std::string socket_path;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--socket" && i + 1 < argc) {
            socket_path = argv[++i];
        } else {
            std::cerr << "usage: handy-qvac --socket <path>" << std::endl;
            return 2;
        }
    }
    if (socket_path.empty()) {
        std::cerr << "usage: handy-qvac --socket <path>" << std::endl;
        return 2;
    }

    try {
        const int server = listen_on(socket_path);
        std::cerr << "listening on " << socket_path << std::endl;
        std::optional<parakeet::Engine> engine;
        std::string backend_name;
        bool quit = false;
        while (true) {
            const int client = ::accept(server, nullptr, nullptr);
            if (client < 0) {
                if (errno == EINTR) {
                    continue;
                }
                std::cerr << "accept() failed: " << std::strerror(errno) << std::endl;
                break;
            }
            serve(client, engine, backend_name, quit);
            ::close(client);
            if (quit) {
                break;
            }
        }
        ::close(server);
        ::unlink(socket_path.c_str());
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << std::endl;
        return 1;
    }
    return 0;
}
