#pragma once
#include <stddef.h>
#include <stdint.h>

namespace motu {
constexpr uint16_t vendorID = 0x07fd;
constexpr uint16_t productID = 0x0002;
constexpr uint8_t controlOut = 0x01;
constexpr uint8_t controlIn = 0x82;
constexpr uint8_t audioOut = 0x03;
constexpr uint8_t audioIn = 0x84;
constexpr uint8_t timingIn = 0x85;
constexpr uint32_t firmwareRegister = 0xf0000000;
constexpr uint32_t guidRegister = 0xf0000004;

enum class Error {
    none, truncated, malformed, unsupported, capacity, wrongSequence,
    wrongOperation, wrongAddress, deviceStatus
};
const char* errorText(Error e);
uint16_t readLE16(const uint8_t* p);
uint32_t readLE32(const uint8_t* p);
uint32_t readBE32(const uint8_t* p);
void writeLE32(uint8_t* p, uint32_t value);

struct Endpoint {
    uint8_t address = 0, attributes = 0, interval = 0;
    uint16_t maxPacket = 0;
    uint16_t payloadBytes() const { return maxPacket & 0x7ff; }
    uint8_t transactions() const { return 1 + ((maxPacket >> 11) & 3); }
    uint32_t capacity() const { return payloadBytes() * transactions(); }
    uint8_t transferType() const { return attributes & 3; }
};
struct Alternate {
    uint8_t interfaceNumber = 0, number = 0, interfaceClass = 0;
    uint8_t subclass = 0, protocol = 0, endpointCount = 0;
    Endpoint endpoints[16]{};
    const Endpoint* endpoint(uint8_t address) const;
};
struct Configuration {
    uint8_t value = 0, interfaceCount = 0, alternateCount = 0;
    uint16_t totalBytes = 0;
    Alternate alternates[16]{};
    const Alternate* alternate(uint8_t number) const;
};
// Bounded, allocation-free parsing shared by the probe and DriverKit target.
Error parseConfiguration(const uint8_t* data, size_t length, Configuration& result);
Error validate828x(const Configuration& config);

struct Command {
    uint8_t bytes[256]{};
    uint16_t length = 0;
};
Command readRegister(uint8_t sequence, uint32_t address);
Command writeRegister(uint8_t sequence, uint32_t address, uint32_t value);
struct Reply {
    uint8_t sequence = 0, operation = 0, status = 0;
    uint32_t address = 0, value = 0;
};
// Formats recovered from local driver 1.6. On-device validation is pending.
Error parseReply(const uint8_t* bytes, size_t length, Reply& reply);
// The interrupt pipe can concatenate notifications and register replies, even
// splitting a reply across transfers. Match the full outstanding transaction
// and retain at most eleven bytes between reads; never accept a stale reply.
class RegisterReplyScanner {
public:
    void begin(uint8_t sequence,uint32_t address,bool write) { sequence_=sequence;address_=address;operation_=write?2:6;used_=0; }
    bool feed(const uint8_t* bytes,size_t length,Reply& reply);
private:
    uint8_t bytes_[12]{},sequence_=0,operation_=0;
    uint32_t address_=0;
    size_t used_=0;
};

Error matchReadReply(const Reply& reply, uint8_t sequence, uint32_t address);

// One outstanding command, explicitly bounded. Late/mismatched replies never
// complete a new transaction. Sequence reuse needs transport draining/reconnect.
class ReadTransaction {
public:
    enum class State { idle, waiting, complete, failed };
    bool begin(uint8_t sequence, uint32_t address, uint64_t nowNs, uint64_t timeoutNs);
    Error receive(const uint8_t* bytes, size_t length);
    bool expire(uint64_t nowNs);
    void cancel();
    State state() const { return state_; }
    uint32_t value() const { return value_; }
    Command command() const { return readRegister(sequence_, address_); }
private:
    State state_ = State::idle;
    uint8_t sequence_ = 0;
    uint32_t address_ = 0, value_ = 0;
    uint64_t deadline_ = 0;
};

// Diagnostic decoder: the caller must provide an independently verified layout.
// The experimental 48 kHz hardware profile is defined separately in MOTUStream.hpp.
struct AudioLayout {
    uint16_t frameBytes = 0, pcmOffset = 0, channels = 0, timestampOffset = 0;
    bool bigEndianPCM = true;
};
Error validateLayout(const AudioLayout& layout);
int32_t decode24(const uint8_t* bytes, bool bigEndian);
void encode24(int32_t sample, uint8_t* bytes, bool bigEndian);
Error decodeAudioPacket(const uint8_t* bytes, size_t length, const AudioLayout& layout,
                        int32_t* samples, size_t capacity, size_t& frames);

// Unwrap a device clock without accepting backwards/out-of-order samples.
class TimestampUnwrapper {
public:
    bool push(uint32_t raw, uint64_t& extended);
    void reset() { valid_ = false; last_ = 0; total_ = 0; }
private:
    bool valid_ = false;
    uint32_t last_ = 0;
    uint64_t total_ = 0;
};
}
